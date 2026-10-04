import Foundation

/// Short random id, like the web Studio's `uid()`.
public func makeID() -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<7).map { _ in chars.randomElement()! })
}

public struct Palette: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let ink: String
    public let fill: String

    public static let blueprint = Palette(id: "blueprint", name: "Blueprint", ink: "#2d55e8", fill: "#ffffff")
    public static let ink = Palette(id: "ink", name: "Ink", ink: "#1a1a1a", fill: "#ffffff")
    public static let redline = Palette(id: "redline", name: "Redline", ink: "#e04a2f", fill: "#fff8f2")
    public static let cyanotype = Palette(id: "cyanotype", name: "Cyanotype", ink: "#ffffff", fill: "#173bb8")
    public static let all: [Palette] = [.blueprint, .ink, .redline, .cyanotype]
}

/// Document-wide drawing style.
public struct Style: Sendable, Hashable {
    public var ink = "#2d55e8"
    public var fill = "#ffffff"
    public var weight = 1.25
    public var gap = 6.0
    public var bg = "#fbfbfa"
    public var preset: String? = "blueprint"
    public var extra: [String: JSONValue] = [:]

    public init() {}

    init(json: JSONValue?) {
        let o = json?.object ?? [:]
        ink = o["ink"]?.string ?? ink
        fill = o["fill"]?.string ?? fill
        weight = o["weight"]?.jsNumber ?? 1.4  // files without a weight are web Studio files
        gap = o["gap"]?.jsNumber ?? gap
        bg = o["bg"]?.string ?? bg
        preset = o["preset"]?.string
        extra = o.filter { !["ink", "fill", "weight", "gap", "bg", "preset"].contains($0.key) }
    }

    var json: JSONValue {
        var o = extra
        o["ink"] = .string(ink)
        o["fill"] = .string(fill)
        o["weight"] = .number(weight)
        o["gap"] = .number(gap)
        o["bg"] = .string(bg)
        if let preset { o["preset"] = .string(preset) }
        return .object(o)
    }
}

/// Per-part override of the document style; nil fields inherit.
public struct PartStyle: Sendable, Hashable {
    public var ink: String?
    public var fill: String?
    public var weight: Double?
    public var gap: Double?

    public init(ink: String? = nil, fill: String? = nil, weight: Double? = nil, gap: Double? = nil) {
        self.ink = ink
        self.fill = fill
        self.weight = weight
        self.gap = gap
    }

    public var isEmpty: Bool { ink == nil && fill == nil && weight == nil && gap == nil }
}

public enum CalloutSide: String, Sendable, Hashable, CaseIterable {
    case left, right, below
}

/// An arrowed leader with a monospace label pointing at a part.
public struct Callout: Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var side: CalloutSide?
    public var reach: Double
    /// Where the leader points, as a fraction of the part's screen box.
    public var target: Vec2?
    /// Lines the label up with another part's callouts (by part name).
    public var alignTo: String?

    public init(id: String = makeID(), text: String, side: CalloutSide? = nil, reach: Double = 70, target: Vec2? = nil, alignTo: String? = nil) {
        self.id = id
        self.text = text
        self.side = side
        self.reach = reach
        self.target = target
        self.alignTo = alignTo
    }

    init(json: JSONValue) {
        id = json["id"]?.string ?? makeID()
        text = json["text"]?.string ?? ""
        side = json["side"]?.string.flatMap(CalloutSide.init(rawValue:))
        reach = json["reach"]?.jsNumber ?? 70
        target = json["target"]?.array.flatMap { a in a.count >= 2 ? Vec2(a[0].jsNumber ?? 0.5, a[1].jsNumber ?? 0.5) : nil }
        alignTo = json["alignTo"]?.string
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "text": .string(text), "reach": .number(reach)]
        if let side { o["side"] = .string(side.rawValue) }
        if let target { o["target"] = [.number(target.x), .number(target.y)] }
        if let alignTo { o["alignTo"] = .string(alignTo) }
        return .object(o)
    }
}

public struct Part: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var ops: [Op]
    /// Position (x, y, z), rotation (spin, tilt, roll) and opacity, with keys.
    public var anim: Animatable
    public var style: PartStyle
    public var callouts: [Callout]
    /// Inlay: drawn right after the part with this name.
    public var on: String?
    public var hidden: Bool
    public var locked: Bool
    /// Edges between faces flatter than this many degrees are hidden.
    public var smooth: Double
    public var extra: [String: JSONValue]

    public static let transformProps = ["x", "y", "z", "spin", "tilt", "roll", "opacity"]

    public init(id: String = makeID(), name: String, ops: [Op]) {
        self.id = id
        self.name = name
        self.ops = ops
        anim = Animatable(base: ["x": 0, "y": 0, "z": 0, "spin": 0, "tilt": 0, "roll": 0, "opacity": 100])
        style = PartStyle()
        callouts = []
        on = nil
        hidden = false
        locked = false
        smooth = 40
        extra = [:]
    }

    static let knownKeys: Set<String> = [
        "id", "name", "ops", "base", "keys", "fill", "style", "label", "side", "target", "callouts", "on", "hidden",
        "locked", "smooth",
    ]

    init(json: JSONValue) {
        let o = json.object ?? [:]
        id = o["id"]?.string ?? makeID()
        name = o["name"]?.string ?? "Part"
        ops = (o["ops"]?.array ?? []).compactMap { $0.object.map(Op.init) }
        anim = Animatable(json: json)
        let s = o["style"]
        style = PartStyle(
            ink: s?["ink"]?.string, fill: s?["fill"]?.string ?? o["fill"]?.string,
            weight: s?["weight"]?.jsNumber, gap: s?["gap"]?.jsNumber)
        if let list = o["callouts"]?.array {
            callouts = list.map(Callout.init(json:))
        } else if let label = o["label"]?.string, !label.isEmpty {
            callouts = [Callout(json: ["text": .string(label), "side": o["side"] ?? .null, "target": o["target"] ?? .null])]
        } else {
            callouts = []
        }
        on = o["on"]?.string
        hidden = o["hidden"]?.isTruthy ?? false
        locked = o["locked"]?.isTruthy ?? false
        smooth = o["smooth"]?.jsNumber ?? 40
        extra = o.filter { !Self.knownKeys.contains($0.key) }
    }

    var json: JSONValue {
        var o = extra
        o["id"] = .string(id)
        o["name"] = .string(name)
        o["ops"] = .array(ops.map(\.json))
        o["base"] = anim.baseJSON
        o["keys"] = anim.keysJSON
        if let fill = style.fill { o["fill"] = .string(fill) }
        var st: [String: JSONValue] = [:]
        if let ink = style.ink { st["ink"] = .string(ink) }
        if let weight = style.weight { st["weight"] = .number(weight) }
        if let gap = style.gap { st["gap"] = .number(gap) }
        if !st.isEmpty { o["style"] = .object(st) }
        // The first callout is also written in the v1 form the web Studio reads.
        if let first = callouts.first {
            o["label"] = .string(first.text)
            if let side = first.side { o["side"] = .string(side.rawValue) }
            if let t = first.target { o["target"] = [.number(t.x), .number(t.y)] }
            o["callouts"] = .array(callouts.map(\.json))
        }
        if let on { o["on"] = .string(on) }
        if hidden { o["hidden"] = true }
        if locked { o["locked"] = true }
        if smooth != 40 { o["smooth"] = .number(smooth) }
        return .object(o)
    }
}

/// A dashed assembly line (behind parts) or a detail line drawn over a part.
public struct Guide: Sendable, Hashable, Identifiable {
    public var id: String
    public var a: Vec3
    public var b: Vec3
    public var arrow: Bool
    public var color: String?
    public var opacity: Double?
    public var dash: [Double]?
    /// Makes this a detail line drawn right after the part with this name.
    public var above: String?

    public init(id: String = makeID(), a: Vec3, b: Vec3, arrow: Bool = false, color: String? = nil, opacity: Double? = nil, dash: [Double]? = nil, above: String? = nil) {
        self.id = id
        self.a = a
        self.b = b
        self.arrow = arrow
        self.color = color
        self.opacity = opacity
        self.dash = dash
        self.above = above
    }

    init(json: JSONValue) {
        func v3(_ j: JSONValue?) -> Vec3 {
            let a = (j?.array ?? []).map { $0.jsNumber ?? 0 }
            return a.count >= 3 ? Vec3(a[0], a[1], a[2]) : .zero
        }
        id = json["id"]?.string ?? makeID()
        a = v3(json["a"])
        b = v3(json["b"])
        arrow = json["arrow"]?.isTruthy ?? false
        color = json["color"]?.string
        opacity = json["opacity"]?.jsNumber
        dash = json["dash"]?.array?.compactMap(\.jsNumber)
        above = json["above"]?.string
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "a": JSONValue(vec: a), "b": JSONValue(vec: b), "arrow": .bool(arrow)]
        if let color { o["color"] = .string(color) }
        if let opacity { o["opacity"] = .number(opacity) }
        if let dash { o["dash"] = JSONValue(numbers: dash) }
        if let above { o["above"] = .string(above) }
        return .object(o)
    }
}

/// A Figma-style frame: a named area on the page that holds parts. It hugs its
/// parts unless it has a fixed size, can fill and clip, and may carry the
/// blueprint marks (grid, FIG number, title and year). Frames are optional;
/// without one the page is an open canvas.
public struct Artboard: Sendable, Hashable, Identifiable {
    public var id = makeID()
    public var name = "Frame"
    /// Parts in this frame. A part sits in at most one frame per page.
    public var children: [Part.ID] = []
    /// Fixed size, or nil to hug the children.
    public var size: Vec2?
    /// Top-left on screen, or nil to centre on the children.
    public var origin: Vec2?
    /// Background colour, or nil for the style's paper tint.
    public var fill: String?
    /// Hides what falls outside the frame.
    public var clip = false
    /// Draws the grid, FIG number, title and year.
    public var marks = false
    public var fig = "FIG.001"
    public var title = "Untitled Drawing"
    public var year = String(Calendar.current.component(.year, from: Date()))
    public var grid = 16.0
    public var margin = 80.0
    /// Set when read from an old drawing sheet: the frame takes every part.
    var adoptsAll = false

    public init(name: String = "Frame", children: [Part.ID] = [], marks: Bool = false) {
        self.name = name
        self.children = children
        self.marks = marks
    }

    public var hugs: Bool { size == nil }

    init(json: JSONValue) {
        let o = json.object ?? [:]
        id = o["id"]?.string ?? id
        name = o["name"]?.string ?? name
        children = (o["children"]?.array ?? []).compactMap(\.string)
        if let a = o["size"]?.array, a.count >= 2 { size = Vec2(a[0].jsNumber ?? 400, a[1].jsNumber ?? 300) }
        if let a = o["origin"]?.array, a.count >= 2 { origin = Vec2(a[0].jsNumber ?? 0, a[1].jsNumber ?? 0) }
        fill = o["fill"]?.string
        clip = o["clip"]?.isTruthy ?? false
        marks = o["marks"]?.isTruthy ?? false
        fig = o["fig"]?.string ?? fig
        title = o["title"]?.string ?? title
        year = o["year"]?.string ?? o["year"]?.jsNumber.map(jsNumberString) ?? year
        grid = o["grid"]?.jsNumber ?? grid
        margin = o["margin"]?.jsNumber ?? margin
    }

    /// The single drawing sheet older files have; nil when it was hidden.
    static func legacySheet(_ json: JSONValue?) -> Artboard? {
        guard let o = json?.object, o["visible"]?.isTruthy ?? true else { return nil }
        var a = Artboard(json: json!)
        a.id = makeID()
        a.name = o["name"]?.string ?? "Frame"
        a.marks = o["marks"]?.isTruthy ?? true
        a.adoptsAll = true
        return a
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "children": .array(children.map(JSONValue.string)),
            "clip": .bool(clip), "marks": .bool(marks),
        ]
        if let size { o["size"] = [.number(size.x), .number(size.y)] }
        if let origin { o["origin"] = [.number(origin.x), .number(origin.y)] }
        if let fill { o["fill"] = .string(fill) }
        if marks {
            o["fig"] = .string(fig)
            o["title"] = .string(title)
            o["year"] = .string(year)
            o["grid"] = .number(grid)
            o["margin"] = .number(margin)
        }
        return .object(o)
    }
}

extension [Artboard] {
    /// The frame holding `part`, if any.
    public func index(holding part: Part.ID) -> Int? { firstIndex { $0.children.contains(part) } }

    /// Moves `parts` into the frame `id`, or out of every frame when `id` is nil.
    public mutating func place(_ parts: [Part.ID], in id: Artboard.ID?) {
        let set = Set(parts)
        for i in indices { self[i].children.removeAll { set.contains($0) } }
        if let id, let i = firstIndex(where: { $0.id == id }) { self[i].children += parts }
    }

    mutating func adoptLegacy(_ parts: [Part.ID]) {
        for i in indices where self[i].adoptsAll {
            self[i].children = parts
            self[i].adoptsAll = false
        }
    }
}

/// A whole document: what's saved in a `.isoscene` file. Version 1 is exactly
/// what the web Studio writes; version 2 adds the plugin features.
public struct SceneFile: Sendable, Hashable {
    public static let currentVersion = 2

    public var v = SceneFile.currentVersion
    public var name = "Untitled"
    public var style = Style()
    public var duration = 4.0
    public var fps = 24.0
    public var camera = Animatable(base: ["spin": 0])
    public var parts: [Part] = []
    /// Projection angle: 30 (isometric) or 26.565 (2:1 pixel).
    public var angle = 30.0
    /// The active page's frames, back to front.
    public var frames: [Artboard] = []
    public var guides: [Guide] = []
    public var dimensions: [DimensionLine] = []
    public var shapes: [FlatShape] = []
    public var decals: [Decal] = []
    /// Layer tree with groups, back to front. Empty means plain `parts` order; read `outline`.
    public var layers: [LayerNode] = []
    public var drawOrder = DrawOrder.depth
    /// Empty means one implicit page. The active page's parts, art, frames, camera
    /// and timing live in the fields above.
    public var pages: [Page] = []
    public var activePage: Page.ID?
    public var extra: [String: JSONValue] = [:]

    public init() {}

    static let knownKeys: Set<String> = [
        "v", "name", "style", "duration", "fps", "camera", "parts", "angle", "sheet", "frames", "guides", "dimensions", "shapes",
        "decals", "layers", "drawOrder", "pages", "activePage", "meta",
    ]

    public init(json: JSONValue) throws {
        guard let o = json.object else { throw SceneFileError.notAScene }
        v = Int(o["v"]?.jsNumber ?? 1)
        name = o["name"]?.string ?? "Untitled"
        style = Style(json: o["style"])
        duration = max(0.1, o["duration"]?.jsNumber ?? 4)
        fps = max(1, o["fps"]?.jsNumber ?? 24)
        camera = Animatable(json: o["camera"])
        parts = (o["parts"]?.array ?? []).map(Part.init(json:))
        angle = o["angle"]?.jsNumber ?? 30
        frames = o["frames"]?.array.map { $0.map(Artboard.init(json:)) } ?? Artboard.legacySheet(o["sheet"]).map { [$0] } ?? []
        guides = (o["guides"]?.array ?? []).map(Guide.init(json:))
        dimensions = (o["dimensions"]?.array ?? []).map(DimensionLine.init(json:))
        shapes = (o["shapes"]?.array ?? []).map(FlatShape.init(json:))
        decals = (o["decals"]?.array ?? []).map(Decal.init(json:))
        layers = (o["layers"]?.array ?? []).compactMap(LayerNode.init(json:))
        drawOrder = o["drawOrder"]?.string.flatMap(DrawOrder.init(rawValue:)) ?? .depth
        pages = (o["pages"]?.array ?? []).map(Page.init(json:))
        activePage = o["activePage"]?.string ?? pages.first?.id
        if !pages.isEmpty, activePageIndex == nil { activePage = pages[0].id }
        resolveLegacyPages()
        frames.adoptLegacy(parts.map(\.id))
        for i in pages.indices { pages[i].frames.adoptLegacy(pages[i].parts.map(\.id)) }
        extra = o.filter { !Self.knownKeys.contains($0.key) }
    }

    public var json: JSONValue {
        var o = extra
        o["v"] = .number(Double(max(v, Self.currentVersion)))
        o["name"] = .string(name)
        o["style"] = style.json
        o["duration"] = .number(duration)
        o["fps"] = .number(fps)
        o["camera"] = ["base": camera.baseJSON, "keys": camera.keysJSON]
        o["parts"] = .array(parts.map(\.json))
        o["angle"] = .number(angle)
        if !frames.isEmpty { o["frames"] = .array(frames.map(\.json)) }
        if !guides.isEmpty { o["guides"] = .array(guides.map(\.json)) }
        if !dimensions.isEmpty { o["dimensions"] = .array(dimensions.map(\.json)) }
        if !shapes.isEmpty { o["shapes"] = .array(shapes.map(\.json)) }
        if !decals.isEmpty { o["decals"] = .array(decals.map(\.json)) }
        if outline.contains(where: { $0.group != nil }) { o["layers"] = .array(outline.map(\.json)) }
        if drawOrder != .depth { o["drawOrder"] = .string(drawOrder.rawValue) }
        if !pages.isEmpty {
            var s = self
            s.storeActivePage()
            o["pages"] = .array(s.pages.map(\.json))
            if let activePage { o["activePage"] = .string(activePage) }
        }
        o["meta"] = ["app": "Isometric Workbench"]
        return .object(o)
    }

    public static func decode(_ data: Data) throws -> SceneFile {
        let json = try JSONValue.parse(data)
        if let solid = PluginSolid(json: json) { return solid.scene }
        return try SceneFile(json: json)
    }

    public func encoded() -> Data { json.jsonData() }

    public var isEmpty: Bool { parts.isEmpty && shapes.isEmpty && decals.isEmpty }

    public var isoAngle: IsoAngle { IsoAngle(degrees: angle) }

    public func partIndex(_ id: Part.ID) -> Int? { parts.firstIndex { $0.id == id } }
}

public enum SceneFileError: Error, LocalizedError {
    case notAScene

    public var errorDescription: String? { "This file isn't an Isometric Workbench scene." }
}

/// A solid copied from the Figma plugin (`{ v, name, angle, smooth, style,
/// ops, rot, pivot, dx, dy }`), pasted as an editable part.
public struct PluginSolid: Sendable {
    public var part: Part
    public var angle: Double

    public init?(json: JSONValue) {
        guard let o = json.object, o["parts"] == nil, let ops = o["ops"]?.array, !ops.isEmpty else { return nil }
        var p = Part(name: o["name"]?.string ?? "Solid", ops: ops.compactMap { $0.object.map(Op.init) })
        let rot = o["rot"]
        p.anim.base["spin"] = rot?["z"]?.jsNumber ?? 0
        p.anim.base["tilt"] = rot?["x"]?.jsNumber ?? 0
        p.anim.base["roll"] = rot?["y"]?.jsNumber ?? 0
        let st = o["style"]
        p.style = PartStyle(ink: st?["stroke"]?.string, fill: st?["fill"]?.string, weight: st?["strokeWeight"]?.jsNumber, gap: st?["gap"]?.jsNumber)
        p.smooth = o["smooth"]?.jsNumber ?? 40
        part = p
        angle = o["angle"]?.jsNumber ?? 30
    }

    public var scene: SceneFile {
        var s = SceneFile()
        s.name = part.name
        s.angle = angle
        s.parts = [part]
        return s
    }
}
