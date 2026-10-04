import Foundation
import IsoDocument
import IsoGeometry
import IsoMath
import IsoRender
import Observation

nonisolated struct RunKey: Hashable, Sendable {
    var ops: [Op]
    var rotation: Vec3
    var angle: Double
    var smooth: Double

    /// Rotations are cached to the half degree, like the web Studio.
    init(ops: [Op], rotation: Vec3, angle: Double, smooth: Double) {
        func norm(_ a: Double) -> Double {
            let v = ((a + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180
            return jsRound(v * 2) / 2
        }
        self.ops = ops
        self.rotation = Vec3(norm(rotation.x), norm(rotation.y), norm(rotation.z))
        self.angle = angle
        self.smooth = smooth
    }

    func options(_ mesh: PreparedMesh) -> RenderOptions {
        RenderOptions(rotation: rotation, pivot: mesh.bounds.center, angle: IsoAngle(degrees: angle), smooth: smooth)
    }
}

/// Small insertion-ordered cache that drops the least recently used entry.
nonisolated struct LRUCache<Key: Hashable, Value> {
    private var store: [Key: Value] = [:]
    private var order: [Key] = []
    let limit: Int

    init(limit: Int) { self.limit = limit }

    mutating func get(_ key: Key) -> Value? {
        guard let v = store[key] else { return nil }
        if let i = order.lastIndex(of: key), i != order.count - 1 {
            order.remove(at: i)
            order.append(key)
        }
        return v
    }

    mutating func set(_ key: Key, _ value: Value) {
        if store.updateValue(value, forKey: key) == nil { order.append(key) }
        while order.count > limit { store[order.removeFirst()] = nil }
    }
}

/// Evaluates and renders parts off the main actor. Callers ask for what they
/// need each frame; missing results are scheduled and the last good result is
/// returned meanwhile, so editing and playback never block or flicker.
@Observable
final class BuildService {
    /// Bumped whenever a build lands, so views redraw.
    private(set) var generation = 0
    private(set) var errors: [Part.ID: String] = [:]
    private(set) var isBuilding = false

    @ObservationIgnored private var meshCache = LRUCache<[Op], PreparedMesh>(limit: 120)
    @ObservationIgnored private var runCache = LRUCache<RunKey, [Run]>(limit: 1500)
    @ObservationIgnored private var lastMesh: [Part.ID: PreparedMesh] = [:]
    @ObservationIgnored private var lastRuns: [Part.ID: [Run]] = [:]
    @ObservationIgnored private var meshJobs: [Part.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var runJobs: [Part.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var wantedMesh: [Part.ID: [Op]] = [:]
    @ObservationIgnored private var wantedRuns: [Part.ID: RunKey] = [:]

    /// The evaluated mesh for a part, or the last one that built.
    func mesh(for part: Part) -> PreparedMesh? {
        if let m = meshCache.get(part.ops) {
            lastMesh[part.id] = m
            return m
        }
        requestMesh(part.id, part.ops)
        return lastMesh[part.id]
    }

    /// Exact cached mesh for some ops, without scheduling anything.
    func cachedMesh(_ ops: [Op]) -> PreparedMesh? { meshCache.get(ops) }

    /// Draw-ordered screen runs for a part at a rotation, or the last ones.
    func runs(for part: Part, rotation: Vec3, angle: Double) -> [Run]? {
        let key = RunKey(ops: part.ops, rotation: rotation, angle: angle, smooth: part.smooth)
        if let r = runCache.get(key) {
            lastRuns[part.id] = r
            return r
        }
        if let mesh = meshCache.get(part.ops) { requestRuns(part.id, key, mesh) } else { requestMesh(part.id, part.ops, runs: key) }
        return lastRuns[part.id]
    }

    /// Builds a part's mesh right away (used by export).
    func meshNow(for part: Part) -> PreparedMesh? {
        if let m = meshCache.get(part.ops) { return m }
        guard let m = try? PreparedMesh.build(part.ops) else { return lastMesh[part.id] }
        meshCache.set(part.ops, m)
        return m
    }

    /// Builds a part's runs right away (used by export).
    func runsNow(for part: Part, rotation: Vec3, angle: Double) -> [Run] {
        let key = RunKey(ops: part.ops, rotation: rotation, angle: angle, smooth: part.smooth)
        if let r = runCache.get(key) { return r }
        guard let mesh = meshCache.get(part.ops) ?? (try? PreparedMesh.build(part.ops)) else { return [] }
        meshCache.set(part.ops, mesh)
        let r = (try? Renderer.render(mesh, options: key.options(mesh))) ?? []
        runCache.set(key, r)
        return r
    }

    func forget(_ id: Part.ID) {
        lastMesh[id] = nil
        lastRuns[id] = nil
        errors[id] = nil
    }

    private func refreshBuilding() {
        let busy = !meshJobs.isEmpty || !runJobs.isEmpty
        if busy != isBuilding { isBuilding = busy }
    }

    /// Live composition: cached results now, builds scheduled for the rest.
    func composer(immediate: Bool = false) -> FrameComposer {
        FrameComposer(
            mesh: { [self] p in immediate ? meshNow(for: p) : mesh(for: p) },
            runs: { [self] p, rot, angle in
                immediate ? runsNow(for: p, rotation: rot, angle: angle.degrees) : runs(for: p, rotation: rot, angle: angle.degrees)
            },
            failed: { [self] id in errors[id] != nil })
    }

    /// Meshes already built for a scene, to start a background export with.
    func builtMeshes(_ scene: SceneFile) -> [[Op]: PreparedMesh] {
        var out: [[Op]: PreparedMesh] = [:]
        for p in scene.parts { if let m = meshCache.get(p.ops) { out[p.ops] = m } }
        return out
    }

    /// Builds a mesh; with `runs`, also renders it at that pose in the same job,
    /// so an edited part reaches the canvas in one trip instead of two.
    private func requestMesh(_ id: Part.ID, _ ops: [Op], runs key: RunKey? = nil) {
        wantedMesh[id] = ops
        if let key { wantedRuns[id] = key }
        guard meshJobs[id] == nil else { return }
        let pose = key.flatMap { $0.ops == ops ? $0 : nil }
        meshJobs[id] = Task(priority: .userInitiated) { [weak self] in
            let result = await Self.build(ops, pose: pose)
            self?.finishMesh(id, ops, pose, result)
        }
        refreshBuilding()
    }

    @concurrent
    private static func build(_ ops: [Op], pose: RunKey?) async -> Result<(PreparedMesh, [Run]?), Error> {
        Result {
            let mesh = try PreparedMesh.build(ops)
            let runs = pose.map { (try? Renderer.render(mesh, options: $0.options(mesh))) ?? [] }
            return (mesh, runs)
        }
    }

    @concurrent
    private static func render(_ mesh: PreparedMesh, _ options: RenderOptions) async -> [Run] {
        (try? Renderer.render(mesh, options: options)) ?? []
    }

    private func finishMesh(_ id: Part.ID, _ ops: [Op], _ pose: RunKey?, _ result: Result<(PreparedMesh, [Run]?), Error>) {
        meshJobs[id] = nil
        switch result {
        case .success(let (mesh, runs)):
            meshCache.set(ops, mesh)
            errors[id] = mesh.isEmpty ? "This part has no geometry." : nil
            if !mesh.isEmpty { lastMesh[id] = mesh }
            if let runs, let pose {
                runCache.set(pose, runs)
                lastRuns[id] = runs
                if wantedRuns[id] == pose { wantedRuns[id] = nil }
            }
        case .failure(let error):
            errors[id] = error.localizedDescription
        }
        if let next = wantedMesh[id], next != ops, meshCache.get(next) == nil {
            requestMesh(id, next, runs: wantedRuns[id])
        } else {
            wantedMesh[id] = nil
        }
        refreshBuilding()
        generation &+= 1
    }

    private func requestRuns(_ id: Part.ID, _ key: RunKey, _ mesh: PreparedMesh) {
        wantedRuns[id] = key
        guard runJobs[id] == nil else { return }
        let options = key.options(mesh)
        runJobs[id] = Task(priority: .userInitiated) { [weak self] in
            let result = await Self.render(mesh, options)
            self?.finishRuns(id, key, result)
        }
        refreshBuilding()
    }

    private func finishRuns(_ id: Part.ID, _ key: RunKey, _ result: [Run]) {
        runJobs[id] = nil
        runCache.set(key, result)
        lastRuns[id] = result
        if let next = wantedRuns[id], next != key, runCache.get(next) == nil, let mesh = meshCache.get(next.ops) {
            requestRuns(id, next, mesh)
        } else {
            wantedRuns[id] = nil
        }
        refreshBuilding()
        generation &+= 1
    }
}

/// Synchronous geometry for background work (video export): its own caches,
/// seeded from what the editor already built. Use from one task at a time.
nonisolated final class OfflineGeometry: @unchecked Sendable {
    private var meshes: [[Op]: PreparedMesh]
    private var runCache = LRUCache<RunKey, [Run]>(limit: 600)
    private var failures: Set<[Op]> = []

    init(seed: [[Op]: PreparedMesh] = [:]) { meshes = seed }

    func mesh(_ part: Part) -> PreparedMesh? {
        if let m = meshes[part.ops] { return m }
        guard !failures.contains(part.ops) else { return nil }
        guard let m = try? PreparedMesh.build(part.ops), !m.isEmpty else {
            failures.insert(part.ops)
            return nil
        }
        meshes[part.ops] = m
        return m
    }

    func runs(_ part: Part, _ rotation: Vec3, _ angle: IsoAngle) -> [Run]? {
        let key = RunKey(ops: part.ops, rotation: rotation, angle: angle.degrees, smooth: part.smooth)
        if let r = runCache.get(key) { return r }
        guard let m = mesh(part) else { return nil }
        let r = (try? Renderer.render(m, options: key.options(m))) ?? []
        runCache.set(key, r)
        return r
    }

    var composer: FrameComposer {
        FrameComposer(
            mesh: { [self] in mesh($0) }, runs: { [self] in runs($0, $1, $2) },
            failed: { _ in true })
    }
}
