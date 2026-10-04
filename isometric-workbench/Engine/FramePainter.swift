import CoreGraphics
import CoreText
import IsoDocument
import IsoGeometry
import IsoMath
import IsoRender

/// Draws a frame with Core Graphics. The context must be in scene units with
/// y pointing down.
nonisolated enum FramePainter {
    static func paint(_ frame: Frame, in ctx: CGContext, background: Bool = true) {
        let style = frame.style
        if background {
            ctx.setFillColor(RGB(hex: style.bg).cgColor)
            ctx.fill(frame.bounds.cgRect.insetBy(dx: -1, dy: -1))
        }
        ctx.saveGState()
        for b in frame.boards { paintSheet(b, style: style, in: ctx) }
        for g in frame.guidesBehind { paintGuide(g, style: style, in: ctx) }
        for o in frame.overlaysBehind { paintOverlay(o, style: style, in: ctx) }
        for (i, item) in frame.items.enumerated() {
            if let b = frame.board(item.board), b.clip {
                ctx.saveGState()
                ctx.clip(to: b.rect.cgRect)
                paintItem(item, style: style, in: ctx)
                ctx.restoreGState()
            } else {
                paintItem(item, style: style, in: ctx)
            }
            for g in frame.guidesAbove[i] ?? [] { paintGuide(g, style: style, in: ctx) }
            for o in frame.overlaysAbove[i] ?? [] { paintOverlay(o, style: style, in: ctx) }
        }
        for c in frame.callouts { paintCallout(c, ink: RGB(hex: style.ink), in: ctx) }
        for d in frame.dimensions { paintDimension(d, style: style, in: ctx) }
        ctx.restoreGState()
    }

    static let watermarkText = "MADE WITH ISOMETRIC WORKBENCH"

    /// Bottom centre of `bounds` (clear of the sheet's side labels), where
    /// free exports carry their mark.
    static func watermarkOrigin(_ bounds: Box2) -> Vec2 {
        let size = Typeset.measure(watermarkText, size: Typeset.sheetSize)
        let inset = max(10, min(bounds.width, bounds.height) * 0.02)
        return Vec2(bounds.midX - size.x / 2, bounds.maxY - inset - size.y)
    }

    static func paintWatermark(_ bounds: Box2, style: Style, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(0.75)
        drawText(watermarkText, at: watermarkOrigin(bounds), size: Typeset.sheetSize, color: style.labelInk, in: ctx)
        ctx.restoreGState()
    }

    static func paintOverlay(_ o: Overlay, style: Style, in ctx: CGContext) {
        switch o {
        case .shape(let s): paintShape(s, style: style, in: ctx)
        case .decal(let d): paintDecal(d, style: style, in: ctx)
        }
    }

    static func paintShape(_ s: ShapeLayout, style: Style, in ctx: CGContext) {
        let path = CGMutablePath()
        for poly in s.polys { path.addPolygon(poly) }
        let ink = RGB(hex: s.shape.stroke ?? style.ink)
        ctx.saveGState()
        ctx.setAlpha(s.opacity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        if let fill = s.shape.fill {
            ctx.setFillColor(RGB(hex: fill).cgColor)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        }
        if s.shape.hatch {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: .evenOdd)
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(0.8)
            for poly in s.polys {
                for (a, b) in Hatch.segments(poly, gap: style.gap) {
                    ctx.move(to: a.cgPoint)
                    ctx.addLine(to: b.cgPoint)
                }
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(style.weight)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func paintDecal(_ d: DecalLayout, style: Style, in ctx: CGContext) {
        let decal = d.decal
        let color = RGB(hex: decal.color ?? style.ink)
        ctx.saveGState()
        ctx.setAlpha(d.opacity)
        ctx.concatenate(d.transform)
        let size = DecalArt.size(decal)
        switch decal.kind {
        case .text:
            drawText(decal.content, at: Vec2(-size.x / 2, -size.y / 2), size: decal.size, color: color, in: ctx)
        case .svg:
            if let path = DecalArt.path(decal) {
                ctx.concatenate(DecalArt.fittedPathTransform(decal))
                ctx.setFillColor(color.cgColor)
                ctx.addPath(path)
                ctx.fillPath(using: .winding)
            }
        case .image:
            if let img = DecalArt.image(decal) {
                ctx.interpolationQuality = .high
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: -size.x / 2, y: -size.y / 2, width: size.x, height: size.y))
            }
        }
        ctx.restoreGState()
    }

    static func paintDimension(_ d: DimensionLayout, style: Style, in ctx: CGContext) {
        let color = RGB(hex: d.dimension.color ?? style.ink)
        ctx.saveGState()
        ctx.setAlpha(d.opacity)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)
        for (a, b) in d.extensions {
            ctx.move(to: a.cgPoint)
            ctx.addLine(to: b.cgPoint)
        }
        ctx.strokePath()
        for s in d.spans {
            ctx.move(to: s.a.cgPoint)
            ctx.addLine(to: s.b.cgPoint)
            ctx.strokePath()
            arrowHead(from: s.b, to: s.a, in: ctx)
            arrowHead(from: s.a, to: s.b, in: ctx)
            let m = Typeset.measure(s.label, size: Typeset.dimensionSize)
            ctx.saveGState()
            ctx.translateBy(x: s.labelCenter.x, y: s.labelCenter.y)
            ctx.rotate(by: -s.rotation * .pi / 180)
            drawText(s.label, at: Vec2(-m.x / 2, -m.y / 2), size: Typeset.dimensionSize, color: color, in: ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    static func paintItem(_ item: FrameItem, style: Style, in ctx: CGContext) {
        let fill = style.fill(for: item.part), ink = style.ink(for: item.part)
        let weight = style.weight(for: item.part), gap = style.gap(for: item.part)
        ctx.saveGState()
        ctx.translateBy(x: item.offset.x, y: item.offset.y)
        let faded = item.opacity < 0.999
        if faded {
            ctx.setAlpha(item.opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for run in item.runs {
            let path = CGMutablePath()
            for poly in run.polys { path.addPolygon(poly) }
            let face = fill.mix(ink, run.shade).cgColor
            ctx.setFillColor(face)
            ctx.addPath(path)
            ctx.fillPath()
            // A hairline in the face colour closes seams between pieces.
            ctx.setStrokeColor(face)
            ctx.setLineWidth(0.6)
            ctx.addPath(path)
            ctx.strokePath()
            if run.kind == .cut {
                ctx.setStrokeColor(ink.cgColor)
                ctx.setLineWidth(0.8)
                for poly in run.polys {
                    for (a, b) in Hatch.segments(poly, gap: gap) {
                        ctx.move(to: a.cgPoint)
                        ctx.addLine(to: b.cgPoint)
                    }
                }
                ctx.strokePath()
            }
            if !run.edges.isEmpty {
                ctx.setStrokeColor(ink.cgColor)
                ctx.setLineWidth(weight)
                for (a, b) in run.edges {
                    ctx.move(to: a.cgPoint)
                    ctx.addLine(to: b.cgPoint)
                }
                ctx.strokePath()
            }
        }
        if faded { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    static func paintGuide(_ g: GuideLayout, style: Style, in ctx: CGContext) {
        let color = RGB(hex: g.guide.color ?? style.ink)
        ctx.saveGState()
        ctx.setAlpha(g.guide.opacity ?? 1)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: (g.guide.dash ?? [7, 5]).map { CGFloat($0) })
        ctx.move(to: g.a.cgPoint)
        ctx.addLine(to: g.b.cgPoint)
        ctx.strokePath()
        if g.guide.arrow {
            ctx.setLineDash(phase: 0, lengths: [])
            arrowHead(from: g.a, to: g.b, in: ctx)
        }
        ctx.restoreGState()
    }

    static func paintCallout(_ c: CalloutLayout, ink: RGB, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(c.opacity)
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)
        ctx.move(to: c.start.cgPoint)
        ctx.addLine(to: c.end.cgPoint)
        ctx.strokePath()
        arrowHead(from: c.start, to: c.end, in: ctx)
        drawText(c.text, at: c.origin, size: Typeset.calloutSize, color: ink, in: ctx)
        ctx.restoreGState()
    }

    static func paintSheet(_ s: SheetLayout, style: Style, in ctx: CGContext) {
        let r = s.rect, m = s.margin
        ctx.setFillColor(s.fill.cgColor)
        ctx.fill(r.cgRect)
        guard s.marks else { return }
        ctx.saveGState()
        ctx.setStrokeColor(RGB(hex: style.ink).cgColor(alpha: 0.07))
        ctx.setLineWidth(0.5)
        var x = r.minX + m
        while x <= r.maxX - m + 1e-6 {
            ctx.move(to: CGPoint(x: x, y: r.minY + m))
            ctx.addLine(to: CGPoint(x: x, y: r.maxY - m))
            x += s.grid
        }
        var y = r.minY + m
        while y <= r.maxY - m + 1e-6 {
            ctx.move(to: CGPoint(x: r.minX + m, y: y))
            ctx.addLine(to: CGPoint(x: r.maxX - m, y: y))
            y += s.grid
        }
        ctx.strokePath()
        ctx.restoreGState()
        for label in sheetLabels(s) {
            drawText(label.text, at: label.origin, size: Typeset.sheetSize, color: style.labelInk, rotated: true, in: ctx)
        }
    }

    struct SheetLabel {
        var text: String
        /// Top-right corner of the rotated label (reads top to bottom).
        var origin: Vec2
    }

    /// FIG number at the left margin, title and year at the right — the
    /// plugin's `cmdFrame`, labels turned 90° clockwise.
    static func sheetLabels(_ s: SheetLayout) -> [SheetLabel] {
        let r = s.rect, m = s.margin, h = Typeset.lineHeight(Typeset.sheetSize)
        let title = "[ \(s.title.uppercased()) ]"
        let year = "© " + s.year
        let yearW = Typeset.measure(year, size: Typeset.sheetSize).x
        return [
            SheetLabel(text: s.fig, origin: Vec2(r.minX + m - 12, r.minY + m)),
            SheetLabel(text: title, origin: Vec2(r.maxX - m + 12 + h, r.minY + m)),
            SheetLabel(text: year, origin: Vec2(r.maxX - m + 12 + h, r.maxY - m - yearW)),
        ]
    }

    /// Open arrowhead at `b`, like Figma's `ARROW_LINES` cap at weight 1.
    static func arrowHead(from a: Vec2, to b: Vec2, in ctx: CGContext) {
        for p in arrowPoints(from: a, to: b) {
            ctx.move(to: p.cgPoint)
            ctx.addLine(to: b.cgPoint)
        }
        ctx.strokePath()
    }

    static func arrowPoints(from a: Vec2, to b: Vec2, size: Double = 6) -> [Vec2] {
        let d = b - a, l = hypot(d.x, d.y)
        guard l > 1e-6 else { return [] }
        let u = d * (1 / l), n = Vec2(-u.y, u.x)
        return [b - u * size + n * (size * 0.55), b - u * size - n * (size * 0.55)]
    }

    /// Draws a label with its line box's top-left at `origin` (or, rotated,
    /// its top-right).
    static func drawText(
        _ text: String, at origin: Vec2, size: Double, color: RGB, rotated: Bool = false, tracking: Double? = nil, in ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.textMatrix = .identity
        ctx.translateBy(x: origin.x, y: origin.y)
        if rotated { ctx.rotate(by: .pi / 2) }
        ctx.translateBy(x: 0, y: Typeset.baseline(size))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(Typeset.line(text, size: size, tracking: tracking), ctx)
        ctx.restoreGState()
    }
}

nonisolated extension Vec2 {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

nonisolated extension Box2 {
    var cgRect: CGRect { isEmpty ? .zero : CGRect(x: minX, y: minY, width: width, height: height) }

    func contains(_ p: Vec2) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }

    func contains(_ b: Box2) -> Bool { b.minX >= minX && b.maxX <= maxX && b.minY >= minY && b.maxY <= maxY }

    func intersects(_ b: Box2) -> Bool { b.minX <= maxX && b.maxX >= minX && b.minY <= maxY && b.maxY >= minY }
}

nonisolated extension CGMutablePath {
    func addPolygon(_ pts: [Vec2]) {
        guard let first = pts.first else { return }
        move(to: first.cgPoint)
        for p in pts.dropFirst() { addLine(to: p.cgPoint) }
        closeSubpath()
    }
}
