import Foundation

/// Loop-cut rings collected while evaluating, so they can be drawn and
/// referenced by later steps.
public struct LoopContext: Sendable {
    public struct Rings: Sendable, Hashable {
        public let k: Int
        public let ts: [Double]
    }

    public struct LoopSet: Sendable, Hashable {
        public let k: Int
        public let knots: [Double]
    }

    public var loops: [Rings] = []
    public var loopSets: [String: LoopSet] = [:]

    public init() {}
}

/// Turns a list of ops into a mesh — the port of `evaluateOps` / `opMesh`.
public enum Evaluator {
    public static func evaluate(_ ops: [Op]) throws -> Mesh {
        var ctx = LoopContext()
        return try evaluate(ops, context: &ctx)
    }

    public static func evaluate(_ ops: [Op], context ctx: inout LoopContext) throws -> Mesh {
        var mesh: Mesh = []
        for op in ops where op.enabled {
            try Task.checkCancellation()
            mesh = try apply(op, to: mesh, context: &ctx)
        }
        return mesh
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func apply(_ op: Op, to mesh: Mesh, context ctx: inout LoopContext) throws -> Mesh {
        switch op.type {
        case "box":
            return try CSG.union(mesh, Solid.box(min: .zero, max: Vec3(op.num("w", 1), op.num("d", 1), op.num("h", 1)), kind: .solid))

        case "cylinder":
            let r = op.num("r", 1), h = op.num("h", 1)
            return try CSG.union(mesh, Solid.revolve([Vec2(0, 0), Vec2(r, 0), Vec2(r, h), Vec2(0, h)], segments: op.num("segments", 48), kind: .solid))

        case "extrude":
            let plane = op.string("plane").flatMap(IsoPlane.init(rawValue:)) ?? .right
            let tool = try Solid.extrude(
                op.loops(), IsoPlaneMapping.profileTo3(plane),
                IsoPlaneMapping.extrudeDirection(plane, depth: op.num("depth", 1)), kind: .solid)
            return try CSG.union(mesh, tool)

        case "revolve":
            let axis = op.num("axis", 0)
            var out = mesh
            for loop in op.loops() {
                out = try CSG.union(out, Solid.revolve(loop.map { Vec2($0.x + axis, $0.y) }, segments: op.num("segments", 48), kind: .solid))
            }
            return out

        case "push":
            let axis = op.axis() ?? .z
            let k = axis.index
            let dir = axis.unit
            let depth = op.num("depth", 0)
            let at = op.num("at", 0)
            let through = op.truthy("through")
            if through || depth < 0 {
                let reach = through && !mesh.isEmpty ? at - mesh.bounds.min[k] + 1 : -depth
                let start = at + 0.5
                let tool = try Solid.extrude(op.loops(), IsoPlaneMapping.planeTo3(axis: axis, at: start), dir.scaled(-(reach + 0.5)), kind: .solid)
                return try CSG.subtract(mesh, tool)
            }
            if depth == 0 { return mesh }
            // Start slightly inside the face so the union welds cleanly.
            let tool = try Solid.extrude(op.loops(), IsoPlaneMapping.planeTo3(axis: axis, at: at - 0.01), dir.scaled(depth + 0.01), kind: .solid)
            return try CSG.union(mesh, tool)

        case "cut":
            if mesh.isEmpty { return mesh }
            let b = mesh.bounds
            let pad = 10.0
            func at(_ k: Int, _ key: String) -> Double {
                b.min[k] + (b.max[k] - b.min[k]) * min(1, max(0, op.num(key, 50) / 100))
            }
            var lo = Vec3(b.min.x - pad, b.min.y - pad, b.min.z - pad)
            let hi = Vec3(b.max.x + pad, b.max.y + pad, b.max.z + pad)
            let preset = op.string("preset")
            if preset == "quarter" || preset == "right" { lo.x = at(0, "fx") }
            if preset == "quarter" || preset == "left" { lo.y = at(1, "fy") }
            if preset == "top" { lo.z = at(2, "fz") }
            return try CSG.subtract(mesh, Solid.box(min: lo, max: hi, kind: .cut))

        case "merge":
            var other = try evaluate(op.subOps)
            if let rows = op["m"]?.array {
                let m = Mat3(rows: rows.map { ($0.array ?? []).map { $0.jsNumber ?? 0 } })
                other = other.transformed({ m * $0 }, normal: { m * $0 })
            }
            other = other.translated(by: Vec3(op.num("ox", 0), op.num("oy", 0), op.num("oz", 0)))
            return op.string("mode") == "subtract" ? try CSG.subtract(mesh, other) : try CSG.union(mesh, other)

        case "sphere":
            let r = op.num("r", 50), seg = max(8, jsRound(op.num("segments", 32)))
            let n = Int(max(4, jsRound(seg / 2)))
            var prof: Loop = [Vec2(0, 0)]
            for i in 1..<n {
                let a = Double.pi * Double(i) / Double(n)
                prof.append(Vec2(r * sin(a), r - r * cos(a)))
            }
            prof.append(Vec2(0, 2 * r))
            return try CSG.union(mesh, Solid.revolve(prof, segments: seg, kind: .solid))

        case "cone":
            let r1 = max(0, op.num("r1", 50)), r2 = max(0, op.num("r2", 0)), h = op.num("h", 80)
            let prof: Loop = r2 > 0.01
                ? [Vec2(0, 0), Vec2(r1, 0), Vec2(r2, h), Vec2(0, h)]
                : [Vec2(0, 0), Vec2(r1, 0), Vec2(0, h)]
            return try CSG.union(mesh, Solid.revolve(prof, segments: op.num("segments", 40), kind: .solid))

        case "tube":
            let r = op.num("r", 50), ri = max(0.5, min(r - 0.5, op.num("ri", 30))), h = op.num("h", 80)
            return try CSG.union(mesh, Solid.revolve([Vec2(ri, 0), Vec2(r, 0), Vec2(r, h), Vec2(ri, h)], segments: op.num("segments", 48), kind: .solid))

        case "torus":
            let bigR = op.num("R", 60), r = max(1, min(bigR - 1, op.num("r", 16)))
            let sides = Int(max(6, jsRound(op.num("sides", 16))))
            var prof: Loop = []
            for i in 0..<sides {
                let a = Double(i) / Double(sides) * Double.pi * 2
                prof.append(Vec2(bigR + r * cos(a), r + r * sin(a)))
            }
            return try CSG.union(mesh, Solid.revolve(prof, segments: op.num("segments", 40), kind: .solid))

        case "prism":
            let r = op.num("r", 50), h = op.num("h", 60), sides = max(3, min(64, jsRound(op.num("sides", 6))))
            return try CSG.union(mesh, Solid.revolve([Vec2(0, 0), Vec2(r, 0), Vec2(r, h), Vec2(0, h)], segments: sides, kind: .solid))

        case "wedge":
            let w = op.num("w", 120), d = op.num("d", 120), h = op.num("h", 80)
            let tri: Loop = [Vec2(0, 0), Vec2(w, 0), Vec2(0, -h)]
            let tool = try Solid.extrude([tri], IsoPlaneMapping.profileTo3(.left), Vec3(0, -d, 0), kind: .solid)
            return try CSG.union(mesh, tool.translated(by: Vec3(0, d, 0)))

        case "stairs":
            let w = op.num("w", 120), d = op.num("d", 160), h = op.num("h", 100)
            let n = Int(max(1, min(24, jsRound(op.num("steps", 5)))))
            var out = mesh
            for i in 0..<n {
                let di = Double(i), dn = Double(n)
                out = try CSG.union(out, Solid.box(min: .zero, max: Vec3(w, d - (di * d) / dn, ((di + 1) * h) / dn), kind: .solid))
            }
            return out

        case "move":
            return mesh.translated(by: Vec3(op.num("x", 0), op.num("y", 0), op.num("z", 0)))

        case "scale":
            if mesh.isEmpty { return mesh }
            let b = mesh.bounds
            let s = Vec3(max(0.01, op.num("x", 100) / 100), max(0.01, op.num("y", 100) / 100), max(0.01, op.num("z", 100) / 100))
            return rescale(mesh, s: s, c: Vec3((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, b.min.z))

        case "size":
            // Resize to an exact width / depth / height around the base centre.
            if mesh.isEmpty { return mesh }
            let b = mesh.bounds
            var s = Vec3(1, 1, 1)
            for (i, key) in ["w", "d", "h"].enumerated() {
                let ext = b.max[i] - b.min[i], target = op.num(key, ext)
                s[i] = ext > 0.01 && target > 0 ? target / ext : 1
            }
            return rescale(mesh, s: s, c: Vec3((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, b.min.z))

        case "mirror":
            if mesh.isEmpty { return mesh }
            let k = (op.axis() ?? .x).index
            let b = mesh.bounds
            let copy = op["copy"] != .bool(false)
            // A copy mirrors across the far side (plus gap); a flip mirrors in place.
            let plane = copy ? b.max[k] + op.num("gap", 0) / 2 : (b.min[k] + b.max[k]) / 2
            let flipped: Mesh = mesh.map { p in
                let v: [Vec3] = p.v.map { q in
                    var r = q
                    r[k] = 2 * plane - q[k]
                    return r
                }.reversed()
                var n = p.n
                n[k] = -n[k]
                return Polygon(v: v, n: n, w: n.dot(v[0]), kind: p.kind)
            }
            return copy ? try CSG.union(mesh, flipped) : flipped

        case "array":
            if mesh.isEmpty { return mesh }
            let k = (op.axis() ?? .x).index
            let b = mesh.bounds
            let step = b.max[k] - b.min[k] + op.num("gap", 20)
            let count = Int(max(1, min(32, jsRound(op.num("count", 3)))))
            var out = mesh
            for i in stride(from: 1, to: count, by: 1) {
                var t = Vec3.zero
                t[k] = step * Double(i)
                out = try CSG.union(out, mesh.translated(by: t))
            }
            return out

        case "radial":
            if mesh.isEmpty { return mesh }
            let b = mesh.bounds
            let count = Int(max(1, min(48, jsRound(op.num("count", 6)))))
            let total = op.num("angle", 360)
            // Copies turn around a vertical axis `radius` behind the part's centre.
            let px = (b.min.x + b.max.x) / 2 - op.num("radius", 80), py = (b.min.y + b.max.y) / 2
            let stepA = ((abs(total) >= 360 ? total / Double(count) : total / Double(max(1, count - 1))) * Double.pi) / 180
            var out = mesh
            for i in stride(from: 1, to: count, by: 1) {
                let a = stepA * Double(i), ca = cos(a), sa = sin(a)
                let rotated: Mesh = mesh.map { p in
                    let v = p.v.map { q in
                        Vec3(px + (q.x - px) * ca - (q.y - py) * sa, py + (q.x - px) * sa + (q.y - py) * ca, q.z)
                    }
                    let n = Vec3(p.n.x * ca - p.n.y * sa, p.n.x * sa + p.n.y * ca, p.n.z)
                    return Polygon(v: v, n: n, w: n.dot(v[0]), kind: p.kind)
                }
                out = try CSG.union(out, rotated)
            }
            return out

        case "facepush":
            return try facePush(op, mesh)

        case "loopcut":
            return loopCut(op, mesh, &ctx)

        case "segpush":
            return try segmentPush(op, mesh, ctx)

        default:
            return mesh
        }
    }

    static func rescale(_ mesh: Mesh, s: Vec3, c: Vec3) -> Mesh {
        mesh.map { p in
            let v = p.v.map { q in Vec3(c.x + (q.x - c.x) * s.x, c.y + (q.y - c.y) * s.y, c.z + (q.z - c.z) * s.z) }
            let n = Vec3(p.n.x / s.x, p.n.y / s.y, p.n.z / s.z).normalized
            return Polygon(v: v, n: n, w: n.dot(v[0]), kind: p.kind)
        }
    }

    /// Splits every face at evenly spaced planes across the axis, then
    /// optionally scales each ring (ends included) to taper the solid.
    static func loopCut(_ op: Op, _ mesh: Mesh, _ ctx: inout LoopContext) -> Mesh {
        if mesh.isEmpty { return mesh }
        let k = (op.axis() ?? .z).index
        let b = mesh.bounds
        let lo = b.min[k], hi = b.max[k]
        let n = Int(max(1, min(24, jsRound(op.num("count", 1)))))
        let spacing = (hi - lo) / Double(n + 1)
        let off = (max(-100, min(100, op.num("slide", 0))) / 100) * spacing * 0.95
        var loops: [Double] = []
        for i in 1...n { loops.append(lo + Double(i) * spacing + off) }
        let knots = [lo] + loops + [hi]

        var polys = mesh
        var nrm = Vec3.zero
        nrm[k] = 1
        for t in loops { polys = splitAll(polys, n: nrm, w: t) }

        let scaleList = op["scales"]?.array
        let scales: [Double] = knots.indices.map { j in
            let raw = (scaleList.flatMap { j < $0.count ? $0[j] : nil })?.jsNumber ?? 100
            return max(0.01, raw / 100)
        }
        if scales.contains(where: { abs($0 - 1) > 1e-9 }) {
            let c = b.center
            func scaleAt(_ t: Double) -> Double {
                if t <= knots[0] { return scales[0] }
                for j in 0..<(knots.count - 1) where t <= knots[j + 1] + 1e-9 {
                    let span = knots[j + 1] - knots[j]
                    let u = span > 1e-9 ? (t - knots[j]) / span : 0
                    return scales[j] + (scales[j + 1] - scales[j]) * u
                }
                return scales[scales.count - 1]
            }
            polys = polys.compactMap { p in
                let warped = p.v.map { v -> Vec3 in
                    let sc = scaleAt(v[k])
                    var out = v
                    for i in 0..<3 where i != k { out[i] = c[i] + (v[i] - c[i]) * sc }
                    return out
                }
                return Polygon.make(warped, kind: p.kind)
            }
        }

        ctx.loops.append(.init(k: k, ts: loops))
        if let id = op["id"], id.isTruthy {
            ctx.loopSets[id.string ?? jsNumberString(id.jsNumber ?? 0)] = .init(k: k, knots: knots)
        }
        return polys
    }

    /// Extrudes (or pushes in) the faces of one loop segment that point at `face`.
    static func segmentPush(_ op: Op, _ mesh: Mesh, _ ctx: LoopContext) throws -> Mesh {
        guard let loopId = op.string("loopId"), let set = ctx.loopSets[loopId],
            let face = op.string("face").flatMap(IsoPlane.init(rawValue:))
        else { return mesh }
        let dir = face.direction
        let depth = op.num("depth", 0)
        if depth == 0 { return mesh }
        let seg = Int(max(0, min(Double(set.knots.count - 2), jsRound(op.num("segment", 0)))))
        let lo = set.knots[seg], hi = set.knots[seg + 1]
        let along = abs(dir[set.k]) < 0.5
        var tool: Mesh = []
        for p in mesh {
            if p.n.dot(dir) < 0.7 || p.kind == .cut { continue }
            if along {
                var sum = 0.0
                for v in p.v { sum += v[set.k] }
                let c = sum / Double(p.v.count)
                if c < lo - 1e-6 || c > hi + 1e-6 { continue }
            }
            tool = try CSG.union(tool, pushPiece(p, depth: depth))
        }
        if tool.isEmpty { return mesh }
        return depth > 0 ? try CSG.union(mesh, tool) : try CSG.subtract(mesh, tool)
    }

    /// Extrudes (or pushes in) one picked face: every piece of the mesh on
    /// that plane, inside the same loop-cut strip.
    static func facePush(_ op: Op, _ mesh: Mesh) throws -> Mesh {
        guard let na = op["n"]?.array, na.count >= 3 else { return mesh }
        let n = Vec3(na[0].jsNumber ?? 0, na[1].jsNumber ?? 0, na[2].jsNumber ?? 0)
        let depth = op.num("depth", 0)
        if depth == 0 { return mesh }
        let w = op.num("w", 0)
        let bounds: [(Int, Double?, Double?)] = (op["bounds"]?.array ?? []).compactMap { e in
            guard let a = e.array, a.count >= 3, let k = a[0].jsNumber else { return nil }
            return (Int(k), a[1].number, a[2].number)
        }
        var tool: Mesh = []
        for p in mesh {
            if p.kind == .cut || p.n.dot(n) < 1 - 1e-4 || abs(p.w - w) > 0.05 { continue }
            let c = p.centroid
            let inside = bounds.allSatisfy { k, lo, hi in
                guard k >= 0 && k < 3 else { return true }
                return (lo == nil || c[k] >= lo! - 1e-3) && (hi == nil || c[k] <= hi! + 1e-3)
            }
            if !inside { continue }
            tool = try CSG.union(tool, pushPiece(p, depth: depth))
        }
        if tool.isEmpty { return mesh }
        return depth > 0 ? try CSG.union(mesh, tool) : try CSG.subtract(mesh, tool)
    }

    static func pushPiece(_ p: Polygon, depth: Double) -> Mesh {
        depth > 0
            ? Solid.prism3(p.v.map { $0 - p.n.scaled(0.01) }, p.n.scaled(depth + 0.01), kind: .solid)
            : Solid.prism3(p.v.map { $0 + p.n.scaled(0.5) }, p.n.scaled(depth - 0.5), kind: .solid)
    }
}
