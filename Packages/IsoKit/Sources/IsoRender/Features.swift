import Foundation

public enum FeatureEdges {
    /// Marks the polygon edges that should be drawn: creases sharper than
    /// `smoothDeg`, silhouettes, boundaries between face kinds, and loop-cut
    /// rings. Also reports which polygons belong to curved surfaces.
    public static func classify(
        _ polys: Mesh, toViewer: Vec3, smoothDeg: Double, loops: [LoopContext.Rings], neighbours nbrs: [[[Int]]]
    ) -> (flags: [[Bool]], curved: [Bool]) {
        var rings: [(Int, Double)] = []
        for l in loops { for t in l.ts { rings.append((l.k, t)) } }
        let smoothCos = cos(smoothDeg * Double.pi / 180)
        let front = polys.map { $0.n.dot(toViewer) > 1e-6 }
        let centroid = polys.map(\.centroid)
        var curved = [Bool](repeating: false, count: polys.count)
        var flags: [[Bool]] = []
        flags.reserveCapacity(polys.count)
        for (pi, p) in polys.enumerated() {
            var f: [Bool] = []
            f.reserveCapacity(p.v.count)
            for i in 0..<p.v.count {
                let a = p.v[i], b = p.v[(i + 1) % p.v.count]
                // Loop-cut rings are always drawn on faces they cross.
                var feature = rings.contains { k, t in
                    abs(a[k] - t) < 1e-3 && abs(b[k] - t) < 1e-3 && abs(p.n[k]) < 0.99
                }
                if !feature {
                    var smooth = false
                    for qi in nbrs[pi][i] {
                        let q = polys[qi]
                        if q.kind != p.kind || p.n.dot(q.n) <= smoothCos { continue }
                        // A back-facing neighbour is a silhouette only on
                        // convex curves; inside a hollow it's hidden anyway.
                        if front[qi] || p.n.dot(centroid[qi]) - p.w > 1e-3 {
                            if p.n.dot(q.n) < 1 - 1e-6 { curved[pi] = true }
                            smooth = true
                            break
                        }
                    }
                    feature = !smooth
                }
                f.append(feature)
            }
            flags.append(f)
        }
        return (flags, curved)
    }
}

/// Which model face a polygon belongs to (plane + loop-cut strip), so a face
/// can be picked in the viewport and extruded later.
public struct FaceID: Sendable, Hashable {
    public struct StripBound: Sendable, Hashable {
        public let k: Int
        public let lo: Double?
        public let hi: Double?
    }

    public let n: Vec3
    public let w: Double
    public let bounds: [StripBound]
    public let curved: Bool
    public let key: String

    init(_ p: Polygon, curved: Bool, loops: [LoopContext.Rings]) {
        let c = p.centroid
        var bounds: [StripBound] = []
        for l in loops {
            if abs(p.n[l.k]) > 0.99 { continue }  // face parallel to the rings
            let ts = l.ts.sorted()
            var i = 0
            while i < ts.count && ts[i] < c[l.k] { i += 1 }
            bounds.append(.init(k: l.k, lo: i > 0 ? round2(ts[i - 1]) : nil, hi: i < ts.count ? round2(ts[i]) : nil))
        }
        let n = Vec3(jsRound(p.n.x * 1e4) / 1e4, jsRound(p.n.y * 1e4) / 1e4, jsRound(p.n.z * 1e4) / 1e4)
        let w = round2(p.w)
        self.n = n
        self.w = w
        self.bounds = bounds
        self.curved = curved
        let nk = [n.x, n.y, n.z].map(jsNumberString).joined(separator: ",")
        let bk = bounds.map { b in
            [jsNumberString(Double(b.k)), b.lo.map(jsNumberString) ?? "", b.hi.map(jsNumberString) ?? ""].joined(separator: ":")
        }.joined(separator: "/")
        key = nk + "|" + jsNumberString(w) + "|" + bk
    }

    /// Human name of the face direction.
    public var name: String {
        let m = max(abs(n.x), abs(n.y), abs(n.z))
        if m < 0.95 { return "slanted" }
        if abs(n.z) == m { return n.z > 0 ? "top" : "bottom" }
        if abs(n.y) == m { return n.y > 0 ? "left" : "back right" }
        return n.x > 0 ? "right" : "back left"
    }

    /// The `bounds` field of a `facepush` op.
    public var boundsJSON: JSONValue {
        .array(bounds.map { b in
            .array([.number(Double(b.k)), b.lo.map(JSONValue.number) ?? .null, b.hi.map(JSONValue.number) ?? .null])
        })
    }
}

public enum Shading {
    /// How far a face is tinted towards the ink: top faces stay paper-white,
    /// the left face is barely tinted, the right face a little more.
    public static func amount(_ n: Vec3, kind: FaceKind) -> Double {
        let k = 0.14 * max(0, n.x) + 0.06 * max(0, n.y)
            + 0.22 * max(0, -n.x) + 0.18 * max(0, -n.y) + 0.3 * max(0, -n.z)
            + (kind == .cut ? 0.03 : 0)
        return jsRound(k * 50) / 50
    }
}
