import AppKit
import CoreText
import IsoDocument
import IsoGeometry
import IsoMath
import IsoRender

/// One visible part in a frame: its runs and where they sit on screen.
nonisolated struct FrameItem {
    var part: Part
    var runs: [Run]
    var offset: Vec2
    var opacity: Double
    var depth: Double
    /// Screen box including `offset`.
    var box: Box2
    /// Model → view space for this part at this moment.
    var view: ViewTransform
    /// Tilt, roll and spin (camera included) behind `view`.
    var rotation: Vec3

    /// Model point → screen.
    func screen(_ p: Vec3, _ angle: IsoAngle) -> Vec2 { angle.project(view.apply(p)) + offset }
}

nonisolated struct GuideLayout {
    var guide: Guide
    var a: Vec2
    var b: Vec2
}

nonisolated struct CalloutLayout {
    var partID: Part.ID
    var text: String
    /// Top-left of the label.
    var origin: Vec2
    var size: Vec2
    var start: Vec2
    var end: Vec2
    var opacity: Double

    var box: Box2 { Box2(minX: origin.x, minY: origin.y, maxX: origin.x + size.x, maxY: origin.y + size.y) }
}

nonisolated struct SheetLayout {
    var rect: Box2
    var margin: Double
    var grid: Double
    var fig: String
    var title: String
    var year: String
}

nonisolated struct ShapeLayout {
    var shape: FlatShape
    /// Screen outlines, one per loop (drawn even-odd so holes work).
    var polys: [[Vec2]]
    var opacity: Double
    var box: Box2
}

nonisolated struct DecalLayout {
    var decal: Decal
    /// Decal space (x right, y down, centred on the decal) → screen.
    var transform: CGAffineTransform
    var opacity: Double
    /// Screen outline of the decal's bounds, for hit-testing and selection.
    var outline: [Vec2]
}

nonisolated struct DimensionLayout {
    struct Span {
        var a: Vec2
        var b: Vec2
        var label: String
        /// Figma-style rotation in degrees (counter-clockwise).
        var rotation: Double
        var labelCenter: Vec2
    }

    var dimension: DimensionLine
    var extensions: [(Vec2, Vec2)]
    var spans: [Span]
    var opacity: Double
}

/// Flat art drawn right after a part (or behind everything when `host` is nil).
nonisolated enum Overlay {
    case shape(ShapeLayout)
    case decal(DecalLayout)
}

/// Everything needed to draw the scene at one moment.
nonisolated struct Frame {
    var style: Style
    var angle: IsoAngle
    var items: [FrameItem] = []
    var guidesBehind: [GuideLayout] = []
    /// Detail lines drawn right after the item at this index.
    var guidesAbove: [Int: [GuideLayout]] = [:]
    /// Unhosted shapes and decals, drawn under the parts.
    var overlaysBehind: [Overlay] = []
    /// Hosted shapes and decals, drawn right after the item at this index.
    var overlaysAbove: [Int: [Overlay]] = [:]
    var callouts: [CalloutLayout] = []
    var dimensions: [DimensionLayout] = []
    var sheet: SheetLayout?
    /// False while some visible part is still building.
    var complete = true
    var contentBox = Box2.empty
    var bounds = Box2(minX: -300, minY: -200, maxX: 300, maxY: 200)
    /// World → view space (the camera's turn about the scene centre).
    var worldView = ViewTransform.identity

    func item(for id: Part.ID) -> FrameItem? { items.first { $0.part.id == id } }

    var allOverlays: [Overlay] { overlaysBehind + overlaysAbove.keys.sorted().flatMap { overlaysAbove[$0]! } }
}

/// Composes a frame the way the web Studio's `frameItems` does, plus the
/// plugin's sheet, guides, callouts, dimensions and flat art. Geometry comes
/// from closures so the same code runs live (from the build cache) and in
/// background exports.
nonisolated struct FrameComposer {
    var mesh: (Part) -> PreparedMesh?
    var runs: (Part, Vec3, IsoAngle) -> [Run]?
    /// Parts that failed to build don't hold up `complete`.
    var failed: (Part.ID) -> Bool = { _ in false }

    func compose(_ scene: SceneFile, at t: Double) -> Frame {
        let angle = scene.isoAngle
        var frame = Frame(style: scene.style, angle: angle)
        let visible = scene.parts.filter { !$0.hidden }
        var meshes: [Part.ID: PreparedMesh] = [:]
        for p in visible {
            if let m = mesh(p), !m.isEmpty { meshes[p.id] = m } else if !failed(p.id) { frame.complete = false }
        }

        // The middle of the scene at rest — the turntable spins around it.
        var rest = Bounds3.empty
        for p in visible {
            guard let m = meshes[p.id] else { continue }
            let o = Vec3(p.anim.base("x"), p.anim.base("y"), p.anim.base("z"))
            rest.add(m.bounds.min + o)
            rest.add(m.bounds.max + o)
        }
        let center = rest.isEmpty ? Vec3.zero : rest.center
        let cam = scene.camera.value("spin", at: t)
        frame.worldView = ViewTransform(rotation: Vec3(0, 0, cam), pivot: center)
        let world = frame.worldView

        var items: [(Int, FrameItem)] = []
        for (i, p) in visible.enumerated() {
            let opacity = p.anim.value("opacity", at: t) / 100
            guard opacity > 0.001, let m = meshes[p.id] else { continue }
            let pivot = m.bounds.center
            let pos = Vec3(p.anim.value("x", at: t), p.anim.value("y", at: t), p.anim.value("z", at: t))
            let w = world.apply(pivot + pos)
            let rot = Vec3(p.anim.value("tilt", at: t), p.anim.value("roll", at: t), p.anim.value("spin", at: t) + cam)
            guard let rr = runs(p, rot, angle) else {
                frame.complete = false
                continue
            }
            let off = angle.project(w - pivot)
            let b = rr.isEmpty ? Box2(minX: 0, minY: 0, maxX: 0, maxY: 0) : Renderer.bounds(rr)
            items.append((i, FrameItem(
                part: p, runs: rr, offset: off, opacity: opacity, depth: w.dot(angle.toViewer), box: b.offset(by: off),
                view: ViewTransform(rotation: rot, pivot: pivot), rotation: rot)))
        }
        // Back to front; inlays ride directly above their host.
        items.sort { $0.1.depth != $1.1.depth ? $0.1.depth < $1.1.depth : $0.0 < $1.0 }
        var ordered = items.map(\.1)
        for inlay in ordered.filter({ $0.part.on != nil }) {
            guard ordered.contains(where: { $0.part.name == inlay.part.on && $0.part.id != inlay.part.id }),
                  let from = ordered.firstIndex(where: { $0.part.id == inlay.part.id }) else { continue }
            ordered.remove(at: from)
            let host = ordered.firstIndex { $0.part.name == inlay.part.on }!
            ordered.insert(inlay, at: host + 1)
        }
        frame.items = ordered
        frame.contentBox = ordered.reduce(Box2.empty) { $0.union($1.box) }

        // Guides share the world origin and turn with the camera.
        for g in scene.guides {
            let layout = GuideLayout(guide: g, a: angle.project(world.apply(g.a)), b: angle.project(world.apply(g.b)))
            if let above = g.above, let i = ordered.firstIndex(where: { $0.part.name == above }) {
                frame.guidesAbove[i, default: []].append(layout)
            } else {
                frame.guidesBehind.append(layout)
            }
        }

        layoutOverlays(scene, &frame)
        frame.dimensions = scene.dimensions.compactMap { d in
            guard let i = ordered.firstIndex(where: { $0.part.id == d.part }), let m = meshes[d.part] else { return nil }
            return layoutDimension(d, ordered[i], m, angle)
        }

        if scene.sheet.visible {
            var restBox = Box2.empty
            for p in visible {
                guard meshes[p.id] != nil,
                      let rr = runs(p, Vec3(p.anim.base("tilt"), p.anim.base("roll"), p.anim.base("spin")), angle), !rr.isEmpty
                else { continue }
                restBox = restBox.union(Renderer.bounds(rr).offset(by: angle.project(Vec3(p.anim.base("x"), p.anim.base("y"), p.anim.base("z")))))
            }
            if restBox.isEmpty { restBox = frame.contentBox.isEmpty ? Box2(minX: -100, minY: -100, maxX: 100, maxY: 100) : frame.contentBox }
            let size = scene.sheet.size ?? Vec2(
                max(1200, ((restBox.width + 560) / 40).rounded(.up) * 40),
                max(800, ((restBox.height + 280) / 40).rounded(.up) * 40))
            let minX = (restBox.midX - size.x / 2).rounded(), minY = (restBox.midY - size.y / 2).rounded()
            frame.sheet = SheetLayout(
                rect: Box2(minX: minX, minY: minY, maxX: minX + size.x, maxY: minY + size.y),
                margin: scene.sheet.margin, grid: max(4, scene.sheet.grid),
                fig: scene.sheet.fig, title: scene.sheet.title, year: scene.sheet.year)
        }

        frame.callouts = layoutCallouts(ordered, midX: frame.sheet?.rect.midX ?? frame.contentBox.midX)

        if let sheet = frame.sheet {
            frame.bounds = sheet.rect
        } else {
            var b = frame.callouts.reduce(frame.contentBox) { $0.union($1.box) }
            for g in frame.guidesBehind + frame.guidesAbove.values.flatMap({ $0 }) {
                b.add(g.a)
                b.add(g.b)
            }
            for o in frame.allOverlays {
                switch o {
                case .shape(let s): b = b.union(s.box)
                case .decal(let d): d.outline.forEach { b.add($0) }
                }
            }
            for d in frame.dimensions {
                for s in d.spans {
                    b.add(s.a)
                    b.add(s.b)
                    b.add(s.labelCenter)
                }
            }
            if !b.isEmpty { frame.bounds = b.insetBy(-40) }
        }
        return frame
    }

    // MARK: - Flat art

    /// Hosted art follows its part (and hides when its plane turns away);
    /// the rest sits in world space and turns with the camera.
    private func layoutOverlays(_ scene: SceneFile, _ frame: inout Frame) {
        let angle = frame.angle
        let toViewer = angle.toViewer
        func place(host: Part.ID?, axis: Axis) -> (map: (Vec3) -> Vec2, index: Int?, opacity: Double)? {
            if let host {
                guard let i = frame.items.firstIndex(where: { $0.part.id == host }) else { return nil }
                let item = frame.items[i]
                guard item.view.applyNormal(axis.unit).dot(toViewer) > 1e-6 else { return nil }
                return ({ item.screen($0, angle) }, i, item.opacity)
            }
            let world = frame.worldView
            guard world.applyNormal(axis.unit).dot(toViewer) > 1e-6 else { return nil }
            return ({ angle.project(world.apply($0)) }, nil, 1)
        }
        func add(_ o: Overlay, _ index: Int?) {
            if let index { frame.overlaysAbove[index, default: []].append(o) } else { frame.overlaysBehind.append(o) }
        }
        for s in scene.shapes {
            guard let p = place(host: s.host, axis: s.axis) else { continue }
            let to3 = IsoPlaneMapping.planeTo3(axis: s.axis, at: s.at)
            let polys = s.loops.map { $0.map { p.map(to3($0)) } }
            var box = Box2.empty
            polys.forEach { $0.forEach { box.add($0) } }
            add(.shape(ShapeLayout(shape: s, polys: polys, opacity: s.opacity * p.opacity, box: box)), p.index)
        }
        for d in scene.decals {
            guard let p = place(host: d.host, axis: d.axis) else { continue }
            let to3 = IsoPlaneMapping.planeTo3(axis: d.axis, at: d.at)
            let flat = { (fx: Double, fy: Double) -> Vec2 in p.map(to3(d.center + DecalArt.planeOffset(fx, fy, d.axis))) }
            let o = flat(0, 0), ux = flat(1, 0) - o, uy = flat(0, 1) - o
            let tr = CGAffineTransform(a: ux.x, b: ux.y, c: uy.x, d: uy.y, tx: o.x, ty: o.y)
            let size = DecalArt.size(d)
            let outline = [Vec2(-size.x / 2, -size.y / 2), Vec2(size.x / 2, -size.y / 2), Vec2(size.x / 2, size.y / 2), Vec2(-size.x / 2, size.y / 2)]
                .map { flat($0.x, $0.y) }
            add(.decal(DecalLayout(decal: d, transform: tr, opacity: d.opacity * p.opacity, outline: outline)), p.index)
        }
    }

    // MARK: - Dimensions

    /// The plugin's `cmdDimension`, measured on the part's current pose.
    private func layoutDimension(_ d: DimensionLine, _ item: FrameItem, _ mesh: PreparedMesh, _ angle: IsoAngle) -> DimensionLayout? {
        var b = Bounds3.empty
        if item.view.isIdentity {
            b = mesh.bounds
        } else {
            for p in mesh.raw { for v in p.v { b.add(item.view.apply(v)) } }
        }
        guard !b.isEmpty else { return nil }
        let P = { (v: Vec3) -> Vec2 in angle.project(v) + item.offset }
        let off = max(1, d.offset), tick = 6.0
        var layout = DimensionLayout(dimension: d, extensions: [], spans: [], opacity: item.opacity)
        func dim(_ p0: Vec3, _ p1: Vec3, _ out: Vec3, _ rotation: Double, _ lift: Vec2) {
            let a = P(p0 + out), c = P(p1 + out)
            for p in [p0, p1] {
                layout.extensions.append((P(p + out * (4 / off)), P(p + out * ((off + tick) / off))))
            }
            let len = (p1 - p0).length
            layout.spans.append(.init(a: a, b: c, label: d.format(len), rotation: rotation, labelCenter: (a + c) * 0.5 + lift))
        }
        let (x0, y0, z0) = (b.min.x, b.min.y, b.min.z), (x1, y1, z1) = (b.max.x, b.max.y, b.max.z)
        let slope = angle.degrees
        if d.width && x1 - x0 > 0.5 { dim(Vec3(x0, y1, z0), Vec3(x1, y1, z0), Vec3(0, off, 0), -slope, Vec2(-5, 9)) }
        if d.depth && y1 - y0 > 0.5 { dim(Vec3(x1, y0, z0), Vec3(x1, y1, z0), Vec3(off, 0, 0), slope, Vec2(5, 9)) }
        if d.height && z1 - z0 > 0.5 { dim(Vec3(x1, y0, z0), Vec3(x1, y0, z1), Vec3(off * 0.7, -off * 0.7, 0), 90, Vec2(10, 0)) }
        return layout.spans.isEmpty ? nil : layout
    }

    // MARK: - Callouts

    /// The plugin's `addCallout`: uppercase monospace label at the side of
    /// the part with an arrowed leader to a point on it.
    private func layoutCallouts(_ items: [FrameItem], midX: Double) -> [CalloutLayout] {
        var out: [CalloutLayout] = []
        for it in items {
            for c in it.part.callouts where !c.text.isEmpty {
                let b = it.box
                let label = c.text.uppercased()
                let size = Typeset.measure(label, size: Typeset.calloutSize)
                let reach = c.reach
                let tg = c.target ?? Vec2(0.5, 0.5)
                let target = Vec2(b.minX + b.width * tg.x, b.minY + b.height * tg.y)
                let below = c.side == .below
                let onRight = c.side.map { $0 == .right } ?? (b.midX >= midX)
                let ab = c.alignTo.flatMap { name in items.first { $0.part.name == name }?.box } ?? b
                let textY = below ? b.maxY + reach : target.y - size.y / 2
                let textX = below ? target.x + 6 : onRight ? max(b.maxX, ab.maxX) + reach : min(b.minX, ab.minX) - reach - size.x
                let start = below ? Vec2(target.x, textY + size.y + 14) : Vec2(onRight ? textX - 8 : textX + size.x + 8, target.y)
                out.append(CalloutLayout(
                    partID: it.part.id, text: label, origin: Vec2(textX, textY), size: size, start: start, end: target,
                    opacity: it.opacity))
            }
        }
        return out
    }
}

/// Monospace label metrics shared by the canvas, PDF/PNG/video and SVG output.
nonisolated enum Typeset {
    static let calloutSize = 11.0
    static let sheetSize = 10.0
    static let dimensionSize = 10.0
    /// Figma's 6% letter spacing.
    static func tracking(_ size: Double) -> Double { size * 0.06 }

    static func font(_ size: Double) -> CTFont {
        CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil) ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
    }

    static func line(_ text: String, size: Double, tracking: Double? = nil) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size),
            NSAttributedString.Key(kCTKernAttributeName as String): tracking ?? self.tracking(size),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    /// Width and line height.
    static func measure(_ text: String, size: Double) -> Vec2 {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CTLineGetTypographicBounds(line(text, size: size), &ascent, &descent, &leading)
        return Vec2(w, lineHeight(size))
    }

    static func lineHeight(_ size: Double) -> Double { (size * 1.21).rounded() }

    /// Distance from the top of the line box to the baseline.
    static func baseline(_ size: Double) -> Double {
        let f = font(size)
        let a = CTFontGetAscent(f), d = CTFontGetDescent(f)
        return (lineHeight(size) - (a + d)) / 2 + a
    }
}

/// Decal content metrics in decal space (x right, y down, centred).
nonisolated enum DecalArt {
    /// Flat decal offset → the plane's 2D coordinates, oriented like the
    /// plugin's `planeMatrix` (text reads left to right on every face).
    static func planeOffset(_ fx: Double, _ fy: Double, _ axis: Axis) -> Vec2 {
        switch axis {
        case .z: Vec2(fx, fy)
        case .y: Vec2(fx, -fy)
        case .x: Vec2(-fx, -fy)
        }
    }

    static func size(_ d: Decal) -> Vec2 {
        switch d.kind {
        case .text:
            let m = Typeset.measure(d.content, size: d.size)
            return Vec2(max(1, m.x), Typeset.lineHeight(d.size))
        case .svg:
            let b = pathBounds(d)
            return b.width > 0 ? Vec2(d.size, d.size * b.height / b.width) : Vec2(d.size, d.size)
        case .image:
            guard let img = image(d) else { return Vec2(d.size, d.size) }
            return Vec2(d.size, d.size * Double(img.height) / Double(max(1, img.width)))
        }
    }

    // Decoded art is cached by content; frames redraw at 60 Hz.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String: CGPath] = [:]
    nonisolated(unsafe) private static var images: [Data: CGImage] = [:]

    static func path(_ d: Decal) -> CGPath? {
        guard d.kind == .svg else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let p = paths[d.content] { return p }
        guard let p = makePath(d.content) else { return nil }
        if paths.count > 64 { paths.removeAll() }
        paths[d.content] = p
        return p
    }

    static func cgPath(_ segs: [PathSegment]) -> CGPath {
        let path = CGMutablePath()
        for s in segs {
            switch s {
            case .move(let p): path.move(to: p.cgPoint)
            case .line(let p): path.addLine(to: p.cgPoint)
            case .quad(let c, let p): path.addQuadCurve(to: p.cgPoint, control: c.cgPoint)
            case .cubic(let c1, let c2, let p): path.addCurve(to: p.cgPoint, control1: c1.cgPoint, control2: c2.cgPoint)
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    static func mimeType(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        return "image/png"
    }

    private static func makePath(_ content: String) -> CGPath? {
        guard let segs = try? SVGPath.parse(content) else { return nil }
        let path = cgPath(segs)
        return path.isEmpty ? nil : path
    }

    static func pathBounds(_ d: Decal) -> CGRect { path(d)?.boundingBoxOfPath ?? .zero }

    /// The SVG path scaled to the decal's width and centred.
    static func fittedPathTransform(_ d: Decal) -> CGAffineTransform {
        let b = pathBounds(d)
        guard b.width > 0 else { return .identity }
        let k = d.size / b.width
        return CGAffineTransform(scaleX: k, y: k).translatedBy(x: -b.midX, y: -b.midY)
    }

    static func image(_ d: Decal) -> CGImage? {
        guard let data = d.image else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let img = images[data] { return img }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        if images.count > 16 { images.removeAll() }
        images[data] = img
        return img
    }
}

nonisolated extension RGB {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    func cgColor(alpha: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }

    /// `rgb(…)` with 0–255 rounded channels, like the web Studio's `mix`.
    var css: String {
        "rgb(\(Int(jsRound(r * 255))),\(Int(jsRound(g * 255))),\(Int(jsRound(b * 255))))"
    }
}

nonisolated extension Style {
    func fill(for part: Part) -> RGB { RGB(hex: part.style.fill ?? fill) }
    func ink(for part: Part) -> RGB { RGB(hex: part.style.ink ?? ink) }
    func weight(for part: Part) -> Double { part.style.weight ?? weight }
    func gap(for part: Part) -> Double { max(2, part.style.gap ?? gap) }
    /// Sheet label colour: ink pulled towards a cool grey.
    var labelInk: RGB { RGB(hex: ink).mix(RGB(r: 0.45, g: 0.45, b: 0.5), 0.7) }
    var sheetFill: RGB { RGB(hex: fill).mix(RGB(hex: ink), 0.025) }
}
