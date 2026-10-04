import Foundation

/// Width / depth / height dimension lines drafted along a part's iso edges —
/// the plugin's `cmdDimension`, kept live so they follow the part.
public struct DimensionLine: Sendable, Hashable, Identifiable {
    public enum Units: String, Sendable, Hashable, CaseIterable {
        case px, mm, cm, `in`
    }

    public var id: String
    public var part: Part.ID
    public var width: Bool
    public var depth: Bool
    public var height: Bool
    public var units: Units
    public var scale: Double
    public var decimals: Int
    public var offset: Double
    public var color: String?

    public init(
        id: String = makeID(), part: Part.ID, width: Bool = true, depth: Bool = true, height: Bool = true,
        units: Units = .px, scale: Double = 1, decimals: Int = 0, offset: Double = 28, color: String? = nil
    ) {
        self.id = id
        self.part = part
        self.width = width
        self.depth = depth
        self.height = height
        self.units = units
        self.scale = scale
        self.decimals = decimals
        self.offset = offset
        self.color = color
    }

    /// The plugin's label format: `(len * scale).toFixed(dec)` plus the unit
    /// unless it's plain pixels.
    public func format(_ length: Double) -> String {
        let s = String(format: "%.\(max(0, min(3, decimals)))f", length * scale)
        return units == .px && scale == 1 ? s : s + " " + units.rawValue
    }

    init(json: JSONValue) {
        id = json["id"]?.string ?? makeID()
        part = json["part"]?.string ?? ""
        width = json["w"]?.isTruthy ?? true
        depth = json["d"]?.isTruthy ?? true
        height = json["h"]?.isTruthy ?? true
        units = json["units"]?.string.flatMap(Units.init(rawValue:)) ?? .px
        scale = json["scale"]?.jsNumber ?? 1
        decimals = Int(json["decimals"]?.jsNumber ?? 0)
        offset = json["offset"]?.jsNumber ?? 28
        color = json["color"]?.string
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "part": .string(part), "w": .bool(width), "d": .bool(depth), "h": .bool(height),
            "units": .string(units.rawValue), "scale": .number(scale), "decimals": .number(Double(decimals)),
            "offset": .number(offset),
        ]
        if let color { o["color"] = .string(color) }
        return .object(o)
    }
}

/// A flat 2D shape on an iso plane: a kept sketch, with optional hatching.
/// Coordinates are in the host part's model space, or world space.
public struct FlatShape: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var axis: Axis
    public var at: Double
    /// Outlines in the plane's 2D coordinates (`planeTo2`).
    public var loops: [Loop]
    public var host: Part.ID?
    public var fill: String?
    public var stroke: String?
    public var hatch: Bool
    public var opacity: Double

    public init(
        id: String = makeID(), name: String = "Shape", axis: Axis, at: Double, loops: [Loop], host: Part.ID? = nil,
        fill: String? = nil, stroke: String? = nil, hatch: Bool = false, opacity: Double = 1
    ) {
        self.id = id
        self.name = name
        self.axis = axis
        self.at = at
        self.loops = loops
        self.host = host
        self.fill = fill
        self.stroke = stroke
        self.hatch = hatch
        self.opacity = opacity
    }

    init(json: JSONValue) {
        let op = Op(json.object ?? [:])
        id = json["id"]?.string ?? makeID()
        name = json["name"]?.string ?? "Shape"
        axis = json["axis"]?.string.flatMap(Axis.init(rawValue:)) ?? .z
        at = json["at"]?.jsNumber ?? 0
        loops = op.loops()
        host = json["host"]?.string
        fill = json["fill"]?.string
        stroke = json["stroke"]?.string
        hatch = json["hatch"]?.isTruthy ?? false
        opacity = json["opacity"]?.jsNumber ?? 1
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "axis": .string(axis.rawValue), "at": .number(at),
            "loops": JSONValue(loops: loops), "hatch": .bool(hatch), "opacity": .number(opacity),
        ]
        if let host { o["host"] = .string(host) }
        if let fill { o["fill"] = .string(fill) }
        if let stroke { o["stroke"] = .string(stroke) }
        return .object(o)
    }
}

/// Flat art mapped onto an iso plane: text, an SVG path or a bitmap.
public struct Decal: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case text, svg, image
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Text for `.text`, path data (`d`) for `.svg`.
    public var content: String
    /// PNG data for `.image`.
    public var image: Data?
    /// Plane the decal lies on: `.z` top, `.y` left, `.x` right.
    public var axis: Axis
    public var at: Double
    /// Centre of the decal in the plane's 2D coordinates (`planeTo2`).
    public var center: Vec2
    /// Font size for text, width for SVG and images (model units).
    public var size: Double
    public var host: Part.ID?
    public var color: String?
    public var opacity: Double

    public init(
        id: String = makeID(), name: String, kind: Kind, content: String = "", image: Data? = nil, axis: Axis = .z,
        at: Double = 0, center: Vec2 = .zero, size: Double = 24, host: Part.ID? = nil, color: String? = nil,
        opacity: Double = 1
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.content = content
        self.image = image
        self.axis = axis
        self.at = at
        self.center = center
        self.size = size
        self.host = host
        self.color = color
        self.opacity = opacity
    }

    init(json: JSONValue) {
        id = json["id"]?.string ?? makeID()
        name = json["name"]?.string ?? "Decal"
        kind = json["kind"]?.string.flatMap(Kind.init(rawValue:)) ?? .text
        content = json["content"]?.string ?? ""
        image = json["image"]?.string.flatMap { Data(base64Encoded: $0) }
        axis = json["axis"]?.string.flatMap(Axis.init(rawValue:)) ?? .z
        at = json["at"]?.jsNumber ?? 0
        let c = (json["center"]?.array ?? []).map { $0.jsNumber ?? 0 }
        center = c.count >= 2 ? Vec2(c[0], c[1]) : .zero
        size = json["size"]?.jsNumber ?? 24
        host = json["host"]?.string
        color = json["color"]?.string
        opacity = json["opacity"]?.jsNumber ?? 1
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "kind": .string(kind.rawValue), "content": .string(content),
            "axis": .string(axis.rawValue), "at": .number(at), "center": [.number(center.x), .number(center.y)],
            "size": .number(size), "opacity": .number(opacity),
        ]
        if let image { o["image"] = .string(image.base64EncodedString()) }
        if let host { o["host"] = .string(host) }
        if let color { o["color"] = .string(color) }
        return .object(o)
    }
}
