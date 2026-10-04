import Foundation

public enum Solid {
    /// Cap polygons for a planar loop given as 2D points plus a 2D → 3D
    /// mapping. Output keeps the loop's winding.
    static func caps(_ pts2: Loop, _ to3: (Vec2) -> Vec3, kind: FaceKind) -> Mesh {
        let ccw = Loop2D.area(pts2) > 0
        let pts = ccw ? pts2 : Array(pts2.reversed())
        let tris: [[Int]] = Loop2D.isConvex(pts) ? [Array(pts.indices)] : Loop2D.triangulate(pts)
        var out: Mesh = []
        for t in tris {
            var verts = t.map { to3(pts[$0]) }
            if !ccw { verts.reverse() }
            if let p = Polygon.make(verts, kind: kind) { out.append(p) }
        }
        return out
    }

    /// A 2D loop placed in 3D by `to3`, swept along `d`.
    public static func prism(_ loop2: Loop, _ to3: (Vec2) -> Vec3, _ d: Vec3, kind: FaceKind) -> Mesh {
        var pts = Loop2D.clean(loop2)
        if pts.count < 3 { return [] }
        // Orient so the base cap faces away from d.
        guard let probe = Polygon.make(pts.map(to3), kind: kind) else { return [] }
        if probe.n.dot(d) > 0 { pts.reverse() }
        let base = pts.map(to3)
        var polys = caps(pts, to3, kind: kind)
        polys.append(contentsOf: caps(Array(pts.reversed()), { to3($0) + d }, kind: kind))
        for i in 0..<base.count {
            let a = base[i], b = base[(i + 1) % base.count]
            if let p = Polygon.make([b, a, a + d, b + d], kind: kind) { polys.append(p) }
        }
        return polys
    }

    /// Prisms for a set of loops with holes: outers minus holes.
    public static func extrude(_ loops2: [Loop], _ to3: @escaping (Vec2) -> Vec3, _ d: Vec3, kind: FaceKind) throws -> Mesh {
        let (outers, holes) = Loop2D.nest(loops2.map(Loop2D.clean).filter { $0.count >= 3 })
        var mesh: Mesh = []
        for o in outers { mesh = try CSG.union(mesh, prism(o, to3, d, kind: kind)) }
        if !holes.isEmpty {
            // Holes overshoot both caps so the subtraction is clean.
            let dn = d.normalized
            let pad = dn.scaled(0.5)
            let holeTo3 = { (p: Vec2) in to3(p) - pad }
            let hd = d + dn.scaled(1)
            for h in holes { mesh = try CSG.subtract(mesh, prism(h, holeTo3, hd, kind: kind)) }
        }
        return mesh
    }

    public static func box(min: Vec3, max: Vec3, kind: FaceKind) -> Mesh {
        let loop: Loop = [Vec2(min.x, min.y), Vec2(max.x, min.y), Vec2(max.x, max.y), Vec2(min.x, max.y)]
        return prism(loop, { Vec3($0.x, $0.y, min.z) }, Vec3(0, 0, max.z - min.z), kind: kind)
    }

    /// Lathe: a profile loop in (r, z) spun around the z axis.
    public static func revolve(_ loop2: Loop, segments: Double, kind: FaceKind) -> Mesh {
        var pts = Loop2D.clean(loop2.map { Vec2(Swift.max(0, $0.x), $0.y) })
        if pts.count < 3 { return [] }
        if Loop2D.area(pts) < 0 { pts.reverse() }
        let segs = Int(Swift.max(6, jsRound(segments)))
        let P = { (p: Vec2, a: Double) in Vec3(p.x * cos(a), p.x * sin(a), p.y) }
        var polys: Mesh = []
        for j in 0..<segs {
            let a0 = Double(j) / Double(segs) * Double.pi * 2
            let a1 = Double(j + 1) / Double(segs) * Double.pi * 2
            for i in 0..<pts.count {
                let p = pts[i], q = pts[(i + 1) % pts.count]
                let quad = [P(p, a0), P(p, a1), P(q, a1), P(q, a0)]
                var verts: [Vec3] = []
                for v in quad {
                    if let last = verts.last, (last - v).length <= 1e-6 { continue }
                    verts.append(v)
                }
                if verts.count > 2 && (verts[0] - verts[verts.count - 1]).length < 1e-6 { verts.removeLast() }
                if verts.count < 3 { continue }
                if let poly = Polygon.make(verts, kind: kind) { polys.append(poly) }
            }
        }
        return polys
    }

    /// A prism over an arbitrary convex 3D polygon, swept along `d`.
    static func prism3(_ verts: [Vec3], _ d: Vec3, kind: FaceKind) -> Mesh {
        var base = verts
        guard let probe = Polygon.make(base, kind: kind) else { return [] }
        if probe.n.dot(d) > 0 { base.reverse() }
        var polys: Mesh = []
        func add(_ vs: [Vec3]) { if let p = Polygon.make(vs, kind: kind) { polys.append(p) } }
        add(base)
        add(Array(base.map { $0 + d }.reversed()))
        for i in 0..<base.count {
            let a = base[i], b = base[(i + 1) % base.count]
            add([b, a, a + d, b + d])
        }
        return polys
    }
}
