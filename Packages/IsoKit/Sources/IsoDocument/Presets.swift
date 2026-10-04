import Foundation

public enum AnimationPreset: String, Sendable, CaseIterable, Identifiable {
    case explode, assemble, turntable, float, fadeIn, clear

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .explode: "Explode"
        case .assemble: "Assemble"
        case .turntable: "Turntable"
        case .float: "Float"
        case .fadeIn: "Fade In"
        case .clear: "Clear Animation"
        }
    }
}

extension SceneFile {
    /// Writes a preset's keyframes, matching the web Studio. `bounds` gives a
    /// part's mesh bounds in its own space.
    @discardableResult
    public mutating func apply(_ preset: AnimationPreset, selection: Set<Part.ID> = [], bounds: (Part) -> Bounds3) -> String {
        let total = duration
        func r3(_ v: Double) -> Double { jsRound(v * 1000) / 1000 }
        switch preset {
        case .clear:
            for i in parts.indices { parts[i].anim.keys = [:] }
            camera.keys = [:]
            return "Animation cleared."
        case .turntable:
            camera.keys["spin"] = [Keyframe(t: 0, v: 0, e: .linear), Keyframe(t: r3(total), v: 360, e: .linear)]
            return "Turntable keys added — press Play."
        case .float:
            let targets = parts.indices.filter { selection.isEmpty ? $0 == 0 : selection.contains(parts[$0].id) }
            for i in targets {
                let z = parts[i].anim.base("z")
                parts[i].anim.keys["z"] = [Keyframe(t: 0, v: z), Keyframe(t: r3(total / 2), v: z + 24), Keyframe(t: r3(total), v: z)]
            }
            return "Float keys added — press Play."
        case .fadeIn:
            let targets = parts.indices.filter { selection.isEmpty || selection.contains(parts[$0].id) }
            for (n, i) in targets.enumerated() {
                let t0 = r3(total * 0.1 * Double(n) / Double(max(1, targets.count)))
                parts[i].anim.keys["opacity"] = [Keyframe(t: t0, v: 0), Keyframe(t: r3(t0 + total * 0.3), v: parts[i].anim.base("opacity"))]
            }
            return "Fade-in keys added — press Play."
        case .explode, .assemble:
            guard parts.count >= 2 else { return "Add at least two parts to explode." }
            // The biggest footprint is the core; other parts collapse onto it
            // in Z, and into its footprint if they sit beside it.
            let info: [(Int, Vec3, Vec3)] = parts.indices.map { i in
                let b = bounds(parts[i]), base = parts[i].anim
                let o = Vec3(base.base("x"), base.base("y"), base.base("z"))
                return b.isEmpty ? (i, o, o) : (i, b.min + o, b.max + o)
            }
            func footprint(_ e: (Int, Vec3, Vec3)) -> Double { (e.2.x - e.1.x) * (e.2.y - e.1.y) }
            let core = info.dropFirst().reduce(info[0]) { footprint($1) > footprint($0) ? $1 : $0 }
            let cz = (core.1.z + core.2.z) / 2
            let t0 = r3(total * 0.12), t1 = r3(total * 0.72)
            for (i, mn, mx) in info {
                let c = (mn + mx) * 0.5
                var off = Vec3(0, 0, -(c.z - cz) * 0.9)
                for k in 0..<2 {
                    let cl = max(core.1[k], min(core.2[k], c[k]))
                    off[k] = -(c[k] - cl) * 0.92
                }
                let anim = parts[i].anim
                let to = Vec3(anim.base("x"), anim.base("y"), anim.base("z"))
                let from = to + off
                let (a, b) = preset == .explode ? (from, to) : (to, from)
                for (k, prop) in ["x", "y", "z"].enumerated() {
                    if abs(a[k] - b[k]) < 0.5 {
                        parts[i].anim.keys[prop] = nil
                        continue
                    }
                    parts[i].anim.keys[prop] = [Keyframe(t: t0, v: r3(a[k])), Keyframe(t: t1, v: r3(b[k]))]
                }
            }
            return preset == .explode ? "Explode keys added — press Play." : "Assemble keys added — press Play."
        }
    }
}
