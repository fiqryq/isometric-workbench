import Foundation

public enum GeometryError: Error, Sendable, Equatable, LocalizedError {
    case tooComplex
    case empty

    public var errorDescription: String? {
        switch self {
        case .tooComplex: "This shape is too complex to draw — try fewer segments or loop cuts."
        case .empty: "The result is empty — nothing left to draw."
        }
    }
}

/// BSP tree. Every walk is iterative so deep trees can't overflow the stack.
/// Built and consumed inside one call, so it's never shared across threads.
public final class BSPNode {
    public internal(set) var n: Vec3?
    public internal(set) var w: Double = 0
    public internal(set) var front: BSPNode?
    public internal(set) var back: BSPNode?
    public internal(set) var polys: [Polygon] = []

    static let workCap = 2_000_000

    public init() {}

    public convenience init(_ polys: [Polygon]) throws {
        self.init()
        try build(polys)
    }

    /// Nodes in the JS engine's walk order (depth first, back subtree first).
    func nodes() -> [BSPNode] {
        var out: [BSPNode] = []
        var stack: [BSPNode] = [self]
        while let node = stack.popLast() {
            out.append(node)
            if let f = node.front { stack.append(f) }
            if let b = node.back { stack.append(b) }
        }
        return out
    }

    func build(_ polys: [Polygon]) throws {
        var stack: [(BSPNode, [Polygon])] = [(self, polys)]
        var work = 0
        while let (node, ps) = stack.popLast() {
            if ps.isEmpty { continue }
            work += ps.count
            if work > Self.workCap { throw GeometryError.tooComplex }
            var start = 0
            if node.n == nil {
                // The polygon that defines the plane always lives on it, even
                // if rounding would classify it otherwise — this guarantees
                // progress.
                node.n = ps[0].n
                node.w = ps[0].w
                node.polys.append(ps[0])
                start = 1
            }
            let n = node.n!, w = node.w
            var f: [Polygon] = [], b: [Polygon] = []
            var i = start
            while i < ps.count {
                splitPolygon(n, w, ps[i]) { bucket, p in
                    switch bucket {
                    case .coFront, .coBack: node.polys.append(p)
                    case .front: f.append(p)
                    case .back: b.append(p)
                    }
                }
                i += 1
            }
            if !f.isEmpty {
                let fr = node.front ?? BSPNode()
                node.front = fr
                stack.append((fr, f))
            }
            if !b.isEmpty {
                let bk = node.back ?? BSPNode()
                node.back = bk
                stack.append((bk, b))
            }
        }
    }

    func invert() {
        for node in nodes() {
            node.polys = node.polys.map { $0.flipped() }
            if let n = node.n {
                node.n = n.scaled(-1)
                node.w = -node.w
            }
            swap(&node.front, &node.back)
        }
    }

    /// Removes the parts of `polys` that are inside this solid.
    func clipPolygons(_ polys: [Polygon]) -> [Polygon] {
        var out: [Polygon] = []
        var stack: [(BSPNode, [Polygon])] = [(self, polys)]
        while let (node, ps) = stack.popLast() {
            guard let n = node.n else {
                out.append(contentsOf: ps)
                continue
            }
            let w = node.w
            var f: [Polygon] = [], b: [Polygon] = []
            for p in ps {
                splitPolygon(n, w, p) { bucket, q in
                    switch bucket {
                    case .coFront, .front: f.append(q)
                    case .coBack, .back: b.append(q)
                    }
                }
            }
            if !f.isEmpty {
                if let fr = node.front { stack.append((fr, f)) } else { out.append(contentsOf: f) }
            }
            if !b.isEmpty, let bk = node.back { stack.append((bk, b)) }
        }
        return out
    }

    func clip(to other: BSPNode) {
        for node in nodes() { node.polys = other.clipPolygons(node.polys) }
    }

    public func allPolygons() -> [Polygon] {
        var out: [Polygon] = []
        for node in nodes() { out.append(contentsOf: node.polys) }
        return out
    }
}

public enum CSG {
    /// Solids whose bounding boxes don't touch can't interact.
    static func disjoint(_ a: Mesh, _ b: Mesh) -> Bool {
        let ba = a.bounds, bb = b.bounds, e = 1e-3
        for k in 0..<3 where ba.max[k] < bb.min[k] - e || bb.max[k] < ba.min[k] - e {
            return true
        }
        return false
    }

    public static func union(_ a: Mesh, _ b: Mesh) throws -> Mesh {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if disjoint(a, b) { return a + b }
        let A = try BSPNode(a), B = try BSPNode(b)
        A.clip(to: B)
        B.clip(to: A)
        B.invert()
        B.clip(to: A)
        B.invert()
        try A.build(B.allPolygons())
        return A.allPolygons()
    }

    public static func subtract(_ a: Mesh, _ b: Mesh) throws -> Mesh {
        if a.isEmpty || b.isEmpty { return a }
        if disjoint(a, b) { return a }
        let A = try BSPNode(a), B = try BSPNode(b)
        A.invert()
        A.clip(to: B)
        B.clip(to: A)
        B.invert()
        B.clip(to: A)
        B.invert()
        try A.build(B.allPolygons())
        A.invert()
        return A.allPolygons()
    }
}
