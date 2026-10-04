import Foundation

/// How a step reads in History — the port of the plugin's `opView`.
public struct OpDisplay: Sendable, Hashable {
    public struct Field: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable { case number, bool }
        public let key: String
        public let label: String
        public let kind: Kind
        public let step: Double
        public var id: String { key }
    }

    public let label: String
    public let fields: [Field]
}

extension Op {
    static let axisLabel: [String: String] = ["x": "X", "y": "Y", "z": "Z"]
    static let axisFace: [String: String] = ["z": "top", "y": "left", "x": "right"]
    public static let loopNames: [String: String] = ["z": "horizontal", "x": "vertical L", "y": "vertical R"]

    /// The JS template-literal form of a field (`${op.sides}`).
    func text(_ key: String) -> String {
        switch fields[key] {
        case .number(let n): jsNumberString(n)
        case .string(let s): s
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case nil: "undefined"
        default: ""
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public var display: OpDisplay {
        func n(_ key: String, _ label: String, _ step: Double = 1) -> OpDisplay.Field {
            .init(key: key, label: label, kind: .number, step: step)
        }
        let ax = { (key: String) in Op.axisLabel[self.string(key) ?? ""] }
        switch type {
        case "box": return .init(label: "Box", fields: [n("w", "W"), n("d", "D"), n("h", "H")])
        case "cylinder": return .init(label: "Cylinder", fields: [n("r", "R"), n("h", "H"), n("segments", "Seg")])
        case "extrude": return .init(label: "Extrude · " + text("plane"), fields: [n("depth", "Depth")])
        case "revolve": return .init(label: "Revolve", fields: [n("axis", "Axis"), n("segments", "Seg")])
        case "push":
            let verb = truthy("through") ? "Cut through" : num("depth", 0) >= 0 ? "Extrude" : "Push in"
            return .init(
                label: verb + " · " + (Op.axisFace[string("axis") ?? ""] ?? "undefined"),
                fields: [
                    n("depth", "Depth"), n("at", ax("axis") ?? "undefined"),
                    .init(key: "through", label: "Thru", kind: .bool, step: 1),
                ])
        case "cut":
            let preset = string("preset")
            let f: [OpDisplay.Field] =
                preset == "quarter" ? [n("fx", "X%"), n("fy", "Y%")]
                : preset == "left" ? [n("fy", "Y%")]
                : preset == "right" ? [n("fx", "X%")]
                : [n("fz", "Z%")]
            return .init(label: "Section · " + text("preset"), fields: f)
        case "merge":
            return .init(
                label: (string("mode") == "subtract" ? "Subtract " : "Union ") + (string("name") ?? ""),
                fields: [n("ox", "X"), n("oy", "Y"), n("oz", "Z")])
        case "sphere": return .init(label: "Sphere", fields: [n("r", "R"), n("segments", "Seg")])
        case "cone":
            return .init(
                label: num("r2", 0) > 0 ? "Frustum" : "Cone",
                fields: [n("r1", "R base"), n("r2", "R top"), n("h", "H"), n("segments", "Seg")])
        case "tube": return .init(label: "Tube", fields: [n("r", "R"), n("ri", "R in"), n("h", "H"), n("segments", "Seg")])
        case "torus": return .init(label: "Torus", fields: [n("R", "R"), n("r", "Tube"), n("segments", "Seg")])
        case "prism": return .init(label: "Prism · \(text("sides")) sides", fields: [n("r", "R"), n("h", "H"), n("sides", "Sides")])
        case "wedge": return .init(label: "Wedge", fields: [n("w", "W"), n("d", "D"), n("h", "H")])
        case "stairs":
            return .init(label: "Stairs · \(text("steps")) steps", fields: [n("w", "W"), n("d", "D"), n("h", "H"), n("steps", "Steps")])
        case "size": return .init(label: "Size", fields: [n("w", "W"), n("d", "D"), n("h", "H")])
        case "move": return .init(label: "Move", fields: [n("x", "X"), n("y", "Y"), n("z", "Z")])
        case "scale": return .init(label: "Scale", fields: [n("x", "X%"), n("y", "Y%"), n("z", "Z%")])
        case "mirror":
            let flip = self["copy"] == .bool(false)
            return .init(label: "Mirror \(ax("axis") ?? "X")\(flip ? " · flip" : "")", fields: flip ? [] : [n("gap", "Gap")])
        case "array":
            return .init(label: "Array ×\(text("count")) · \(ax("axis") ?? "X")", fields: [n("count", "Count"), n("gap", "Gap")])
        case "radial":
            return .init(label: "Radial array ×\(text("count"))", fields: [n("count", "Count"), n("radius", "Radius"), n("angle", "Angle°")])
        case "facepush":
            return .init(label: "\(num("depth", 0) >= 0 ? "Extrude" : "Push in") face · \(string("name") ?? "face")", fields: [n("depth", "Depth")])
        case "loopcut":
            let axis = string("axis") ?? ""
            return .init(label: "Loop cut ×\(text("count")) · \(Op.loopNames[axis] ?? axis)", fields: [n("count", "Cuts"), n("slide", "Slide")])
        case "segpush":
            return .init(
                label: "\(num("depth", 0) >= 0 ? "Extrude" : "Inset") segment \(jsNumberString(num("segment", 0) + 1)) · \(text("face"))",
                fields: [n("depth", "Depth"), n("segment", "Seg")])
        default:
            return .init(label: type, fields: [])
        }
    }

    /// Applies a History edit (`cmdOpEdit` action "set"), with the same clamps.
    public mutating func setField(_ key: String, to value: JSONValue) {
        if key.hasPrefix("scales.") {
            let j = Int(key.dropFirst("scales.".count)) ?? 0
            var scales = self["scales"]?.array ?? []
            while scales.count <= j { scales.append(.number(100)) }
            scales[j] = .number(clamp(value.jsNumber ?? 100, 1, 500))
            self["scales"] = .array(scales)
        } else if case .bool = fields[key] {
            fields[key] = .bool(value.isTruthy)
        } else if key == "through" {
            fields[key] = .bool(value.isTruthy)
        } else {
            fields[key] = .number(value.jsNumber ?? num(key, 0))
        }
        if type == "loopcut" { normalizeLoopCut() }
    }

    /// One scale per ring, both ends included. The ends keep their scale when
    /// the number of cuts changes; new inner rings start at 100%.
    public mutating func normalizeLoopCut() {
        let count = Int(max(1, min(24, jsRound(num("count", 1)))))
        set("count", Double(count))
        set("slide", max(-100, min(100, num("slide", 0))))
        let old = (self["scales"]?.array ?? []).map { $0.jsNumber }
        let last = count + 1
        let scales: [Double] = (0...last).map { j in
            if j == 0 { return (old.first ?? nil) ?? 100 }
            if j == last { return (old.last ?? nil) ?? 100 }
            return j < old.count - 1 ? (old[j] ?? 100) : 100
        }
        self["scales"] = JSONValue(numbers: scales)
    }
}
