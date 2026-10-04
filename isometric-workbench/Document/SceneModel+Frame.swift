import Foundation
import IsoDocument
import IsoMath

/// Figma-style frames: optional named areas that hold parts. Moving a frame
/// moves its parts, and exports cover the frames when a page has any.
extension SceneModel {
    var selectedBoard: Artboard? { selectedFrame.flatMap { id in scene.frames.first { $0.id == id } } }

    /// Where a frame sits on screen right now.
    func frameRect(_ id: Artboard.ID) -> Box2? { frame().board(id)?.rect }

    func selectFrame(_ id: Artboard.ID) {
        selection = []
        pickedFaces = []
        annotation = nil
        selectedFrame = id
    }

    func editFrame(_ id: Artboard.ID, _ name: String, _ body: (inout Artboard) -> Void) {
        edit(name) { s in
            if let i = s.frames.firstIndex(where: { $0.id == id }) { body(&s.frames[i]) }
        }
    }

    /// Wraps the selected parts, or every part outside a frame when nothing is
    /// selected, in a new frame that hugs them.
    func frameSelection() {
        let ids = scene.parts.map(\.id).filter { selection.isEmpty ? scene.frames.index(holding: $0) == nil : selection.contains($0) }
        let board = Artboard(name: uniqueFrameName(), children: ids)
        edit("Frame Selection") { s in
            s.frames.place(ids, in: nil)
            s.frames.append(board)
        }
        selectFrame(board.id)
    }

    /// A fixed frame drawn on the canvas; parts whose middle falls inside join it.
    func addFrame(_ rect: Box2) {
        let inside = frame().items.filter { rect.contains(Vec2($0.box.midX, $0.box.midY)) }.map(\.part.id)
        var board = Artboard(name: uniqueFrameName(), children: inside)
        board.origin = Vec2(rect.minX.rounded(), rect.minY.rounded())
        board.size = Vec2(max(16, rect.width.rounded()), max(16, rect.height.rounded()))
        edit("Add Frame") { s in
            s.frames.place(inside, in: nil)
            s.frames.append(board)
        }
        selectFrame(board.id)
    }

    /// Removes a frame; `keepParts` leaves its parts on the canvas, otherwise
    /// they go with it, as in Figma.
    func deleteFrame(_ id: Artboard.ID, keepParts: Bool) {
        guard let board = scene.frames.first(where: { $0.id == id }) else { return }
        let kids = Set(board.children)
        edit(keepParts ? "Remove Frame" : "Delete Frame") { s in
            s.frames.removeAll { $0.id == id }
            if !keepParts { Self.removeParts(kids, from: &s) }
        }
        if !keepParts { kids.forEach(build.forget) }
        selectedFrame = nil
        prune()
    }

    func moveFrame(_ id: Artboard.ID, by d: Vec2) {
        let base = scene, t = frameTime
        edit("Move Frame") { Self.moveFrame(id, by: d, in: &$0, from: base, at: t) }
    }

    func setFrameOrigin(_ id: Artboard.ID, _ origin: Vec2) {
        guard let r = frameRect(id) else { return }
        moveFrame(id, by: Vec2(origin.x - r.minX, origin.y - r.minY))
    }

    /// Fixes the frame's size, keeping its top-left where it is.
    func setFrameSize(_ id: Artboard.ID, _ size: Vec2) {
        guard let r = frameRect(id) else { return }
        editFrame(id, "Resize Frame") { a in
            a.origin = Vec2(r.minX, r.minY)
            a.size = Vec2(max(16, size.x.rounded()), max(16, size.y.rounded()))
        }
    }

    func hugFrame(_ id: Artboard.ID) {
        editFrame(id, "Hug Contents") { a in
            a.size = nil
            a.origin = nil
        }
    }

    func uniqueFrameName() -> String {
        let names = Set(scene.frames.map(\.name))
        var i = scene.frames.count + 1
        while names.contains("Frame \(i)") { i += 1 }
        return "Frame \(i)"
    }

    // MARK: - Geometry

    /// Screen delta → ground-plane delta at time `t`, undoing the camera turn.
    static func groundDelta(_ d: Vec2, in scene: SceneFile, at t: Double) -> Vec2 {
        let a = scene.isoAngle
        let cam = scene.camera.value("spin", at: t) * .pi / 180
        let gx = (d.x / a.c + d.y / a.s) / 2, gy = (d.y / a.s - d.x / a.c) / 2
        return Vec2(gx * cos(-cam) - gy * sin(-cam), gx * sin(-cam) + gy * cos(-cam))
    }

    /// Moves a frame and its parts by `d` on screen, starting from `base`. Parts
    /// shift every key, so their animation moves with them.
    static func moveFrame(_ id: Artboard.ID, by d: Vec2, in s: inout SceneFile, from base: SceneFile, at t: Double) {
        guard let i = base.frames.firstIndex(where: { $0.id == id }), i < s.frames.count else { return }
        let board = base.frames[i]
        if let o = board.origin { s.frames[i].origin = Vec2((o.x + d.x).rounded(), (o.y + d.y).rounded()) }
        let g = groundDelta(d, in: base, at: t)
        let kids = Set(board.children)
        for j in s.parts.indices where kids.contains(s.parts[j].id) {
            guard let from = base.parts.first(where: { $0.id == s.parts[j].id })?.anim else { continue }
            s.parts[j].anim = from.shifted(["x": g.x, "y": g.y])
        }
    }

    /// After parts are dragged, each joins the frame its middle lands in, or
    /// leaves its frame when it lands outside, like Figma. `boards` are the
    /// frames as they were when the drag began.
    func reparent(_ ids: Set<Part.ID>, among boards: [SheetLayout]) {
        let now = frame()
        updateGesture { s in
            for item in now.items where ids.contains(item.part.id) {
                let c = Vec2(item.box.midX, item.box.midY)
                let target = boards.last { $0.rect.contains(c) }?.id
                let current = s.frames.index(holding: item.part.id).map { s.frames[$0].id }
                if target != current { s.frames.place([item.part.id], in: target) }
            }
        }
    }
}

extension Animatable {
    /// The same animation with `deltas` added to every value of those properties.
    func shifted(_ deltas: [String: Double]) -> Animatable {
        var a = self
        for (prop, d) in deltas {
            a.base[prop] = jsRound(a.base(prop) + d)
            if let ks = a.keys[prop] {
                a.keys[prop] = ks.map { k in
                    var k = k
                    k.v = jsRound(k.v + d)
                    return k
                }
            }
        }
        return a
    }
}
