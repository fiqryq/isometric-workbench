import AppKit
import IsoDocument
import IsoExamples
import IsoGeometry
import IsoMath
import IsoRender
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct PickedFace: Hashable {
    var partID: Part.ID
    var face: FaceID
}

/// Editor state for one document window. Every change to `scene` goes
/// through `edit` (or a gesture) so it can be undone.
@Observable
final class SceneModel {
    var scene: SceneFile {
        didSet { snapshot.value = scene }
    }
    var selection: Set<Part.ID> = [] {
        didSet { if !selection.isEmpty { selectedFrames = [] } }
    }
    /// Selected frames. A marquee can pick frames and loose parts together;
    /// set `selectedFrames` after `selection` to keep both.
    var selectedFrames: Set<Artboard.ID> = []
    /// The frame the inspector edits: set when one frame and nothing else is picked.
    var selectedFrame: Artboard.ID? {
        get { selectedFrames.count == 1 && selection.isEmpty ? selectedFrames.first : nil }
        set { selectedFrames = newValue.map { [$0] } ?? [] }
    }
    var pickedFaces: [PickedFace] = []
    var status = "Ready"

    var tool: Tool = .select {
        didSet { if tool != oldValue { toolChanged(from: oldValue) } }
    }
    /// Plane new world-space sketches sit on when no face is under the pointer.
    var drawPlane: IsoPlane = .top
    var polygonSides = 6
    /// A finished outline waiting for Extrude / Push / Revolve / Keep.
    var sketch: PendingSketch?
    var annotation: AnnotationRef? {
        didSet { if annotation != nil { selectedFrames = [] } }
    }
    var pickedRings: [RingPick] = []
    var pickedSegments: [SegmentPick] = []
    /// Keys picked in the timeline.
    var pickedKeys: Set<KeyRef> = []
    var presentVideoExport = false
    var presentPaywall = false

    var time = 0.0
    private(set) var isPlaying = false
    var loops = true
    var autoKey = false

    /// Canvas zoom and pan (screen points).
    var zoom = 1.0
    var pan = Vec2.zero

    let build = BuildService()
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored var viewportSize = CGSize(width: 800, height: 600)
    /// Zoom and pan each page was left at, restored when it comes back.
    @ObservationIgnored var pageViews: [Page.ID: (zoom: Double, pan: Vec2)] = [:]
    @ObservationIgnored private var gestureStart: SceneFile?
    /// Set while a live edit runs: the first edit's undo name, or empty before one.
    @ObservationIgnored private var liveEditName: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var playStart = 0.0
    @ObservationIgnored private let snapshot: SceneSnapshot

    init(scene: SceneFile, snapshot: SceneSnapshot) {
        self.scene = scene
        self.snapshot = snapshot
    }

    // MARK: - Frames

    /// Time snapped to the document's frame rate.
    var frameTime: Double { (time * scene.fps).rounded(.down) / scene.fps }

    func frame(at t: Double? = nil, immediate: Bool = false) -> Frame {
        build.composer(immediate: immediate).compose(scene, at: t ?? frameTime)
    }

    var selectedParts: [Part] { scene.parts.filter { selection.contains($0.id) } }

    var selectedIndex: Int? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return scene.partIndex(id)
    }

    // MARK: - Undo

    func edit(_ name: String, _ body: (inout SceneFile) -> Void) {
        if let live = liveEditName {
            if live.isEmpty { liveEditName = name }
            return updateGesture(body)
        }
        let old = scene
        body(&scene)
        guard scene != old else { return }
        registerUndo(old, name)
    }

    /// Starts a slider or scrub drag: every edit lands on the canvas at once,
    /// and the whole drag undoes as one step.
    func beginLiveEdit() {
        liveEditName = ""
        beginGesture()
    }

    func endLiveEdit() {
        guard let name = liveEditName else { return }
        liveEditName = nil
        endGesture(name.isEmpty ? "Edit" : name)
    }

    func beginGesture() {
        if gestureStart == nil { gestureStart = scene }
    }

    func updateGesture(_ body: (inout SceneFile) -> Void) {
        beginGesture()
        body(&scene)
    }

    func endGesture(_ name: String) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        if scene != start { registerUndo(start, name) }
    }

    var gestureBase: SceneFile { gestureStart ?? scene }

    private func registerUndo(_ old: SceneFile, _ name: String) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { model in model.restore(old, name) }
        um.setActionName(name)
    }

    private func restore(_ s: SceneFile, _ name: String) {
        let current = scene
        scene = s
        prune()
        registerUndo(current, name)
    }

    func prune() {
        let ids = Set(scene.parts.map(\.id))
        selection = selection.filter(ids.contains)
        pickedFaces.removeAll { !ids.contains($0.partID) }
        pickedRings.removeAll { !ids.contains($0.partID) }
        pickedSegments.removeAll { !ids.contains($0.partID) }
        if let a = annotation, !scene.contains(a) { annotation = nil }
        if let h = sketch?.plane.host, !ids.contains(h) { sketch = nil }
        pickedKeys = pickedKeys.filter { $0.exists(in: scene) }
        let frameIDs = Set(scene.frames.map(\.id))
        if !selectedFrames.isSubset(of: frameIDs) { selectedFrames.formIntersection(frameIDs) }
    }

    // MARK: - Parts

    func addPrimitive(_ spec: PrimitiveSpec) {
        var part = Part(name: uniqueName(spec.name), ops: [spec.op])
        // Drop new parts beside what's already there.
        if let right = scene.parts.compactMap({ p -> Double? in
            guard let b = build.cachedMesh(p.ops)?.bounds, !b.isEmpty else { return nil }
            return b.max.x + p.anim.base("x")
        }).max() {
            part.anim.base["x"] = jsRound(right + 40)
        }
        edit("Add \(spec.name)") { $0.parts.append(part) }
        selection = [part.id]
        status = "\(spec.name) added — edit its steps in the inspector."
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(scene.parts.map(\.name))
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    func deleteSelection() {
        if !pickedKeys.isEmpty { return deletePickedKeys() }
        if let a = annotation { return deleteAnnotation(a) }
        if !selectedFrames.isEmpty { return deleteSelectedFrames() }
        guard !selection.isEmpty else { return }
        let ids = selection
        edit(ids.count == 1 ? "Delete Part" : "Delete Parts") { Self.removeParts(ids, from: &$0) }
        ids.forEach(build.forget)
        prune()
    }

    /// Takes parts out of the scene with everything that hangs off them.
    static func removeParts(_ ids: Set<Part.ID>, from s: inout SceneFile) {
        s.parts.removeAll { ids.contains($0.id) }
        s.dimensions.removeAll { ids.contains($0.part) }
        s.shapes.removeAll { $0.host.map(ids.contains) ?? false }
        s.decals.removeAll { $0.host.map(ids.contains) ?? false }
        s.frames.place(Array(ids), in: nil)
    }

    func duplicateSelection() {
        let src = selectedParts
        guard !src.isEmpty else { return }
        var copies: [Part] = []
        for p in src {
            var c = p
            c.id = makeID()
            c.name = uniqueName(p.name)
            c.anim.base["x"] = p.anim.base("x") + 20
            c.anim.base["y"] = p.anim.base("y") + 20
            copies.append(c)
        }
        edit("Duplicate") { $0.parts.append(contentsOf: copies) }
        selection = Set(copies.map(\.id))
    }

    func updatePart(_ id: Part.ID, _ name: String, _ body: (inout Part) -> Void) {
        edit(name) { s in
            guard let i = s.partIndex(id) else { return }
            body(&s.parts[i])
        }
    }

    func movePart(from: IndexSet, to: Int) {
        edit("Reorder Parts") { $0.parts.move(fromOffsets: from, toOffset: to) }
    }

    func toggleHidden() {
        let ids = selection
        guard !ids.isEmpty else { return }
        let hide = selectedParts.contains { !$0.hidden }
        edit(hide ? "Hide" : "Show") { s in
            for i in s.parts.indices where ids.contains(s.parts[i].id) { s.parts[i].hidden = hide }
        }
    }

    func toggleLocked() {
        let ids = selection
        guard !ids.isEmpty else { return }
        let lock = selectedParts.contains { !$0.locked }
        edit(lock ? "Lock" : "Unlock") { s in
            for i in s.parts.indices where ids.contains(s.parts[i].id) { s.parts[i].locked = lock }
        }
    }

    /// Sets an animatable property at the current time (as a key when the
    /// property is animated or auto-key is on).
    func setProperty(_ prop: String, _ value: Double, for ids: Set<Part.ID>? = nil) {
        let ids = ids ?? selection
        let t = frameTime, auto = autoKey
        edit("Change \(prop.capitalized)") { s in
            for i in s.parts.indices where ids.contains(s.parts[i].id) { s.parts[i].anim.set(prop, value, at: t, autoKey: auto) }
        }
    }

    func value(_ prop: String, of part: Part) -> Double { part.anim.value(prop, at: frameTime) }

    func nudge(_ d: Vec3) {
        let frames = selectedFrames
        let carried = framedParts(frames)
        let ids = Set(selectedParts.filter { !$0.locked && !carried.contains($0.id) }.map(\.id))
        guard !ids.isEmpty || !frames.isEmpty else { return }
        let base = scene, t = frameTime, auto = autoKey, layout = frame()
        edit(frames.isEmpty ? "Nudge" : "Move") { s in
            for f in frames { Self.moveFrame(f, by: Vec2(d.x, d.y), in: &s, from: base, at: t, rect: layout.board(f)?.rect) }
            for i in s.parts.indices where ids.contains(s.parts[i].id) {
                for (k, prop) in ["x", "y", "z"].enumerated() where d[k] != 0 {
                    s.parts[i].anim.set(prop, s.parts[i].anim.value(prop, at: t) + d[k], at: t, autoKey: auto)
                }
            }
        }
    }

    /// Keys every transform property of the selection at the current time.
    func addKeyframe() {
        let ids = selection
        guard !ids.isEmpty else {
            status = "Select a part to key."
            return
        }
        let t = frameTime
        edit("Add Keyframe") { s in
            for i in s.parts.indices where ids.contains(s.parts[i].id) {
                for prop in Part.transformProps {
                    s.parts[i].anim.setKey(prop, t: t, v: s.parts[i].anim.value(prop, at: t))
                }
            }
        }
        status = "Keyed \(ids.count == 1 ? "part" : "\(ids.count) parts") at \(String(format: "%.2f", t))s."
    }

    func clearKeys(of id: Part.ID, prop: String) {
        updatePart(id, "Remove Animation") { p in
            let v = p.anim.value(prop, at: frameTime)
            p.anim.keys[prop] = nil
            p.anim.base[prop] = v
        }
    }

    // MARK: - Steps

    func addStep(_ op: Op, name: String) {
        guard let i = selectedIndex else {
            status = "Select one part to add a step."
            return
        }
        edit(name) { $0.parts[i].ops.append(op) }
    }

    func setStepField(_ id: Part.ID, step: Int, key: String, value: JSONValue) {
        updatePart(id, "Edit Step") { p in
            guard p.ops.indices.contains(step) else { return }
            p.ops[step].setField(key, to: value)
        }
    }

    func toggleStep(_ id: Part.ID, step: Int) {
        updatePart(id, "Toggle Step") { p in
            guard p.ops.indices.contains(step) else { return }
            p.ops[step].enabled.toggle()
        }
    }

    func deleteStep(_ id: Part.ID, step: Int) {
        updatePart(id, "Delete Step") { p in
            guard p.ops.indices.contains(step), p.ops.count > 1 else { return }
            p.ops.remove(at: step)
        }
    }

    func moveStep(_ id: Part.ID, step: Int, by delta: Int) {
        updatePart(id, "Reorder Steps") { p in
            let j = step + delta
            guard p.ops.indices.contains(step), p.ops.indices.contains(j), step > 0, j > 0 else { return }
            p.ops.swapAt(step, j)
        }
    }

    // MARK: - Faces

    func toggleFace(_ part: Part.ID, _ face: FaceID) {
        let f = PickedFace(partID: part, face: face)
        if let i = pickedFaces.firstIndex(of: f) { pickedFaces.remove(at: i) } else { pickedFaces.append(f) }
        selection = [part]
        status = pickedFaces.isEmpty ? "Ready" : "\(pickedFaces.count) face\(pickedFaces.count == 1 ? "" : "s") picked — extrude or push in from the inspector."
    }

    /// The plugin's `cmdFacePush`: one `facepush` step per picked face.
    func pushFaces(depth: Double) {
        guard !pickedFaces.isEmpty else {
            status = "⌘-click a face to pick it first."
            return
        }
        guard depth != 0 else {
            status = "Set a depth other than 0."
            return
        }
        let faces = pickedFaces
        edit(depth > 0 ? "Extrude Face" : "Push In Face") { s in
            for f in faces {
                guard let i = s.partIndex(f.partID) else { continue }
                s.parts[i].ops.append(Op(type: "facepush", [
                    "n": JSONValue(vec: f.face.n), "w": .number(f.face.w), "bounds": f.face.boundsJSON,
                    "depth": .number(depth), "name": .string(f.face.name),
                ]))
            }
        }
        let what = faces.count == 1 ? "face" : "\(faces.count) faces"
        status = depth > 0 ? "Extruded \(what) \(jsNumberString(depth))." : "Pushed \(what) in \(jsNumberString(-depth))."
        pickedFaces = []
    }

    // MARK: - Combine

    /// Merges the other selected parts into the first one as `merge` steps,
    /// keeping where they are on screen.
    func combineSelection() {
        let parts = selectedParts
        guard parts.count >= 2, let host = parts.first else {
            status = "Select two or more parts to combine."
            return
        }
        let rot = ["spin", "tilt", "roll"]
        guard rot.allSatisfy({ host.anim.base($0) == 0 && !host.anim.isAnimated($0) }) else {
            status = "Reset the first part's rotation before combining."
            return
        }
        guard !parts.contains(where: { $0.anim.isAnimated }) else {
            status = "Clear animation before combining."
            return
        }
        let hostPos = Vec3(host.anim.base("x"), host.anim.base("y"), host.anim.base("z"))
        var merges: [Op] = []
        for p in parts.dropFirst() {
            let pos = Vec3(p.anim.base("x"), p.anim.base("y"), p.anim.base("z"))
            let angles = Vec3(p.anim.base("tilt"), p.anim.base("roll"), p.anim.base("spin"))
            if angles == .zero {
                merges.append(.merge(p.ops, name: p.name, offset: pos - hostPos))
            } else {
                guard let b = build.meshNow(for: p)?.bounds, !b.isEmpty else { continue }
                let m = Mat3.rotation(x: angles.x, y: angles.y, z: angles.z)
                let pivot = b.center
                merges.append(.merge(p.ops, name: p.name, offset: pivot + pos - m * pivot - hostPos, matrix: m))
            }
        }
        let others = Set(parts.dropFirst().map(\.id))
        edit("Combine") { s in
            guard let i = s.partIndex(host.id) else { return }
            s.parts[i].ops.append(contentsOf: merges)
            s.parts.removeAll { others.contains($0.id) }
        }
        selection = [host.id]
        status = "Combined \(parts.count) parts into \(host.name)."
    }

    // MARK: - Animation

    func applyPreset(_ preset: AnimationPreset) {
        let build = build
        var msg = ""
        let sel = selection
        edit(preset.title) { s in
            msg = s.apply(preset, selection: sel) { build.meshNow(for: $0)?.bounds ?? .empty }
        }
        status = msg
        if preset != .clear, !isPlaying {
            time = 0
            play()
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying else { return }
        if time >= scene.duration - 1e-6 { time = 0 }
        isPlaying = true
        playStart = CACurrentMediaTime() - time
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    func seek(_ t: Double) {
        time = clamp(t, 0, scene.duration)
        if isPlaying { playStart = CACurrentMediaTime() - time }
    }

    func step(frames: Int) {
        pause()
        seek(frameTime + Double(frames) / scene.fps)
    }

    private func tick() {
        var t = CACurrentMediaTime() - playStart
        let d = scene.duration
        if t > d {
            if loops {
                t = t.truncatingRemainder(dividingBy: d)
                playStart = CACurrentMediaTime() - t
            } else {
                t = d
                pause()
            }
        }
        time = t
    }

    // MARK: - View

    func zoomToFit(after delay: Double = 0) {
        guard delay > 0 else { return fit() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.fit()
        }
    }

    private func fit() {
        let b = frame(immediate: true).bounds
        let size = viewportSize
        guard b.width > 0, b.height > 0, size.width > 10, size.height > 10 else { return }
        // Keep the drawing clear of the floating tool pills along the top.
        let top = 52.0
        zoom = clamp(min((size.width - 48) / b.width, (size.height - 48 - top) / b.height), 0.05, 8)
        pan = Vec2(-b.midX * zoom, -b.midY * zoom + top / 2)
    }

    func zoom(by factor: Double, around p: Vec2? = nil) {
        let anchor = p ?? .zero
        let z = clamp(zoom * factor, 0.05, 16)
        let k = z / zoom
        pan = anchor + (pan - anchor) * k
        zoom = z
    }

    // MARK: - Export

    func exportFrame() -> Frame { frame(immediate: true) }

    /// Free exports carry a small mark.
    var watermarks: Bool { !Store.shared.isPro }

    func svg(watermark: Bool? = nil) -> String { SVGWriter.document(exportFrame(), watermark: watermark ?? watermarks) }

    func pdf(watermark: Bool? = nil) -> Data {
        let f = exportFrame()
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: f.bounds.width, height: f.bounds.height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -f.bounds.minX, y: -f.bounds.minY)
        FramePainter.paint(f, in: ctx)
        if watermark ?? watermarks { FramePainter.paintWatermark(f.bounds, style: f.style, in: ctx) }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    func png(scale: Double = 2, watermark: Bool? = nil) -> Data? {
        let f = exportFrame()
        let mark = watermark ?? watermarks
        // Free PNGs top out at 1200 px on the long side.
        let scale = mark ? min(scale, Limits.freeImageSide / max(1, max(f.bounds.width, f.bounds.height))) : scale
        let w = Int((f.bounds.width * scale).rounded(.up)), h = Int((f.bounds.height * scale).rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -f.bounds.minX, y: -f.bounds.minY)
        ctx.setShouldSmoothFonts(false)
        FramePainter.paint(f, in: ctx)
        if mark { FramePainter.paintWatermark(f.bounds, style: f.style, in: ctx) }
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
