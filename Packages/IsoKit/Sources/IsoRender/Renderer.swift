import Foundation

/// One drawing layer: consecutive faces that share a look and don't overlap
/// on screen. Flat faces only share a layer with pieces of the same face, so a
/// layer with a `face` is always one selectable face.
public struct Run: Sendable {
    public var kind: FaceKind
    public var shade: Double
    public var faceKey: String?
    public var face: FaceID?
    public var polys: [[Vec2]]
    public var boxes: [Box2]
    public var edges: [(Vec2, Vec2)]
}

public struct RenderOptions: Sendable, Hashable {
    /// Rotation in degrees: x = tilt, y = roll, z = spin.
    public var rotation: Vec3
    public var pivot: Vec3
    public var angle: IsoAngle
    public var smooth: Double

    public init(rotation: Vec3 = .zero, pivot: Vec3 = .zero, angle: IsoAngle = .isometric, smooth: Double = 40) {
        self.rotation = rotation
        self.pivot = pivot
        self.angle = angle
        self.smooth = smooth
    }

    public var view: ViewTransform { ViewTransform(rotation: rotation, pivot: pivot) }
}

public enum Renderer {
    /// Draw-ordered runs in screen space, relative to the world origin — the
    /// port of `renderSolid`.
    public static func render(_ prepared: PreparedMesh, options: RenderOptions) throws -> [Run] {
        if prepared.raw.isEmpty { throw GeometryError.empty }
        let t = options.angle
        let toViewer = t.toViewer
        let view = options.view
        // Edges are classified in model space (where loop rings are
        // axis-aligned), then the mesh is turned to face the viewer.
        let modelViewer = view.r.transposed * toViewer
        let (flags, curved) = FeatureEdges.classify(
            prepared.mesh, toViewer: modelViewer, smoothDeg: options.smooth,
            loops: prepared.context.loops, neighbours: prepared.neighbours)
        let srcs = prepared.mesh.indices.map { FaceID(prepared.mesh[$0], curved: curved[$0], loops: prepared.context.loops) }
        var mesh = prepared.mesh
        if !view.isIdentity { mesh = mesh.transformed(view.apply, normal: view.applyNormal) }
        var visible: Mesh = []
        for (i, p) in mesh.enumerated() where p.n.dot(toViewer) > 1e-6 {
            visible.append(Polygon(v: p.v, n: p.n, w: p.w, kind: p.kind, flags: flags[i], src: i))
        }
        try Task.checkCancellation()

        // A back-to-front walk of a BSP tree gives an exact painter's order.
        enum Item {
            case node(BSPNode?)
            case polys([Polygon])
        }
        var order: [Polygon] = []
        order.reserveCapacity(visible.count)
        var stack: [Item] = [.node(try BSPNode(visible))]
        while let item = stack.popLast() {
            switch item {
            case .polys(let ps):
                order.append(contentsOf: ps)
            case .node(let node):
                guard let node, let n = node.n else { continue }
                let viewerInFront = n.dot(toViewer) > 0
                stack.append(.node(viewerInFront ? node.front : node.back))
                stack.append(.polys(node.polys))
                stack.append(.node(viewerInFront ? node.back : node.front))
            }
        }

        // Consecutive faces share one layer when they look the same and don't
        // overlap on screen — then their order within the layer doesn't matter.
        var runs: [Run] = []
        for p in order {
            let pts = p.v.map { Vec2(($0.x - $0.y) * t.c, ($0.x + $0.y) * t.s - $0.z) }
            if abs(Loop2D.area(pts)) < 1e-4 { continue }
            let shade = Shading.amount(p.n, kind: p.kind)
            let box = Overlap.bbox(pts)
            let src = p.src.map { srcs[$0] }
            let faceKey = src.flatMap { $0.curved ? nil : $0.key }
            func hits(_ r: Run) -> Bool {
                for (i, q) in r.polys.enumerated() where Overlap.boxes(r.boxes[i], box) && Overlap.convex(q, pts) {
                    return true
                }
                return false
            }
            // Walk back through earlier layers: join a matching one as long as
            // we don't jump over anything this face overlaps.
            var target: Int? = nil
            var k = runs.count - 1
            while k >= 0 {
                let r = runs[k]
                let overlaps = hits(r)
                if !overlaps && r.kind == p.kind && r.shade == shade && r.faceKey == faceKey {
                    target = k
                    break
                }
                if overlaps { break }
                k -= 1
            }
            if target == nil {
                runs.append(Run(kind: p.kind, shade: shade, faceKey: faceKey, face: faceKey != nil ? src : nil, polys: [], boxes: [], edges: []))
                target = runs.count - 1
            }
            let ri = target!
            runs[ri].polys.append(pts)
            runs[ri].boxes.append(box)
            if let fl = p.flags {
                for (i, a) in pts.enumerated() where i < fl.count && fl[i] {
                    runs[ri].edges.append((a, pts[(i + 1) % pts.count]))
                }
            }
        }
        return runs
    }

    public static func bounds(_ runs: [Run]) -> Box2 {
        var b = Box2.empty
        for r in runs { for poly in r.polys { for p in poly { b.add(p) } } }
        return b
    }
}

public enum Overlap {
    public static func bbox(_ pts: [Vec2]) -> Box2 {
        var b = Box2.empty
        for p in pts { b.add(p) }
        return b
    }

    public static func boxes(_ a: Box2, _ b: Box2) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// Separating-axis test for convex polygons; touching along an edge
    /// doesn't count.
    public static func convex(_ a: [Vec2], _ b: [Vec2]) -> Bool {
        for poly in [a, b] {
            for i in 0..<poly.count {
                let p = poly[i], q = poly[(i + 1) % poly.count]
                let ax = -(q.y - p.y), ay = q.x - p.x
                let l = hypot(ax, ay)
                if l < 1e-9 { continue }
                var aMin = Double.infinity, aMax = -Double.infinity, bMin = Double.infinity, bMax = -Double.infinity
                for v in a {
                    let d = (v.x * ax + v.y * ay) / l
                    aMin = min(aMin, d)
                    aMax = max(aMax, d)
                }
                for v in b {
                    let d = (v.x * ax + v.y * ay) / l
                    bMin = min(bMin, d)
                    bMax = max(bMax, d)
                }
                if aMax <= bMin + 0.01 || bMax <= aMin + 0.01 { return false }
            }
        }
        return true
    }
}

public enum Hatch {
    /// 45° screen-space hatch lines clipped to a convex polygon.
    public static func segments(_ pts: [Vec2], gap: Double) -> [(Vec2, Vec2)] {
        var lo = Double.infinity, hi = -Double.infinity
        for p in pts {
            lo = min(lo, p.x + p.y)
            hi = max(hi, p.x + p.y)
        }
        var out: [(Vec2, Vec2)] = []
        var s = (lo / gap).rounded(.up) * gap
        while s <= hi {
            var hits: [Vec2] = []
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                let fa = a.x + a.y - s, fb = b.x + b.y - s
                if (fa < 0) != (fb < 0) {
                    let k = fa / (fa - fb)
                    hits.append(Vec2(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k))
                }
            }
            if hits.count >= 2 { out.append((hits[0], hits[1])) }
            s += gap
        }
        return out
    }
}

public enum RingOutline {
    /// Where the plane `axis = t` crosses the visible faces, in screen space.
    public static func trace(_ prepared: PreparedMesh, k: Int, t: Double, options: RenderOptions) -> [(Vec2, Vec2)] {
        let view = options.view
        let tr = options.angle
        let vm = view.r.transposed * tr.toViewer
        func project(_ v: Vec3) -> Vec2 {
            let q = view.apply(v)
            return Vec2(round1((q.x - q.y) * tr.c), round1((q.x + q.y) * tr.s - q.z))
        }
        var out: [(Vec2, Vec2)] = []
        for p in prepared.raw {
            if p.n.dot(vm) <= 1e-6 || abs(p.n[k]) > 0.99 { continue }
            var pts: [Vec3] = []
            var onEdge: (Vec3, Vec3)? = nil
            for i in 0..<p.v.count {
                let a = p.v[i], b = p.v[(i + 1) % p.v.count]
                let da = a[k] - t, db = b[k] - t
                if abs(da) < 1e-4 && abs(db) < 1e-4 {
                    onEdge = (a, b)
                    break
                }
                if abs(da) < 1e-4 {
                    pts.append(a)
                } else if da * db < 0 {
                    pts.append(a.lerp(to: b, da / (da - db)))
                }
            }
            if let seg = onEdge ?? (pts.count >= 2 ? (pts[0], pts[1]) : nil) {
                out.append((project(seg.0), project(seg.1)))
            }
        }
        return out
    }
}
