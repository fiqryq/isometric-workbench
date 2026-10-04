import Foundation

public typealias Vec3 = SIMD3<Double>
public typealias Vec2 = SIMD2<Double>

// Products are written out component by component (not with SIMD `sum()`), so
// rounding happens in the same order as the JavaScript engine and the port
// produces the same numbers.
extension SIMD3 where Scalar == Double {
    @inlinable public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }

    @inlinable public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }

    @inlinable public var length: Double { (x * x + y * y + z * z).squareRoot() }

    @inlinable public var normalized: Vec3 {
        let l = length
        return l > 0 ? Vec3(x * (1 / l), y * (1 / l), z * (1 / l)) : .zero
    }

    @inlinable public func scaled(_ k: Double) -> Vec3 { Vec3(x * k, y * k, z * k) }

    @inlinable public func lerp(to b: Vec3, _ t: Double) -> Vec3 {
        Vec3(x + (b.x - x) * t, y + (b.y - y) * t, z + (b.z - z) * t)
    }

    @inlinable public subscript(axis axis: Axis) -> Double {
        get { self[axis.index] }
        set { self[axis.index] = newValue }
    }
}

public enum Axis: String, Sendable, Hashable, CaseIterable, Codable {
    case x, y, z

    public var index: Int {
        switch self {
        case .x: 0
        case .y: 1
        case .z: 2
        }
    }

    public init?(index: Int) {
        switch index {
        case 0: self = .x
        case 1: self = .y
        case 2: self = .z
        default: return nil
        }
    }

    public var unit: Vec3 {
        var v = Vec3.zero
        v[index] = 1
        return v
    }
}

/// Axis-aligned bounds of a set of points. Empty bounds have infinite extents.
public struct Bounds3: Sendable, Hashable {
    public var min: Vec3
    public var max: Vec3

    public init(min: Vec3, max: Vec3) {
        self.min = min
        self.max = max
    }

    public static let empty = Bounds3(
        min: Vec3(repeating: .infinity), max: Vec3(repeating: -.infinity))

    public var isEmpty: Bool { !(min.x <= max.x) }
    public var center: Vec3 {
        Vec3((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2)
    }
    public var size: Vec3 { max - min }

    public mutating func add(_ v: Vec3) {
        for k in 0..<3 {
            if v[k] < min[k] { min[k] = v[k] }
            if v[k] > max[k] { max[k] = v[k] }
        }
    }
}

/// 2D screen-space box.
public struct Box2: Sendable, Hashable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public static let empty = Box2(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    public var isEmpty: Bool { !(minX <= maxX) }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }

    public mutating func add(_ p: Vec2) {
        minX = Swift.min(minX, p.x)
        maxX = Swift.max(maxX, p.x)
        minY = Swift.min(minY, p.y)
        maxY = Swift.max(maxY, p.y)
    }

    public func union(_ o: Box2) -> Box2 {
        Box2(
            minX: Swift.min(minX, o.minX), minY: Swift.min(minY, o.minY),
            maxX: Swift.max(maxX, o.maxX), maxY: Swift.max(maxY, o.maxY))
    }

    public func offset(by d: Vec2) -> Box2 {
        Box2(minX: minX + d.x, minY: minY + d.y, maxX: maxX + d.x, maxY: maxY + d.y)
    }

    public func insetBy(_ d: Double) -> Box2 {
        Box2(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d)
    }
}
