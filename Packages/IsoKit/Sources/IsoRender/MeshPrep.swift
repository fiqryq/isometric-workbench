@_exported import IsoGeometry
import Foundation

struct CellKey: Hashable {
    let x: Int, y: Int, z: Int
}

@inline(__always) func cellIndex(_ v: Double, _ cell: Double) -> Int { Int((v / cell).rounded(.down)) }

public enum TJunctions {
    /// CSG leaves T-junctions (a vertex of one face lying mid-edge on
    /// another). Splitting edges at those vertices gives every edge exactly
    /// one neighbour.
    public static func repair(_ polys: Mesh) -> Mesh {
        let cell = 24.0
        var grid: [CellKey: [Vec3]] = [:]
        var seen = Set<SIMD3<Int64>>()
        for p in polys {
            for v in p.v {
                let id = SIMD3<Int64>(Int64(jsRound(v.x * 1000)), Int64(jsRound(v.y * 1000)), Int64(jsRound(v.z * 1000)))
                if !seen.insert(id).inserted { continue }
                grid[CellKey(x: cellIndex(v.x, cell), y: cellIndex(v.y, cell), z: cellIndex(v.z, cell)), default: []].append(v)
            }
        }
        return polys.map { p in
            var out: [Vec3] = []
            out.reserveCapacity(p.v.count)
            let m = p.v.count
            for i in 0..<m {
                let a = p.v[i], b = p.v[(i + 1) % m]
                out.append(a)
                let ab = b - a
                let l2 = ab.dot(ab)
                if l2 < 1e-6 { continue }
                var lo = [Int](repeating: 0, count: 3), hi = lo
                for k in 0..<3 {
                    lo[k] = cellIndex(min(a[k], b[k]) - 0.01, cell)
                    hi[k] = cellIndex(max(a[k], b[k]) + 0.01, cell)
                }
                var mids: [(Double, Vec3)] = []
                for x in lo[0]...hi[0] {
                    for y in lo[1]...hi[1] {
                        for z in lo[2]...hi[2] {
                            guard let list = grid[CellKey(x: x, y: y, z: z)] else { continue }
                            for v in list {
                                let t = (v - a).dot(ab) / l2
                                if t <= 1e-4 || t >= 1 - 1e-4 { continue }
                                let onEdge = a + ab.scaled(t)
                                if (v - onEdge).length > 0.005 { continue }
                                // Insert the point *on* this edge (not the
                                // neighbour's vertex) so the face stays planar.
                                mids.append((t, onEdge))
                            }
                        }
                    }
                }
                if mids.isEmpty { continue }
                mids.sort { $0.0 < $1.0 }
                var lastT = 0.0
                for (t, v) in mids where t - lastT > 1e-5 {
                    out.append(v)
                    lastT = t
                }
            }
            return Polygon(v: out, n: p.n, w: p.w, kind: p.kind)
        }
    }
}

public enum EdgeIndex {
    /// For every polygon edge, the polygons on the other side of it. After
    /// T-junction repair neighbours share exact endpoints, so a hash of the
    /// edge finds them directly; a spatial scan is only the fallback.
    public static func build(_ polys: Mesh) -> [[[Int]]] {
        struct Q: Hashable, Comparable {
            let x: Int64, y: Int64, z: Int64
            static func < (a: Q, b: Q) -> Bool { (a.x, a.y, a.z) < (b.x, b.y, b.z) }
        }
        struct EKey: Hashable { let a: Q, b: Q }
        func q(_ v: Vec3) -> Q { Q(x: Int64(jsRound(v.x * 100)), y: Int64(jsRound(v.y * 100)), z: Int64(jsRound(v.z * 100))) }
        func ekey(_ a: Vec3, _ b: Vec3) -> EKey {
            let ka = q(a), kb = q(b)
            return ka < kb ? EKey(a: ka, b: kb) : EKey(a: kb, b: ka)
        }
        var byEdge: [EKey: [Int]] = [:]
        for (pi, p) in polys.enumerated() {
            for i in 0..<p.v.count { byEdge[ekey(p.v[i], p.v[(i + 1) % p.v.count]), default: []].append(pi) }
        }
        let cell = 24.0
        var grid: [CellKey: [(Int, Vec3, Vec3)]]? = nil
        func buildGrid() -> [CellKey: [(Int, Vec3, Vec3)]] {
            var g: [CellKey: [(Int, Vec3, Vec3)]] = [:]
            for (pi, p) in polys.enumerated() {
                for i in 0..<p.v.count {
                    let a = p.v[i], b = p.v[(i + 1) % p.v.count]
                    let lo = (0..<3).map { cellIndex(min(a[$0], b[$0]) - 0.05, cell) }
                    let hi = (0..<3).map { cellIndex(max(a[$0], b[$0]) + 0.05, cell) }
                    for x in lo[0]...hi[0] {
                        for y in lo[1]...hi[1] {
                            for z in lo[2]...hi[2] { g[CellKey(x: x, y: y, z: z), default: []].append((pi, a, b)) }
                        }
                    }
                }
            }
            return g
        }
        func distToSeg(_ m: Vec3, _ a: Vec3, _ b: Vec3) -> Double {
            let ab = b - a
            let l2 = ab.dot(ab)
            let t = l2 != 0 ? max(0, min(1, (m - a).dot(ab) / l2)) : 0
            return (m - (a + ab.scaled(t))).length
        }
        return polys.enumerated().map { pi, p in
            var out: [[Int]] = []
            out.reserveCapacity(p.v.count)
            for i in 0..<p.v.count {
                let a = p.v[i], b = p.v[(i + 1) % p.v.count]
                var found = (byEdge[ekey(a, b)] ?? []).filter { $0 != pi }
                if found.isEmpty {
                    if grid == nil { grid = buildGrid() }
                    let m = a.lerp(to: b, 0.5)
                    let dir = (b - a).normalized
                    let list = grid![CellKey(x: cellIndex(m.x, cell), y: cellIndex(m.y, cell), z: cellIndex(m.z, cell))] ?? []
                    for (qi, qa, qb) in list {
                        if qi == pi || found.contains(qi) { continue }
                        if distToSeg(m, qa, qb) > 0.02 { continue }
                        if dir.cross((qb - qa).normalized).length > 0.02 { continue }
                        found.append(qi)
                    }
                }
                out.append(found)
            }
            return out
        }
    }
}

/// A mesh ready to be drawn from any angle: the raw CSG result, its loop-cut
/// context, the T-junction-free copy and its edge neighbours.
public struct PreparedMesh: Sendable {
    public let raw: Mesh
    public let context: LoopContext
    public let mesh: Mesh
    public let neighbours: [[[Int]]]
    public let bounds: Bounds3

    public init(raw: Mesh, context: LoopContext) {
        self.raw = raw
        self.context = context
        let fixed = raw.isEmpty ? [] : TJunctions.repair(raw)
        self.mesh = fixed
        self.neighbours = EdgeIndex.build(fixed)
        self.bounds = raw.bounds
    }

    public static func build(_ ops: [Op]) throws -> PreparedMesh {
        var ctx = LoopContext()
        let raw = try Evaluator.evaluate(ops, context: &ctx)
        try Task.checkCancellation()
        return PreparedMesh(raw: raw, context: ctx)
    }

    public var isEmpty: Bool { raw.isEmpty }
}
