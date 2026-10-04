@_exported import IsoMath
import Foundation

public enum FaceKind: String, Sendable, Hashable {
    /// Ordinary surface.
    case solid
    /// Surface left by a section cut (drawn hatched).
    case cut
}

/// A planar, convex-or-not polygon with its plane (n · p = w).
public struct Polygon: Sendable {
    public var v: [Vec3]
    public var n: Vec3
    public var w: Double
    public var kind: FaceKind
    /// Render-time only: which edges are drawn (edge i runs v[i] → v[i+1]).
    public var flags: [Bool]?
    /// Render-time only: index of the face identity this piece came from.
    public var src: Int?

    public init(v: [Vec3], n: Vec3, w: Double, kind: FaceKind, flags: [Bool]? = nil, src: Int? = nil) {
        self.v = v
        self.n = n
        self.w = w
        self.kind = kind
        self.flags = flags
        self.src = src
    }

    /// Newell's method: a robust normal for any planar polygon. Nil when
    /// degenerate.
    public static func make(_ verts: [Vec3], kind: FaceKind) -> Polygon? {
        var nx = 0.0, ny = 0.0, nz = 0.0, cx = 0.0, cy = 0.0, cz = 0.0
        let m = verts.count
        for i in 0..<m {
            let a = verts[i], b = verts[(i + 1) % m]
            nx += (a.y - b.y) * (a.z + b.z)
            ny += (a.z - b.z) * (a.x + b.x)
            nz += (a.x - b.x) * (a.y + b.y)
            cx += a.x
            cy += a.y
            cz += a.z
        }
        let l = (nx * nx + ny * ny + nz * nz).squareRoot()
        if l < 1e-9 { return nil }
        let n = Vec3(nx / l, ny / l, nz / l)
        let k = Double(m)
        return Polygon(v: verts, n: n, w: n.dot(Vec3(cx / k, cy / k, cz / k)), kind: kind)
    }

    public func flipped() -> Polygon {
        var p = self
        p.v.reverse()
        p.n = n.scaled(-1)
        p.w = -w
        return p
    }

    public var centroid: Vec3 {
        var s = Vec3.zero
        for q in v { s = s + q }
        return s.scaled(1 / Double(v.count))
    }
}

public typealias Mesh = [Polygon]

extension Array where Element == Polygon {
    public var bounds: Bounds3 {
        var b = Bounds3.empty
        for p in self { for q in p.v { b.add(q) } }
        return b
    }

    public func translated(by t: Vec3) -> Mesh {
        map { p in
            Polygon(v: p.v.map { $0 + t }, n: p.n, w: p.w + p.n.dot(t), kind: p.kind)
        }
    }

    /// Applies `f` to every vertex and `fn` to every normal; the plane offset
    /// is recomputed from the first vertex.
    public func transformed(_ f: (Vec3) -> Vec3, normal fn: (Vec3) -> Vec3) -> Mesh {
        map { p in
            let v = p.v.map(f)
            let n = fn(p.n)
            return Polygon(v: v, n: n, w: n.dot(v[0]), kind: p.kind)
        }
    }
}

let planeEps = 1e-4

enum SplitBucket { case coFront, coBack, front, back }

/// Splits `poly` by the plane (n, w). Edge flags follow the pieces of the
/// original edges; new edges along the split line are not drawn.
@inline(__always)
func splitPolygon(_ n: Vec3, _ w: Double, _ poly: Polygon, _ emit: (SplitBucket, Polygon) -> Void) {
    let coplanar = 0, front = 1, back = 2, spanning = 3
    var polyType = 0
    let m = poly.v.count
    var types = [Int](repeating: 0, count: m)
    for i in 0..<m {
        let t = n.dot(poly.v[i]) - w
        let type = t < -planeEps ? back : t > planeEps ? front : coplanar
        polyType |= type
        types[i] = type
    }
    if polyType == coplanar {
        emit(n.dot(poly.n) > 0 ? .coFront : .coBack, poly)
    } else if polyType == front {
        emit(.front, poly)
    } else if polyType == back {
        emit(.back, poly)
    } else {
        var f: [Vec3] = [], b: [Vec3] = []
        f.reserveCapacity(m + 1)
        b.reserveCapacity(m + 1)
        let hasFlags = poly.flags != nil
        var ff: [Bool] = [], bf: [Bool] = []
        for i in 0..<m {
            let j = (i + 1) % m
            let ti = types[i], tj = types[j], vi = poly.v[i], vj = poly.v[j]
            let fl = poly.flags?[i] ?? false
            if ti != back {
                f.append(vi)
                if hasFlags { ff.append(tj != back || ti == front ? fl : false) }
            }
            if ti != front {
                b.append(vi)
                if hasFlags { bf.append(tj != front || ti == back ? fl : false) }
            }
            if (ti | tj) == spanning {
                let t = (w - n.dot(vi)) / n.dot(vj - vi)
                let v = vi.lerp(to: vj, t)
                f.append(v)
                b.append(v)
                if hasFlags {
                    ff.append(ti == back ? fl : false)
                    bf.append(ti == front ? fl : false)
                }
            }
        }
        if f.count >= 3 {
            emit(.front, Polygon(v: f, n: poly.n, w: poly.w, kind: poly.kind, flags: hasFlags ? ff : nil, src: poly.src))
        }
        if b.count >= 3 {
            emit(.back, Polygon(v: b, n: poly.n, w: poly.w, kind: poly.kind, flags: hasFlags ? bf : nil, src: poly.src))
        }
    }
}

/// Splits every polygon at the plane, keeping all pieces (used by loop cuts).
func splitAll(_ polys: Mesh, n: Vec3, w: Double) -> Mesh {
    var out: Mesh = []
    out.reserveCapacity(polys.count)
    for p in polys { splitPolygon(n, w, p) { _, q in out.append(q) } }
    return out
}
