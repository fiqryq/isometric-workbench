import AppKit
import IsoDocument
import IsoGeometry
import IsoMath
import IsoRender
import SwiftUI

struct Viewport: NSViewRepresentable {
    let model: SceneModel

    func makeNSView(context: Context) -> ViewportView { ViewportView(model: model) }

    func updateNSView(_ view: ViewportView, context: Context) {}
}

/// A plane on screen: maps between scene (screen-space iso) points and the
/// plane's 2D coordinates, through a part's pose or the camera.
struct DrawTarget {
    var plane: SketchPlane
    var view: ViewTransform
    var offset: Vec2
    var angle: IsoAngle

    func toPlane(_ s: Vec2) -> Vec2? {
        angle.screenToPlane(s.x - offset.x, s.y - offset.y, axis: plane.axis, at: plane.at, view: view)
            .map { IsoPlaneMapping.planeTo2(axis: plane.axis, $0) }
    }

    func toScreen(_ p: Vec2) -> Vec2 {
        angle.project(view.apply(IsoPlaneMapping.planeTo3(axis: plane.axis, at: plane.at)(p))) + offset
    }
}

/// The drawing canvas: renders the current frame with Core Graphics and turns
/// mouse and keyboard input into model edits.
final class ViewportView: NSView {
    let model: SceneModel
    private var frameCache: Frame?
    private var didInitialFit = false
    private var drag: Drag?
    private var lastTool: Tool = .select

    /// Shape being dragged out, in plane coordinates.
    private var shapeDrag: (target: DrawTarget, start: Vec2, current: Vec2, even: Bool)?
    private var penTarget: DrawTarget?
    private var penPoints: [Vec2] = []
    private var hover: Vec2?

    private enum HoverTarget: Equatable {
        case part(Part.ID)
        case frame(Artboard.ID)
    }

    /// What the select tool would pick under the pointer, outlined as in Figma.
    private var hoverTarget: HoverTarget?

    private var ringCache: (key: String, rings: [(RingPick, [(Vec2, Vec2)])])?

    private enum DragMode {
        case move, lift, spin, pan, orbit, annotation, frameMove, frameResize, frameDraw, marquee
    }

    /// Space held down: drags pan, as in Figma. A tap with no pan plays.
    private var spaceHeld = false
    private var spacePanned = false

    private struct Drag {
        var mode: DragMode
        var start: CGPoint
        var last: CGPoint
        var moved = false
        var hitPart: Part.ID?
        var extend = false
        var startPan = Vec2.zero
        var annotation: AnnotationRef?
        var target: DrawTarget?
        var planeStart = Vec2.zero
        /// Which edges a frame resize moves: -1 min, 1 max, 0 neither.
        var handle = (x: 0, y: 0)
        var board: Artboard.ID?
        var boardStart = Box2.empty
        /// The frames when the drag began, for dropping parts into them.
        var boards: [SheetLayout] = []
        /// The selection when a marquee began, kept when extending with ⇧.
        var baseSelection: Set<Part.ID> = []
        var baseFrames: Set<Artboard.ID> = []
    }

    init(model: SceneModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Since the macOS 14 SDK views don't clip by default; panned art would paint over the page tabs.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        model.viewportSize = newSize
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        if model.tool.draws || model.tool == .frame { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: - Coordinates

    private var viewCenter: Vec2 { Vec2(bounds.midX, bounds.midY) }

    /// View point → scene (screen-space iso) coordinates.
    private func scenePoint(_ p: CGPoint) -> Vec2 {
        (Vec2(p.x, p.y) - viewCenter - model.pan) * (1 / model.zoom)
    }

    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// One screen point in scene units.
    private var px: Double { 1 / model.zoom }

    private func viewRect(_ b: Box2) -> CGRect {
        CGRect(x: b.minX * model.zoom + viewCenter.x + model.pan.x, y: b.minY * model.zoom + viewCenter.y + model.pan.y,
               width: b.width * model.zoom, height: b.height * model.zoom)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        withObservationTracking {
            render(ctx)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    private func render(_ ctx: CGContext) {
        _ = model.build.generation
        if model.tool != lastTool {
            if lastTool == .pen { cancelPen() }
            lastTool = model.tool
            window?.invalidateCursorRects(for: self)
        }
        let frame = model.frame()
        frameCache = frame
        let style = frame.style

        ctx.setFillColor(RGB(hex: style.bg).mix(.black, 0.035).cgColor)
        ctx.fill(bounds)

        ctx.saveGState()
        ctx.translateBy(x: viewCenter.x + model.pan.x, y: viewCenter.y + model.pan.y)
        ctx.scaleBy(x: model.zoom, y: model.zoom)
        FramePainter.paint(frame, in: ctx, background: false)
        paintSelection(frame, in: ctx)
        if model.tool == .rings { paintRings(frame, in: ctx) }
        paintSketches(frame, in: ctx)
        ctx.restoreGState()
        paintChrome(frame, in: ctx)

        if frame.items.isEmpty && model.scene.isEmpty { paintEmptyHint(in: ctx) }

        if !didInitialFit, frame.complete, !frame.items.isEmpty || !frame.boards.isEmpty {
            didInitialFit = true
            DispatchQueue.main.async { [model] in model.zoomToFit() }
        }
    }

    private var accent: CGColor {
        NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1)
    }

    /// Picked faces, rings and annotations; outlines and handles are drawn in
    /// view space by `paintChrome`.
    private func paintSelection(_ frame: Frame, in ctx: CGContext) {
        for f in model.pickedFaces {
            guard let item = frame.item(for: f.partID) else { continue }
            highlight(item, in: ctx) { $0.faceKey == f.face.key }
        }
        for s in model.pickedSegments {
            guard let item = frame.item(for: s.partID), let info = model.loopInfos(item.part).first(where: { $0.loopID == s.loopID }) else { continue }
            let last = info.knots.count - 2
            let lo = s.segment == 0 ? nil : round2(info.knots[s.segment])
            let hi = s.segment >= last ? nil : round2(info.knots[s.segment + 1])
            highlight(item, in: ctx) { run in
                guard let face = run.face, face.n.dot(s.face.direction) > 0.999 else { return false }
                guard let b = face.bounds.first(where: { $0.k == info.k }) else { return info.knots.count <= 2 }
                return b.lo == lo && b.hi == hi
            }
        }
        if let a = model.annotation { paintAnnotationSelection(a, frame, in: ctx) }
    }

    private func highlight(_ item: FrameItem, in ctx: CGContext, where match: (Run) -> Bool) {
        let accent = accent
        ctx.saveGState()
        ctx.translateBy(x: item.offset.x, y: item.offset.y)
        let path = CGMutablePath()
        for run in item.runs where match(run) {
            for poly in run.polys { path.addPolygon(poly) }
        }
        ctx.setFillColor(accent.copy(alpha: 0.28) ?? accent)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(2 * px)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func paintAnnotationSelection(_ a: AnnotationRef, _ frame: Frame, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.5 * px)
        ctx.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
        switch a {
        case .decal(let id):
            for case .decal(let d) in frame.allOverlays where d.decal.id == id {
                let path = CGMutablePath()
                path.addPolygon(d.outline)
                ctx.addPath(path)
            }
        case .shape(let id):
            for case .shape(let s) in frame.allOverlays where s.shape.id == id {
                ctx.addRect(s.box.cgRect.insetBy(dx: -4 * px, dy: -4 * px))
            }
        case .dimension(let id):
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(3 * px)
            ctx.setStrokeColor(accent.copy(alpha: 0.5) ?? accent)
            for d in frame.dimensions where d.dimension.id == id {
                for s in d.spans {
                    ctx.move(to: s.a.cgPoint)
                    ctx.addLine(to: s.b.cgPoint)
                }
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Ring outlines of the selected parts, for the loop rings tool.
    private func rings(_ frame: Frame) -> [(RingPick, [(Vec2, Vec2)])] {
        let items = frame.items.filter { model.selection.contains($0.part.id) }
        let key = items.map { "\($0.part.id)|\($0.part.ops.hashValue)|\($0.rotation)|\($0.offset)" }.joined(separator: ";") + "|\(frame.angle.degrees)"
        if let c = ringCache, c.key == key { return c.rings }
        var out: [(RingPick, [(Vec2, Vec2)])] = []
        for item in items {
            guard let mesh = model.build.cachedMesh(item.part.ops) else { continue }
            let opts = RenderOptions(rotation: item.rotation, pivot: mesh.bounds.center, angle: frame.angle, smooth: item.part.smooth)
            for info in model.loopInfos(item.part) {
                for (j, t) in info.knots.enumerated() {
                    let segs = RingOutline.trace(mesh, k: info.k, t: t, options: opts).map { ($0.0 + item.offset, $0.1 + item.offset) }
                    out.append((RingPick(partID: item.part.id, loopID: info.loopID, knot: j), segs))
                }
            }
        }
        ringCache = (key, out)
        return out
    }

    private func paintRings(_ frame: Frame, in ctx: CGContext) {
        let accent = accent
        let picked = Set(model.pickedRings)
        for (pick, segs) in rings(frame) {
            let on = picked.contains(pick)
            ctx.saveGState()
            ctx.setStrokeColor(on ? accent : accent.copy(alpha: 0.55) ?? accent)
            ctx.setLineWidth((on ? 3 : 1.25) * px)
            ctx.setLineCap(.round)
            if !on { ctx.setLineDash(phase: 0, lengths: [3 * px, 3 * px]) }
            for (a, b) in segs {
                ctx.move(to: a.cgPoint)
                ctx.addLine(to: b.cgPoint)
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// The pending sketch, the shape being dragged and the pen path.
    private func paintSketches(_ frame: Frame, in ctx: CGContext) {
        let accent = accent
        func outline(_ pts: [Vec2], closed: Bool, dashed: Bool = false) {
            guard let first = pts.first else { return }
            let path = CGMutablePath()
            path.move(to: first.cgPoint)
            pts.dropFirst().forEach { path.addLine(to: $0.cgPoint) }
            if closed { path.closeSubpath() }
            ctx.saveGState()
            if closed {
                ctx.setFillColor(accent.copy(alpha: 0.14) ?? accent)
                ctx.addPath(path)
                ctx.fillPath(using: .evenOdd)
            }
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5 * px)
            ctx.setLineJoin(.round)
            if dashed { ctx.setLineDash(phase: 0, lengths: [5 * px, 3 * px]) }
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
        if let sk = model.sketch, let target = target(for: sk.plane, frame) {
            for loop in sk.loops { outline(loop.map(target.toScreen), closed: true, dashed: true) }
        }
        if let d = shapeDrag {
            for loop in dragLoops(d) { outline(loop.map(d.target.toScreen), closed: true) }
        }
        if let target = penTarget, !penPoints.isEmpty {
            var pts = penPoints.map(target.toScreen)
            if let h = hover, let q = target.toPlane(h) { pts.append(target.toScreen(snapPen(q))) }
            outline(pts, closed: false)
            ctx.saveGState()
            for (i, p) in penPoints.map(target.toScreen).enumerated() {
                let r = (i == 0 ? 4.5 : 3) * px
                let dot = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
                ctx.setFillColor(i == 0 ? accent : CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(accent)
                ctx.setLineWidth(1.25 * px)
                ctx.strokeEllipse(in: dot)
            }
            ctx.restoreGState()
        }
    }

    // MARK: - Frame

    private static let frameLabelFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// A frame's name above its top-left corner, in view points.
    private func frameLabelRect(_ board: SheetLayout) -> CGRect {
        let r = viewRect(board.rect)
        let size = (board.name as NSString).size(withAttributes: [.font: Self.frameLabelFont])
        return CGRect(x: r.minX, y: r.minY - size.height - 4, width: min(size.width.rounded(.up), max(0, r.width)), height: size.height)
    }

    /// Edges under `p` when it's on a frame's outline.
    private func frameHandle(at p: CGPoint, _ rect: Box2) -> (x: Int, y: Int)? {
        let r = viewRect(rect), tol = 5.0
        guard r.insetBy(dx: -tol, dy: -tol).contains(p) else { return nil }
        let x = abs(p.x - r.minX) <= tol ? -1 : abs(p.x - r.maxX) <= tol ? 1 : 0
        let y = abs(p.y - r.minY) <= tol ? -1 : abs(p.y - r.maxY) <= tol ? 1 : 0
        return x == 0 && y == 0 ? nil : (x, y)
    }

    private var selectedLayout: SheetLayout? { frameCache?.board(model.selectedFrame) }

    /// A rect snapped so 1 pt strokes land on whole pixels.
    private func crisp(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded() + 0.5, y: r.minY.rounded() + 0.5, width: max(0, r.width.rounded() - 1), height: max(0, r.height.rounded() - 1))
    }

    /// Figma-style selection in view space, so lines stay 1 pt at any zoom:
    /// frame names, a hover outline, an outline per picked part and frame, a
    /// box around a multiple selection, resize handles and size for a lone
    /// frame, and the marquee.
    private func paintChrome(_ frame: Frame, in ctx: CGContext) {
        let accent = accent
        let picking = model.tool == .select && drag == nil
        let hovered: Artboard.ID? = if picking, case .frame(let id) = hoverTarget { id } else { nil }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let quiet = NSColor(cgColor: RGB(hex: frame.style.bg).mix(.black, 0.55).cgColor) ?? .gray
        let accentInk = NSColor(cgColor: accent) ?? .controlAccentColor
        for b in frame.boards {
            let hot = model.selectedFrames.contains(b.id) || b.id == hovered
            (b.name as NSString).draw(in: frameLabelRect(b), withAttributes: [.font: Self.frameLabelFont, .foregroundColor: hot ? accentInk : quiet, .paragraphStyle: para])
        }

        ctx.saveGState()
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1)

        if picking, let t = hoverTarget {
            switch t {
            case .part(let id) where !model.selection.contains(id):
                if let item = frame.item(for: id) { ctx.stroke(crisp(viewRect(item.box))) }
            case .frame(let id) where !model.selectedFrames.contains(id):
                if let b = frame.board(id) { ctx.stroke(crisp(viewRect(b.rect))) }
            default: break
            }
        }

        let partRects = frame.items.filter { model.selection.contains($0.part.id) }.map { viewRect($0.box) }
        let frameRects = frame.boards.filter { model.selectedFrames.contains($0.id) }.map { viewRect($0.rect) }
        let picked = partRects + frameRects
        picked.forEach { ctx.stroke(crisp($0)) }
        if picked.count > 1 {
            ctx.stroke(crisp(picked.dropFirst().reduce(picked[0]) { $0.union($1) }.insetBy(dx: -4, dy: -4)))
        }

        if let b = selectedLayout {
            let r = crisp(viewRect(b.rect))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            for x in [r.minX, r.midX, r.maxX] {
                for y in [r.minY, r.midY, r.maxY] where x != r.midX || y != r.midY {
                    // Edge handles only when the frame is big enough to keep them apart.
                    if (x == r.midX && r.width < 48) || (y == r.midY && r.height < 48) { continue }
                    let h = CGRect(x: (x - 4).rounded() + 0.5, y: (y - 4).rounded() + 0.5, width: 7, height: 7)
                    ctx.fill(h)
                    ctx.stroke(h)
                }
            }
        }
        ctx.restoreGState()

        if partRects.isEmpty, !frameRects.isEmpty {
            let boxes = frame.boards.filter { model.selectedFrames.contains($0.id) }.map(\.rect)
            let u = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            let all = frameRects.dropFirst().reduce(frameRects[0]) { $0.union($1) }
            paintSizePill("\(jsNumberString(u.width.rounded())) × \(jsNumberString(u.height.rounded()))", below: all, in: ctx)
        }

        if let d = drag, d.mode == .frameDraw || d.mode == .marquee, d.moved {
            let r = CGRect(x: min(d.start.x, d.last.x), y: min(d.start.y, d.last.y), width: abs(d.last.x - d.start.x), height: abs(d.last.y - d.start.y))
            ctx.saveGState()
            ctx.setFillColor(accent.copy(alpha: 0.08) ?? accent)
            ctx.fill(r)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1)
            ctx.stroke(crisp(r))
            ctx.restoreGState()
            if d.mode == .frameDraw {
                paintSizePill("\(jsNumberString((r.width / model.zoom).rounded())) × \(jsNumberString((r.height / model.zoom).rounded()))", below: r, in: ctx)
            }
        }
    }

    /// Figma's dimension label: white figures on an accent pill under `r`.
    private func paintSizePill(_ text: String, below r: CGRect, in ctx: CGContext) {
        let s = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.white]
        let m = s.size(withAttributes: attrs)
        let pill = CGRect(x: (r.midX - m.width / 2 - 6).rounded(), y: (r.maxY + 8).rounded(), width: (m.width + 12).rounded(.up), height: (m.height + 4).rounded(.up))
        ctx.saveGState()
        ctx.setFillColor(accent)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        s.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
    }

    private func paintEmptyHint(in ctx: CGContext) {
        let text = "Add a primitive with + or draw with the shape tools" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }

    // MARK: - Targets

    private func worldTarget(_ frame: Frame) -> DrawTarget {
        DrawTarget(plane: SketchPlane(axis: model.drawPlane.axis, at: 0, host: nil), view: frame.worldView, offset: .zero, angle: frame.angle)
    }

    private func target(for plane: SketchPlane, _ frame: Frame) -> DrawTarget? {
        guard let host = plane.host else {
            var t = worldTarget(frame)
            t.plane = plane
            return t
        }
        guard let item = frame.item(for: host) else { return nil }
        return DrawTarget(plane: plane, view: item.view, offset: item.offset, angle: frame.angle)
    }

    /// The face under the pointer (when it faces +x, +y or +z), else the
    /// world draw plane.
    private func drawTarget(at p: CGPoint) -> DrawTarget? {
        guard let frame = frameCache else { return nil }
        if let h = hit(p), let run = h.run, run.kind == .solid, let face = run.face, let axis = SceneModel.axis(of: face.n),
           let item = frame.item(for: h.part.id) {
            return DrawTarget(plane: SketchPlane(axis: axis, at: face.w, host: h.part.id), view: item.view, offset: item.offset, angle: frame.angle)
        }
        let t = worldTarget(frame)
        return t.toPlane(scenePoint(p)) == nil ? nil : t
    }

    private func snap(_ p: Vec2) -> Vec2 { Vec2(p.x.rounded(), p.y.rounded()) }

    private func dragLoops(_ d: (target: DrawTarget, start: Vec2, current: Vec2, even: Bool)) -> [Loop] {
        var b = d.current
        if d.even {
            let dx = b.x - d.start.x, dy = b.y - d.start.y, m = max(abs(dx), abs(dy))
            b = Vec2(d.start.x + (dx < 0 ? -m : m), d.start.y + (dy < 0 ? -m : m))
        }
        guard abs(b.x - d.start.x) >= 1, abs(b.y - d.start.y) >= 1 else { return [] }
        switch model.tool {
        case .ellipse: return [Sketch.ellipse(d.start, b)]
        case .polygon: return [Sketch.polygon(d.start, b, sides: model.polygonSides)]
        default: return [Sketch.rectangle(d.start, b)]
        }
    }

    private func snapPen(_ q: Vec2) -> Vec2 {
        var q = snap(q)
        if NSEvent.modifierFlags.contains(.shift), let last = penPoints.last {
            // 45° steps in the plane.
            let d = q - last, a = (atan2(d.y, d.x) / (.pi / 4)).rounded() * (.pi / 4), l = hypot(d.x, d.y)
            q = snap(last + Vec2(cos(a), sin(a)) * l)
        }
        return q
    }

    // MARK: - Hit testing

    private struct Hit {
        var part: Part
        var run: Run?
    }

    private func hit(_ p: CGPoint) -> Hit? {
        guard let frame = frameCache else { return nil }
        let s = scenePoint(p)
        for item in frame.items.reversed() where item.box.insetBy(-2).contains(s) {
            if let b = frame.board(item.board), b.clip, !b.rect.contains(s) { continue }
            let q = s - item.offset
            for run in item.runs.reversed() {
                for (i, poly) in run.polys.enumerated() where run.boxes[i].insetBy(-1).contains(q) && Loop2D.contains(q, in: poly) {
                    return Hit(part: item.part, run: run)
                }
            }
        }
        for c in frame.callouts where c.box.insetBy(-3).contains(s) {
            if let p = model.scene.parts.first(where: { $0.id == c.partID }) { return Hit(part: p, run: nil) }
        }
        return nil
    }

    private func hitOverlay(_ overlays: [Overlay], _ s: Vec2) -> AnnotationRef? {
        for o in overlays.reversed() {
            switch o {
            case .decal(let d) where Loop2D.contains(s, in: d.outline):
                return .decal(d.decal.id)
            case .shape(let sh) where sh.box.insetBy(-2).contains(s):
                let inside = sh.polys.filter { Loop2D.contains(s, in: $0) }.count % 2 == 1
                if inside || sh.shape.fill == nil && sh.polys.contains(where: { distance(s, to: $0) < 4 * px }) { return .shape(sh.shape.id) }
            default: break
            }
        }
        return nil
    }

    private func distance(_ p: Vec2, to poly: [Vec2]) -> Double {
        var best = Double.infinity
        for i in poly.indices { best = min(best, segmentDistance(p, poly[i], poly[(i + 1) % poly.count])) }
        return best
    }

    private func segmentDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let d = b - a, l2 = d.x * d.x + d.y * d.y
        let t = l2 > 0 ? clamp(((p - a).x * d.x + (p - a).y * d.y) / l2, 0, 1) : 0
        let q = a + d * t
        return hypot(p.x - q.x, p.y - q.y)
    }

    /// Hosted art (drawn over parts) wins over parts; world art loses.
    private func annotationHit(_ p: CGPoint, partHit: Bool) -> AnnotationRef? {
        guard let frame = frameCache else { return nil }
        let s = scenePoint(p)
        let above = frame.overlaysAbove.keys.sorted().flatMap { frame.overlaysAbove[$0]! }
        if let a = hitOverlay(above, s) { return a }
        for d in frame.dimensions {
            for sp in d.spans where segmentDistance(s, sp.a, sp.b) < 4 * px || hypot(s.x - sp.labelCenter.x, s.y - sp.labelCenter.y) < 10 {
                return .dimension(d.dimension.id)
            }
        }
        return partHit ? nil : hitOverlay(frame.overlaysBehind, s)
    }

    private func annotationTarget(_ a: AnnotationRef) -> DrawTarget? {
        guard let frame = frameCache else { return nil }
        switch a {
        case .decal(let id):
            guard let d = model.scene.decals.first(where: { $0.id == id }) else { return nil }
            return target(for: SketchPlane(axis: d.axis, at: d.at, host: d.host), frame)
        case .shape(let id):
            guard let s = model.scene.shapes.first(where: { $0.id == id }) else { return nil }
            return target(for: SketchPlane(axis: s.axis, at: s.at, host: s.host), frame)
        case .dimension: return nil
        }
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        if spaceHeld {
            NSCursor.openHand.set()
        } else if model.tool == .select, let b = selectedLayout {
            switch frameHandle(at: local(event), b.rect) {
            case let h? where h.y == 0: NSCursor.resizeLeftRight.set()
            case let h? where h.x == 0: NSCursor.resizeUpDown.set()
            case .some: NSCursor.crosshair.set()
            case nil: NSCursor.arrow.set()
            }
        }
        setHover(model.tool == .select && !spaceHeld ? pickTarget(at: local(event)) : nil)
        guard penTarget != nil else { return }
        hover = scenePoint(local(event))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        setHover(nil)
        if penTarget != nil { needsDisplay = true }
    }

    private func setHover(_ t: HoverTarget?) {
        guard t != hoverTarget else { return }
        hoverTarget = t
        needsDisplay = true
    }

    /// What a click with the select tool would pick: a frame by its name, then
    /// a part, then a frame by its empty area.
    private func pickTarget(at p: CGPoint) -> HoverTarget? {
        guard let frame = frameCache else { return nil }
        if let b = frame.boards.last(where: { frameLabelRect($0).contains(p) }) { return .frame(b.id) }
        if let h = hit(p) { return .part(h.part.id) }
        let s = scenePoint(p)
        return frame.boards.last { $0.rect.contains(s) }.map { .frame($0.id) }
    }

    // Middle-button drag pans the canvas with any tool, as in Figma and Sketch.
    private var middlePan: (start: CGPoint, startPan: Vec2)?

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        middlePan = (local(event), model.pan)
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let m = middlePan else { return super.otherMouseDragged(with: event) }
        let p = local(event)
        model.pan = m.startPan + Vec2(p.x - m.start.x, p.y - m.start.y)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard middlePan != nil else { return super.otherMouseUp(with: event) }
        middlePan = nil
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = local(event)
        if spaceHeld {
            spacePanned = true
            NSCursor.closedHand.set()
            drag = Drag(mode: .pan, start: p, last: p, startPan: model.pan)
            return
        }
        switch model.tool {
        case .rectangle, .ellipse, .polygon:
            guard let t = drawTarget(at: p), let q = t.toPlane(scenePoint(p)) else { return }
            shapeDrag = (t, snap(q), snap(q), event.modifierFlags.contains(.shift))
            return
        case .pen:
            penClick(p, clickCount: event.clickCount)
            return
        case .rings:
            ringClick(p, extend: event.modifierFlags.contains(.shift))
            return
        case .frame:
            drag = Drag(mode: .frameDraw, start: p, last: p)
            return
        case .select:
            break
        }
        let flags = event.modifierFlags
        if let b = selectedLayout, let handle = frameHandle(at: p, b.rect) {
            drag = Drag(mode: .frameResize, start: p, last: p, handle: handle, board: b.id, boardStart: b.rect)
            return
        }
        if let b = frameCache?.boards.last(where: { frameLabelRect($0).contains(p) }) {
            grabFrame(b, at: p, extend: flags.contains(.shift))
            return
        }
        let h = hit(p)
        if flags.contains(.command), let h, let run = h.run, run.kind == .solid, let face = run.face {
            model.toggleFace(h.part.id, face)
            return
        }
        if let a = annotationHit(p, partHit: h != nil) {
            model.annotation = a
            model.selection = []
            var d = Drag(mode: .annotation, start: p, last: p, annotation: a)
            if let t = annotationTarget(a), let q = t.toPlane(scenePoint(p)) {
                d.target = t
                d.planeStart = q
            }
            drag = d
            return
        }
        model.annotation = nil
        if let h {
            let extend = flags.contains(.shift)
            if !model.selection.contains(h.part.id) && !extend {
                model.selection = [h.part.id]
                model.pickedFaces.removeAll { $0.partID != h.part.id }
            }
            let mode: DragMode = flags.contains(.option) ? .spin : extend ? .lift : .move
            drag = Drag(mode: mode, start: p, last: p, hitPart: h.part.id, extend: extend, boards: frameCache?.boards ?? [])
        } else if flags.contains(.option) {
            drag = Drag(mode: .orbit, start: p, last: p)
        } else if let b = frameCache?.boards.last(where: { $0.rect.contains(scenePoint(p)) }) {
            // A frame's empty area grabs the frame, so it can go anywhere on the canvas.
            grabFrame(b, at: p, extend: flags.contains(.shift))
        } else {
            let extend = flags.contains(.shift)
            if !extend {
                model.selection = []
                model.pickedFaces = []
                model.selectedFrames = []
            }
            drag = Drag(mode: .marquee, start: p, last: p, extend: extend, baseSelection: model.selection, baseFrames: model.selectedFrames)
        }
    }

    /// Picks a frame for dragging. A frame already in a multiple selection keeps
    /// it, so the whole selection moves; ⇧ adds or removes the frame.
    private func grabFrame(_ b: SheetLayout, at p: CGPoint, extend: Bool) {
        if extend {
            model.annotation = nil
            model.selectedFrames.formSymmetricDifference([b.id])
        } else if !model.selectedFrames.contains(b.id) {
            model.selectFrame(b.id)
        }
        drag = Drag(mode: .frameMove, start: p, last: p, extend: extend, board: b.id, boardStart: b.rect, boards: frameCache?.boards ?? [])
    }

    /// As in Figma, frames the marquee touches are picked whole; loose parts it
    /// touches are picked on their own.
    private func updateMarquee(_ d: Drag) {
        guard let frame = frameCache else { return }
        let a = scenePoint(d.start), b = scenePoint(d.last)
        let r = Box2(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
        let frames = d.baseFrames.union(frame.boards.filter { $0.rect.intersects(r) }.map(\.id))
        let hits = frame.items.filter { item in
            !item.part.locked && item.box.intersects(r) && !(item.board.map(frames.contains) ?? false)
        }.map(\.part.id)
        let parts = d.baseSelection.union(hits).subtracting(model.framedParts(frames))
        if parts != model.selection { model.selection = parts }
        if frames != model.selectedFrames { model.selectedFrames = frames }
    }

    /// Drags the selected frames (with their parts) and loose selected parts together.
    private func moveSelected(_ d: Drag, dx: Double, dy: Double) {
        let frames = model.selectedFrames
        if !frames.isEmpty {
            let base = model.gestureBase, t = model.frameTime, step = Vec2(dx.rounded(), dy.rounded())
            let rects = Dictionary(d.boards.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
            model.updateGesture { s in
                for f in frames { SceneModel.moveFrame(f, by: step, in: &s, from: base, at: t, rect: rects[f]) }
            }
        }
        transformSelection(dx: dx, dy: dy, mode: .move, skipping: model.framedParts(frames))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = local(event)
        if var d = shapeDrag {
            if let q = d.target.toPlane(scenePoint(p)) { d.current = snap(q) }
            d.even = event.modifierFlags.contains(.shift)
            shapeDrag = d
            needsDisplay = true
            return
        }
        guard var d = drag else { return }
        if !d.moved && hypot(p.x - d.start.x, p.y - d.start.y) < 3 { return }
        if !d.moved, d.extend, let id = d.hitPart, !model.selection.contains(id) { model.selection.insert(id) }
        d.moved = true
        d.last = p
        drag = d
        let dx = (p.x - d.start.x) / model.zoom, dy = (p.y - d.start.y) / model.zoom
        switch d.mode {
        case .pan:
            model.pan = d.startPan + Vec2(p.x - d.start.x, p.y - d.start.y)
        case .orbit:
            let base = model.gestureBase.camera.value("spin", at: model.frameTime)
            let t = model.frameTime, auto = model.autoKey
            model.updateGesture { $0.camera.set("spin", jsRound(base + dx * 0.5), at: t, autoKey: auto) }
        case .annotation:
            guard let a = d.annotation, let t = d.target, let q = t.toPlane(scenePoint(p)) else { return }
            model.dragAnnotation(a, by: snap(q - d.planeStart))
        case .move, .frameMove:
            moveSelected(d, dx: dx, dy: dy)
        case .lift, .spin:
            transformSelection(dx: dx, dy: dy, mode: d.mode)
        case .frameDraw:
            needsDisplay = true
        case .marquee:
            updateMarquee(d)
            needsDisplay = true
        case .frameResize:
            guard let id = d.board else { return }
            let b0 = d.boardStart, h = d.handle
            var b = b0
            if h.x < 0 { b.minX = min(b0.minX + dx, b0.maxX - 16).rounded() }
            if h.x > 0 { b.maxX = max(b0.maxX + dx, b0.minX + 16).rounded() }
            if h.y < 0 { b.minY = min(b0.minY + dy, b0.maxY - 16).rounded() }
            if h.y > 0 { b.maxY = max(b0.maxY + dy, b0.minY + 16).rounded() }
            model.updateGesture { s in
                guard let i = s.frames.firstIndex(where: { $0.id == id }) else { return }
                s.frames[i].origin = Vec2(b.minX, b.minY)
                s.frames[i].size = Vec2(b.width, b.height)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let d = shapeDrag {
            shapeDrag = nil
            let loops = dragLoops(d)
            if !loops.isEmpty { model.finishSketch(loops, plane: d.target.plane, name: model.tool.title) }
            needsDisplay = true
            return
        }
        guard let d = drag else { return }
        drag = nil
        if d.mode == .pan { (spaceHeld ? NSCursor.openHand : NSCursor.arrow).set() }
        if d.mode == .frameDraw {
            let a = scenePoint(d.start), b = scenePoint(d.last)
            let rect = d.moved
                ? Box2(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
                : Box2(minX: a.x, minY: a.y, maxX: a.x + 400, maxY: a.y + 300)
            model.addFrame(rect)
            model.tool = .select
            needsDisplay = true
            return
        }
        if d.moved {
            switch d.mode {
            case .pan, .frameDraw: break
            case .marquee: needsDisplay = true
            case .orbit: model.endGesture("Orbit Camera")
            case .move, .frameMove:
                // Parts carried by a moving frame stay in it; loose parts join the frame they land in.
                let frames = model.selectedFrames
                let loose = model.selection.subtracting(model.framedParts(frames))
                if !loose.isEmpty { model.reparent(loose, among: d.boards.filter { !frames.contains($0.id) }) }
                model.endGesture(frames.count == 1 && model.selection.isEmpty ? "Move Frame" : "Move")
            case .lift: model.endGesture("Lift")
            case .spin: model.endGesture("Rotate")
            case .annotation: model.endGesture("Move Art")
            case .frameResize: model.endGesture("Resize Frame")
            }
            return
        }
        // A plain click on a frame in a multiple selection narrows it to that frame.
        if d.mode == .frameMove, !d.extend, let id = d.board { model.selectFrame(id) }
        if [.annotation, .frameMove, .frameResize, .pan, .marquee].contains(d.mode) { return }
        if let id = d.hitPart {
            if d.extend {
                if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
            } else {
                model.selection = [id]
            }
        } else {
            model.selection = []
            model.pickedFaces = []
            model.selectedFrame = nil
        }
    }

    // MARK: - Pen

    private func penClick(_ p: CGPoint, clickCount: Int) {
        if penTarget == nil {
            guard let t = drawTarget(at: p), let q = t.toPlane(scenePoint(p)) else { return }
            penTarget = t
            penPoints = [snap(q)]
            hover = scenePoint(p)
            needsDisplay = true
            return
        }
        guard let t = penTarget else { return }
        if clickCount >= 2 {
            closePen()
            return
        }
        let s = scenePoint(p)
        if penPoints.count >= 3, let first = penPoints.first {
            let f = t.toScreen(first)
            if hypot(s.x - f.x, s.y - f.y) < 8 * px {
                closePen()
                return
            }
        }
        guard let q = t.toPlane(s) else { return }
        let next = snapPen(q)
        if next != penPoints.last { penPoints.append(next) }
        needsDisplay = true
    }

    private func closePen() {
        guard let t = penTarget else { return }
        let pts = penPoints
        cancelPen()
        if pts.count >= 3 {
            model.finishSketch([pts], plane: t.plane, name: "Path")
        } else {
            model.status = "A path needs three or more points."
        }
    }

    private func cancelPen() {
        penTarget = nil
        penPoints = []
        hover = nil
        needsDisplay = true
    }

    // MARK: - Rings

    private func ringClick(_ p: CGPoint, extend: Bool) {
        guard let frame = frameCache else { return }
        let s = scenePoint(p)
        var best: (RingPick, Double)?
        for (pick, segs) in rings(frame) {
            for (a, b) in segs {
                let d = segmentDistance(s, a, b)
                if d < 6 * px && d < (best?.1 ?? .infinity) { best = (pick, d) }
            }
        }
        if let best {
            model.toggleRing(best.0, extend: extend)
            return
        }
        guard let h = hit(p) else {
            if !extend {
                model.pickedRings = []
                model.pickedSegments = []
            }
            return
        }
        guard model.selection.contains(h.part.id) else {
            model.selection = [h.part.id]
            model.pickedRings = []
            model.pickedSegments = []
            let n = model.loopInfos(h.part).count
            model.status = n == 0 ? "\(h.part.name) has no loop cuts — add one from Add Step." : "Click a ring or a face between rings."
            return
        }
        guard let run = h.run, let face = run.face, let axis = SceneModel.axis(of: face.n), let item = frame.item(for: h.part.id),
              let info = model.loopInfos(h.part).last(where: { $0.k != axis.index }),
              let q = frame.angle.screenToPlane(s.x - item.offset.x, s.y - item.offset.y, axis: axis, at: face.w, view: item.view)
        else {
            model.status = "Pick a top, left or right face between two rings."
            return
        }
        let c = q[info.k]
        var seg = 0
        while seg < info.knots.count - 2 && c > info.knots[seg + 1] { seg += 1 }
        model.toggleSegment(SegmentPick(partID: h.part.id, loopID: info.loopID, segment: seg, face: IsoPlane(axis: axis)), extend: extend)
    }

    /// Drags move parts on the ground plane, ⇧ lifts them, ⌥ spins them.
    private func transformSelection(dx: Double, dy: Double, mode: DragMode, skipping skip: Set<Part.ID> = []) {
        let base = model.gestureBase
        let t = model.frameTime, auto = model.autoKey
        let ids = Set(base.parts.filter { model.selection.contains($0.id) && !$0.locked && !skip.contains($0.id) }.map(\.id))
        guard !ids.isEmpty else { return }
        let a = base.isoAngle
        let cam = base.camera.value("spin", at: t) * .pi / 180
        // Screen delta → ground-plane delta, then undo the camera turn.
        let gx = (dx / a.c + dy / a.s) / 2, gy = (dy / a.s - dx / a.c) / 2
        let wx = gx * cos(-cam) - gy * sin(-cam), wy = gx * sin(-cam) + gy * cos(-cam)
        model.updateGesture { s in
            for i in s.parts.indices where ids.contains(s.parts[i].id) {
                let from = base.parts.first { $0.id == s.parts[i].id }!.anim
                func set(_ prop: String, _ delta: Double) {
                    s.parts[i].anim.set(prop, jsRound(from.value(prop, at: t) + delta), at: t, autoKey: auto)
                }
                switch mode {
                case .move:
                    set("x", wx)
                    set("y", wy)
                case .lift: set("z", -dy)
                case .spin: set("spin", dx * 0.5)
                default: break
                }
            }
        }
    }

    // MARK: - Scroll & zoom

    override func scrollWheel(with event: NSEvent) {
        let p = local(event)
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            model.zoom(by: exp(delta * 0.01), around: Vec2(p.x, p.y) - viewCenter)
        } else {
            model.pan = model.pan + Vec2(event.scrollingDeltaX, event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 8)
        }
    }

    override func magnify(with event: NSEvent) {
        let p = local(event)
        model.zoom(by: 1 + event.magnification, around: Vec2(p.x, p.y) - viewCenter)
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let step = shift ? 10.0 : 1.0
        switch event.keyCode {
        case 51, 117:  // delete, forward delete
            if penTarget != nil {
                penPoints.removeLast()
                if penPoints.isEmpty { cancelPen() }
                needsDisplay = true
            } else if model.sketch != nil {
                model.discardSketch()
            } else {
                model.deleteSelection()
            }
        case 36, 76:  // return, enter
            if penTarget != nil { closePen() } else if model.sketch != nil { model.extrudeSketch(depth: 20) }
        case 53:  // escape
            if penTarget != nil {
                cancelPen()
            } else if shapeDrag != nil {
                shapeDrag = nil
                needsDisplay = true
            } else if model.sketch != nil {
                model.discardSketch()
            } else if model.tool != .select {
                model.tool = .select
            } else {
                model.selection = []
                model.pickedFaces = []
                model.annotation = nil
                model.pickedKeys = []
                model.selectedFrame = nil
            }
        case 123: model.nudge(Vec3(-step, 0, 0))
        case 124: model.nudge(Vec3(step, 0, 0))
        case 125: model.nudge(Vec3(0, step, 0))
        case 126: model.nudge(Vec3(0, -step, 0))
        case 49:  // space
            guard !event.isARepeat, !spaceHeld else { return }
            spaceHeld = true
            spacePanned = false
            if drag == nil { NSCursor.openHand.set() }
        default:
            let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags.subtracting(.shift).isEmpty, let tool = Tool.allCases.first(where: { String($0.key) == ch }) {
                model.tool = tool
                return
            }
            switch ch {
            case "f": model.zoomToFit()
            case "e": model.applyPreset(.explode)
            case "[": model.step(frames: -1)
            case "]": model.step(frames: 1)
            case "0": model.seek(0)
            case "=", "+": model.zoom(by: 1.25)
            case "-": model.zoom(by: 0.8)
            default: super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49 else { return super.keyUp(with: event) }
        releaseSpace(play: true)
    }

    override func resignFirstResponder() -> Bool {
        releaseSpace(play: false)
        return super.resignFirstResponder()
    }

    private func releaseSpace(play: Bool) {
        guard spaceHeld else { return }
        spaceHeld = false
        if drag?.mode != .pan { NSCursor.arrow.set() }
        if play && !spacePanned { model.togglePlay() }
    }
}
