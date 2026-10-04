import Foundation

/// Reads SVG files from other apps: every path command (relative too, plus
/// H/V/S/T/A) and the basic shapes, flattened to absolute M/L/Q/C/Z.
public enum SVGImport {
    /// All outlines in an SVG document as absolute segments. Element
    /// transforms of the `translate` / `scale` / `matrix` kind are applied.
    public static func segments(fromDocument data: Data) throws -> [PathSegment] {
        let parser = XMLParser(data: data)
        let delegate = Collector()
        parser.delegate = delegate
        guard parser.parse() else { throw SVGPathError.unsupported("This isn't a readable SVG file.") }
        return delegate.segments
    }

    /// Path data with relative commands, shorthands and arcs → absolute.
    public static func segments(fromPathData d: String) throws -> [PathSegment] {
        var tokens = tokenize(d)
        var out: [PathSegment] = []
        var i = 0
        var cur = Vec2.zero, start = Vec2.zero
        var lastCubic: Vec2? = nil, lastQuad: Vec2? = nil
        var cmd: Character = "M"
        func isCommand(_ t: String) -> Bool { t.count == 1 && t.first!.isLetter && t != "e" && t != "E" }
        func num() throws -> Double {
            guard i < tokens.count, let v = Double(tokens[i]) else { throw SVGPathError.unsupported("Bad path data") }
            i += 1
            return v
        }
        func flag() throws -> Bool {
            guard i < tokens.count else { throw SVGPathError.unsupported("Bad arc flag") }
            let t = tokens[i]
            guard let first = t.first, first == "0" || first == "1" else { throw SVGPathError.unsupported("Bad arc flag") }
            if t.count > 1 { tokens[i] = String(t.dropFirst()) } else { i += 1 }
            return first == "1"
        }
        while i < tokens.count {
            if isCommand(tokens[i]) {
                cmd = Character(tokens[i])
                i += 1
            } else if cmd == "Z" || cmd == "z" {
                throw SVGPathError.unsupported("Bad path data")
            }
            let rel = cmd.isLowercase
            func pt() throws -> Vec2 {
                let p = Vec2(try num(), try num())
                return rel ? cur + p : p
            }
            switch cmd.uppercased().first! {
            case "M":
                cur = try pt()
                start = cur
                out.append(.move(cur))
                cmd = rel ? "l" : "L"
                lastCubic = nil
                lastQuad = nil
            case "L":
                cur = try pt()
                out.append(.line(cur))
                lastCubic = nil
                lastQuad = nil
            case "H":
                let x = try num()
                cur = Vec2(rel ? cur.x + x : x, cur.y)
                out.append(.line(cur))
                lastCubic = nil
                lastQuad = nil
            case "V":
                let y = try num()
                cur = Vec2(cur.x, rel ? cur.y + y : y)
                out.append(.line(cur))
                lastCubic = nil
                lastQuad = nil
            case "C":
                let c1 = try pt(), c2 = try pt(), p = try pt()
                out.append(.cubic(c1, c2, p))
                lastCubic = c2
                lastQuad = nil
                cur = p
            case "S":
                let c1 = lastCubic.map { cur * 2 - $0 } ?? cur
                let c2 = try pt(), p = try pt()
                out.append(.cubic(c1, c2, p))
                lastCubic = c2
                lastQuad = nil
                cur = p
            case "Q":
                let c = try pt(), p = try pt()
                out.append(.quad(c, p))
                lastQuad = c
                lastCubic = nil
                cur = p
            case "T":
                let c = lastQuad.map { cur * 2 - $0 } ?? cur
                let p = try pt()
                out.append(.quad(c, p))
                lastQuad = c
                lastCubic = nil
                cur = p
            case "A":
                let rx = try num(), ry = try num(), rot = try num()
                let large = try flag(), sweep = try flag()
                let p = try pt()
                out.append(contentsOf: arc(from: cur, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep))
                cur = p
                lastCubic = nil
                lastQuad = nil
            case "Z":
                out.append(.close)
                cur = start
                lastCubic = nil
                lastQuad = nil
            default:
                throw SVGPathError.unsupported(String(cmd))
            }
        }
        return out
    }

    static func tokenize(_ d: String) -> [String] {
        // Arc flags may be packed without separators ("a1 1 0 01 1 1"), so
        // numbers stop at a second dot as well as at a sign or letter.
        var tokens: [String] = []
        var cur = ""
        var sawDot = false, sawExp = false
        func flush() {
            if !cur.isEmpty { tokens.append(cur) }
            cur = ""
            sawDot = false
            sawExp = false
        }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush()
                tokens.append(String(ch))
            } else if ch == "e" || ch == "E" {
                cur.append(ch)
                sawExp = true
            } else if ch == "-" || ch == "+" {
                if let last = cur.last, last == "e" || last == "E" { cur.append(ch) } else {
                    flush()
                    cur.append(ch)
                }
            } else if ch == "." {
                if sawDot || sawExp { flush() }
                cur.append(ch)
                sawDot = true
            } else if ch.isNumber {
                cur.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Endpoint arc → cubic Béziers (SVG implementation notes, F.6).
    static func arc(from p0: Vec2, to p1: Vec2, rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool) -> [PathSegment] {
        var rx = abs(rx), ry = abs(ry)
        if rx < 1e-9 || ry < 1e-9 || p0 == p1 { return [.line(p1)] }
        let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = (max(0, num) / den).squareRoot()
        if large == sweep { k = -k }
        let cxp = k * rx * y1 / ry, cyp = -k * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2
        let cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
        func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let t1 = ang(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dt = ang((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
        let n = max(1, Int((abs(dt) / (.pi / 2)).rounded(.up)))
        let step = dt / Double(n)
        let alpha = 4.0 / 3 * tan(step / 4)
        func point(_ t: Double) -> Vec2 {
            let x = rx * cos(t), y = ry * sin(t)
            return Vec2(cx + cp * x - sp * y, cy + sp * x + cp * y)
        }
        func deriv(_ t: Double) -> Vec2 {
            let x = -rx * sin(t), y = ry * cos(t)
            return Vec2(cp * x - sp * y, sp * x + cp * y)
        }
        var out: [PathSegment] = []
        var t = t1
        for j in 0..<n {
            let a = point(t), b = j == n - 1 ? p1 : point(t + step)
            out.append(.cubic(a + deriv(t) * alpha, b - deriv(t + step) * alpha, b))
            t += step
        }
        return out
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var segments: [PathSegment] = []
        private var stack: [CGAffine] = [.identity]

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            let m = stack.last!.concat(CGAffine(transform: a["transform"]))
            stack.append(m)
            if local == "defs" || local == "clipPath" || local == "mask" { stack[stack.count - 1].hidden = true }
            guard !m.hidden else { return }
            func n(_ k: String, _ fallback: Double = 0) -> Double { a[k].flatMap { Double($0.filter { "0123456789.-eE".contains($0) }) } ?? fallback }
            var segs: [PathSegment] = []
            switch local {
            case "path":
                segs = (try? SVGImport.segments(fromPathData: a["d"] ?? "")) ?? []
            case "rect":
                let x = n("x"), y = n("y"), w = n("width"), h = n("height")
                if w > 0, h > 0 { segs = [.move(Vec2(x, y)), .line(Vec2(x + w, y)), .line(Vec2(x + w, y + h)), .line(Vec2(x, y + h)), .close] }
            case "circle", "ellipse":
                let cx = n("cx"), cy = n("cy")
                let rx = local == "circle" ? n("r") : n("rx"), ry = local == "circle" ? n("r") : n("ry")
                if rx > 0, ry > 0 {
                    segs = [.move(Vec2(cx + rx, cy))]
                    segs += SVGImport.arc(from: Vec2(cx + rx, cy), to: Vec2(cx - rx, cy), rx: rx, ry: ry, rotation: 0, large: false, sweep: true)
                    segs += SVGImport.arc(from: Vec2(cx - rx, cy), to: Vec2(cx + rx, cy), rx: rx, ry: ry, rotation: 0, large: false, sweep: true)
                    segs.append(.close)
                }
            case "polygon", "polyline":
                let v = SVGImport.tokenize(a["points"] ?? "").compactMap(Double.init)
                let pts = stride(from: 0, to: v.count - 1, by: 2).map { Vec2(v[$0], v[$0 + 1]) }
                if pts.count >= 3 { segs = [.move(pts[0])] + pts.dropFirst().map { .line($0) } + [.close] }
            default:
                break
            }
            segments += segs.map { m.apply($0) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if stack.count > 1 { stack.removeLast() }
        }
    }

    /// 2D affine transform (a b c d e f), as in SVG.
    struct CGAffine {
        var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0
        var hidden = false

        static let identity = CGAffine()

        init() {}

        init(transform: String?) {
            guard let transform else { return }
            var m = CGAffine()
            let pattern = try! NSRegularExpression(pattern: "(matrix|translate|scale|rotate)\\s*\\(([^)]*)\\)")
            let ns = transform as NSString
            for r in pattern.matches(in: transform, range: NSRange(location: 0, length: ns.length)) {
                let kind = ns.substring(with: r.range(at: 1))
                let v = SVGImport.tokenize(ns.substring(with: r.range(at: 2))).compactMap(Double.init)
                var t = CGAffine()
                switch kind {
                case "matrix" where v.count >= 6: (t.a, t.b, t.c, t.d, t.e, t.f) = (v[0], v[1], v[2], v[3], v[4], v[5])
                case "translate": (t.e, t.f) = (v.first ?? 0, v.count > 1 ? v[1] : 0)
                case "scale": (t.a, t.d) = (v.first ?? 1, v.count > 1 ? v[1] : v.first ?? 1)
                case "rotate":
                    let r = (v.first ?? 0) * .pi / 180
                    (t.a, t.b, t.c, t.d) = (cos(r), sin(r), -sin(r), cos(r))
                    if v.count >= 3 {
                        t = CGAffine.translation(v[1], v[2]).concat(t).concat(.translation(-v[1], -v[2]))
                    }
                default: break
                }
                m = m.concat(t)
            }
            self = m
        }

        static func translation(_ x: Double, _ y: Double) -> CGAffine {
            var t = CGAffine()
            t.e = x
            t.f = y
            return t
        }

        /// self · o (o applied first).
        func concat(_ o: CGAffine) -> CGAffine {
            var r = CGAffine()
            r.a = a * o.a + c * o.b
            r.b = b * o.a + d * o.b
            r.c = a * o.c + c * o.d
            r.d = b * o.c + d * o.d
            r.e = a * o.e + c * o.f + e
            r.f = b * o.e + d * o.f + f
            r.hidden = hidden || o.hidden
            return r
        }

        func apply(_ p: Vec2) -> Vec2 { Vec2(a * p.x + c * p.y + e, b * p.x + d * p.y + f) }

        func apply(_ s: PathSegment) -> PathSegment {
            switch s {
            case .move(let p): .move(apply(p))
            case .line(let p): .line(apply(p))
            case .quad(let c1, let p): .quad(apply(c1), apply(p))
            case .cubic(let c1, let c2, let p): .cubic(apply(c1), apply(c2), apply(p))
            case .close: .close
            }
        }
    }
}
