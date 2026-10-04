import Foundation

/// A closed 2D outline.
public typealias Loop = [Vec2]

public enum Loop2D {
    public static func area(_ pts: Loop) -> Double {
        var a = 0.0
        let m = pts.count
        for i in 0..<m {
            let p = pts[i], q = pts[(i + 1) % m]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    public static func contains(_ pt: Vec2, in poly: Loop) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > pt.y) != (b.y > pt.y)
                && pt.x < ((b.x - a.x) * (pt.y - a.y)) / (b.y - a.y) + a.x
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Drops repeated points, a closing duplicate, and collinear points.
    public static func clean(_ pts: Loop) -> Loop {
        var out: Loop = []
        out.reserveCapacity(pts.count)
        for p in pts {
            if let last = out.last, abs(last.x - p.x) <= 1e-6, abs(last.y - p.y) <= 1e-6 { continue }
            out.append(p)
        }
        while out.count > 1, abs(out[0].x - out[out.count - 1].x) < 1e-6,
            abs(out[0].y - out[out.count - 1].y) < 1e-6
        {
            out.removeLast()
        }
        var i = out.count - 1
        while out.count > 3 && i >= 0 {
            let c = out.count
            let a = out[(i - 1 + c) % c], b = out[i], d = out[(i + 1) % c]
            if abs((b.x - a.x) * (d.y - a.y) - (b.y - a.y) * (d.x - a.x)) < 1e-9 { out.remove(at: i) }
            i -= 1
        }
        return out
    }

    /// Ear clipping. `pts` must be counter-clockwise; returns index triples.
    public static func triangulate(_ pts: Loop) -> [[Int]] {
        var idx = Array(pts.indices)
        var tris: [[Int]] = []
        func cross(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var guardCount = 0
        while idx.count > 3 && guardCount < 100_000 {
            guardCount += 1
            var clipped = false
            for k in 0..<idx.count {
                let c = idx.count
                let i0 = idx[(k - 1 + c) % c], i1 = idx[k], i2 = idx[(k + 1) % c]
                let a = pts[i0], b = pts[i1], d = pts[i2]
                if cross(a, b, d) <= 1e-12 { continue }
                var ear = true
                for j in idx where j != i0 && j != i1 && j != i2 {
                    let p = pts[j]
                    if cross(a, b, p) > 0 && cross(b, d, p) > 0 && cross(d, a, p) > 0 {
                        ear = false
                        break
                    }
                }
                if !ear { continue }
                tris.append([i0, i1, i2])
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped {
                tris.append([idx[0], idx[1], idx[2]])
                idx.remove(at: 1)
            }
        }
        if idx.count == 3 { tris.append(idx) }
        return tris
    }

    public static func isConvex(_ pts: Loop) -> Bool {
        let m = pts.count
        for i in 0..<m {
            let a = pts[i], b = pts[(i + 1) % m], c = pts[(i + 2) % m]
            if (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) < -1e-9 { return false }
        }
        return true
    }

    /// Splits loops into outer boundaries and holes (even-odd nesting).
    public static func nest(_ loops: [Loop]) -> (outers: [Loop], holes: [Loop]) {
        var outers: [Loop] = [], holes: [Loop] = []
        for (i, loop) in loops.enumerated() {
            var depth = 0
            for (j, other) in loops.enumerated() where i != j && contains(loop[0], in: other) {
                depth += 1
            }
            if depth % 2 == 1 { holes.append(loop) } else { outers.append(loop) }
        }
        return (outers, holes)
    }

    public static func bounds(_ loops: [Loop]) -> Box2 {
        var b = Box2.empty
        for l in loops { for p in l { b.add(p) } }
        return b
    }

    public static func rounded(_ loops: [Loop]) -> [Loop] {
        loops.map { $0.map { Vec2(round2($0.x), round2($0.y)) } }
    }
}
