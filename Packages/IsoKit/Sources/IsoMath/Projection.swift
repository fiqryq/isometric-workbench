import Foundation

/// The projection angle: 30° isometric or 26.565° for 2:1 pixel art.
/// Never hard-code cos 30°.
public struct IsoAngle: Sendable, Hashable {
    public let degrees: Double
    public let c: Double
    public let s: Double

    public init(degrees: Double) {
        self.degrees = degrees
        let a = degrees * Double.pi / 180
        c = cos(a)
        s = sin(a)
    }

    public static let isometric = IsoAngle(degrees: 30)
    public static let pixel = IsoAngle(degrees: 26.565)

    /// World (x, y, z) → screen. x runs down-right, y down-left, z up.
    @inlinable public func project(_ v: Vec3) -> Vec2 {
        Vec2((v.x - v.y) * c, (v.x + v.y) * s - v.z)
    }

    /// Direction towards the viewer: the 3D vector that projects to a point.
    public var toViewer: Vec3 { Vec3(1, 1, 2 * s).normalized }

    /// Screen point → point on the plane perpendicular to `axis` at `at`
    /// (unrotated model).
    public func screenToPlane(_ sx: Double, _ sy: Double, axis: Axis, at: Double) -> Vec3 {
        switch axis {
        case .z:
            let a = sx / c, b = (sy + at) / s
            return Vec3((a + b) / 2, (b - a) / 2, at)
        case .y:
            let x = sx / c + at
            return Vec3(x, at, (x + at) * s - sy)
        case .x:
            let y = at - sx / c
            return Vec3(at, y, (at + y) * s - sy)
        }
    }

    /// Screen point (relative to the part's origin) → model point on a plane,
    /// seen through `view`. The mapping is affine, so it's solved from three
    /// projected points. Returns nil when the plane is seen edge-on.
    public func screenToPlane(
        _ sx: Double, _ sy: Double, axis: Axis, at: Double, view: ViewTransform
    ) -> Vec3? {
        if view.isIdentity { return screenToPlane(sx, sy, axis: axis, at: at) }
        let to3 = IsoPlaneMapping.planeTo3(axis: axis, at: at)
        let f = { (a: Double, b: Double) -> Vec2 in
            let v = view.apply(to3(Vec2(a, b)))
            return Vec2((v.x - v.y) * self.c, (v.x + v.y) * self.s - v.z)
        }
        let o = f(0, 0)
        let a = f(1, 0) - o
        let b = f(0, 1) - o
        let det = a.x * b.y - a.y * b.x
        if abs(det) < 1e-9 { return nil }
        let dx = sx - o.x, dy = sy - o.y
        return to3(Vec2((dx * b.y - dy * b.x) / det, (a.x * dy - a.y * dx) / det))
    }
}

/// The three iso faces a flat drawing can sit on.
public enum IsoPlane: String, Sendable, Hashable, CaseIterable, Codable {
    case top, left, right

    /// The axis perpendicular to the face.
    public var axis: Axis {
        switch self {
        case .top: .z
        case .left: .y
        case .right: .x
        }
    }

    public init(axis: Axis) {
        switch axis {
        case .z: self = .top
        case .y: self = .left
        case .x: self = .right
        }
    }

    public var direction: Vec3 {
        switch self {
        case .top: Vec3(0, 0, 1)
        case .left: Vec3(0, 1, 0)
        case .right: Vec3(1, 0, 0)
        }
    }

    /// 2×2 matrix (a, b, c, d) mapping a flat (u, v) point onto this plane on
    /// screen: x = a·u + c·v, y = b·u + d·v.
    public func matrix(_ t: IsoAngle) -> (a: Double, b: Double, c: Double, d: Double) {
        switch self {
        case .top: (t.c, -t.c, t.s, t.s)
        case .left: (t.c, 0, t.s, 1)
        case .right: (t.c, 0, -t.s, 1)
        }
    }
}

public enum IsoPlaneMapping {
    /// 2D in-plane coordinates → 3D for a plane perpendicular to `axis` at `at`.
    public static func planeTo3(axis: Axis, at: Double) -> @Sendable (Vec2) -> Vec3 {
        switch axis {
        case .z: { p in Vec3(p.x, p.y, at) }
        case .y: { p in Vec3(p.x, at, p.y) }
        case .x: { p in Vec3(at, p.x, p.y) }
        }
    }

    public static func planeTo2(axis: Axis, _ v: Vec3) -> Vec2 {
        switch axis {
        case .z: Vec2(v.x, v.y)
        case .y: Vec2(v.x, v.z)
        case .x: Vec2(v.y, v.z)
        }
    }

    /// Flat drawing (u right, v down) → 3D for a profile drawn on an iso face.
    public static func profileTo3(_ plane: IsoPlane) -> @Sendable (Vec2) -> Vec3 {
        switch plane {
        case .top: { p in Vec3(p.x, p.y, 0) }
        case .left: { p in Vec3(p.x, 0, -p.y) }
        case .right: { p in Vec3(0, -p.x, -p.y) }
        }
    }

    public static func extrudeDirection(_ plane: IsoPlane, depth: Double) -> Vec3 {
        switch plane {
        case .top: Vec3(0, 0, depth)
        case .left: Vec3(0, -depth, 0)
        case .right: Vec3(-depth, 0, 0)
        }
    }
}
