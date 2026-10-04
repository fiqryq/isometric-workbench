import Foundation

/// JavaScript's `Math.round`: halves round towards +∞ (`-2.5 → -2`).
@inlinable public func jsRound(_ x: Double) -> Double {
    guard x.isFinite else { return x }
    let r = x.rounded(.down)
    return x - r >= 0.5 ? r + 1 : r
}

/// Two-decimal rounding used whenever the plugin stores a value in an op.
@inlinable public func round2(_ n: Double) -> Double { jsRound(n * 100) / 100 }

@inlinable public func round1(_ n: Double) -> Double { jsRound(n * 10) / 10 }

@inlinable public func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    Swift.max(lo, Swift.min(hi, v))
}

/// `String(n)` in JavaScript for the numbers the engine prints (labels, keys).
public func jsNumberString(_ n: Double) -> String {
    if n.isNaN { return "NaN" }
    if n.isInfinite { return n > 0 ? "Infinity" : "-Infinity" }
    if n == 0 { return "0" }
    if n == n.rounded(), abs(n) < 1e21 { return String(Int64(n)) }
    var s = String(n)
    if s.hasSuffix(".0") { s.removeLast(2) }
    return s
}
