import CoreGraphics
import CoreText
import Foundation
import IsoDocument
import IsoGeometry
import IsoMath
import IsoRender

/// Bodymovin (Lottie) JSON, drawn frame by frame: parts change outline as
/// they turn, so each distinct frame is its own shape layer, shown only for
/// its frames. Hatching is clipped geometrically and text is outlined, so any
/// player draws it without masks, mattes or fonts. Image decals are embedded
/// assets on image layers, which splits a frame into several layers.
nonisolated enum LottieWriter {
    /// One filled and/or stroked path, in scene units.
    struct Mark {
        var path: CGPath
        var fill: RGB?
        var evenOdd = false
        var stroke: RGB?
        var width = 1.0
        var dash: [Double]?
        var roundCaps = true
        var opacity = 1.0
        /// Polygons that tile without overlapping, drawn as their outline.
        var merge = false
    }

    enum Chunk {
        case marks([Mark])
        case image(DecalLayout, CGImage)
    }

    /// A stretch of a frame that becomes one shape layer, or an image layer
    /// under a null that carries the rest of its transform.
    enum Piece: Equatable {
        case shapes(String)
        case image(asset: String, child: String, parent: String)
    }

    struct Content: Equatable {
        var sheet: [Piece]
        var body: [Piece]
    }

    static func document(
        _ scene: SceneFile, composer: FrameComposer, plan: VideoPlan, settings: VideoSettings, progress: (Double) -> Void
    ) throws -> String {
        var assets = Assets()
        var style = scene.style
        let spans = try plan.spans(progress: progress) { t in
            var frame = composer.compose(scene, at: t)
            style = frame.style
            let sheet = frame.boards.isEmpty ? [] : pieces(frame.boards.map { .marks(sheetMarks($0, style: frame.style)) }, plan, &assets)
            frame.boards = []
            return Content(sheet: sheet, body: pieces(chunks(frame), plan, &assets))
        }

        let count = plan.times.count
        var layers = Layers(plan: plan)
        if !settings.transparent {
            let o = plan.origin
            let rect = CGPath(rect: CGRect(x: o.x, y: o.y, width: Double(plan.width) / plan.scale, height: Double(plan.height) / plan.scale), transform: nil)
            layers.add(pieces([.marks([Mark(path: rect, fill: RGB(hex: style.bg))])], plan, &assets), name: "Background", 0, count)
        }
        // The sheet rarely changes, so it's drawn once under the frames.
        let sheet = spans.first?.content.sheet ?? []
        let sheetHolds = spans.allSatisfy { $0.content.sheet == sheet }
        if sheetHolds { layers.add(sheet, name: "Sheet", 0, count) }
        for (k, span) in spans.enumerated() {
            let ps = (sheetHolds ? [] : span.content.sheet) + span.content.body
            layers.add(ps.isEmpty ? [.shapes("[]")] : ps, name: "Frame \(k + 1)", span.start, span.end)
        }
        if settings.watermark {
            let o = FramePainter.watermarkOrigin(plan.box)
            let text = textPath(FramePainter.watermarkText, size: Typeset.sheetSize, transform: CGAffineTransform(translationX: o.x, y: o.y))
            layers.add(pieces([.marks([Mark(path: text, fill: style.labelInk, opacity: 0.75)])], plan, &assets), name: "Watermark", 0, count)
        }
        progress(1)
        let fps = max(1, settings.fps.rounded())
        return #"{"v":"5.7.0","fr":\#(n(fps)),"ip":0,"op":\#(count),"w":\#(plan.width),"h":\#(plan.height),"nm":\#(str(scene.name.isEmpty ? "Animation" : scene.name)),"ddd":0,"#
            + #""assets":[\#(assets.json.joined(separator: ","))],"layers":[\#(layers.json.reversed().joined(separator: ","))]}"#
    }

    // MARK: - Layers

    struct Assets {
        var ids: [Data: String] = [:]
        var json: [String] = []

        mutating func id(_ data: Data, _ img: CGImage) -> String {
            if let id = ids[data] { return id }
            let id = "image_\(json.count)"
            ids[data] = id
            json.append(#"{"id":"\#(id)","w":\#(img.width),"h":\#(img.height),"u":"","p":"data:\#(DecalArt.mimeType(data));base64,\#(data.base64EncodedString())","e":1}"#)
            return id
        }
    }

    /// Layers bottom first; Lottie lists them top first.
    private struct Layers {
        let plan: VideoPlan
        var json: [String] = []

        mutating func add(_ pieces: [Piece], name: String, _ ip: Int, _ op: Int) {
            for p in pieces {
                switch p {
                case .shapes(let shapes):
                    append(4, name, ip, op, transform(anchor: Vec2(0, 0), position: Vec2(0, 0), scale: Vec2(1, 1)), #""shapes":\#(shapes)"#)
                case .image(let asset, let child, let parent):
                    append(3, name, ip, op, parent, nil)
                    append(2, name, ip, op, child, #""refId":"\#(asset)","parent":\#(json.count)"#)
                }
            }
        }

        private mutating func append(_ ty: Int, _ name: String, _ ip: Int, _ op: Int, _ ks: String, _ extra: String?) {
            let more = extra.map { $0 + "," } ?? ""
            json.append(#"{"ddd":0,"ind":\#(json.count + 1),"ty":\#(ty),"nm":\#(str(name)),"sr":1,"ks":\#(ks),"ao":0,\#(more)"ip":\#(ip),"op":\#(op),"st":0,"bm":0}"#)
        }
    }

    /// Layer transform: anchor, then scale, then rotation (radians, y-down so
    /// clockwise), then position.
    static func transform(anchor: Vec2, position: Vec2, scale: Vec2, rotation: Double = 0, opacity: Double = 1) -> String {
        func v(_ p: Vec2, _ z: Double) -> String { #"{"a":0,"k":[\#(n(p.x, 4)),\#(n(p.y, 4)),\#(n(z))]}"# }
        return #"{"o":{"a":0,"k":\#(n(opacity * 100))},"r":{"a":0,"k":\#(n(rotation * 180 / .pi, 4))},"p":\#(v(position, 0)),"a":\#(v(anchor, 0)),"s":\#(v(scale * 100, 100))}"#
    }

    /// `[a c; b d] = R(phi) · diag(sx, sy) · R(theta)` — every 2D linear map
    /// as rotations and scales, which all players support (skew isn't).
    static func decompose(_ t: CGAffineTransform) -> (phi: Double, sx: Double, sy: Double, theta: Double) {
        let e = (t.a + t.d) / 2, f = (t.a - t.d) / 2, g = (t.b + t.c) / 2, h = (t.b - t.c) / 2
        let q = hypot(e, h), r = hypot(f, g)
        let a1 = atan2(g, f), a2 = atan2(h, e)
        return ((a2 + a1) / 2, q + r, q - r, (a2 - a1) / 2)
    }

    static func pieces(_ chunks: [Chunk], _ plan: VideoPlan, _ assets: inout Assets) -> [Piece] {
        chunks.compactMap { chunk in
            switch chunk {
            case .marks(let marks):
                let groups = marks.reversed().compactMap { group($0, plan) }
                return groups.isEmpty ? nil : .shapes("[" + groups.joined(separator: ",") + "]")
            case .image(let d, let img):
                guard let data = d.decal.image else { return nil }
                let size = DecalArt.size(d.decal), w = Double(img.width), h = Double(img.height)
                let t = d.transform, m = decompose(t), k = plan.scale, o = plan.origin
                let child = transform(anchor: Vec2(w / 2, h / 2), position: Vec2(0, 0), scale: Vec2(size.x / w, size.y / h), rotation: m.theta, opacity: d.opacity)
                let parent = transform(anchor: Vec2(0, 0), position: Vec2((t.tx - o.x) * k, (t.ty - o.y) * k), scale: Vec2(m.sx * k, m.sy * k), rotation: m.phi)
                return .image(asset: assets.id(data, img), child: child, parent: parent)
            }
        }
    }

    // MARK: - Shapes

    /// A mark as a shape group, in canvas pixels.
    private static func group(_ m: Mark, _ plan: VideoPlan) -> String? {
        let k = plan.scale, o = plan.origin
        var t = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: -o.x * k, ty: -o.y * k)
        guard let path = m.path.copy(using: &t) else { return nil }
        var cs = PathMerge.contours(path)
        if m.merge { cs = PathMerge.outline(cs) }
        var items = PathMerge.chain(cs).map(shape)
        guard !items.isEmpty else { return nil }
        if let s = m.stroke {
            var st = #"{"ty":"st","c":\#(color(s)),"o":{"a":0,"k":100},"w":{"a":0,"k":\#(n(m.width * k, 3))},"lc":\#(m.roundCaps ? 2 : 1),"lj":2,"ml":4"#
            if let dash = m.dash, !dash.isEmpty {
                let parts = dash.enumerated().map { i, v in
                    i % 2 == 0 ? #"{"n":"d","nm":"dash","v":{"a":0,"k":\#(n(v * k))}}"# : #"{"n":"g","nm":"gap","v":{"a":0,"k":\#(n(v * k))}}"#
                }
                st += #","d":[\#(parts.joined(separator: ",")),{"n":"o","nm":"offset","v":{"a":0,"k":0}}]"#
            }
            items.append(st + "}")
        }
        if let f = m.fill {
            items.append(#"{"ty":"fl","c":\#(color(f)),"o":{"a":0,"k":100},"r":\#(m.evenOdd || m.merge ? 2 : 1)}"#)
        }
        items.append(#"{"ty":"tr","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":\#(n(m.opacity * 100))}}"#)
        return #"{"ty":"gr","it":[\#(items.joined(separator: ","))]}"#
    }

    private static func shape(_ c: PathMerge.Contour) -> String {
        func pts(_ f: (PathMerge.Vertex) -> CGPoint) -> String { c.v.map { "[\(n(f($0).x, 1)),\(n(f($0).y, 1))]" }.joined(separator: ",") }
        return #"{"ty":"sh","ks":{"a":0,"k":{"c":\#(c.closed),"v":[\#(pts(\.p))],"i":[\#(pts(\.i))],"o":[\#(pts(\.o))]}}}"#
    }

    private static func color(_ c: RGB) -> String { #"{"a":0,"k":[\#(n(c.r, 3)),\#(n(c.g, 3)),\#(n(c.b, 3)),1]}"# }

    // MARK: - Frame → marks (FramePainter's paint order)

    static func chunks(_ frame: Frame) -> [Chunk] {
        let style = frame.style
        var out: [Chunk] = [], marks: [Mark] = []
        func overlay(_ o: Overlay) {
            switch o {
            case .shape(let s):
                marks += shapeMarks(s, style: style)
            case .decal(let d):
                if d.decal.kind == .image {
                    guard let img = DecalArt.image(d.decal) else { return }
                    if !marks.isEmpty { out.append(.marks(marks)) }
                    marks = []
                    out.append(.image(d, img))
                } else {
                    marks += decalMarks(d, style: style)
                }
            }
        }
        for g in frame.guidesBehind { marks += guideMarks(g, style: style) }
        for o in frame.overlaysBehind { overlay(o) }
        for (i, item) in frame.items.enumerated() {
            marks += itemMarks(item, style: style)
            for g in frame.guidesAbove[i] ?? [] { marks += guideMarks(g, style: style) }
            for o in frame.overlaysAbove[i] ?? [] { overlay(o) }
        }
        let ink = RGB(hex: style.ink)
        for c in frame.callouts { marks += calloutMarks(c, ink: ink) }
        for d in frame.dimensions { marks += dimensionMarks(d, style: style) }
        if !marks.isEmpty { out.append(.marks(marks)) }
        return out
    }

    static func itemMarks(_ item: FrameItem, style: Style) -> [Mark] {
        let fill = style.fill(for: item.part), ink = style.ink(for: item.part)
        let weight = style.weight(for: item.part), gap = style.gap(for: item.part)
        let o = item.offset, a = item.opacity
        var out: [Mark] = []
        for run in item.runs {
            let face = fill.mix(ink, run.shade)
            out.append(Mark(path: PathMerge.polygons(run.polys, offset: o), fill: face, stroke: face, width: 0.6, opacity: a, merge: true))
            if run.kind == .cut {
                out.append(Mark(path: PathMerge.lines(run.polys.flatMap { Hatch.segments($0, gap: gap) }, offset: o), stroke: ink, width: 0.8, opacity: a))
            }
            if !run.edges.isEmpty {
                out.append(Mark(path: PathMerge.lines(run.edges, offset: o), stroke: ink, width: weight, opacity: a))
            }
        }
        return out
    }

    static func shapeMarks(_ s: ShapeLayout, style: Style) -> [Mark] {
        let path = PathMerge.polygons(s.polys), ink = RGB(hex: s.shape.stroke ?? style.ink)
        var out: [Mark] = []
        if let fill = s.shape.fill { out.append(Mark(path: path, fill: RGB(hex: fill), evenOdd: true, opacity: s.opacity)) }
        if s.shape.hatch {
            out.append(Mark(path: PathMerge.lines(clippedHatch(s.polys, gap: style.gap)), stroke: ink, width: 0.8, opacity: s.opacity))
        }
        out.append(Mark(path: path, stroke: ink, width: style.weight, opacity: s.opacity))
        return out
    }

    static func decalMarks(_ d: DecalLayout, style: Style) -> [Mark] {
        let decal = d.decal, color = RGB(hex: decal.color ?? style.ink)
        switch decal.kind {
        case .text:
            let size = DecalArt.size(decal)
            let path = textPath(decal.content, size: decal.size, transform: d.transform.translatedBy(x: -size.x / 2, y: -size.y / 2))
            return [Mark(path: path, fill: color, opacity: d.opacity)]
        case .svg:
            var t = DecalArt.fittedPathTransform(decal).concatenating(d.transform)
            guard let path = DecalArt.path(decal)?.copy(using: &t) else { return [] }
            return [Mark(path: path, fill: color, opacity: d.opacity)]
        case .image:
            return []
        }
    }

    static func guideMarks(_ g: GuideLayout, style: Style) -> [Mark] {
        let color = RGB(hex: g.guide.color ?? style.ink), o = g.guide.opacity ?? 1
        var out = [Mark(path: PathMerge.lines([(g.a, g.b)]), stroke: color, dash: g.guide.dash ?? [7, 5], roundCaps: false, opacity: o)]
        if g.guide.arrow {
            let p = CGMutablePath()
            addArrow(g.a, g.b, to: p)
            out.append(Mark(path: p, stroke: color, roundCaps: false, opacity: o))
        }
        return out
    }

    static func calloutMarks(_ c: CalloutLayout, ink: RGB) -> [Mark] {
        let p = CGMutablePath()
        p.move(to: c.start.cgPoint)
        p.addLine(to: c.end.cgPoint)
        addArrow(c.start, c.end, to: p)
        let text = textPath(c.text, size: Typeset.calloutSize, transform: CGAffineTransform(translationX: c.origin.x, y: c.origin.y))
        return [Mark(path: p, stroke: ink, opacity: c.opacity), Mark(path: text, fill: ink, opacity: c.opacity)]
    }

    static func dimensionMarks(_ d: DimensionLayout, style: Style) -> [Mark] {
        let color = RGB(hex: d.dimension.color ?? style.ink)
        let p = CGMutablePath(), text = CGMutablePath()
        for (a, b) in d.extensions {
            p.move(to: a.cgPoint)
            p.addLine(to: b.cgPoint)
        }
        for s in d.spans {
            p.move(to: s.a.cgPoint)
            p.addLine(to: s.b.cgPoint)
            addArrow(s.b, s.a, to: p)
            addArrow(s.a, s.b, to: p)
            let m = Typeset.measure(s.label, size: Typeset.dimensionSize)
            let t = CGAffineTransform(translationX: s.labelCenter.x, y: s.labelCenter.y)
                .rotated(by: -s.rotation * .pi / 180).translatedBy(x: -m.x / 2, y: -m.y / 2)
            text.addPath(textPath(s.label, size: Typeset.dimensionSize, transform: t))
        }
        return [Mark(path: p, stroke: color, opacity: d.opacity), Mark(path: text, fill: color, opacity: d.opacity)]
    }

    static func sheetMarks(_ s: SheetLayout, style: Style) -> [Mark] {
        let r = s.rect, m = s.margin
        let paper = Mark(path: CGPath(rect: r.cgRect, transform: nil), fill: s.fill)
        guard s.marks else { return [paper] }
        let grid = CGMutablePath()
        var x = r.minX + m
        while x <= r.maxX - m + 1e-6 {
            grid.move(to: CGPoint(x: x, y: r.minY + m))
            grid.addLine(to: CGPoint(x: x, y: r.maxY - m))
            x += s.grid
        }
        var y = r.minY + m
        while y <= r.maxY - m + 1e-6 {
            grid.move(to: CGPoint(x: r.minX + m, y: y))
            grid.addLine(to: CGPoint(x: r.maxX - m, y: y))
            y += s.grid
        }
        let labels = CGMutablePath()
        for label in FramePainter.sheetLabels(s) {
            let t = CGAffineTransform(translationX: label.origin.x, y: label.origin.y).rotated(by: .pi / 2)
            labels.addPath(textPath(label.text, size: Typeset.sheetSize, transform: t))
        }
        return [
            paper,
            Mark(path: grid, stroke: RGB(hex: style.ink), width: 0.5, roundCaps: false, opacity: 0.07),
            Mark(path: labels, fill: style.labelInk),
        ]
    }

    // MARK: - Geometry

    private static func addArrow(_ a: Vec2, _ b: Vec2, to p: CGMutablePath) {
        let pts = FramePainter.arrowPoints(from: a, to: b)
        guard pts.count == 2 else { return }
        p.move(to: pts[0].cgPoint)
        p.addLine(to: b.cgPoint)
        p.addLine(to: pts[1].cgPoint)
    }

    /// The 45° hatch of `Hatch.segments`, clipped even-odd to all the loops
    /// at once (holes and concave outlines included).
    static func clippedHatch(_ polys: [[Vec2]], gap: Double) -> [(Vec2, Vec2)] {
        var lo = Double.infinity, hi = -Double.infinity
        for poly in polys {
            for p in poly {
                lo = min(lo, p.x + p.y)
                hi = max(hi, p.x + p.y)
            }
        }
        guard lo <= hi, gap > 0 else { return [] }
        var out: [(Vec2, Vec2)] = []
        var s = (lo / gap).rounded(.up) * gap
        while s <= hi {
            var hits: [Vec2] = []
            for poly in polys where poly.count > 2 {
                for i in poly.indices {
                    let a = poly[i], b = poly[(i + 1) % poly.count]
                    let fa = a.x + a.y - s, fb = b.x + b.y - s
                    if (fa < 0) != (fb < 0) {
                        let k = fa / (fa - fb)
                        hits.append(Vec2(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k))
                    }
                }
            }
            hits.sort { $0.x < $1.x }
            for k in Swift.stride(from: 0, to: hits.count - 1, by: 2) { out.append((hits[k], hits[k + 1])) }
            s += gap
        }
        return out
    }

    /// A label's glyph outlines with its line box's top-left at the origin
    /// of `transform` (y down), like `FramePainter.drawText`.
    static func textPath(_ text: String, size: Double, transform: CGAffineTransform) -> CGPath {
        let path = CGMutablePath()
        let base = Typeset.baseline(size)
        let runs = CTLineGetGlyphRuns(Typeset.line(text, size: size)) as? [CTRun] ?? []
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let font = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? Typeset.font(size)
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for i in 0..<count {
                var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[i].x, ty: base - positions[i].y).concatenating(transform)
                if let g = CTFontCreatePathForGlyph(font, glyphs[i], &t) { path.addPath(g) }
            }
        }
        return path
    }

    // MARK: - JSON

    private static func n(_ v: Double, _ places: Double = 2) -> String {
        let k = pow(10, places)
        return jsNumberString(jsRound(v * k) / k)
    }

    private static func str(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}
