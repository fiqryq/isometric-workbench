import AppKit
import IsoDocument
import IsoGeometry
import IsoMath
import IsoRender
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable {
    case select, frame, rectangle, ellipse, polygon, pen, rings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .frame: "Frame"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .polygon: "Polygon"
        case .pen: "Pen"
        case .rings: "Loop Rings"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .frame: "number"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .polygon: "hexagon"
        case .pen: "pencil.and.outline"
        case .rings: "circle.dotted.and.circle"
        }
    }

    var key: Character {
        switch self {
        case .select: "v"
        case .frame: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .polygon: "g"
        case .pen: "p"
        case .rings: "l"
        }
    }

    var draws: Bool { self == .rectangle || self == .ellipse || self == .polygon || self == .pen }
}

/// Where a sketch lies: a plane in a host part's model space, or world space.
struct SketchPlane: Hashable {
    var axis: Axis
    var at: Double
    var host: Part.ID?
}

struct PendingSketch {
    var plane: SketchPlane
    var loops: [Loop]
    var name: String
}

enum AnnotationRef: Hashable {
    case shape(String), decal(String), dimension(String)
}

/// A loop-cut ring: knot index into the loop set (0 and last are the ends).
struct RingPick: Hashable {
    var partID: Part.ID
    var loopID: String
    var knot: Int
}

struct SegmentPick: Hashable {
    var partID: Part.ID
    var loopID: String
    var segment: Int
    var face: IsoPlane
}

/// A keyframe in the timeline, by owner, property and time.
struct KeyRef: Hashable {
    enum Owner: Hashable {
        case camera
        case part(Part.ID)
    }

    var owner: Owner
    var prop: String
    var t: Double

    func exists(in scene: SceneFile) -> Bool {
        scene.animatable(owner)?.keys[prop]?.contains { abs($0.t - t) < 1e-3 } ?? false
    }
}

/// A part's loop cut, as built.
struct LoopInfo {
    var opIndex: Int
    var loopID: String
    var k: Int
    var knots: [Double]
}

extension SceneFile {
    func contains(_ a: AnnotationRef) -> Bool {
        switch a {
        case .shape(let id): shapes.contains { $0.id == id }
        case .decal(let id): decals.contains { $0.id == id }
        case .dimension(let id): dimensions.contains { $0.id == id }
        }
    }

    func animatable(_ owner: KeyRef.Owner) -> Animatable? {
        switch owner {
        case .camera: camera
        case .part(let id): parts.first { $0.id == id }?.anim
        }
    }

    mutating func withAnimatable(_ owner: KeyRef.Owner, _ body: (inout Animatable) -> Void) {
        switch owner {
        case .camera: body(&camera)
        case .part(let id):
            guard let i = partIndex(id) else { return }
            body(&parts[i].anim)
        }
    }
}

extension SceneModel {
    func toolChanged(from old: Tool) {
        if tool.draws { annotation = nil }
        if old == .rings && tool != .rings {
            pickedRings = []
            pickedSegments = []
        }
        switch tool {
        case .select: status = "Ready"
        case .frame: status = "Drag to draw a frame; parts inside it join it. Click for a 400 × 300 frame."
        case .rectangle, .ellipse, .polygon:
            status = "Drag on a face to sketch on it, or on empty canvas to sketch on the \(drawPlane.rawValue) plane. ⇧ keeps it even."
        case .pen: status = "Click to place points; click the first point, double-click or press Return to close. Esc cancels."
        case .rings:
            status = "Click a ring to pick it (⇧ adds), or a face to pick that segment. Add a loop cut step first if there are none."
        }
    }

    // MARK: - Sketches

    func finishSketch(_ loops: [Loop], plane: SketchPlane, name: String) {
        let loops = loops.map(Loop2D.clean).filter { $0.count >= 3 && abs(Loop2D.area($0)) > 1 }
        guard !loops.isEmpty else {
            status = "That outline is too small."
            return
        }
        sketch = PendingSketch(plane: plane, loops: loops, name: name)
        annotation = nil
        let on = plane.host.flatMap { id in scene.parts.first { $0.id == id }?.name }.map { "on \($0)" } ?? "on the \(IsoPlane(axis: plane.axis).rawValue) plane"
        status = "\(name) sketched \(on) — extrude, push in, revolve or keep it from the inspector. Return extrudes."
    }

    func discardSketch() {
        sketch = nil
        status = "Sketch discarded."
    }

    /// Host position when the host isn't rotated (sketch → world).
    private func worldOffset(_ host: Part.ID?) -> Vec3? {
        guard let host else { return .zero }
        guard let p = scene.parts.first(where: { $0.id == host }) else { return nil }
        let rot = ["tilt", "roll", "spin"].map { p.anim.value($0, at: frameTime) }
        guard rot.allSatisfy({ abs($0) < 1e-6 }) else { return nil }
        return Vec3(p.anim.value("x", at: frameTime), p.anim.value("y", at: frameTime), p.anim.value("z", at: frameTime))
    }

    private func addSketchPart(_ np: Sketch.NewPart, _ sk: PendingSketch, _ action: String) {
        guard let off = worldOffset(sk.plane.host) else {
            status = "Reset the host's rotation to make a new part from this sketch."
            return
        }
        var part = Part(name: uniqueName(sk.name), ops: [np.op])
        let pos = np.position + off
        part.anim.base["x"] = round2(pos.x)
        part.anim.base["y"] = round2(pos.y)
        part.anim.base["z"] = round2(pos.z)
        edit(action) { $0.parts.append(part) }
        selection = [part.id]
        sketch = nil
        status = "\(part.name) added."
    }

    /// Extrudes towards the viewer: out of the host face, or as a new part.
    func extrudeSketch(depth: Double, asNewPart: Bool = false) {
        guard let sk = sketch else { return }
        let d = max(0.5, depth)
        if let host = sk.plane.host, !asNewPart {
            updatePart(host, "Extrude Sketch") { $0.ops.append(Sketch.push(sk.loops, axis: sk.plane.axis, at: sk.plane.at, depth: d, through: false)) }
            selection = [host]
            sketch = nil
            status = "Extruded \(jsNumberString(d)) out of the face."
        } else {
            addSketchPart(Sketch.extrudedPart(sk.loops, axis: sk.plane.axis, at: sk.plane.at, depth: d), sk, "Extrude Sketch")
        }
    }

    func pushSketch(depth: Double, through: Bool) {
        guard let sk = sketch, let host = sk.plane.host else {
            status = "Draw on a part's face to push into it."
            return
        }
        let d = max(0.5, abs(depth))
        updatePart(host, through ? "Cut Through" : "Push In") {
            $0.ops.append(Sketch.push(sk.loops, axis: sk.plane.axis, at: sk.plane.at, depth: -d, through: through))
        }
        selection = [host]
        sketch = nil
        status = through ? "Cut through." : "Pushed in \(jsNumberString(d))."
    }

    func revolveSketch() {
        guard let sk = sketch else { return }
        guard let np = Sketch.revolvedPart(sk.loops, axis: sk.plane.axis, at: sk.plane.at) else {
            status = "Revolve needs a profile drawn on a left or right plane."
            return
        }
        addSketchPart(np, sk, "Revolve Sketch")
    }

    func keepSketch(hatch: Bool) {
        guard let sk = sketch else { return }
        let shape = FlatShape(
            name: uniqueShapeName(sk.name), axis: sk.plane.axis, at: sk.plane.at, loops: Loop2D.rounded(sk.loops),
            host: sk.plane.host, fill: hatch ? nil : scene.style.fill, hatch: hatch)
        edit("Add Shape") { $0.shapes.append(shape) }
        sketch = nil
        annotation = .shape(shape.id)
        status = "\(shape.name) kept as flat art."
    }

    private func uniqueShapeName(_ base: String) -> String {
        let names = Set(scene.shapes.map(\.name) + scene.decals.map(\.name))
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    // MARK: - Placement

    /// Where new flat art goes: the picked face, else the top of the selected
    /// part, else the world plane. Returns the plane, a centre and a width.
    func placement() -> (plane: SketchPlane, center: Vec2, width: Double) {
        if let f = pickedFaces.first, let part = scene.parts.first(where: { $0.id == f.partID }),
           let m = build.meshNow(for: part), let axis = Self.axis(of: f.face.n) {
            var c = m.bounds.center
            for b in f.face.bounds {
                if let lo = b.lo, let hi = b.hi { c[b.k] = (lo + hi) / 2 } else if let lo = b.lo { c[b.k] = (lo + m.bounds.max[b.k]) / 2 } else if let hi = b.hi { c[b.k] = (m.bounds.min[b.k] + hi) / 2 }
            }
            let size = m.bounds.max - m.bounds.min
            let w = axis == .z ? min(size.x, size.y) : axis == .y ? min(size.x, size.z) : min(size.y, size.z)
            return (SketchPlane(axis: axis, at: f.face.w, host: part.id), IsoPlaneMapping.planeTo2(axis: axis, c), w)
        }
        if let i = selectedIndex, let m = build.meshNow(for: scene.parts[i]), !m.isEmpty {
            let b = m.bounds
            return (SketchPlane(axis: .z, at: b.max.z, host: scene.parts[i].id), Vec2(b.center.x, b.center.y), min(b.max.x - b.min.x, b.max.y - b.min.y))
        }
        return (SketchPlane(axis: drawPlane.axis, at: 0, host: nil), .zero, 160)
    }

    /// The axis of an axis-aligned face pointing towards +axis.
    static func axis(of n: Vec3) -> Axis? {
        if n.z > 0.999 { return .z }
        if n.y > 0.999 { return .y }
        if n.x > 0.999 { return .x }
        return nil
    }

    // MARK: - Decals

    func addTextDecal() {
        let p = placement()
        var d = Decal(name: uniqueShapeName("Label"), kind: .text, content: "LABEL", axis: p.plane.axis, at: p.plane.at, center: p.center, host: p.plane.host)
        let unit = Typeset.measure(d.content, size: 10).x / 10
        d.size = round2(clamp(p.width * 0.6 / max(unit, 0.1), 6, 64))
        insertDecal(d)
    }

    func addDecal(fromFile url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            status = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let p = placement()
        let name = uniqueShapeName(url.deletingPathExtension().lastPathComponent)
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .svg) == true {
            do {
                let segs = try SVGImport.segments(fromDocument: data)
                guard !segs.isEmpty else { throw SVGPathError.unsupported("No outlines in that SVG.") }
                insertDecal(Decal(
                    name: name, kind: .svg, content: SVGPath.data(segs), axis: p.plane.axis, at: p.plane.at, center: p.center,
                    size: round2(p.width * 0.6), host: p.plane.host))
            } catch {
                status = error.localizedDescription
            }
        } else {
            guard let png = Self.imageData(data, maxSide: 1024) else {
                status = "\(url.lastPathComponent) isn't an image Workbench can read."
                return
            }
            insertDecal(Decal(
                name: name, kind: .image, image: png, axis: p.plane.axis, at: p.plane.at, center: p.center,
                size: round2(p.width * 0.6), host: p.plane.host))
        }
    }

    private func insertDecal(_ d: Decal) {
        edit("Add Decal") { $0.decals.append(d) }
        annotation = .decal(d.id)
        tool = .select
        status = "\(d.name) placed — drag it on the canvas or edit it in the inspector."
    }

    /// PNG/JPEG data kept as is when small enough, otherwise re-encoded as PNG.
    static func imageData(_ data: Data, maxSide: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let type = CGImageSourceGetType(src) as String?
        if max(img.width, img.height) <= maxSide, type == UTType.png.identifier || type == UTType.jpeg.identifier { return data }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: thumb).representation(using: .png, properties: [:])
    }

    // MARK: - SVG profiles

    /// Imports an SVG's outlines as a pending sketch on the placement plane.
    func importSketch(fromFile url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            var loops = SVGPath.loops(try SVGImport.segments(fromDocument: data))
            guard !loops.isEmpty else { throw SVGPathError.unsupported("No closed outlines in that SVG.") }
            let b = Loop2D.bounds(loops)
            let p = placement()
            let fit = max(b.width, b.height)
            let k = fit > 0 && fit > p.width ? p.width * 0.8 / fit : 1
            let axis = p.plane.axis
            loops = loops.map { $0.map { q in p.center + DecalArt.planeOffset((q.x - b.midX) * k, (q.y - b.midY) * k, axis) } }
            finishSketch(loops, plane: p.plane, name: url.deletingPathExtension().lastPathComponent)
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: - Dimensions

    func addDimensions() {
        let ids = selectedParts.map(\.id).filter { id in !scene.dimensions.contains { $0.part == id } }
        guard !ids.isEmpty else {
            status = selection.isEmpty ? "Select a part to dimension." : "Those parts already have dimensions."
            return
        }
        let dims = ids.map { DimensionLine(part: $0, color: scene.style.ink) }
        edit("Add Dimensions") { $0.dimensions.append(contentsOf: dims) }
        if dims.count == 1 { annotation = .dimension(dims[0].id) }
        status = "Dimensions follow the part — set units and scale in the inspector."
    }

    // MARK: - Annotations

    func updateShape(_ id: String, _ name: String = "Edit Shape", _ body: (inout FlatShape) -> Void) {
        edit(name) { s in
            guard let i = s.shapes.firstIndex(where: { $0.id == id }) else { return }
            body(&s.shapes[i])
        }
    }

    func updateDecal(_ id: String, _ name: String = "Edit Decal", _ body: (inout Decal) -> Void) {
        edit(name) { s in
            guard let i = s.decals.firstIndex(where: { $0.id == id }) else { return }
            body(&s.decals[i])
        }
    }

    func updateDimension(_ id: String, _ name: String = "Edit Dimensions", _ body: (inout DimensionLine) -> Void) {
        edit(name) { s in
            guard let i = s.dimensions.firstIndex(where: { $0.id == id }) else { return }
            body(&s.dimensions[i])
        }
    }

    func deleteAnnotation(_ a: AnnotationRef) {
        edit("Delete") { s in
            switch a {
            case .shape(let id): s.shapes.removeAll { $0.id == id }
            case .decal(let id): s.decals.removeAll { $0.id == id }
            case .dimension(let id): s.dimensions.removeAll { $0.id == id }
            }
        }
        annotation = nil
    }

    /// Moves a shape or decal within its plane (gesture; call `endGesture`).
    func dragAnnotation(_ a: AnnotationRef, by delta: Vec2) {
        let base = gestureBase
        updateGesture { s in
            switch a {
            case .shape(let id):
                guard let i = s.shapes.firstIndex(where: { $0.id == id }), let from = base.shapes.first(where: { $0.id == id }) else { return }
                s.shapes[i].loops = from.loops.map { $0.map { Vec2(round2($0.x + delta.x), round2($0.y + delta.y)) } }
            case .decal(let id):
                guard let i = s.decals.firstIndex(where: { $0.id == id }), let from = base.decals.first(where: { $0.id == id }) else { return }
                s.decals[i].center = Vec2(round2(from.center.x + delta.x), round2(from.center.y + delta.y))
            case .dimension: break
            }
        }
    }

    // MARK: - Loop rings

    func loopInfos(_ part: Part) -> [LoopInfo] {
        guard let m = build.cachedMesh(part.ops) else { return [] }
        return part.ops.enumerated().compactMap { j, op in
            guard op.enabled, op.type == "loopcut", let id = op.string("id"), let set = m.context.loopSets[id] else { return nil }
            return LoopInfo(opIndex: j, loopID: id, k: set.k, knots: set.knots)
        }
    }

    func toggleRing(_ pick: RingPick, extend: Bool) {
        if extend {
            if let i = pickedRings.firstIndex(of: pick) { pickedRings.remove(at: i) } else { pickedRings.append(pick) }
        } else {
            pickedRings = pickedRings == [pick] ? [] : [pick]
            pickedSegments = []
        }
        selection = [pick.partID]
        ringStatus()
    }

    func toggleSegment(_ pick: SegmentPick, extend: Bool) {
        if extend {
            if let i = pickedSegments.firstIndex(of: pick) { pickedSegments.remove(at: i) } else { pickedSegments.append(pick) }
        } else {
            pickedSegments = pickedSegments == [pick] ? [] : [pick]
            pickedRings = []
        }
        selection = [pick.partID]
        ringStatus()
    }

    private func ringStatus() {
        var parts: [String] = []
        if !pickedRings.isEmpty { parts.append("\(pickedRings.count) ring\(pickedRings.count == 1 ? "" : "s")") }
        if !pickedSegments.isEmpty { parts.append("\(pickedSegments.count) segment\(pickedSegments.count == 1 ? "" : "s")") }
        status = parts.isEmpty ? "Nothing picked." : parts.joined(separator: ", ") + " picked — scale, taper or push from the inspector."
    }

    private func loopOpIndex(_ part: Part, _ loopID: String) -> Int? {
        part.ops.firstIndex { $0.type == "loopcut" && $0.string("id") == loopID }
    }

    /// Current scale of a ring, in percent.
    func ringScale(_ pick: RingPick) -> Double {
        guard let part = scene.parts.first(where: { $0.id == pick.partID }), let j = loopOpIndex(part, pick.loopID) else { return 100 }
        let list = part.ops[j]["scales"]?.array ?? []
        return pick.knot < list.count ? list[pick.knot].jsNumber ?? 100 : 100
    }

    func setRingScales(_ values: [RingPick: Double], name: String) {
        edit(name) { s in
            for (pick, v) in values {
                guard let i = s.partIndex(pick.partID), let j = loopOpIndex(s.parts[i], pick.loopID) else { continue }
                s.parts[i].ops[j].setField("scales.\(pick.knot)", to: .number(jsRound(v)))
            }
        }
    }

    func scalePickedRings(_ v: Double) {
        setRingScales(Dictionary(uniqueKeysWithValues: pickedRings.map { ($0, v) }), name: "Scale Rings")
    }

    /// Scales picked rings evenly from `a`% to `b`% in ring order.
    func taperPickedRings(from a: Double, to b: Double) {
        let sorted = pickedRings.sorted { ($0.partID, $0.loopID, $0.knot) < ($1.partID, $1.loopID, $1.knot) }
        guard sorted.count >= 2 else {
            status = "Pick two or more rings to taper."
            return
        }
        var values: [RingPick: Double] = [:]
        for (i, r) in sorted.enumerated() { values[r] = a + (b - a) * Double(i) / Double(sorted.count - 1) }
        setRingScales(values, name: "Taper Rings")
    }

    /// The plugin's segment push: one `segpush` step per picked segment.
    func pushPickedSegments(depth: Double, face: IsoPlane? = nil) {
        guard !pickedSegments.isEmpty, depth != 0 else {
            status = pickedSegments.isEmpty ? "Click a face between rings to pick a segment." : "Set a depth other than 0."
            return
        }
        let picks = pickedSegments
        edit(depth > 0 ? "Extrude Segment" : "Inset Segment") { s in
            for p in picks {
                guard let i = s.partIndex(p.partID) else { continue }
                s.parts[i].ops.append(.segmentPush(loopId: p.loopID, segment: p.segment, face: face ?? p.face, depth: depth))
            }
        }
        status = "\(depth > 0 ? "Extruded" : "Inset") \(picks.count) segment\(picks.count == 1 ? "" : "s")."
        pickedSegments = []
    }

    // MARK: - Keys

    func deletePickedKeys() {
        let keys = pickedKeys
        guard !keys.isEmpty else { return }
        edit(keys.count == 1 ? "Delete Key" : "Delete Keys") { s in
            for k in keys {
                s.withAnimatable(k.owner) { a in
                    if a.keys[k.prop]?.count == 1 { a.base[k.prop] = a.keys[k.prop]?.first?.v }
                    a.removeKey(k.prop, t: k.t)
                }
            }
        }
        pickedKeys = []
    }
}
