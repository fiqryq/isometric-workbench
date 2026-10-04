import IsoDocument
import IsoMath
import SwiftUI

/// Name, position, size, fill and blueprint marks of the selected frame.
struct FrameInspector: View {
    let model: SceneModel
    let board: Artboard

    private static let presets: [(name: String, size: Vec2)] = [
        ("Landscape", Vec2(1200, 800)), ("Desktop HD", Vec2(1920, 1080)), ("Square", Vec2(1080, 1080)),
        ("Portrait", Vec2(1080, 1350)), ("Story", Vec2(1080, 1920)), ("A4", Vec2(1123, 794)),
    ]

    var body: some View {
        let rect = model.frameRect(board.id) ?? Box2(minX: 0, minY: 0, maxX: 0, maxY: 0)
        InspectorSection("Frame · \(board.children.count) part\(board.children.count == 1 ? "" : "s")") {
            CommitField(title: "Name", text: board.name) { v in
                let name = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { edit("Rename Frame") { $0.name = name } }
            }
            FieldPair {
                NumberField(label: "X", value: rect.minX, step: 10) { v in model.setFrameOrigin(board.id, Vec2(v, rect.minY)) }
            } _: {
                NumberField(label: "Y", value: rect.minY, step: 10) { v in model.setFrameOrigin(board.id, Vec2(rect.minX, v)) }
            }
        } accessory: {
            InspectorIconButton("square.dashed", help: "Remove the frame, keep its parts") { model.deleteFrame(board.id, keepParts: true) }
            InspectorIconButton("trash", help: "Delete the frame and its parts", role: .destructive) { model.deleteFrame(board.id, keepParts: false) }
        }
        InspectorSection("Layout") {
            FieldPair {
                NumberField(label: "W", value: rect.width, step: 10, range: 16...20_000) { v in
                    model.setFrameSize(board.id, Vec2(v, rect.height))
                }
            } _: {
                NumberField(label: "H", value: rect.height, step: 10, range: 16...20_000) { v in
                    model.setFrameSize(board.id, Vec2(rect.width, v))
                }
            }
            PopupField("Size", icon: "aspectratio", selection: Binding(get: { presetTag }, set: { tag in
                if tag == "hug" {
                    model.hugFrame(board.id)
                } else if let p = Self.presets.first(where: { Self.tag($0.size) == tag }) {
                    model.setFrameSize(board.id, p.size)
                }
            })) {
                Text("Hug Contents").tag("hug")
                ForEach(Self.presets, id: \.name) { p in
                    Text("\(p.name) · \(Int(p.size.x)) × \(Int(p.size.y))").tag(Self.tag(p.size))
                }
                if presetTag == "fixed" { Text("Fixed").tag("fixed") }
            }
            InspectorRow {
                Toggle("Clip content", isOn: Binding(get: { board.clip }, set: { v in
                    edit(v ? "Clip Content" : "Unclip Content") { $0.clip = v }
                }))
            }
        }
        InspectorSection("Fill") {
            HexColorPicker(title: "Fill", hex: board.fill ?? model.scene.style.sheetFill.hex, onCommit: { v in
                edit("Change Frame Fill") { $0.fill = v }
            }, onReset: board.fill == nil ? nil : { edit("Reset Frame Fill") { $0.fill = nil } })
        }
        InspectorSection("Blueprint") {
            InspectorRow {
                Toggle("Grid and labels", isOn: Binding(get: { board.marks }, set: { v in
                    edit(v ? "Show Marks" : "Hide Marks") { $0.marks = v }
                }))
            }
            if board.marks {
                CommitField(title: "Figure", text: board.fig) { v in edit("Edit Frame") { $0.fig = v } }
                CommitField(title: "Title", text: board.title) { v in edit("Edit Frame") { $0.title = v } }
                CommitField(title: "Year", text: board.year) { v in edit("Edit Frame") { $0.year = v } }
                SliderField(label: "Grid", icon: "squareshape.split.3x3", value: board.grid, range: 4...200, step: 4) { v in
                    edit("Edit Frame") { $0.grid = v }
                }
                SliderField(label: "Margin", icon: "rectangle.inset.filled", value: board.margin, range: 0...400, step: 8) { v in
                    edit("Edit Frame") { $0.margin = v }
                }
            }
        }
    }

    private func edit(_ name: String, _ body: (inout Artboard) -> Void) {
        model.editFrame(board.id, name, body)
    }

    private static func tag(_ size: Vec2) -> String { "\(Int(size.x))x\(Int(size.y))" }

    private var presetTag: String {
        guard let size = board.size else { return "hug" }
        return Self.presets.contains { $0.size == size } ? Self.tag(size) : "fixed"
    }
}
