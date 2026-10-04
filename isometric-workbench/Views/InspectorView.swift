import IsoDocument
import IsoExamples
import IsoGeometry
import IsoMath
import IsoRender
import SwiftUI

struct InspectorView: View {
    @Bindable var model: SceneModel

    var body: some View {
        Form {
            if let sketch = model.sketch {
                SketchSection(model: model, sketch: sketch)
            }
            if model.tool.draws && model.sketch == nil {
                ToolOptionsSection(model: model)
            }
            if let a = model.annotation {
                AnnotationInspector(model: model, ref: a)
            } else if let i = model.selectedIndex {
                PartInspector(model: model, part: model.scene.parts[i])
            } else if model.selection.count > 1 {
                Section("\(model.selection.count) Parts") {
                    Button("Combine into First Part", action: model.combineSelection)
                    Button("Duplicate", action: model.duplicateSelection)
                    Button("Hide / Show", action: model.toggleHidden)
                    Button("Delete", role: .destructive, action: model.deleteSelection)
                }
            } else {
                SceneInspector(model: model)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Scene

struct SceneInspector: View {
    let model: SceneModel

    private var scene: SceneFile { model.scene }

    var body: some View {
        Section("Drawing") {
            CommitField(title: "Name", text: scene.name) { v in model.edit("Rename Drawing") { $0.name = v } }
            Picker("Projection", selection: Binding(get: { scene.angle < 28 ? 26.565 : 30 }, set: { v in
                model.edit("Change Projection") { $0.angle = v }
            })) {
                Text("Isometric 30°").tag(30.0)
                Text("Pixel 2:1").tag(26.565)
            }
        }
        Section("Style") {
            Picker("Palette", selection: Binding(get: { scene.style.preset ?? "" }, set: { id in
                guard let p = Palette.all.first(where: { $0.id == id }) else { return }
                model.edit("Change Palette") { s in
                    s.style.ink = p.ink
                    s.style.fill = p.fill
                    s.style.preset = p.id
                }
            })) {
                ForEach(Palette.all) { Text($0.name).tag($0.id) }
                if scene.style.preset == nil { Text("Custom").tag("") }
            }
            HexColorPicker(title: "Ink", hex: scene.style.ink) { v in model.edit("Change Ink") { $0.style.ink = v; $0.style.preset = nil } }
            HexColorPicker(title: "Fill", hex: scene.style.fill) { v in model.edit("Change Fill") { $0.style.fill = v; $0.style.preset = nil } }
            HexColorPicker(title: "Paper", hex: scene.style.bg) { v in model.edit("Change Paper") { $0.style.bg = v } }
            NumberField(label: "Line weight", value: scene.style.weight, step: 0.25, range: 0.25...8) { v in
                model.edit("Change Line Weight") { $0.style.weight = v }
            }
            NumberField(label: "Hatch gap", value: scene.style.gap, step: 1, range: 2...40) { v in
                model.edit("Change Hatch Gap") { $0.style.gap = v }
            }
        }
        Section("Sheet") {
            Toggle("Show drawing sheet", isOn: Binding(get: { scene.sheet.visible }, set: { v in
                model.edit(v ? "Show Sheet" : "Hide Sheet") { $0.sheet.visible = v }
            }))
            if scene.sheet.visible {
                CommitField(title: "Figure", text: scene.sheet.fig) { v in model.edit("Edit Sheet") { $0.sheet.fig = v } }
                CommitField(title: "Title", text: scene.sheet.title) { v in model.edit("Edit Sheet") { $0.sheet.title = v } }
                CommitField(title: "Year", text: scene.sheet.year) { v in model.edit("Edit Sheet") { $0.sheet.year = v } }
                NumberField(label: "Grid", value: scene.sheet.grid, step: 4, range: 4...200) { v in
                    model.edit("Edit Sheet") { $0.sheet.grid = v }
                }
            }
        }
        Section("Animation") {
            NumberField(label: "Duration (s)", value: scene.duration, step: 0.5, range: 0.5...600) { v in
                model.edit("Change Duration") { $0.duration = v }
            }
            NumberField(label: "Frame rate", value: scene.fps, step: 1, range: 1...120) { v in
                model.edit("Change Frame Rate") { $0.fps = v.rounded() }
            }
            NumberField(label: "Camera spin°", value: scene.camera.value("spin", at: model.frameTime), step: 15) { v in
                let t = model.frameTime, auto = model.autoKey
                model.edit("Orbit Camera") { $0.camera.set("spin", v, at: t, autoKey: auto) }
            }
        }
        Section {
            Text("Click a part to select it. Drag to move, ⇧-drag to lift, ⌥-drag to spin. ⌘-click a face to extrude it. Drag the background to pan, ⌥-drag it to orbit. R, O, G and P draw rectangles, ellipses, polygons and pen paths; L picks loop rings.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Part

struct PartInspector: View {
    let model: SceneModel
    let part: Part
    @State private var faceDepth = 10.0

    var body: some View {
        Section("Part") {
            CommitField(title: "Name", text: part.name) { v in model.updatePart(part.id, "Rename") { $0.name = v } }
            Toggle("Hidden", isOn: Binding(get: { part.hidden }, set: { v in model.updatePart(part.id, v ? "Hide" : "Show") { $0.hidden = v } }))
            Toggle("Locked", isOn: Binding(get: { part.locked }, set: { v in model.updatePart(part.id, v ? "Lock" : "Unlock") { $0.locked = v } }))
            if let error = model.build.errors[part.id] {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
        }
        Section("Transform") {
            transformRow("X", "x")
            transformRow("Y", "y")
            transformRow("Z", "z")
            transformRow("Spin°", "spin", step: 15)
            transformRow("Tilt°", "tilt", step: 15)
            transformRow("Roll°", "roll", step: 15)
            transformRow("Opacity %", "opacity", step: 10, range: 0...100)
        }
        Section("Style") {
            HStack {
                HexColorPicker(title: "Fill", hex: part.style.fill ?? model.scene.style.fill) { v in
                    model.updatePart(part.id, "Change Fill") { $0.style.fill = v }
                }
                if part.style.fill != nil {
                    Button("Reset") { model.updatePart(part.id, "Reset Fill") { $0.style.fill = nil } }.controlSize(.small)
                }
            }
            NumberField(label: "Line weight", value: part.style.weight ?? model.scene.style.weight, step: 0.25, range: 0.25...8) { v in
                model.updatePart(part.id, "Change Line Weight") { $0.style.weight = v }
            }
            NumberField(label: "Smooth edges°", value: part.smooth, step: 5, range: 0...90) { v in
                model.updatePart(part.id, "Change Smoothing") { $0.smooth = v }
            }
        }
        if model.tool == .rings || model.pickedRings.contains(where: { $0.partID == part.id })
            || model.pickedSegments.contains(where: { $0.partID == part.id }) {
            RingsSection(model: model, part: part)
        }
        if !model.pickedFaces.filter({ $0.partID == part.id }).isEmpty { facesSection }
        dimensions
        callouts
        StepsSection(model: model, part: part)
    }

    private func transformRow(_ label: String, _ prop: String, step: Double = 1, range: ClosedRange<Double> = -100_000...100_000) -> some View {
        let t = model.frameTime
        let keyed = part.anim.keys[prop]?.contains { abs($0.t - t) < 1e-3 } ?? false
        return HStack(spacing: 6) {
            KeyButton(animated: part.anim.isAnimated(prop), keyed: keyed) {
                model.updatePart(part.id, keyed ? "Remove Key" : "Add Key") { p in
                    if keyed { p.anim.removeKey(prop, t: t) } else { p.anim.setKey(prop, t: t, v: p.anim.value(prop, at: t)) }
                }
            }
            NumberField(label: label, value: model.value(prop, of: part), step: step, range: range) { v in
                model.setProperty(prop, v, for: [part.id])
            }
        }
        .contextMenu {
            if part.anim.isAnimated(prop) { Button("Remove Animation") { model.clearKeys(of: part.id, prop: prop) } }
        }
    }

    private var facesSection: some View {
        let faces = model.pickedFaces.filter { $0.partID == part.id }
        return Section("Picked Faces") {
            ForEach(faces, id: \.self) { f in Label("Face · \(f.face.name)", systemImage: "square.on.square.dashed") }
            NumberField(label: "Depth", value: faceDepth, step: 5, range: 0.5...10_000) { faceDepth = $0 }
            HStack {
                Button("Extrude") { model.pushFaces(depth: faceDepth) }
                Button("Push In") { model.pushFaces(depth: -faceDepth) }
                Spacer()
                Button("Clear") { model.pickedFaces.removeAll { $0.partID == part.id } }
            }
        }
    }

    private var dimensions: some View {
        Section("Dimensions") {
            ForEach(model.scene.dimensions.filter { $0.part == part.id }) { d in
                Button {
                    model.annotation = .dimension(d.id)
                } label: {
                    Label([d.width ? "W" : nil, d.depth ? "D" : nil, d.height ? "H" : nil].compactMap { $0 }.joined(separator: " · ") + " in \(d.units.rawValue)",
                          systemImage: "ruler")
                }
                .buttonStyle(.borderless)
            }
            if !model.scene.dimensions.contains(where: { $0.part == part.id }) {
                Button("Add Dimensions") { model.addDimensions() }
            }
        }
    }

    private var callouts: some View {
        Section {
            ForEach(Array(part.callouts.enumerated()), id: \.element.id) { i, c in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        CommitField(title: "Label", text: c.text) { v in model.updatePart(part.id, "Edit Callout") { $0.callouts[i].text = v } }
                        Button(role: .destructive) {
                            model.updatePart(part.id, "Remove Callout") { $0.callouts.remove(at: i) }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                    Picker("Side", selection: Binding(get: { c.side?.rawValue ?? "auto" }, set: { v in
                        model.updatePart(part.id, "Edit Callout") { $0.callouts[i].side = CalloutSide(rawValue: v) }
                    })) {
                        Text("Auto").tag("auto")
                        ForEach(CalloutSide.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                    }
                    NumberField(label: "Reach", value: c.reach, step: 10, range: 0...2000) { v in
                        model.updatePart(part.id, "Edit Callout") { $0.callouts[i].reach = v }
                    }
                }
            }
            Button("Add Callout") {
                model.updatePart(part.id, "Add Callout") { $0.callouts.append(Callout(text: $0.name)) }
            }
        } header: {
            Text("Callouts")
        }
    }
}

// MARK: - Steps

struct StepsSection: View {
    let model: SceneModel
    let part: Part

    var body: some View {
        Section {
            ForEach(Array(part.ops.enumerated()), id: \.offset) { i, op in
                StepRow(model: model, part: part, index: i, op: op)
            }
        } header: {
            HStack {
                Text("Steps")
                Spacer()
                addMenu
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Menu("Section") {
                ForEach(Op.SectionPreset.allCases, id: \.self) { p in
                    Button(p.rawValue.capitalized) { model.addStep(.section(p), name: "Add Section") }
                }
            }
            Menu("Loop Cut") {
                Button("Horizontal") { model.addStep(.loopCut(id: Op.newLoopID(), axis: .z, count: 1), name: "Add Loop Cut") }
                Button("Vertical L") { model.addStep(.loopCut(id: Op.newLoopID(), axis: .x, count: 1), name: "Add Loop Cut") }
                Button("Vertical R") { model.addStep(.loopCut(id: Op.newLoopID(), axis: .y, count: 1), name: "Add Loop Cut") }
            }
            Menu("Union Primitive") {
                ForEach(PrimitiveSpec.all) { spec in
                    Button(spec.name) {
                        model.addStep(.merge([spec.op], name: spec.name, offset: .zero), name: "Add \(spec.name)")
                    }
                }
            }
            Menu("Subtract Primitive") {
                ForEach(PrimitiveSpec.all) { spec in
                    Button(spec.name) {
                        model.addStep(.merge([spec.op], mode: "subtract", name: spec.name, offset: .zero), name: "Subtract \(spec.name)")
                    }
                }
            }
            Divider()
            Menu("Mirror") {
                ForEach(Axis.allCases, id: \.self) { a in Button(a.rawValue.uppercased()) { model.addStep(.mirror(axis: a), name: "Add Mirror") } }
            }
            Menu("Array") {
                ForEach(Axis.allCases, id: \.self) { a in Button(a.rawValue.uppercased()) { model.addStep(.array(axis: a), name: "Add Array") } }
            }
            Button("Radial Array") { model.addStep(.radial(), name: "Add Radial Array") }
            Button("Move") { model.addStep(.move(x: 0, y: 0, z: 0), name: "Add Move") }
            Button("Scale") { model.addStep(.scale(x: 100, y: 100, z: 100), name: "Add Scale") }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a step")
    }
}

struct StepRow: View {
    let model: SceneModel
    let part: Part
    let index: Int
    let op: Op

    var body: some View {
        let display = op.display
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(get: { op.enabled }, set: { _ in model.toggleStep(part.id, step: index) })) {
                    Text(display.label).fontWeight(.medium)
                }
                .toggleStyle(.checkbox)
                .disabled(index == 0)
                Spacer()
                Menu {
                    Button("Move Up") { model.moveStep(part.id, step: index, by: -1) }.disabled(index <= 1)
                    Button("Move Down") { model.moveStep(part.id, step: index, by: 1) }.disabled(index == 0 || index == part.ops.count - 1)
                    Divider()
                    Button("Delete Step", role: .destructive) { model.deleteStep(part.id, step: index) }.disabled(part.ops.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if op.enabled {
                ForEach(display.fields) { field in
                    switch field.kind {
                    case .number:
                        NumberField(label: field.label, value: op.num(field.key, 0), step: field.step) { v in
                            model.setStepField(part.id, step: index, key: field.key, value: .number(v))
                        }
                    case .bool:
                        Toggle(field.label, isOn: Binding(get: { op.truthy(field.key) }, set: { v in
                            model.setStepField(part.id, step: index, key: field.key, value: .bool(v))
                        }))
                    }
                }
                if op.type == "loopcut" {
                    let scales = (op["scales"]?.array ?? []).map { $0.jsNumber ?? 100 }
                    ForEach(Array(scales.enumerated()), id: \.offset) { j, s in
                        NumberField(label: "Ring \(j + 1) %", value: s, step: 5, range: 1...500) { v in
                            model.setStepField(part.id, step: index, key: "scales.\(j)", value: .number(v))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(op.enabled ? 1 : 0.55)
    }
}
