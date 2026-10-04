import Foundation
import IsoDocument
import IsoGeometry
import IsoMath
import IsoRender

/// SVG markup for a frame — the web Studio's `frameSVG` plus the sheet,
/// guides and plugin-style callouts. Pastes into Figma as editable vectors.
nonisolated enum SVGWriter {
    static func document(_ frame: Frame, background: Bool = true, watermark: Bool = false) -> String {
        let b = frame.bounds
        let style = frame.style
        var out = """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(n(b.width))" height="\(n(b.height))" \
            viewBox="\(n(b.minX)) \(n(b.minY)) \(n(b.width)) \(n(b.height))">
            """
        if background {
            out += #"<rect x="\#(n(b.minX))" y="\#(n(b.minY))" width="\#(n(b.width))" height="\#(n(b.height))" fill="\#(style.bg)"/>"#
        }
        if let sheet = frame.sheet { out += sheetSVG(sheet, style: style) }
        for g in frame.guidesBehind { out += guideSVG(g, style: style) }
        var clip = 0
        for o in frame.overlaysBehind { out += overlaySVG(o, style: style, clip: &clip) }
        for (i, item) in frame.items.enumerated() {
            out += itemSVG(item, style: style)
            for g in frame.guidesAbove[i] ?? [] { out += guideSVG(g, style: style) }
            for o in frame.overlaysAbove[i] ?? [] { out += overlaySVG(o, style: style, clip: &clip) }
        }
        for c in frame.callouts { out += calloutSVG(c, ink: style.ink) }
        for d in frame.dimensions { out += dimensionSVG(d, style: style) }
        if watermark {
            let o = FramePainter.watermarkOrigin(b)
            out += #"<g opacity="0.75">"# + text(FramePainter.watermarkText, x: o.x, y: o.y + Typeset.baseline(Typeset.sheetSize), size: Typeset.sheetSize, fill: style.labelInk.hex) + "</g>"
        }
        return out + "</svg>\n"
    }

    static func overlaySVG(_ o: Overlay, style: Style, clip: inout Int) -> String {
        switch o {
        case .shape(let s): shapeSVG(s, style: style, clip: &clip)
        case .decal(let d): decalSVG(d, style: style)
        }
    }

    static func shapeSVG(_ s: ShapeLayout, style: Style, clip: inout Int) -> String {
        let d = s.polys.map { poly in "M" + poly.map { "\(n($0.x)) \(n($0.y))" }.joined(separator: "L") + "Z" }.joined()
        let ink = s.shape.stroke ?? style.ink
        var out = #"<g id="\#(esc(s.shape.name))"\#(s.opacity < 0.999 ? #" opacity="\#(n(s.opacity))""# : "")>"#
        out += #"<path d="\#(d)" fill="\#(s.shape.fill ?? "none")" fill-rule="evenodd"/>"#
        if s.shape.hatch {
            clip += 1
            let h = s.polys.flatMap { Hatch.segments($0, gap: style.gap) }.map(seg).joined()
            out += #"<clipPath id="hatch\#(clip)"><path d="\#(d)" clip-rule="evenodd"/></clipPath>"#
            out += #"<path d="\#(h)" fill="none" stroke="\#(ink)" stroke-width="0.8" clip-path="url(#hatch\#(clip))"/>"#
        }
        out += #"<path d="\#(d)" fill="none" stroke="\#(ink)" stroke-width="\#(n(style.weight))" stroke-linecap="round" stroke-linejoin="round"/>"#
        return out + "</g>"
    }

    static func decalSVG(_ d: DecalLayout, style: Style) -> String {
        let decal = d.decal, t = d.transform
        let color = decal.color ?? style.ink
        let m = [t.a, t.b, t.c, t.d, t.tx, t.ty].map { jsNumberString(($0 * 1000).rounded() / 1000) }.joined(separator: " ")
        var out = #"<g id="\#(esc(decal.name))" transform="matrix(\#(m))"\#(d.opacity < 0.999 ? #" opacity="\#(n(d.opacity))""# : "")>"#
        let size = DecalArt.size(decal)
        switch decal.kind {
        case .text:
            out += text(decal.content, x: -size.x / 2, y: -size.y / 2 + Typeset.baseline(decal.size), size: decal.size, fill: color)
        case .svg:
            let f = DecalArt.fittedPathTransform(decal)
            let fm = [f.a, f.b, f.c, f.d, f.tx, f.ty].map { jsNumberString(($0 * 10000).rounded() / 10000) }.joined(separator: " ")
            out += #"<path d="\#(esc(decal.content))" transform="matrix(\#(fm))" fill="\#(color)"/>"#
        case .image:
            if let data = decal.image {
                out += #"<image x="\#(n(-size.x / 2))" y="\#(n(-size.y / 2))" width="\#(n(size.x))" height="\#(n(size.y))" preserveAspectRatio="none" href="data:\#(DecalArt.mimeType(data));base64,\#(data.base64EncodedString())"/>"#
            }
        }
        return out + "</g>"
    }

    static func dimensionSVG(_ d: DimensionLayout, style: Style) -> String {
        let color = d.dimension.color ?? style.ink
        var out = #"<g fill="none" stroke="\#(color)" stroke-width="1" stroke-linecap="round"\#(d.opacity < 0.999 ? #" opacity="\#(n(d.opacity))""# : "")>"#
        out += #"<path d="\#(d.extensions.map(seg).joined())"/>"#
        for s in d.spans {
            out += #"<path d="M\#(n(s.a.x)) \#(n(s.a.y))L\#(n(s.b.x)) \#(n(s.b.y))"/>"# + arrowSVG(s.b, s.a) + arrowSVG(s.a, s.b)
            let m = Typeset.measure(s.label, size: Typeset.dimensionSize)
            out += #"<g transform="translate(\#(n(s.labelCenter.x)) \#(n(s.labelCenter.y))) rotate(\#(n(-s.rotation)))">"#
            out += text(s.label, x: -m.x / 2, y: -m.y / 2 + Typeset.baseline(Typeset.dimensionSize), size: Typeset.dimensionSize, fill: color)
            out += "</g>"
        }
        return out + "</g>"
    }

    static func itemSVG(_ item: FrameItem, style: Style) -> String {
        let fill = style.fill(for: item.part), ink = style.ink(for: item.part)
        let weight = style.weight(for: item.part), gap = style.gap(for: item.part)
        var body = ""
        for run in item.runs {
            let d = run.polys.map { poly in "M" + poly.map { "\(n($0.x)) \(n($0.y))" }.joined(separator: "L") + "Z" }.joined()
            let f = fill.mix(ink, run.shade).css
            body += #"<path d="\#(d)" fill="\#(f)" stroke="\#(f)" stroke-width="0.6" stroke-linejoin="round"/>"#
            if run.kind == .cut {
                let h = run.polys.flatMap { Hatch.segments($0, gap: gap) }.map(seg).joined()
                if !h.isEmpty { body += #"<path d="\#(h)" fill="none" stroke="\#(ink.hex)" stroke-width="0.8"/>"# }
            }
            if !run.edges.isEmpty {
                let e = run.edges.map(seg).joined()
                body += #"<path d="\#(e)" fill="none" stroke="\#(ink.hex)" stroke-width="\#(n(weight))" stroke-linecap="round" stroke-linejoin="round"/>"#
            }
        }
        let opacity = item.opacity < 0.999 ? #" opacity="\#(n(item.opacity))""# : ""
        return #"<g id="\#(esc(item.part.name))" transform="translate(\#(n(item.offset.x)) \#(n(item.offset.y)))"\#(opacity)>\#(body)</g>"#
    }

    static func guideSVG(_ g: GuideLayout, style: Style) -> String {
        let color = g.guide.color ?? style.ink
        let dash = (g.guide.dash ?? [7, 5]).map(n).joined(separator: " ")
        var out = #"<g fill="none" stroke="\#(color)" stroke-width="1"\#(g.guide.opacity.map { #" opacity="\#(n($0))""# } ?? "")>"#
        out += #"<path d="M\#(n(g.a.x)) \#(n(g.a.y))L\#(n(g.b.x)) \#(n(g.b.y))" stroke-dasharray="\#(dash)"/>"#
        if g.guide.arrow { out += arrowSVG(g.a, g.b) }
        return out + "</g>"
    }

    static func calloutSVG(_ c: CalloutLayout, ink: String) -> String {
        let base = c.origin.y + Typeset.baseline(Typeset.calloutSize)
        var out = #"<g fill="none" stroke="\#(ink)" stroke-width="1" stroke-linecap="round"\#(c.opacity < 0.999 ? #" opacity="\#(n(c.opacity))""# : "")>"#
        out += #"<path d="M\#(n(c.start.x)) \#(n(c.start.y))L\#(n(c.end.x)) \#(n(c.end.y))"/>"# + arrowSVG(c.start, c.end)
        out += text(c.text, x: c.origin.x, y: base, size: Typeset.calloutSize, fill: ink)
        return out + "</g>"
    }

    static func sheetSVG(_ s: SheetLayout, style: Style) -> String {
        let r = s.rect, m = s.margin
        var out = #"<rect x="\#(n(r.minX))" y="\#(n(r.minY))" width="\#(n(r.width))" height="\#(n(r.height))" fill="\#(style.sheetFill.hex)"/>"#
        var d = ""
        var x = r.minX + m
        while x <= r.maxX - m + 1e-6 {
            d += "M\(n(x)) \(n(r.minY + m))V\(n(r.maxY - m))"
            x += s.grid
        }
        var y = r.minY + m
        while y <= r.maxY - m + 1e-6 {
            d += "M\(n(r.minX + m)) \(n(y))H\(n(r.maxX - m))"
            y += s.grid
        }
        out += #"<path d="\#(d)" fill="none" stroke="\#(style.ink)" stroke-width="0.5" opacity="0.07"/>"#
        let base = Typeset.baseline(Typeset.sheetSize)
        for label in FramePainter.sheetLabels(s) {
            out += #"<g transform="translate(\#(n(label.origin.x)) \#(n(label.origin.y))) rotate(90)">"#
            out += text(label.text, x: 0, y: base, size: Typeset.sheetSize, fill: style.labelInk.hex) + "</g>"
        }
        return out
    }

    private static func text(_ s: String, x: Double, y: Double, size: Double, fill: String) -> String {
        #"<text x="\#(n(x))" y="\#(n(y))" font-family="JetBrains Mono, SF Mono, ui-monospace, Menlo, monospace" font-size="\#(n(size))" letter-spacing="\#(n(Typeset.tracking(size)))" fill="\#(fill)" stroke="none">\#(esc(s))</text>"#
    }

    private static func arrowSVG(_ a: Vec2, _ b: Vec2) -> String {
        let pts = FramePainter.arrowPoints(from: a, to: b)
        guard pts.count == 2 else { return "" }
        return #"<path d="M\#(n(pts[0].x)) \#(n(pts[0].y))L\#(n(b.x)) \#(n(b.y))L\#(n(pts[1].x)) \#(n(pts[1].y))" stroke-linejoin="round"/>"#
    }

    private static func seg(_ e: (Vec2, Vec2)) -> String { "M\(n(e.0.x)) \(n(e.0.y))L\(n(e.1.x)) \(n(e.1.y))" }

    private static func n(_ v: Double) -> String { jsNumberString(round1(v)) }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
