import Foundation

/// Turns outlines drawn on an iso plane into steps. Sketch coordinates are the
/// plane's 2D coordinates (`planeTo2`) at offset `at` along `axis`.
public enum Sketch {
    public struct NewPart: Sendable {
        public let op: Op
        /// Where the part goes so the solid sits exactly on the sketch.
        public let position: Vec3
    }

    /// A new part extruded from the sketch towards the viewer (+axis).
    public static func extrudedPart(_ loops: [Loop], axis: Axis, at: Double, depth: Double) -> NewPart {
        let b = Loop2D.bounds(loops)
        let d = max(0.5, depth)
        switch axis {
        case .z:
            let uv = loops.map { $0.map { Vec2($0.x - b.minX, $0.y - b.minY) } }
            return NewPart(op: .extrude(plane: .top, depth: d, loops: Loop2D.rounded(uv)), position: Vec3(round2(b.minX), round2(b.minY), round2(at)))
        case .y:
            let uv = loops.map { $0.map { Vec2($0.x - b.minX, b.maxY - $0.y) } }
            return NewPart(op: .extrude(plane: .left, depth: d, loops: Loop2D.rounded(uv)), position: Vec3(round2(b.minX), round2(at + d), round2(b.maxY)))
        case .x:
            let uv = loops.map { $0.map { Vec2(b.maxX - $0.x, b.maxY - $0.y) } }
            return NewPart(op: .extrude(plane: .right, depth: d, loops: Loop2D.rounded(uv)), position: Vec3(round2(at + d), round2(b.maxX), round2(b.maxY)))
        }
    }

    /// A new part revolved around the sketch's left edge; only for profiles
    /// drawn on a vertical (left or right) plane.
    public static func revolvedPart(_ loops: [Loop], axis: Axis, at: Double, segments: Double = 48) -> NewPart? {
        guard axis != .z else { return nil }
        let b = Loop2D.bounds(loops)
        let rz = loops.map { $0.map { Vec2($0.x - b.minX, $0.y - b.minY) } }
        let op = Op.revolve(segments: segments, axis: 0, loops: Loop2D.rounded(rz))
        let position = axis == .y ? Vec3(round2(b.minX), round2(at), round2(b.minY)) : Vec3(round2(at), round2(b.minX), round2(b.minY))
        return NewPart(op: op, position: position)
    }

    /// A push / pull of the sketch into (negative depth) or out of a face of
    /// the host part — the plugin's `cmdPush`.
    public static func push(_ loops: [Loop], axis: Axis, at: Double, depth: Double, through: Bool) -> Op {
        .push(axis: axis, at: round2(at), depth: depth, through: through, loops: Loop2D.rounded(loops))
    }

    /// A flat profile (x right, y down) extruded on a plane — the plugin's
    /// `cmdExtrude`, used for imported SVG paths.
    public static func extrudeProfile(_ loops: [Loop], plane: IsoPlane, depth: Double) -> Op {
        let b = Loop2D.bounds(loops)
        let uv = loops.map { $0.map { Vec2($0.x - b.minX, $0.y - b.minY) } }
        return .extrude(plane: plane, depth: depth, loops: Loop2D.rounded(uv))
    }

    // MARK: - Shapes

    public static func rectangle(_ a: Vec2, _ b: Vec2) -> Loop {
        [Vec2(a.x, a.y), Vec2(b.x, a.y), Vec2(b.x, b.y), Vec2(a.x, b.y)]
    }

    public static func ellipse(_ a: Vec2, _ b: Vec2, segments: Int = 48) -> Loop {
        let c = (a + b) * 0.5, r = Vec2(abs(b.x - a.x) / 2, abs(b.y - a.y) / 2)
        return (0..<segments).map { i in
            let t = Double(i) / Double(segments) * 2 * .pi
            return Vec2(c.x + r.x * cos(t), c.y + r.y * sin(t))
        }
    }

    /// Regular polygon inscribed in the box from `a` to `b`.
    public static func polygon(_ a: Vec2, _ b: Vec2, sides: Int = 6) -> Loop {
        let c = (a + b) * 0.5, r = Vec2(abs(b.x - a.x) / 2, abs(b.y - a.y) / 2)
        let n = max(3, sides)
        return (0..<n).map { i in
            let t = Double(i) / Double(n) * 2 * .pi - .pi / 2
            return Vec2(c.x + r.x * cos(t), c.y + r.y * sin(t))
        }
    }
}
