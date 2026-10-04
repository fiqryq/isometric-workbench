import Foundation

/// sRGB colour with components in 0…1.
public struct RGB: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Parses `#rgb` / `#rrggbb` (the plugin's `hexToRgb`).
    public init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let n = UInt32(h, radix: 16) ?? 0
        r = Double((n >> 16) & 255) / 255
        g = Double((n >> 8) & 255) / 255
        b = Double(n & 255) / 255
    }

    public var hex: String {
        func h(_ x: Double) -> String {
            let v = Int(jsRound(max(0, min(1, x)) * 255))
            return String(format: "%02x", v)
        }
        return "#" + h(r) + h(g) + h(b)
    }

    public func mix(_ o: RGB, _ t: Double) -> RGB {
        RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }

    public static let white = RGB(r: 1, g: 1, b: 1)
    public static let black = RGB(r: 0, g: 0, b: 0)
}
