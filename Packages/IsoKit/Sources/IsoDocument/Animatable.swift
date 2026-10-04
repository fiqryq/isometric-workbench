@_exported import IsoGeometry
import Foundation

public enum Easing: String, Sendable, Hashable, CaseIterable, Codable {
    case smooth, linear, `in`, out, back, hold

    public func callAsFunction(_ u: Double) -> Double {
        switch self {
        case .smooth: return u * u * (3 - 2 * u)
        case .linear: return u
        case .in: return u * u * u
        case .out: return 1 - pow(1 - u, 3)
        case .back:
            let c = 1.70158, d = u - 1
            return 1 + (c + 1) * d * d * d + c * d * d
        case .hold: return 0
        }
    }
}

public struct Keyframe: Sendable, Hashable {
    public var t: Double
    public var v: Double
    /// Easing from this key to the next one.
    public var e: Easing

    public init(t: Double, v: Double, e: Easing = .smooth) {
        self.t = t
        self.v = v
        self.e = e
    }

    init(json: JSONValue) {
        t = json["t"]?.jsNumber ?? 0
        v = json["v"]?.jsNumber ?? 0
        e = json["e"]?.string.flatMap(Easing.init(rawValue:)) ?? .smooth
    }

    var json: JSONValue { ["t": .number(t), "v": .number(v), "e": .string(e.rawValue)] }
}

/// Base values per property plus optional keyframe tracks — the web Studio's
/// `{ base, keys }` shape.
public struct Animatable: Sendable, Hashable {
    public var base: [String: Double]
    public var keys: [String: [Keyframe]]

    public init(base: [String: Double] = [:], keys: [String: [Keyframe]] = [:]) {
        self.base = base
        self.keys = keys
    }

    public static func defaultValue(_ prop: String) -> Double { prop == "opacity" ? 100 : 0 }

    public func base(_ prop: String) -> Double { base[prop] ?? Self.defaultValue(prop) }

    public func isAnimated(_ prop: String) -> Bool { !(keys[prop]?.isEmpty ?? true) }

    public var isAnimated: Bool { keys.values.contains { !$0.isEmpty } }

    /// The value at time `t`. Before the first key it holds at the first key,
    /// after the last it holds at the last (no extrapolation).
    public func value(_ prop: String, at t: Double) -> Double {
        guard let ks = keys[prop], let first = ks.first, let last = ks.last else { return base(prop) }
        if t <= first.t { return first.v }
        if t >= last.t { return last.v }
        for i in 0..<(ks.count - 1) {
            let a = ks[i], b = ks[i + 1]
            if t >= a.t && t < b.t {
                let u = (t - a.t) / (b.t - a.t)
                return a.v + (b.v - a.v) * a.e(u)
            }
        }
        return last.v
    }

    public mutating func setKey(_ prop: String, t: Double, v: Double, e: Easing? = nil) {
        var list = keys[prop] ?? []
        if let i = list.firstIndex(where: { abs($0.t - t) < 1e-3 }) {
            list[i].v = v
            if let e { list[i].e = e }
        } else {
            list.append(Keyframe(t: jsRound(t * 1000) / 1000, v: v, e: e ?? .smooth))
            list.sort { $0.t < $1.t }
        }
        keys[prop] = list
    }

    public mutating func removeKey(_ prop: String, t: Double) {
        guard var list = keys[prop] else { return }
        list.removeAll { abs($0.t - t) < 1e-3 }
        keys[prop] = list.isEmpty ? nil : list
    }

    /// Writes a value the way the web Studio does: as a key at `t` when the
    /// property is animated (or auto-key is on), otherwise as the base value.
    public mutating func set(_ prop: String, _ v: Double, at t: Double, autoKey: Bool = false) {
        if isAnimated(prop) || autoKey { setKey(prop, t: t, v: v) } else { base[prop] = v }
    }

    public var keyTimes: [Double] {
        Set(keys.values.flatMap { $0.map { jsRound($0.t * 1000) / 1000 } }).sorted()
    }

    init(json: JSONValue?) {
        base = (json?["base"]?.object ?? [:]).compactMapValues(\.jsNumber)
        keys = (json?["keys"]?.object ?? [:]).compactMapValues { v in
            v.array.map { $0.map(Keyframe.init(json:)).sorted { $0.t < $1.t } }
        }
    }

    var baseJSON: JSONValue { .object(base.mapValues(JSONValue.number)) }
    var keysJSON: JSONValue { .object(keys.mapValues { .array($0.map(\.json)) }) }
}
