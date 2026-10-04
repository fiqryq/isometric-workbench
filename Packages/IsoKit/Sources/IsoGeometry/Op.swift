import Foundation

/// One modelling step, stored exactly as the plugin's JSON op
/// (`{ "type": "box", "w": 160, … }`). Fields are read leniently like the JS
/// engine's `num(v, default)`, and anything unknown is kept as-is, so files
/// round-trip between the plugin, the web Studio and the Mac app.
public struct Op: Sendable, Hashable, Codable {
    public var fields: [String: JSONValue]

    public init(_ fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(type: String, _ fields: [String: JSONValue] = [:]) {
        var f = fields
        f["type"] = .string(type)
        self.fields = f
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        fields = value.object ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        try JSONValue.object(fields).encode(to: encoder)
    }

    public var json: JSONValue { .object(fields) }

    public var type: String { fields["type"]?.string ?? "" }

    public var enabled: Bool {
        get { fields["enabled"] != .bool(false) }
        set {
            if newValue { fields.removeValue(forKey: "enabled") } else { fields["enabled"] = .bool(false) }
        }
    }

    public subscript(key: String) -> JSONValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    /// JS `num(op[key], fallback)`.
    public func num(_ key: String, _ fallback: Double) -> Double {
        fields[key]?.jsNumber ?? fallback
    }

    public func string(_ key: String) -> String? { fields[key]?.string }

    public func truthy(_ key: String) -> Bool { fields[key]?.isTruthy ?? false }

    public func axis(_ key: String = "axis") -> Axis? { string(key).flatMap(Axis.init(rawValue:)) }

    public mutating func set(_ key: String, _ value: Double) { fields[key] = .number(value) }

    /// Profile loops (`[[[x, y], …], …]`).
    public func loops(_ key: String = "loops") -> [Loop] {
        guard let arr = fields[key]?.array else { return [] }
        return arr.map { loop in
            (loop.array ?? []).compactMap { p -> Vec2? in
                guard let a = p.array, a.count >= 2 else { return nil }
                return Vec2(a[0].jsNumber ?? 0, a[1].jsNumber ?? 0)
            }
        }
    }

    public var subOps: [Op] {
        (fields["ops"]?.array ?? []).compactMap { $0.object.map(Op.init) }
    }
}

extension JSONValue {
    public init(loops: [Loop]) {
        self = .array(loops.map { l in .array(l.map { .array([.number($0.x), .number($0.y)]) }) })
    }

    public init(vec: Vec3) {
        self = .array([.number(vec.x), .number(vec.y), .number(vec.z)])
    }

    public init(matrix: Mat3) {
        self = .array(matrix.rows.map { .array($0.map { .number($0) }) })
    }

    public init(numbers: [Double]) {
        self = .array(numbers.map { .number($0) })
    }
}

// MARK: - Builders (the plugin's command defaults)

extension Op {
    public static func box(w: Double, d: Double, h: Double) -> Op {
        Op(type: "box", ["w": .number(w), "d": .number(d), "h": .number(h)])
    }

    public static func cylinder(r: Double, h: Double, segments: Double) -> Op {
        Op(type: "cylinder", ["r": .number(r), "h": .number(h), "segments": .number(segments)])
    }

    public static func extrude(plane: IsoPlane, depth: Double, loops: [Loop]) -> Op {
        Op(type: "extrude", ["plane": .string(plane.rawValue), "depth": .number(depth), "loops": JSONValue(loops: loops)])
    }

    public static func revolve(segments: Double, axis: Double, loops: [Loop]) -> Op {
        Op(type: "revolve", ["segments": .number(segments), "axis": .number(axis), "loops": JSONValue(loops: loops)])
    }

    public static func push(axis: Axis, at: Double, depth: Double, through: Bool = false, loops: [Loop]) -> Op {
        var f: [String: JSONValue] = [
            "axis": .string(axis.rawValue), "at": .number(at), "depth": .number(depth), "loops": JSONValue(loops: loops),
        ]
        if through { f["through"] = .bool(true) }
        return Op(type: "push", f)
    }

    public enum SectionPreset: String, Sendable, CaseIterable {
        case quarter, left, right, top
    }

    public static func section(_ preset: SectionPreset, percent: Double = 50) -> Op {
        Op(type: "cut", ["preset": .string(preset.rawValue), "fx": .number(percent), "fy": .number(percent), "fz": .number(percent)])
    }

    public static func cut(_ preset: SectionPreset, fx: Double? = nil, fy: Double? = nil, fz: Double? = nil) -> Op {
        var f: [String: JSONValue] = ["preset": .string(preset.rawValue)]
        if let fx { f["fx"] = .number(fx) }
        if let fy { f["fy"] = .number(fy) }
        if let fz { f["fz"] = .number(fz) }
        return Op(type: "cut", f)
    }

    public static func merge(
        _ ops: [Op], mode: String = "union", name: String = "part", offset: Vec3, matrix: Mat3? = nil
    ) -> Op {
        var f: [String: JSONValue] = [
            "mode": .string(mode), "name": .string(name),
            "ox": .number(offset.x), "oy": .number(offset.y), "oz": .number(offset.z),
            "ops": .array(ops.map(\.json)),
        ]
        if let matrix { f["m"] = JSONValue(matrix: matrix) }
        return Op(type: "merge", f)
    }

    public static func loopCut(id: String, axis: Axis, count: Int, slide: Double = 0, scales: [Double]? = nil) -> Op {
        let s = scales ?? Array(repeating: 100, count: count + 2)
        return Op(type: "loopcut", [
            "id": .string(id), "axis": .string(axis.rawValue), "count": .number(Double(count)),
            "slide": .number(slide), "scales": JSONValue(numbers: s),
        ])
    }

    public static func segmentPush(loopId: String, segment: Int, face: IsoPlane, depth: Double) -> Op {
        Op(type: "segpush", [
            "loopId": .string(loopId), "segment": .number(Double(segment)), "face": .string(face.rawValue),
            "depth": .number(depth),
        ])
    }

    public static func move(x: Double, y: Double, z: Double) -> Op {
        Op(type: "move", ["x": .number(x), "y": .number(y), "z": .number(z)])
    }

    public static func scale(x: Double, y: Double, z: Double) -> Op {
        Op(type: "scale", ["x": .number(x), "y": .number(y), "z": .number(z)])
    }

    public static func size(w: Double?, d: Double?, h: Double?) -> Op {
        var f: [String: JSONValue] = [:]
        if let w { f["w"] = .number(w) }
        if let d { f["d"] = .number(d) }
        if let h { f["h"] = .number(h) }
        return Op(type: "size", f)
    }

    public static func mirror(axis: Axis, copy: Bool = true, gap: Double = 0) -> Op {
        Op(type: "mirror", ["axis": .string(axis.rawValue), "copy": .bool(copy), "gap": .number(gap)])
    }

    public static func array(axis: Axis, count: Double = 3, gap: Double = 20) -> Op {
        Op(type: "array", ["axis": .string(axis.rawValue), "count": .number(count), "gap": .number(gap)])
    }

    public static func radial(count: Double = 6, radius: Double = 80, angle: Double = 360) -> Op {
        Op(type: "radial", ["count": .number(count), "radius": .number(radius), "angle": .number(angle)])
    }

    /// A new unique loop-cut id, like the plugin's `"L" + Date.now().toString(36) + …`.
    public static func newLoopID() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        return "L" + String(ms, radix: 36) + String(Int.random(in: 0..<10_000))
    }
}

/// The plugin's parametric primitives and their defaults (`PRIMITIVES`).
public struct PrimitiveSpec: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let keys: [(String, Double)]

    public static func == (a: PrimitiveSpec, b: PrimitiveSpec) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public static let all: [PrimitiveSpec] = [
        PrimitiveSpec(id: "box", name: "Box", keys: [("w", 160), ("d", 160), ("h", 40)]),
        PrimitiveSpec(id: "cylinder", name: "Cylinder", keys: [("r", 50), ("h", 80), ("segments", 48)]),
        PrimitiveSpec(id: "sphere", name: "Sphere", keys: [("r", 60), ("segments", 32)]),
        PrimitiveSpec(id: "cone", name: "Cone", keys: [("r1", 60), ("r2", 0), ("h", 100), ("segments", 40)]),
        PrimitiveSpec(id: "tube", name: "Tube", keys: [("r", 60), ("ri", 40), ("h", 80), ("segments", 48)]),
        PrimitiveSpec(id: "torus", name: "Torus", keys: [("R", 60), ("r", 18), ("segments", 40), ("sides", 16)]),
        PrimitiveSpec(id: "prism", name: "Prism", keys: [("r", 60), ("h", 60), ("sides", 6)]),
        PrimitiveSpec(id: "wedge", name: "Wedge", keys: [("w", 160), ("d", 120), ("h", 80)]),
        PrimitiveSpec(id: "stairs", name: "Stairs", keys: [("w", 120), ("d", 160), ("h", 100), ("steps", 5)]),
    ]

    public var op: Op {
        var f: [String: JSONValue] = [:]
        for (k, v) in keys { f[k] = .number(v) }
        return Op(type: id, f)
    }
}
