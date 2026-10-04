import Foundation
import IsoDocument
import IsoMath

enum AlignEdge: CaseIterable {
    case left, centerX, right, top, centerY, bottom

    var title: String {
        switch self {
        case .left: "Align Left"
        case .centerX: "Align Horizontal Centres"
        case .right: "Align Right"
        case .top: "Align Top"
        case .centerY: "Align Vertical Centres"
        case .bottom: "Align Bottom"
        }
    }

    var symbol: String {
        switch self {
        case .left: "align.horizontal.left"
        case .centerX: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .centerY: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }
}

/// Sketch-style align and distribute, on the drawing as it looks on screen.
/// Several parts line up against their combined bounds; a single part lines
/// up against the fixed-size frame it sits in.
extension SceneModel {
    private var alignBoxes: [(id: Part.ID, box: Box2, locked: Bool)] {
        let f = frame()
        return selectedParts.compactMap { p in f.item(for: p.id).map { (p.id, $0.box, p.locked) } }
    }

    private var alignTarget: Box2? {
        let boxes = alignBoxes
        if boxes.count >= 2 { return boxes.reduce(Box2.empty) { $0.union($1.box) } }
        // A hugging frame follows its part, so only a fixed frame is something to align to.
        guard let only = boxes.first, let i = scene.frames.index(holding: only.id), scene.frames[i].size != nil else { return nil }
        return frame().board(scene.frames[i].id)?.rect
    }

    var canAlign: Bool { alignTarget != nil && alignBoxes.contains { !$0.locked } }

    var canDistribute: Bool { alignBoxes.filter { !$0.locked }.count >= 3 }

    func align(_ edge: AlignEdge) {
        guard let t = alignTarget else { return }
        var deltas: [Part.ID: Vec2] = [:]
        for b in alignBoxes where !b.locked {
            let r = b.box
            switch edge {
            case .left: deltas[b.id] = Vec2(t.minX - r.minX, 0)
            case .centerX: deltas[b.id] = Vec2(t.midX - r.midX, 0)
            case .right: deltas[b.id] = Vec2(t.maxX - r.maxX, 0)
            case .top: deltas[b.id] = Vec2(0, t.minY - r.minY)
            case .centerY: deltas[b.id] = Vec2(0, t.midY - r.midY)
            case .bottom: deltas[b.id] = Vec2(0, t.maxY - r.maxY)
            }
        }
        shiftOnScreen(deltas, edge.title)
    }

    /// Evens out the gaps between the parts, keeping the outermost two in place.
    func distribute(horizontally: Bool) {
        let boxes = alignBoxes.filter { !$0.locked }
            .sorted { horizontally ? $0.box.minX < $1.box.minX : $0.box.minY < $1.box.minY }
        guard boxes.count >= 3, let first = boxes.first?.box, let last = boxes.last?.box else { return }
        func lo(_ b: Box2) -> Double { horizontally ? b.minX : b.minY }
        func hi(_ b: Box2) -> Double { horizontally ? b.maxX : b.maxY }
        let used = boxes.reduce(0) { $0 + hi($1.box) - lo($1.box) }
        let gap = (hi(last) - lo(first) - used) / Double(boxes.count - 1)
        var cursor = hi(first) + gap
        var deltas: [Part.ID: Vec2] = [:]
        for b in boxes.dropFirst().dropLast() {
            let d = cursor - lo(b.box)
            deltas[b.id] = horizontally ? Vec2(d, 0) : Vec2(0, d)
            cursor += hi(b.box) - lo(b.box) + gap
        }
        shiftOnScreen(deltas, horizontally ? "Distribute Horizontally" : "Distribute Vertically")
    }

    /// Moves parts by screen deltas along the ground, at the playhead.
    private func shiftOnScreen(_ deltas: [Part.ID: Vec2], _ name: String) {
        let deltas = deltas.filter { abs($0.value.x) > 1e-6 || abs($0.value.y) > 1e-6 }
        guard !deltas.isEmpty else { return }
        let t = frameTime, auto = autoKey, base = scene
        edit(name) { s in
            for i in s.parts.indices {
                guard let d = deltas[s.parts[i].id] else { continue }
                let g = Self.groundDelta(d, in: base, at: t)
                let a = s.parts[i].anim
                s.parts[i].anim.set("x", jsRound(a.value("x", at: t) + g.x), at: t, autoKey: auto)
                s.parts[i].anim.set("y", jsRound(a.value("y", at: t) + g.y), at: t, autoKey: auto)
            }
        }
    }
}
