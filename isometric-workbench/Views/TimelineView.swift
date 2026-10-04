import AppKit
import IsoDocument
import IsoGeometry
import IsoMath
import SwiftUI

/// The full timeline: a fixed ruler over scrolling rows for the camera and
/// every part, each expandable into per-property tracks.
struct TimelinePanel: NSViewRepresentable {
    let model: SceneModel

    func makeNSView(context: Context) -> TimelineContainer { TimelineContainer(model: model) }

    func updateNSView(_ view: TimelineContainer, context: Context) {}
}

private enum Metrics {
    static let header: CGFloat = 176
    static let ruler: CGFloat = 24
    static let row: CGFloat = 22
    static let pad: CGFloat = 12
    static let diamond: CGFloat = 5
}

/// Shared time ↔ x mapping for the ruler and the tracks.
private struct TimeAxis {
    var width: CGFloat
    var duration: Double

    var span: CGFloat { max(1, width - Metrics.header - 2 * Metrics.pad) }

    func x(_ t: Double) -> CGFloat { Metrics.header + Metrics.pad + CGFloat(t / max(duration, 1e-6)) * span }

    func t(_ x: CGFloat) -> Double { clamp(Double((x - Metrics.header - Metrics.pad) / span) * duration, 0, duration) }

    /// Seconds between labelled ticks so labels stay ~60 pt apart.
    func step(fps: Double) -> Double {
        let candidates = [1 / fps, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120]
        return candidates.first { CGFloat($0 / max(duration, 1e-6)) * span >= 60 } ?? 120
    }
}

private func accentColor() -> NSColor { .controlAccentColor }

final class TimelineContainer: NSView {
    let model: SceneModel
    private let ruler: TimelineRuler
    private let scroll = NSScrollView()
    private let tracks: TimelineTracks

    init(model: SceneModel) {
        self.model = model
        ruler = TimelineRuler(model: model)
        tracks = TimelineTracks(model: model)
        super.init(frame: .zero)
        clipsToBounds = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = tracks
        addSubview(ruler)
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // The detail column runs under the translucent sidebar.
        let r = safeAreaRect
        ruler.frame = NSRect(x: r.minX, y: r.minY, width: r.width, height: Metrics.ruler)
        scroll.frame = NSRect(x: r.minX, y: r.minY + Metrics.ruler, width: r.width, height: max(0, r.height - Metrics.ruler))
        tracks.fit(width: scroll.contentSize.width)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }
}

// MARK: - Ruler

final class TimelineRuler: NSView {
    let model: SceneModel

    init(model: SceneModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        withObservationTracking { render() } onChange: { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    private func render() {
        let axis = TimeAxis(width: bounds.width, duration: model.scene.duration)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let fps = max(1, model.scene.fps)
        let step = axis.step(fps: fps)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let fine = step / (step >= 1 ? 4 : step >= 0.25 ? 5 : 1)
        var t = 0.0
        let path = NSBezierPath()
        while t <= axis.duration + 1e-9 {
            let x = axis.x(t).rounded() + 0.5
            let major = abs((t / step).rounded() * step - t) < 1e-6
            path.move(to: NSPoint(x: x, y: bounds.maxY))
            path.line(to: NSPoint(x: x, y: bounds.maxY - (major ? 9 : 4)))
            if major {
                let label = step < 1 ? String(format: "%.2fs", t) : String(format: "%gs", t)
                (label as NSString).draw(at: NSPoint(x: x + 3, y: 3), withAttributes: attrs)
            }
            t += fine
        }
        NSColor.tertiaryLabelColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let title = String(format: "%.2f s · f%d", model.frameTime, Int((model.frameTime * fps).rounded()))
        (title as NSString).draw(at: NSPoint(x: 10, y: 5), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])

        let px = axis.x(model.frameTime)
        accentColor().setFill()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: px - 5, y: bounds.maxY - 10))
        head.line(to: NSPoint(x: px + 5, y: bounds.maxY - 10))
        head.line(to: NSPoint(x: px + 5, y: bounds.maxY - 4))
        head.line(to: NSPoint(x: px, y: bounds.maxY))
        head.line(to: NSPoint(x: px - 5, y: bounds.maxY - 4))
        head.close()
        head.fill()
        NSRect(x: px - 0.75, y: bounds.maxY - 10, width: 1.5, height: 10).fill()

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        NSRect(x: Metrics.header - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) { scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }

    private func scrub(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.x >= Metrics.header - 4 else { return }
        if model.isPlaying { model.pause() }
        let axis = TimeAxis(width: bounds.width, duration: model.scene.duration)
        let fps = max(1, model.scene.fps)
        model.seek((axis.t(p.x) * fps).rounded() / fps)
    }
}

// MARK: - Tracks

final class TimelineTracks: NSView {
    let model: SceneModel
    private var expanded: Set<KeyRef.Owner> = []
    private var rows: [Row] = []
    private var drag: Drag?
    private var marquee: NSRect?
    private static var clipboard: CopiedKeys?

    private enum RowKind {
        case owner(KeyRef.Owner)
        case prop(KeyRef.Owner, String)
    }

    private struct Row {
        var kind: RowKind
        var y: CGFloat

        var owner: KeyRef.Owner {
            switch kind {
            case .owner(let o), .prop(let o, _): o
            }
        }
    }

    private enum Drag {
        case retime(origin: Set<KeyRef>, startX: CGFloat, moved: Bool)
        case marquee(start: NSPoint, extend: Bool, base: Set<KeyRef>, moved: Bool)
    }

    init(model: SceneModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func fit(width: CGFloat) {
        let h = max(CGFloat(rows.count) * Metrics.row, enclosingScrollView?.contentSize.height ?? 0)
        if frame.width != width || frame.height != h { setFrameSize(NSSize(width: width, height: h)) }
        needsDisplay = true
    }

    private var axis: TimeAxis { TimeAxis(width: bounds.width, duration: model.scene.duration) }

    private func buildRows() {
        var out: [Row] = []
        var y: CGFloat = 0
        func add(_ k: RowKind) {
            out.append(Row(kind: k, y: y))
            y += Metrics.row
        }
        let owners: [KeyRef.Owner] = [.camera] + model.scene.parts.map { .part($0.id) }
        for o in owners {
            add(.owner(o))
            if expanded.contains(o) {
                let props = o == .camera ? SceneModel.cameraProps : Part.transformProps
                let extra = (model.scene.animatable(o)?.keys.keys.sorted() ?? []).filter { !props.contains($0) }
                for p in props + extra { add(.prop(o, p)) }
            }
        }
        rows = out
        let h = max(y, enclosingScrollView?.contentSize.height ?? 0)
        if abs(frame.height - h) > 0.5 {
            DispatchQueue.main.async { [weak self] in self?.setFrameSize(NSSize(width: self?.frame.width ?? 0, height: h)) }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        withObservationTracking { render() } onChange: { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    private func keyTimes(_ row: Row) -> [Keyframe] {
        guard let a = model.scene.animatable(row.owner) else { return [] }
        switch row.kind {
        case .prop(_, let p): return a.keys[p] ?? []
        case .owner:
            let times = a.keyTimes
            return times.map { Keyframe(t: $0, v: 0) }
        }
    }

    private func render() {
        buildRows()
        let axis = axis
        let picked = model.pickedKeys
        let selection = model.selection
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor]
        let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let value: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let t = model.frameTime

        for (i, row) in rows.enumerated() {
            let r = NSRect(x: 0, y: row.y, width: bounds.width, height: Metrics.row)
            guard r.intersects(visibleRect) else { continue }
            let isOwnerSelected: Bool = {
                if case .part(let id) = row.owner { return selection.contains(id) }
                return false
            }()
            if isOwnerSelected {
                accentColor().withAlphaComponent(0.1).setFill()
                r.fill()
            } else if i % 2 == 1 {
                NSColor.alternatingContentBackgroundColors.last?.withAlphaComponent(0.5).setFill()
                r.fill()
            }
            let a = model.scene.animatable(row.owner)
            switch row.kind {
            case .owner(let o):
                let open = expanded.contains(o)
                let tri = NSBezierPath()
                let cx: CGFloat = 12, cy = row.y + Metrics.row / 2
                if open {
                    tri.move(to: NSPoint(x: cx - 4, y: cy - 2)); tri.line(to: NSPoint(x: cx + 4, y: cy - 2)); tri.line(to: NSPoint(x: cx, y: cy + 3))
                } else {
                    tri.move(to: NSPoint(x: cx - 2, y: cy - 4)); tri.line(to: NSPoint(x: cx + 3, y: cy)); tri.line(to: NSPoint(x: cx - 2, y: cy + 4))
                }
                tri.close()
                NSColor.secondaryLabelColor.setFill()
                tri.fill()
                let name = model.ownerName(o) as NSString
                name.draw(in: NSRect(x: 24, y: row.y + 3, width: Metrics.header - 30, height: 16), withAttributes: label)
            case .prop(_, let p):
                (Self.propTitle(p) as NSString).draw(at: NSPoint(x: 30, y: row.y + 4), withAttributes: sub)
                let v = a?.value(p, at: t) ?? 0
                let vs = jsNumberString(jsRound(v * 10) / 10) as NSString
                let w = vs.size(withAttributes: value).width
                vs.draw(at: NSPoint(x: Metrics.header - 26 - w, y: row.y + 5), withAttributes: value)
                let keyed = a?.keys[p]?.contains { abs($0.t - t) < 1e-3 } ?? false
                drawDiamond(at: NSPoint(x: Metrics.header - 13, y: row.y + Metrics.row / 2), size: 4,
                            fill: keyed ? (a?.isAnimated(p) == true ? accentColor() : .secondaryLabelColor) : nil,
                            stroke: a?.isAnimated(p) == true ? accentColor() : .tertiaryLabelColor)
            }

            // Spans and easing curves.
            let keys = keyTimes(row)
            let mid = row.y + Metrics.row / 2
            if keys.count >= 2 {
                switch row.kind {
                case .owner:
                    let bar = NSRect(x: axis.x(keys.first!.t), y: mid - 2, width: axis.x(keys.last!.t) - axis.x(keys.first!.t), height: 4)
                    NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
                    NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
                case .prop:
                    for j in 0..<(keys.count - 1) {
                        let x0 = axis.x(keys[j].t), x1 = axis.x(keys[j + 1].t)
                        let span = NSRect(x: x0, y: row.y + 4, width: x1 - x0, height: Metrics.row - 8)
                        accentColor().withAlphaComponent(0.08).setFill()
                        span.fill()
                        let curve = NSBezierPath()
                        let e = keys[j].e
                        let n = max(2, Int((x1 - x0) / 3))
                        for s in 0...n {
                            let u = Double(s) / Double(n)
                            let pt = NSPoint(x: x0 + (x1 - x0) * u, y: span.maxY - span.height * e(u))
                            if s == 0 { curve.move(to: pt) } else { curve.line(to: pt) }
                        }
                        accentColor().withAlphaComponent(0.55).setStroke()
                        curve.lineWidth = 1
                        if e == .hold { curve.setLineDash([3, 2], count: 2, phase: 0) }
                        curve.stroke()
                    }
                }
            }
            for k in keys {
                let refs: Set<KeyRef> = {
                    switch row.kind {
                    case .prop(let o, let p): return [KeyRef(owner: o, prop: p, t: k.t)]
                    case .owner(let o): return model.keys(of: o, at: k.t)
                    }
                }()
                let on = !refs.isEmpty && refs.isSubset(of: picked)
                let some = !on && !refs.isDisjoint(with: picked)
                let size: CGFloat = { if case .owner = row.kind { return Metrics.diamond + 1 } else { return Metrics.diamond } }()
                drawDiamond(at: NSPoint(x: axis.x(k.t), y: mid), size: size,
                            fill: on ? accentColor() : some ? accentColor().withAlphaComponent(0.5) : NSColor.labelColor.withAlphaComponent(0.75),
                            stroke: on ? NSColor.white : NSColor.controlBackgroundColor)
            }
        }

        NSColor.separatorColor.setFill()
        NSRect(x: Metrics.header - 1, y: 0, width: 1, height: bounds.height).fill()

        let px = axis.x(t)
        (model.autoKey ? NSColor.systemRed : accentColor()).setFill()
        NSRect(x: px - 0.75, y: 0, width: 1.5, height: bounds.height).fill()

        if let m = marquee {
            accentColor().withAlphaComponent(0.12).setFill()
            m.fill()
            accentColor().setStroke()
            NSBezierPath(rect: m.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        if rows.count <= 1 && model.scene.parts.isEmpty {
            ("Add parts to animate them here" as NSString).draw(at: NSPoint(x: Metrics.header + 16, y: Metrics.row + 6), withAttributes: sub)
        }
    }

    private func drawDiamond(at p: NSPoint, size s: CGFloat, fill: NSColor?, stroke: NSColor) {
        let d = NSBezierPath()
        d.move(to: NSPoint(x: p.x, y: p.y - s))
        d.line(to: NSPoint(x: p.x + s, y: p.y))
        d.line(to: NSPoint(x: p.x, y: p.y + s))
        d.line(to: NSPoint(x: p.x - s, y: p.y))
        d.close()
        if let fill {
            fill.setFill()
            d.fill()
        }
        stroke.setStroke()
        d.lineWidth = 1
        d.stroke()
    }

    static func propTitle(_ p: String) -> String {
        switch p {
        case "x": "X"
        case "y": "Y"
        case "z": "Z"
        case "spin": "Spin°"
        case "tilt": "Tilt°"
        case "roll": "Roll°"
        case "opacity": "Opacity %"
        default: p.capitalized
        }
    }

    // MARK: Hit testing

    private func row(at y: CGFloat) -> Row? {
        let i = Int(y / Metrics.row)
        return rows.indices.contains(i) ? rows[i] : nil
    }

    private func keyHit(_ p: NSPoint) -> Set<KeyRef>? {
        guard p.x > Metrics.header, let row = row(at: p.y) else { return nil }
        let axis = axis
        let hit = keyTimes(row).min { abs(axis.x($0.t) - p.x) < abs(axis.x($1.t) - p.x) }
        guard let k = hit, abs(axis.x(k.t) - p.x) <= Metrics.diamond + 3 else { return nil }
        switch row.kind {
        case .prop(let o, let prop): return [KeyRef(owner: o, prop: prop, t: k.t)]
        case .owner(let o): return model.keys(of: o, at: k.t)
        }
    }

    private func keys(in rect: NSRect) -> Set<KeyRef> {
        var out: Set<KeyRef> = []
        let axis = axis
        for row in rows where rect.intersects(NSRect(x: 0, y: row.y, width: bounds.width, height: Metrics.row)) {
            for k in keyTimes(row) where rect.minX <= axis.x(k.t) && axis.x(k.t) <= rect.maxX {
                switch row.kind {
                case .prop(let o, let p): out.insert(KeyRef(owner: o, prop: p, t: k.t))
                case .owner(let o):
                    if !expanded.contains(o) { out.formUnion(model.keys(of: o, at: k.t)) }
                }
            }
        }
        return out
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        guard let row = row(at: p.y) else {
            if !shift { model.pickedKeys = [] }
            return
        }
        if p.x < Metrics.header {
            headerClick(row, p)
            return
        }
        if let refs = keyHit(p) {
            if event.clickCount == 2, let t = refs.first?.t {
                model.pause()
                model.seek(t)
                return
            }
            if shift {
                if refs.isSubset(of: model.pickedKeys) { model.pickedKeys.subtract(refs) } else { model.pickedKeys.formUnion(refs) }
            } else if !refs.isSubset(of: model.pickedKeys) {
                model.pickedKeys = refs
            }
            if !model.pickedKeys.isEmpty { drag = .retime(origin: model.pickedKeys, startX: p.x, moved: false) }
            return
        }
        drag = .marquee(start: p, extend: shift, base: shift ? model.pickedKeys : [], moved: false)
    }

    private func headerClick(_ row: Row, _ p: NSPoint) {
        switch row.kind {
        case .owner(let o):
            if p.x < 24 {
                if expanded.contains(o) { expanded.remove(o) } else { expanded.insert(o) }
                needsDisplay = true
            } else if case .part(let id) = o {
                model.selection = [id]
                model.annotation = nil
            } else {
                model.selection = []
            }
        case .prop(let o, let prop):
            if p.x > Metrics.header - 24 { model.toggleKey(o, prop) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .retime(let origin, let startX, let moved):
            if !moved && abs(p.x - startX) < 3 { return }
            if !moved { model.beginGesture() }
            let dt = Double((p.x - startX) / axis.span) * model.scene.duration
            model.pickedKeys = model.retimeKeys(origin, by: dt)
            drag = .retime(origin: origin, startX: startX, moved: true)
        case .marquee(let start, let extend, let base, _):
            let r = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            marquee = r
            model.pickedKeys = base.union(keys(in: r))
            drag = .marquee(start: start, extend: extend, base: base, moved: true)
            needsDisplay = true
            autoscroll(with: event)
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer {
            drag = nil
            marquee = nil
            needsDisplay = true
        }
        switch drag {
        case .retime(_, _, let moved):
            if moved { model.endGesture(model.pickedKeys.count == 1 ? "Move Key" : "Move Keys") }
        case .marquee(_, let extend, _, let moved):
            if !moved {
                if !extend { model.pickedKeys = [] }
                if model.isPlaying { model.pause() }
                let fps = max(1, model.scene.fps)
                model.seek((axis.t(p.x) * fps).rounded() / fps)
            }
        case nil: break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let refs = keyHit(p) {
            if !refs.isSubset(of: model.pickedKeys) { model.pickedKeys = refs }
            let current = Set(model.pickedKeys.compactMap { model.keyframe($0)?.e })
            for e in Easing.allCases {
                let item = NSMenuItem(title: e.title, action: #selector(setEasing(_:)), keyEquivalent: "")
                item.representedObject = e.rawValue
                item.target = self
                item.state = current == [e] ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(item("Copy Keys", #selector(copy(_:))))
            menu.addItem(item("Delete Keys", #selector(deleteKeys(_:))))
        } else if let row = row(at: p.y) {
            if case .prop = row.kind {
                menu.addItem(item("Add Key at Playhead", #selector(addKeyHere(_:)), row: row))
            } else if case .owner(let o) = row.kind, case .part(let id) = o {
                let it = item("Key All at Playhead", #selector(keyAll(_:)))
                it.representedObject = id
                menu.addItem(it)
            }
            if Self.clipboard != nil { menu.addItem(item("Paste Keys at Playhead", #selector(paste(_:)))) }
        }
        return menu.items.isEmpty ? nil : menu
    }

    private var rowForMenu: Row?

    private func item(_ title: String, _ action: Selector, row: Row? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        if let row { rowForMenu = row }
        return it
    }

    @objc private func setEasing(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let e = Easing(rawValue: raw) else { return }
        model.setEasing(e, for: model.pickedKeys)
    }

    @objc private func deleteKeys(_ sender: Any?) { model.deletePickedKeys() }

    @objc private func addKeyHere(_ sender: Any?) {
        guard let row = rowForMenu, case .prop(let o, let p) = row.kind else { return }
        model.toggleKey(o, p)
    }

    @objc private func keyAll(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Part.ID else { return }
        model.selection = [id]
        model.addKeyframe()
    }

    @objc func copy(_ sender: Any?) {
        if let c = model.copyKeys() { Self.clipboard = c }
    }

    @objc func paste(_ sender: Any?) {
        if let c = Self.clipboard { model.pasteKeys(c) }
    }

    @objc func delete(_ sender: Any?) { model.deletePickedKeys() }

    @objc override func selectAll(_ sender: Any?) {
        model.pickedKeys = keys(in: bounds)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: model.deletePickedKeys()
        case 53: model.pickedKeys = []
        case 49: model.togglePlay()
        case 123: model.step(frames: -1)
        case 124: model.step(frames: 1)
        default: super.keyDown(with: event)
        }
    }
}
