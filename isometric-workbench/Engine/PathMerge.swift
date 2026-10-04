import CoreGraphics
import Foundation
import IsoMath

/// Shrinks line art for vector animation formats, where every frame is
/// written out in full: points snap to a 0.1 unit grid, faces that tile merge
/// into outlines and segments join into polylines.
nonisolated enum PathMerge {
    struct Vertex {
        var p: CGPoint
        var i = CGPoint.zero
        var o = CGPoint.zero

        var sharp: Bool { i == .zero && o == .zero }
    }

    struct Contour {
        var v: [Vertex] = []
        var closed = false

        var straight: Bool { v.allSatisfy(\.sharp) }
    }

    /// Points on a 0.1 unit grid, as integers so they compare exactly.
    struct GridPoint: Hashable {
        var x: Int
        var y: Int

        init(_ p: CGPoint) {
            x = Int((p.x * 10).rounded())
            y = Int((p.y * 10).rounded())
        }

        var point: CGPoint { CGPoint(x: Double(x) / 10, y: Double(y) / 10) }
    }

    struct Edge: Hashable {
        var a: GridPoint
        var b: GridPoint

        init(_ p: GridPoint, _ q: GridPoint) {
            (a, b) = (p.x, p.y) < (q.x, q.y) ? (p, q) : (q, p)
        }
    }

    /// Bezier contours on the 0.1 unit grid with tangents relative to their
    /// vertex; quadratic curves (from glyphs) become cubics.
    static func contours(_ path: CGPath) -> [Contour] {
        func snap(_ p: CGPoint) -> CGPoint { GridPoint(p).point }
        var out: [Contour] = []
        var cur = Contour()
        var start = CGPoint.zero
        func flush() {
            if cur.v.count > 1 { out.append(cur) }
            cur = Contour()
        }
        func begin() { if cur.v.isEmpty { cur.v = [Vertex(p: start)] } }
        func add(_ v: Vertex) {
            if let last = cur.v.last, last.p == v.p, last.o == .zero, v.i == .zero {
                cur.v[cur.v.count - 1].o = v.o
            } else {
                cur.v.append(v)
            }
        }
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                flush()
                start = snap(e.points[0])
                cur.v = [Vertex(p: start)]
            case .addLineToPoint:
                begin()
                add(Vertex(p: snap(e.points[0])))
            case .addQuadCurveToPoint:
                begin()
                let p0 = cur.v[cur.v.count - 1].p, c = e.points[0], p = snap(e.points[1])
                cur.v[cur.v.count - 1].o = snap(CGPoint(x: (c.x - p0.x) * 2 / 3, y: (c.y - p0.y) * 2 / 3))
                add(Vertex(p: p, i: snap(CGPoint(x: (c.x - p.x) * 2 / 3, y: (c.y - p.y) * 2 / 3))))
            case .addCurveToPoint:
                begin()
                let p0 = cur.v[cur.v.count - 1].p, c1 = e.points[0], c2 = e.points[1], p = snap(e.points[2])
                cur.v[cur.v.count - 1].o = snap(CGPoint(x: c1.x - p0.x, y: c1.y - p0.y))
                add(Vertex(p: p, i: snap(CGPoint(x: c2.x - p.x, y: c2.y - p.y))))
            case .closeSubpath:
                cur.closed = true
                if cur.v.count > 2, let first = cur.v.first, let last = cur.v.last, first.p == last.p {
                    cur.v[0].i = last.i
                    cur.v.removeLast()
                }
                flush()
            @unknown default:
                break
            }
        }
        flush()
        return out
    }

    /// Straight polygons that tile without overlapping, as the loops around
    /// them: shared edges cancel in pairs, and filling what's left even-odd
    /// covers the same area with far fewer points.
    static func outline(_ cs: [Contour]) -> [Contour] {
        guard cs.count > 1, cs.allSatisfy({ $0.closed && $0.straight }) else { return cs }
        var odd: [Edge: Int] = [:]
        var order: [Edge] = []
        for c in cs {
            for i in c.v.indices {
                let a = GridPoint(c.v[i].p), b = GridPoint(c.v[(i + 1) % c.v.count].p)
                guard a != b else { continue }
                let e = Edge(a, b)
                if odd.removeValue(forKey: e) == nil {
                    odd[e] = order.count
                    order.append(e)
                }
            }
        }
        let edges = order.enumerated().filter { odd[$0.element] == $0.offset }.map(\.element)
        var graph = Graph(edges)
        var out: [Contour] = []
        for e in edges {
            let loop = graph.walk(from: e.a)
            guard loop.count > 3 else { continue }
            let pts = simplify(Array(loop.dropLast()))
            if pts.count > 2 { out.append(Contour(v: pts.map { Vertex(p: $0) }, closed: true)) }
        }
        return out
    }

    /// Straight open polylines joined where they meet; repeated segments drop.
    static func chain(_ cs: [Contour]) -> [Contour] {
        var out: [Contour] = []
        var seen: Set<Edge> = []
        var edges: [Edge] = []
        for c in cs {
            guard !c.closed, c.straight else {
                out.append(c)
                continue
            }
            for i in 1..<c.v.count {
                let e = Edge(GridPoint(c.v[i - 1].p), GridPoint(c.v[i].p))
                if e.a != e.b, seen.insert(e).inserted { edges.append(e) }
            }
        }
        var graph = Graph(edges)
        // Ends first, so open chains come out whole.
        let ends = edges.flatMap { [$0.a, $0.b] }.filter { graph.degree($0) % 2 == 1 }
        for p in ends + edges.map(\.a) {
            let line = graph.walk(from: p)
            guard line.count > 1 else { continue }
            let closed = line.count > 3 && line.first == line.last
            let pts = simplify(closed ? Array(line.dropLast()) : line, closed: closed)
            out.append(Contour(v: pts.map { Vertex(p: $0) }, closed: closed))
        }
        return out
    }

    /// Undirected edges, walked in the order they were added so output is
    /// stable from frame to frame.
    struct Graph {
        private var next: [GridPoint: [GridPoint]] = [:]

        init(_ edges: [Edge]) {
            for e in edges {
                next[e.a, default: []].append(e.b)
                next[e.b, default: []].append(e.a)
            }
        }

        func degree(_ p: GridPoint) -> Int { next[p]?.count ?? 0 }

        /// Follows unused edges from `p` until stuck, using them up.
        mutating func walk(from p: GridPoint) -> [GridPoint] {
            var path = [p], at = p
            while let to = next[at]?.first {
                next[at]?.removeFirst()
                if let i = next[to]?.firstIndex(of: at) { next[to]?.remove(at: i) }
                at = to
                path.append(at)
                if at == p && degree(p) == 0 { break }
            }
            return path
        }
    }

    /// Drops points within 0.05 units of the line through their neighbours.
    static func simplify(_ pts: [GridPoint], closed: Bool = true) -> [CGPoint] {
        let p = pts.map(\.point)
        guard p.count > 2 else { return p }
        var out = [p[0]]
        for i in 1..<p.count {
            let a = out[out.count - 1], b = p[i]
            guard let c = i + 1 < p.count ? p[i + 1] : (closed ? out[0] : nil) else {
                out.append(b)
                continue
            }
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y), bc = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let ac = hypot(c.x - a.x, c.y - a.y)
            let cross = abs(ab.x * bc.y - ab.y * bc.x)
            if ac > 0, cross / ac < 0.05, ab.x * bc.x + ab.y * bc.y > 0 { continue }
            out.append(b)
        }
        return out
    }

    static func polygons(_ polys: [[Vec2]], offset: Vec2 = Vec2(0, 0)) -> CGPath {
        let p = CGMutablePath()
        for poly in polys { p.addPolygon(poly.map { $0 + offset }) }
        return p
    }

    /// Segments as polylines, joining ones that continue from the last.
    static func lines(_ segs: [(Vec2, Vec2)], offset: Vec2 = Vec2(0, 0)) -> CGPath {
        let p = CGMutablePath()
        for (a, b) in segs {
            let a = (a + offset).cgPoint, b = (b + offset).cgPoint
            if p.isEmpty || abs(p.currentPoint.x - a.x) > 1e-6 || abs(p.currentPoint.y - a.y) > 1e-6 { p.move(to: a) }
            p.addLine(to: b)
        }
        return p
    }
}
