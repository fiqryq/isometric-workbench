import AppKit
import IsoDocument
import IsoGeometry
import IsoMath
import IsoRender
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tools

struct ToolOptionsSection: View {
    @Bindable var model: SceneModel

    var body: some View {
        Section(model.tool.title) {
            Picker("Empty canvas plane", selection: $model.drawPlane) {
                ForEach(IsoPlane.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            if model.tool == .polygon {
                Stepper("Sides: \(model.polygonSides)", value: $model.polygonSides, in: 3...24)
            }
            Text(model.tool == .pen
                ? "Click to add points (⇧ for 45°). Click the first point, double-click or press Return to close."
                : "Drag on a part's face to sketch on it, or on the canvas for the \(model.drawPlane.rawValue) plane. ⇧ keeps it even.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct SketchSection: View {
    let model: SceneModel
    let sketch: PendingSketch
    @State private var depth = 20.0
    @State private var hatch = true

    var body: some View {
        Section("Sketch · \(sketch.name)") {
            NumberField(label: "Depth", value: depth, step: 5, range: 0.5...10_000) { depth = $0 }
            if sketch.plane.host != nil {
                HStack {
                    Button("Extrude") { model.extrudeSketch(depth: depth) }.keyboardShortcut(.defaultAction)
                    Button("Push In") { model.pushSketch(depth: depth, through: false) }
                    Button("Cut Through") { model.pushSketch(depth: depth, through: true) }
                }
                Button("Extrude as New Part") { model.extrudeSketch(depth: depth, asNewPart: true) }
            } else {
                Button("Extrude as New Part") { model.extrudeSketch(depth: depth) }.keyboardShortcut(.defaultAction)
            }
            if sketch.plane.axis != .z {
                Button("Revolve as New Part") { model.revolveSketch() }
            }
            HStack {
                Button("Keep as Flat Shape") { model.keepSketch(hatch: hatch) }
                Toggle("Hatched", isOn: $hatch).toggleStyle(.checkbox)
            }
            Button("Discard", role: .destructive) { model.discardSketch() }
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
        Section("Loop Rings") {
            if infos.isEmpty {
                Text("No loop cuts yet. Add one from Steps ▸ + ▸ Loop Cut, then pick rings or the faces between them.")
                    .font(.callout).foregroundStyle(.secondary)
                Menu("Add Loop Cut") {
                    Button("Horizontal") { model.addStep(.loopCut(id: Op.newLoopID(), axis: .z, count: 3), name: "Add Loop Cut") }
                    Button("Vertical L") { model.addStep(.loopCut(id: Op.newLoopID(), axis: .x, count: 3), name: "Add Loop Cut") }
                    Button("Vertical R") { model.addStep(.loopCut(id: Op.newLoopID(), axis: .y, count: 3), name: "Add Loop Cut") }
                }
            } else if rings.isEmpty && segments.isEmpty {
                Text("Click a ring to pick it (⇧ adds more), or click a face between two rings to pick that segment.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !rings.isEmpty {
                chips(rings.map { r in "Ring \(r.knot + 1)" + (infos.count > 1 ? " · \(loopName(r.loopID, infos))" : "") })
                NumberField(label: "Scale %", value: model.ringScale(rings[0]), step: 5, range: 1...500) { model.scalePickedRings($0) }
                if rings.count >= 2 {
                    NumberField(label: "Taper from %", value: taperFrom, step: 5, range: 1...500) { taperFrom = $0 }
                    NumberField(label: "Taper to %", value: taperTo, step: 5, range: 1...500) { taperTo = $0 }
                    Button("Taper Across Picked Rings") { model.taperPickedRings(from: taperFrom, to: taperTo) }
                }
                if let info = infos.first(where: { $0.loopID == rings[0].loopID }) {
                    NumberField(label: "Slide", value: part.ops[info.opIndex].num("slide", 0), step: 5, range: -100...100) { v in
                        model.setStepField(part.id, step: info.opIndex, key: "slide", value: .number(v))
                    }
                }
            }
            if !segments.isEmpty {
                chips(segments.map { "Segment \($0.segment + 1) · \($0.face.rawValue)" })
                Picker("Face", selection: $face) {
                    Text("As picked").tag(IsoPlane?.none)
                    ForEach(IsoPlane.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(IsoPlane?.some($0)) }
                }
                NumberField(label: "Depth", value: depth, step: 5, range: 0.5...10_000) { depth = $0 }
                HStack {
                    Button("Extrude") { model.pushPickedSegments(depth: depth, face: face) }
                    Button("Inset") { model.pushPickedSegments(depth: -depth, face: face) }
                }
            }
            if !rings.isEmpty || !segments.isEmpty {
                Button("Clear Picks") {
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
                        .font(.caption)
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
    Picker("On", selection: Binding(get: { host ?? "" }, set: { set($0.isEmpty ? nil : $0) })) {
        Text("World").tag("")
        ForEach(model.scene.parts) { Text($0.name).tag($0.id) }
    }
}

struct ShapeInspector: View {
    let model: SceneModel
    let shape: FlatShape

    var body: some View {
        Section("Shape") {
            CommitField(title: "Name", text: shape.name) { v in model.updateShape(shape.id, "Rename") { $0.name = v } }
            LabeledContent("Plane", value: "\(IsoPlane(axis: shape.axis).rawValue.capitalized) at \(jsNumberString(shape.at))")
            Toggle("Fill", isOn: Binding(get: { shape.fill != nil }, set: { on in
                model.updateShape(shape.id) { $0.fill = on ? model.scene.style.fill : nil }
            }))
            if let fill = shape.fill {
                HexColorPicker(title: "Fill colour", hex: fill) { v in model.updateShape(shape.id) { $0.fill = v } }
            }
            HexColorPicker(title: "Stroke", hex: shape.stroke ?? model.scene.style.ink) { v in model.updateShape(shape.id) { $0.stroke = v } }
            Toggle("Hatched", isOn: Binding(get: { shape.hatch }, set: { v in model.updateShape(shape.id) { $0.hatch = v } }))
            NumberField(label: "Opacity %", value: shape.opacity * 100, step: 10, range: 0...100) { v in
                model.updateShape(shape.id) { $0.opacity = v / 100 }
            }
            Button("Delete Shape", role: .destructive) { model.deleteAnnotation(.shape(shape.id)) }
        }
        Section {
            Button("Extrude into a Part") {
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
        Section("Decal · \(decal.kind.rawValue.capitalized)") {
            CommitField(title: "Name", text: decal.name) { v in model.updateDecal(decal.id, "Rename") { $0.name = v } }
            if decal.kind == .text {
                CommitField(title: "Text", text: decal.content) { v in model.updateDecal(decal.id, "Edit Text") { $0.content = v } }
            }
            NumberField(label: decal.kind == .text ? "Font size" : "Width", value: decal.size, step: decal.kind == .text ? 1 : 5, range: 1...5000) { v in
                model.updateDecal(decal.id, "Resize Decal") { $0.size = v }
            }
            if decal.kind != .image {
                HexColorPicker(title: "Colour", hex: decal.color ?? model.scene.style.ink) { v in model.updateDecal(decal.id) { $0.color = v } }
            }
            NumberField(label: "Opacity %", value: decal.opacity * 100, step: 10, range: 0...100) { v in
                model.updateDecal(decal.id) { $0.opacity = v / 100 }
            }
        }
        Section("Placement") {
            hostPicker(model, host: decal.host) { h in model.updateDecal(decal.id, "Move Decal") { $0.host = h } }
            Picker("Plane", selection: Binding(get: { IsoPlane(axis: decal.axis) }, set: { p in
                model.updateDecal(decal.id, "Change Plane") { $0.axis = p.axis }
            })) {
                ForEach(IsoPlane.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            NumberField(label: "Offset", value: decal.at, step: 1) { v in model.updateDecal(decal.id, "Move Decal") { $0.at = v } }
            NumberField(label: "Centre U", value: decal.center.x, step: 1) { v in model.updateDecal(decal.id, "Move Decal") { $0.center.x = v } }
            NumberField(label: "Centre V", value: decal.center.y, step: 1) { v in model.updateDecal(decal.id, "Move Decal") { $0.center.y = v } }
            Button("Delete Decal", role: .destructive) { model.deleteAnnotation(.decal(decal.id)) }
        }
    }
}

struct DimensionInspector: View {
    let model: SceneModel
    let dim: DimensionLine

    var body: some View {
        let partName = model.scene.parts.first { $0.id == dim.part }?.name ?? "Part"
        Section("Dimensions · \(partName)") {
            Toggle("Width", isOn: Binding(get: { dim.width }, set: { v in model.updateDimension(dim.id) { $0.width = v } }))
            Toggle("Depth", isOn: Binding(get: { dim.depth }, set: { v in model.updateDimension(dim.id) { $0.depth = v } }))
            Toggle("Height", isOn: Binding(get: { dim.height }, set: { v in model.updateDimension(dim.id) { $0.height = v } }))
            Picker("Units", selection: Binding(get: { dim.units }, set: { v in model.updateDimension(dim.id) { $0.units = v } })) {
                ForEach(DimensionLine.Units.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            NumberField(label: "Scale (units per px)", value: dim.scale, step: 0.1, range: 0.0001...10_000) { v in
                model.updateDimension(dim.id) { $0.scale = v }
            }
            Stepper("Decimals: \(dim.decimals)", value: Binding(get: { dim.decimals }, set: { v in model.updateDimension(dim.id) { $0.decimals = v } }), in: 0...3)
            NumberField(label: "Offset", value: dim.offset, step: 4, range: 1...400) { v in model.updateDimension(dim.id) { $0.offset = v } }
            HexColorPicker(title: "Colour", hex: dim.color ?? model.scene.style.ink) { v in model.updateDimension(dim.id) { $0.color = v } }
            Button("Delete Dimensions", role: .destructive) { model.deleteAnnotation(.dimension(dim.id)) }
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
