import AppKit
import IsoDocument
import IsoGeometry
import IsoMath
import IsoRender
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tools

/// Top · Left · Right as segments.
let planeSegments: [Segment<IsoPlane>] = IsoPlane.allCases.map { .text($0.rawValue.capitalized, $0) }

struct ToolOptionsSection: View {
    @Bindable var model: SceneModel

    var body: some View {
        InspectorSection(model.tool.title) {
            IconSegmented(selection: $model.drawPlane, planeSegments)
                .help("The plane shapes are drawn on when you start on an empty canvas")
            if model.tool == .polygon {
                SliderField(label: "Sides", icon: "hexagon", value: Double(model.polygonSides), range: 3...24) { v in
                    model.polygonSides = Int(v.rounded())
                }
            }
            InspectorNote(model.tool == .pen ? "Click to add points · Return closes" : "Drag on a face or the canvas · ⇧ keeps it even")
        }
    }
}

struct SketchSection: View {
    let model: SceneModel
    let sketch: PendingSketch
    @State private var depth = 20.0
    @State private var hatch = true

    var body: some View {
        InspectorSection("Sketch · \(sketch.name)") {
            FieldPair {
                NumberField(label: "Depth", value: depth, step: 5, range: 0.5...10_000) { depth = $0 }
            } _: {
                Color.clear
            }
            if sketch.plane.host != nil {
                WideButton("Extrude", prominent: true) { model.extrudeSketch(depth: depth) }.keyboardShortcut(.defaultAction)
                HStack(spacing: InspectorMetrics.rowSpacing) {
                    WideButton("Push In") { model.pushSketch(depth: depth, through: false) }
                    WideButton("Cut Through") { model.pushSketch(depth: depth, through: true) }
                }
                WideButton("Extrude as New Part") { model.extrudeSketch(depth: depth, asNewPart: true) }
            } else {
                WideButton("Extrude as New Part", prominent: true) { model.extrudeSketch(depth: depth) }.keyboardShortcut(.defaultAction)
            }
            if sketch.plane.axis != .z {
                WideButton("Revolve as New Part") { model.revolveSketch() }
            }
            HStack(spacing: InspectorMetrics.rowSpacing) {
                WideButton("Keep as Flat Shape") { model.keepSketch(hatch: hatch) }
                Toggle("Hatched", isOn: $hatch).fixedSize()
            }
        } accessory: {
            InspectorIconButton("trash", help: "Discard", role: .destructive) { model.discardSketch() }
        }
    }
}

// MARK: - Loop rings

struct RingsSection: View {
    let model: SceneModel
    let part: Part
    @State private var taperFrom = 100.0
    @State private var taperTo = 60.0
    @State private var depth = 10.0
    @State private var face: IsoPlane? = nil

    var body: some View {
        let infos = model.loopInfos(part)
        let rings = model.pickedRings.filter { $0.partID == part.id }
        let segments = model.pickedSegments.filter { $0.partID == part.id }
        InspectorSection("Loop Rings") {
            if infos.isEmpty {
                InspectorNote("No loop cuts yet.")
                Menu {
                    Button("Horizontal") { model.addStep(.loopCut(id: Op.newLoopID(), axis: .z, count: 3), name: "Add Loop Cut") }
                    Button("Vertical L") { model.addStep(.loopCut(id: Op.newLoopID(), axis: .x, count: 3), name: "Add Loop Cut") }
                    Button("Vertical R") { model.addStep(.loopCut(id: Op.newLoopID(), axis: .y, count: 3), name: "Add Loop Cut") }
                } label: {
                    Text("Add Loop Cut").frame(maxWidth: .infinity)
                }
                .menuStyle(.button)
                .buttonStyle(FieldButtonStyle())
                .menuIndicator(.hidden)
            } else if rings.isEmpty && segments.isEmpty {
                InspectorNote("Click a ring or the face between two. ⇧ adds more.")
            }
            if !rings.isEmpty {
                chips(rings.map { r in "Ring \(r.knot + 1)" + (infos.count > 1 ? " · \(loopName(r.loopID, infos))" : "") })
                SliderField(label: "Scale", icon: "arrow.up.left.and.arrow.down.right", value: model.ringScale(rings[0]), range: 1...300,
                            suffix: "%") { model.scalePickedRings($0) }
                if let info = infos.first(where: { $0.loopID == rings[0].loopID }) {
                    SliderField(label: "Slide", icon: "arrow.left.and.right", value: part.ops[info.opIndex].num("slide", 0), range: -100...100) { v in
                        model.setStepField(part.id, step: info.opIndex, key: "slide", value: .number(v))
                    }
                }
                if rings.count >= 2 {
                    FieldPair {
                        SliderField(label: "From", value: taperFrom, range: 1...300, suffix: "%") { taperFrom = $0 }
                    } _: {
                        SliderField(label: "To", value: taperTo, range: 1...300, suffix: "%") { taperTo = $0 }
                    }
                    WideButton("Taper Across Picked Rings") { model.taperPickedRings(from: taperFrom, to: taperTo) }
                }
            }
            if !segments.isEmpty {
                chips(segments.map { "Segment \($0.segment + 1) · \($0.face.rawValue)" })
                IconSegmented(selection: $face, [.text("As picked", nil)] + IsoPlane.allCases.map { Segment<IsoPlane?>.text($0.rawValue.capitalized, $0) })
                    .help("Face")
                FieldPair {
                    NumberField(label: "Depth", value: depth, step: 5, range: 0.5...10_000) { depth = $0 }
                } _: {
                    Color.clear
                }
                HStack(spacing: InspectorMetrics.rowSpacing) {
                    WideButton("Extrude", prominent: true) { model.pushPickedSegments(depth: depth, face: face) }
                    WideButton("Inset") { model.pushPickedSegments(depth: -depth, face: face) }
                }
            }
        } accessory: {
            if !rings.isEmpty || !segments.isEmpty {
                InspectorIconButton("xmark", help: "Clear picks") {
                    model.pickedRings = []
                    model.pickedSegments = []
                }
            }
        }
    }

    private func loopName(_ id: String, _ infos: [LoopInfo]) -> String {
        guard let i = infos.firstIndex(where: { $0.loopID == id }) else { return "" }
        return "cut \(i + 1)"
    }

    private func chips(_ labels: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, l in
                    Text(l)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
        }
    }
}

// MARK: - Annotations

struct AnnotationInspector: View {
    let model: SceneModel
    let ref: AnnotationRef

    var body: some View {
        switch ref {
        case .shape(let id):
            if let s = model.scene.shapes.first(where: { $0.id == id }) { ShapeInspector(model: model, shape: s) }
        case .decal(let id):
            if let d = model.scene.decals.first(where: { $0.id == id }) { DecalInspector(model: model, decal: d) }
        case .dimension(let id):
            if let d = model.scene.dimensions.first(where: { $0.id == id }) { DimensionInspector(model: model, dim: d) }
        }
    }
}

private func hostPicker(_ model: SceneModel, host: Part.ID?, _ set: @escaping (Part.ID?) -> Void) -> some View {
    PopupField("On", selection: Binding(get: { host ?? "" }, set: { set($0.isEmpty ? nil : $0) })) {
        Text("World").tag("")
        ForEach(model.scene.parts) { Text($0.name).tag($0.id) }
    }
}

struct ShapeInspector: View {
    let model: SceneModel
    let shape: FlatShape

    var body: some View {
        InspectorSection("Shape") {
            CommitField(title: "Name", text: shape.name) { v in model.updateShape(shape.id, "Rename") { $0.name = v } }
            ValueField(label: "Plane", value: "\(IsoPlane(axis: shape.axis).rawValue.capitalized) at \(jsNumberString(shape.at))")
            SliderField(label: "Opacity", icon: "circle.lefthalf.filled", value: shape.opacity * 100, range: 0...100, suffix: "%") { v in
                model.updateShape(shape.id) { $0.opacity = v / 100 }
            }
            InspectorRow {
                Toggle("Hatched", isOn: Binding(get: { shape.hatch }, set: { v in model.updateShape(shape.id) { $0.hatch = v } }))
            }
        } accessory: {
            InspectorIconButton("trash", help: "Delete Shape", role: .destructive) { model.deleteAnnotation(.shape(shape.id)) }
        }
        InspectorSection("Fill") {
            HStack(spacing: InspectorMetrics.rowSpacing) {
                Toggle("", isOn: Binding(get: { shape.fill != nil }, set: { on in
                    model.updateShape(shape.id) { $0.fill = on ? model.scene.style.fill : nil }
                }))
                .labelsHidden()
                .help(shape.fill == nil ? "Fill the shape" : "Remove the fill")
                HexColorPicker(title: "Fill", hex: shape.fill ?? model.scene.style.fill) { v in model.updateShape(shape.id) { $0.fill = v } }
                    .disabled(shape.fill == nil)
                    .opacity(shape.fill == nil ? 0.5 : 1)
            }
        }
        InspectorSection("Border") {
            HexColorPicker(title: "Stroke", hex: shape.stroke ?? model.scene.style.ink) { v in model.updateShape(shape.id) { $0.stroke = v } }
        }
        InspectorSection {
            WideButton("Extrude into a Part") {
                model.sketch = PendingSketch(plane: SketchPlane(axis: shape.axis, at: shape.at, host: shape.host), loops: shape.loops, name: shape.name)
                model.deleteAnnotation(.shape(shape.id))
            }
            .help("Turns the shape back into a sketch you can extrude, push or revolve")
        }
    }
}

struct DecalInspector: View {
    let model: SceneModel
    let decal: Decal

    var body: some View {
        InspectorSection("Decal · \(decal.kind.rawValue.capitalized)") {
            CommitField(title: "Name", text: decal.name) { v in model.updateDecal(decal.id, "Rename") { $0.name = v } }
            if decal.kind == .text {
                CommitField(title: "Text", text: decal.content) { v in model.updateDecal(decal.id, "Edit Text") { $0.content = v } }
            }
            SliderField(label: decal.kind == .text ? "Font size" : "Width", icon: decal.kind == .text ? "textformat.size" : "arrow.left.and.right",
                        value: decal.size, range: decal.kind == .text ? 4...200 : 4...1000) { v in
                model.updateDecal(decal.id, "Resize Decal") { $0.size = v }
            }
            SliderField(label: "Opacity", icon: "circle.lefthalf.filled", value: decal.opacity * 100, range: 0...100, suffix: "%") { v in
                model.updateDecal(decal.id) { $0.opacity = v / 100 }
            }
            if decal.kind != .image {
                HexColorPicker(title: "Colour", hex: decal.color ?? model.scene.style.ink) { v in model.updateDecal(decal.id) { $0.color = v } }
            }
        } accessory: {
            InspectorIconButton("trash", help: "Delete Decal", role: .destructive) { model.deleteAnnotation(.decal(decal.id)) }
        }
        InspectorSection("Placement") {
            hostPicker(model, host: decal.host) { h in model.updateDecal(decal.id, "Move Decal") { $0.host = h } }
            IconSegmented(selection: Binding(get: { IsoPlane(axis: decal.axis) }, set: { p in
                model.updateDecal(decal.id, "Change Plane") { $0.axis = p.axis }
            }), planeSegments)
            .help("Plane")
            FieldPair {
                NumberField(label: "U", value: decal.center.x, step: 1) { v in model.updateDecal(decal.id, "Move Decal") { $0.center.x = v } }
            } _: {
                NumberField(label: "V", value: decal.center.y, step: 1) { v in model.updateDecal(decal.id, "Move Decal") { $0.center.y = v } }
            }
            .help("Centre of the decal on its plane")
            FieldPair {
                NumberField(label: "Offset", value: decal.at, step: 1) { v in model.updateDecal(decal.id, "Move Decal") { $0.at = v } }
            } _: {
                Color.clear
            }
        }
    }
}

struct DimensionInspector: View {
    let model: SceneModel
    let dim: DimensionLine

    var body: some View {
        let partName = model.scene.parts.first { $0.id == dim.part }?.name ?? "Part"
        InspectorSection("Dimensions · \(partName)") {
            ToggleSegments([
                ("Width", Binding(get: { dim.width }, set: { v in model.updateDimension(dim.id) { $0.width = v } })),
                ("Depth", Binding(get: { dim.depth }, set: { v in model.updateDimension(dim.id) { $0.depth = v } })),
                ("Height", Binding(get: { dim.height }, set: { v in model.updateDimension(dim.id) { $0.height = v } })),
            ])
            .help("Which sizes to show")
            IconSegmented(selection: Binding(get: { dim.units }, set: { v in model.updateDimension(dim.id) { $0.units = v } }),
                          DimensionLine.Units.allCases.map { Segment.text($0.rawValue, $0) })
            .help("Units")
            NumberField(label: "Units per px", icon: "ruler", value: dim.scale, step: 0.1, range: 0.0001...10_000) { v in
                model.updateDimension(dim.id) { $0.scale = v }
            }
            IconSegmented(selection: Binding(get: { dim.decimals }, set: { v in model.updateDimension(dim.id) { $0.decimals = v } }),
                          [.text("1", 0), .text("0.1", 1), .text("0.01", 2), .text("0.001", 3)])
            .help("Decimals")
            SliderField(label: "Offset", icon: "arrow.up.to.line", value: dim.offset, range: 1...200) { v in
                model.updateDimension(dim.id) { $0.offset = v }
            }
            HexColorPicker(title: "Colour", hex: dim.color ?? model.scene.style.ink) { v in model.updateDimension(dim.id) { $0.color = v } }
        } accessory: {
            InspectorIconButton("trash", help: "Delete Dimensions", role: .destructive) { model.deleteAnnotation(.dimension(dim.id)) }
        }
    }
}

// MARK: - Insert

enum ArtPicker {
    static func chooseDecal(_ model: SceneModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg, .png, .jpeg, .image]
        panel.message = "Choose an SVG or image to place as a decal"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addDecal(fromFile: url)
    }

    static func chooseProfile(_ model: SceneModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg]
        panel.message = "Choose an SVG whose outlines become a sketch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importSketch(fromFile: url)
    }
}

struct InsertMenuItems: View {
    let model: SceneModel

    var body: some View {
        Button("Text Decal") { model.addTextDecal() }
        Button("SVG or Image Decal…") { ArtPicker.chooseDecal(model) }
        Divider()
        Button("Dimensions") { model.addDimensions() }.disabled(model.selection.isEmpty)
        Divider()
        Button("SVG as Sketch…") { ArtPicker.chooseProfile(model) }
    }
}
