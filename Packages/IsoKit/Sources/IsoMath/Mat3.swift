import Foundation

/// Row-major 3×3 matrix (`rows[i]` is row i), as in the JS engine.
public struct Mat3: Sendable, Hashable {
    public var r0: Vec3
    public var r1: Vec3
    public var r2: Vec3

    public init(_ r0: Vec3, _ r1: Vec3, _ r2: Vec3) {
        self.r0 = r0
        self.r1 = r1
        self.r2 = r2
    }

    public init(rows: [[Double]]) {
        func row(_ i: Int) -> Vec3 {
            guard i < rows.count, rows[i].count >= 3 else { return Axis(index: i)!.unit }
            return Vec3(rows[i][0], rows[i][1], rows[i][2])
        }
        self.init(row(0), row(1), row(2))
    }

    public static let identity = Mat3(Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))

    public var rows: [[Double]] { [r0, r1, r2].map { [$0.x, $0.y, $0.z] } }

    public subscript(i: Int) -> Vec3 {
        switch i {
        case 0: r0
        case 1: r1
        default: r2
        }
    }

    public var transposed: Mat3 {
        Mat3(Vec3(r0.x, r1.x, r2.x), Vec3(r0.y, r1.y, r2.y), Vec3(r0.z, r1.z, r2.z))
    }

    public static func * (a: Mat3, v: Vec3) -> Vec3 {
        Vec3(a.r0.dot(v), a.r1.dot(v), a.r2.dot(v))
    }

    public static func * (a: Mat3, b: Mat3) -> Mat3 {
        func row(_ r: Vec3) -> Vec3 {
            Vec3(
                r.x * b.r0.x + r.y * b.r1.x + r.z * b.r2.x,
                r.x * b.r0.y + r.y * b.r1.y + r.z * b.r2.y,
                r.x * b.r0.z + r.y * b.r1.z + r.z * b.r2.z)
        }
        return Mat3(row(a.r0), row(a.r1), row(a.r2))
    }

    /// Display rotation: R = Rx · Ry · Rz, angles in degrees
    /// (x = tilt, y = roll, z = spin).
    public static func rotation(x: Double, y: Double, z: Double) -> Mat3 {
        let r = { (d: Double) in d * Double.pi / 180 }
        let (cx, sx) = (cos(r(x)), sin(r(x)))
        let (cy, sy) = (cos(r(y)), sin(r(y)))
        let (cz, sz) = (cos(r(z)), sin(r(z)))
        let rx = Mat3(Vec3(1, 0, 0), Vec3(0, cx, -sx), Vec3(0, sx, cx))
        let ry = Mat3(Vec3(cy, 0, sy), Vec3(0, 1, 0), Vec3(-sy, 0, cy))
        let rz = Mat3(Vec3(cz, -sz, 0), Vec3(sz, cz, 0), Vec3(0, 0, 1))
        return rx * (ry * rz)
    }
}

/// Rotation of a part about its pivot (model space → view space).
public struct ViewTransform: Sendable, Hashable {
    public let r: Mat3
    public let pivot: Vec3
    public let isIdentity: Bool

    public static let identity = ViewTransform()

    private init() {
        r = .identity
        pivot = .zero
        isIdentity = true
    }

    /// Rotation in degrees: x = tilt, y = roll, z = spin.
    public init(rotation: Vec3, pivot: Vec3) {
        if rotation.x == 0 && rotation.y == 0 && rotation.z == 0 {
            self.r = .identity
            self.pivot = .zero
            self.isIdentity = true
        } else {
            self.r = Mat3.rotation(x: rotation.x, y: rotation.y, z: rotation.z)
            self.pivot = pivot
            self.isIdentity = false
        }
    }

    @inlinable public func apply(_ v: Vec3) -> Vec3 {
        isIdentity ? v : (r * (v - pivot)) + pivot
    }

    @inlinable public func applyNormal(_ n: Vec3) -> Vec3 {
        isIdentity ? n : r * n
    }
}
