import Foundation

/// SVG path data reduced to M / L / Q / C / Z segments in absolute
/// coordinates, as the plugin parses it.
public enum PathSegment: Sendable, Hashable {
    case move(Vec2)
    case line(Vec2)
    case quad(Vec2, Vec2)
    case cubic(Vec2, Vec2, Vec2)
    case close

    var points: [Vec2] {
        switch self {
        case .move(let p), .line(let p): [p]
        case .quad(let a, let b): [a, b]
        case .cubic(let a, let b, let c): [a, b, c]
        case .close: []
        }
    }
}

public enum SVGPathError: Error, Equatable, LocalizedError {
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let c): "Unsupported path command \(c)"
        }
    }
}

public enum SVGPath {
    // Same token pattern as the plugin: commands are upper-cased, so relative
    // commands are read as absolute — matching the plugin's input (Figma
    // always hands over absolute paths).
    private static let tokenRegex = try! NSRegularExpression(
        pattern: "[a-zA-Z]|-?(?:\\d+\\.?\\d*|\\.\\d+)(?:e[-+]?\\d+)?")

    public static func parse(_ data: String) throws -> [PathSegment] {
        let ns = data as NSString
        let tokens = tokenRegex.matches(in: data, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
        var segs: [PathSegment] = []
        var i = 0
        var c = Vec2.zero, s = Vec2.zero
        func num() -> Double {
            defer { i += 1 }
            return i < tokens.count ? Double(tokens[i]) ?? .nan : .nan
        }
        while i < tokens.count {
            let cmd = tokens[i].uppercased()
            i += 1
            switch cmd {
            case "M", "L":
                c = Vec2(num(), num())
                if cmd == "M" {
                    s = c
                    segs.append(.move(c))
                } else {
                    segs.append(.line(c))
                }
            case "H":
                c.x = num()
                segs.append(.line(c))
            case "V":
                c.y = num()
                segs.append(.line(c))
            case "Q":
                let p1 = Vec2(num(), num())
                c = Vec2(num(), num())
                segs.append(.quad(p1, c))
            case "C":
                let p1 = Vec2(num(), num()), p2 = Vec2(num(), num())
                c = Vec2(num(), num())
                segs.append(.cubic(p1, p2, c))
            case "Z":
                c = s
                segs.append(.close)
            default:
                throw SVGPathError.unsupported(cmd)
            }
        }
        return segs
    }

    /// Closed outlines with curves sampled into polylines exactly as the
    /// plugin does (`sampleSegs`).
    public static func loops(_ segs: [PathSegment]) -> [Loop] {
        var loops: [Loop] = []
        var cur: Loop? = nil
        var last = Vec2.zero, start = Vec2.zero
        func push(_ p: Vec2) {
            cur?.append(p)
            last = p
        }
        for seg in segs {
            if case .move = seg {} else if case .close = seg {} else if let c = cur, c.isEmpty {
                push(start)  // subpath restarts after Z
            }
            switch seg {
            case .move(let p):
                if let c = cur, !c.isEmpty { loops.append(c) }
                cur = []
                push(p)
                start = last
            case .line(let p):
                push(p)
            case .quad, .cubic:
                let pts = [last] + seg.points
                var length = 0.0
                for k in 1..<pts.count { length += hypot(pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y) }
                let n = Int(max(2, min(24, (length / 6).rounded(.up))))
                for k in 1...n {
                    let t = Double(k) / Double(n), u = 1 - t
                    if pts.count == 3 {
                        push(Vec2(
                            u * u * pts[0].x + 2 * u * t * pts[1].x + t * t * pts[2].x,
                            u * u * pts[0].y + 2 * u * t * pts[1].y + t * t * pts[2].y))
                    } else {
                        push(Vec2(
                            u * u * u * pts[0].x + 3 * u * u * t * pts[1].x + 3 * u * t * t * pts[2].x + t * t * t * pts[3].x,
                            u * u * u * pts[0].y + 3 * u * u * t * pts[1].y + 3 * u * t * t * pts[2].y + t * t * t * pts[3].y))
                    }
                }
            case .close:
                if let c = cur, !c.isEmpty { loops.append(c) }
                cur = []
                last = start
            }
        }
        if let c = cur, !c.isEmpty { loops.append(c) }
        return loops.map(Loop2D.clean).filter { $0.count >= 3 }
    }

    public static func loops(fromPathData data: String) throws -> [Loop] {
        loops(try parse(data))
    }

    /// Serialises segments back to path data (3 decimals).
    public static func data(_ segs: [PathSegment]) -> String {
        func r(_ n: Double) -> String { jsNumberString(jsRound(n * 1000) / 1000) }
        return segs.map { seg -> String in
            switch seg {
            case .move(let p): "M \(r(p.x)) \(r(p.y))"
            case .line(let p): "L \(r(p.x)) \(r(p.y))"
            case .quad(let a, let b): "Q \(r(a.x)) \(r(a.y)) \(r(b.x)) \(r(b.y))"
            case .cubic(let a, let b, let c): "C \(r(a.x)) \(r(a.y)) \(r(b.x)) \(r(b.y)) \(r(c.x)) \(r(c.y))"
            case .close: "Z"
            }
        }.joined(separator: " ")
    }
}
