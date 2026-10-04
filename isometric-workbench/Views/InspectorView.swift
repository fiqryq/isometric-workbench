import IsoDocument
import IsoExamples
import IsoGeometry
import IsoMath
import IsoRender
import SwiftUI

struct InspectorView: View {
    @Bindable var model: SceneModel

    var body: some View {
        InspectorStack {
            if let sketch = model.sketch {
                SketchSection(model: model, sketch: sketch)
            }
            if model.tool.draws && model.sketch == nil {
                ToolOptionsSection(model: model)
            }
            if model.annotation == nil, model.selectedBoard == nil, !model.selection.isEmpty {
                AlignmentBar(model: model)
            }
            if let a = model.annotation {
                AnnotationInspector(model: model, ref: a)
            } else if let board = model.selectedBoard {
                FrameInspector(model: model, board: board)
            } else if let i = model.selectedIndex {
                PartInspector(model: model, part: model.scene.parts[i])
            } else if model.selection.count > 1 {
                InspectorSection("\(model.selection.count) Parts") {
                    WideButton("Combine into First Part", action: model.combineSelection)
                } accessory: {
                    InspectorIconButton("plus.square.on.square", help: "Duplicate", action: model.duplicateSelection)
                    InspectorIconButton("eye", help: "Hide / Show", action: model.toggleHidden)
                    InspectorIconButton("trash", help: "Delete", role: .destructive, action: model.deleteSelection)
                }
            } else {
                SceneInspector(model: model)
            }
        }
    }
}

/// Sketch's alignment row: six align buttons, a dot, then distribute.
struct AlignmentBar: View {
    let model: SceneModel

    var body: some View {
        let align = model.canAlign, spread = model.canDistribute
        InspectorSection {
            HStack(spacing: 4) {
                IconButtonRow(AlignEdge.allCases.map { e in
                    .init(symbol: e.symbol, help: e.title, disabled: !align) { model.align(e) }
                })
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 3, height: 3)
                IconButtonRow([
                    .init(symbol: "distribute.horizontal.center", help: "Distribute Horizontally", disabled: !spread) { model.distribute(horizontally: true) },
                    .init(symbol: "distribute.vertical.center", help: "Distribute Vertically", disabled: !spread) { model.distribute(horizontally: false) },
                ])
                .frame(width: 56)
            }
        }
    }
}

// MARK: - Scene

struct SceneInspector: View {
    let model: SceneModel

    private var scene: SceneFile { model.scene }

    var body: some View {
        InspectorSection("Drawing") {
            CommitField(title: "Name", text: scene.name) { v in model.edit("Rename Drawing") { $0.name = v } }
            IconSegmented(selection: Binding(get: { scene.angle < 28 ? 26.565 : 30 }, set: { v in
                model.edit("Change Projection") { $0.angle = v }
            }), [.text("Isometric 30°", 30.0), .text("Pixel 2:1", 26.565)])
            .help("Projection")
        }
        InspectorSection("Style") {
            PopupField("Palette", icon: "paintpalette", selection: Binding(get: { scene.style.preset ?? "" }, set: { id in
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
            FieldPair {
                NumberField(label: "Line weight", icon: "lineweight", value: scene.style.weight, step: 0.25, range: 0.25...8) { v in
                    model.edit("Change Line Weight") { $0.style.weight = v }
                }
            } _: {
                NumberField(label: "Hatch gap", icon: "line.diagonal", value: scene.style.gap, step: 1, range: 2...40) { v in
                    model.edit("Change Hatch Gap") { $0.style.gap = v }
                }
            }
        }
        InspectorSection("Frames") {
            if scene.frames.isEmpty {
                InspectorNote("Press A to draw a frame, or ⌥⌘G to frame the parts.")
            }
            ForEach(scene.frames) { f in
                Button { model.selectFrame(f.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "number").foregroundStyle(.secondary)
                        Text(f.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(f.children.count)").monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .font(InspectorMetrics.font)
                }
                .buttonStyle(FieldButtonStyle())
                .help("Select \(f.name)")
            }
        } accessory: {
            SectionAddButton(help: "Frame the parts (⌥⌘G)", action: model.frameSelection)
        }
        InspectorSection("Animation") {
            FieldPair {
                NumberField(label: "Duration", icon: "timer", value: scene.duration, step: 0.5, range: 0.5...600, suffix: "s") { v in
                    model.edit("Change Duration") { $0.duration = v }
                }
            } _: {
                NumberField(label: "FPS", value: scene.fps, step: 1, range: 1...120) { v in
                    model.edit("Change Frame Rate") { $0.fps = v.rounded() }
                }
            }
            FieldPair {
                NumberField(label: "Camera spin", icon: "rotate.3d", value: scene.camera.value("spin", at: model.frameTime), step: 15, suffix: "°") { v in
                    let t = model.frameTime, auto = model.autoKey
                    model.edit("Orbit Camera") { $0.camera.set("spin", v, at: t, autoKey: auto) }
                }
            } _: {
                Color.clear
            }
        }
        InspectorSection {
            InspectorNote("Click a part to edit it. R, O, G, P draw; L picks rings.")
                .help("Drag to move, ⇧-drag to lift, ⌥-drag to spin. ⌘-click a face to extrude it. Drag the background to pan, ⌥-drag it to orbit.")
        }
    }
}

// MARK: - Part

struct PartInspector: View {
    let model: SceneModel
    let part: Part
    @State private var faceDepth = 10.0

    var body: some View {
        InspectorSection("Part") {
            CommitField(title: "Name", text: part.name) { v in model.updatePart(part.id, "Rename") { $0.name = v } }
            if let error = model.build.errors[part.id] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } accessory: {
            InspectorIconToggle(on: "eye.slash", off: "eye", help: part.hidden ? "Show" : "Hide",
                                isOn: Binding(get: { part.hidden }, set: { v in model.updatePart(part.id, v ? "Hide" : "Show") { $0.hidden = v } }))
            InspectorIconToggle(on: "lock.fill", off: "lock.open", help: part.locked ? "Unlock" : "Lock",
                                isOn: Binding(get: { part.locked }, set: { v in model.updatePart(part.id, v ? "Lock" : "Unlock") { $0.locked = v } }))
        }
        InspectorSection("Transform") {
            FieldPair { transformRow("X", "x") } _: { transformRow("Y", "y") }
            FieldPair { transformRow("Z", "z") } _: {
                transformRow("Opacity", "opacity", icon: "circle.lefthalf.filled", suffix: "%", step: 10, range: 0...100)
            }
            FieldPair { transformRow("Spin", "spin", icon: "rotate.right", suffix: "°", step: 15) } _: {
                transformRow("Tilt", "tilt", suffix: "°", step: 15)
            }
            FieldPair { transformRow("Roll", "roll", suffix: "°", step: 15) } _: { Color.clear }
        }
        InspectorSection("Style") {
            HexColorPicker(title: "Fill", hex: part.style.fill ?? model.scene.style.fill, onCommit: { v in
                model.updatePart(part.id, "Change Fill") { $0.style.fill = v }
            }, onReset: part.style.fill == nil ? nil : {
                model.updatePart(part.id, "Reset Fill") { $0.style.fill = nil }
            })
            FieldPair {
                NumberField(label: "Line weight", icon: "lineweight", value: part.style.weight ?? model.scene.style.weight, step: 0.25, range: 0.25...8) { v in
                    model.updatePart(part.id, "Change Line Weight") { $0.style.weight = v }
                }
            } _: {
                NumberField(label: "Smooth", value: part.smooth, step: 5, range: 0...90, suffix: "°") { v in
                    model.updatePart(part.id, "Change Smoothing") { $0.smooth = v }
                }
            }
            .help("Line weight and the angle below which edges are smoothed away")
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

    private func transformRow(_ label: String, _ prop: String, icon: String? = nil, suffix: String? = nil, step: Double = 1,
                              range: ClosedRange<Double> = -100_000...100_000) -> some View {
        let t = model.frameTime
        let keyed = part.anim.keys[prop]?.contains { abs($0.t - t) < 1e-3 } ?? false
        let key = KeyButton(animated: part.anim.isAnimated(prop), keyed: keyed) {
            model.updatePart(part.id, keyed ? "Remove Key" : "Add Key") { p in
                if keyed { p.anim.removeKey(prop, t: t) } else { p.anim.setKey(prop, t: t, v: p.anim.value(prop, at: t)) }
            }
        }
        return NumberField(label: label, icon: icon, value: model.value(prop, of: part), step: step, range: range, suffix: suffix, key: key) { v in
            model.setProperty(prop, v, for: [part.id])
        }
        .contextMenu {
            if part.anim.isAnimated(prop) { Button("Remove Animation") { model.clearKeys(of: part.id, prop: prop) } }
        }
    }

    private var facesSection: some View {
        let faces = model.pickedFaces.filter { $0.partID == part.id }
        return InspectorSection("Picked Faces") {
            ForEach(faces, id: \.self) { f in
                ValueField(label: "Face", icon: "square.on.square.dashed", value: f.face.name)
            }
            NumberField(label: "Depth", value: faceDepth, step: 5, range: 0.5...10_000) { faceDepth = $0 }
            HStack(spacing: InspectorMetrics.rowSpacing) {
                WideButton("Extrude", prominent: true) { model.pushFaces(depth: faceDepth) }
                WideButton("Push In") { model.pushFaces(depth: -faceDepth) }
            }
        } accessory: {
            InspectorIconButton("xmark", help: "Clear picked faces") { model.pickedFaces.removeAll { $0.partID == part.id } }
        }
    }

    private var dimensions: some View {
        let dims = model.scene.dimensions.filter { $0.part == part.id }
        return InspectorSection("Dimensions") {
            ForEach(dims) { d in
                Button {
                    model.annotation = .dimension(d.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ruler").foregroundStyle(.secondary)
                        Text([d.width ? "W" : nil, d.depth ? "D" : nil, d.height ? "H" : nil].compactMap { $0 }.joined(separator: " · "))
                        Spacer(minLength: 4)
                        Text(d.units.rawValue).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .font(InspectorMetrics.font)
                }
                .buttonStyle(FieldButtonStyle())
            }
        } accessory: {
            if dims.isEmpty {
                SectionAddButton(help: "Add dimensions", action: model.addDimensions)
            }
        }
        .dimmed(dims.isEmpty)
    }

    private var callouts: some View {
        InspectorSection("Callouts") {
            ForEach(Array(part.callouts.enumerated()), id: \.element.id) { i, c in
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    HStack(spacing: 4) {
                        CommitField(title: "\(i + 1)", text: c.text) { v in model.updatePart(part.id, "Edit Callout") { $0.callouts[i].text = v } }
                        NumberField(label: "Reach", icon: "arrow.up.right", value: c.reach, step: 10, range: 0...2000) { v in
                            model.updatePart(part.id, "Edit Callout") { $0.callouts[i].reach = v }
                        }
                        .frame(width: 76)
                        .padding(.leading, 4)
                        InspectorIconButton("minus", help: "Remove callout") {
                            model.updatePart(part.id, "Remove Callout") { $0.callouts.remove(at: i) }
                        }
                    }
                    IconSegmented(selection: Binding(get: { c.side?.rawValue ?? "auto" }, set: { v in
                        model.updatePart(part.id, "Edit Callout") { $0.callouts[i].side = CalloutSide(rawValue: v) }
                    }), [.text("Auto", "auto")] + CalloutSide.allCases.map { Segment.text($0.rawValue.capitalized, $0.rawValue) })
                    .help("Side")
                    .padding(.trailing, 26)
                }
                .padding(.bottom, 4)
            }
        } accessory: {
            SectionAddButton(help: "Add a callout") {
                model.updatePart(part.id, "Add Callout") { $0.callouts.append(Callout(text: $0.name)) }
            }
        }
        .dimmed(part.callouts.isEmpty)
    }
}

// MARK: - Steps

struct StepsSection: View {
    let model: SceneModel
    let part: Part

    var body: some View {
        InspectorSection("Steps") {
            ForEach(Array(part.ops.enumerated()), id: \.offset) { i, op in
                StepRow(model: model, part: part, index: i, op: op)
            }
        } accessory: {
            addMenu
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
        .menuStyle(.button)
        .buttonStyle(InspectorIconButtonStyle())
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
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { op.enabled }, set: { _ in model.toggleStep(part.id, step: index) })) {
                    Text(display.label).fontWeight(.medium).lineLimit(1)
                }
                .labeledContentStyle(.automatic)
                .disabled(index == 0)
                Spacer(minLength: 0)
                Menu {
                    Button("Move Up") { model.moveStep(part.id, step: index, by: -1) }.disabled(index <= 1)
                    Button("Move Down") { model.moveStep(part.id, step: index, by: 1) }.disabled(index == 0 || index == part.ops.count - 1)
                    Divider()
                    Button("Delete Step", role: .destructive) { model.deleteStep(part.id, step: index) }.disabled(part.ops.count <= 1)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(InspectorIconButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Step actions")
            }
            .frame(minHeight: 24)
            if op.enabled {
                ForEach(Array(Self.rows(display.fields).enumerated()), id: \.offset) { _, row in
                    if row.count == 2 {
                        FieldPair { field(row[0]) } _: { field(row[1]) }
                    } else if row[0].kind == .number {
                        FieldPair { field(row[0]) } _: { Color.clear }
                    } else {
                        field(row[0])
                    }
                }
                if op.type == "loopcut" {
                    let scales = (op["scales"]?.array ?? []).map { $0.jsNumber ?? 100 }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: InspectorMetrics.rowSpacing) {
                        ForEach(Array(scales.enumerated()), id: \.offset) { j, s in
                            NumberField(label: "R\(j + 1) %", value: s, step: 5, range: 1...500) { v in
                                model.setStepField(part.id, step: index, key: "scales.\(j)", value: .number(v))
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(op.enabled ? 1 : 0.55)
    }

    @ViewBuilder private func field(_ field: OpDisplay.Field) -> some View {
        switch field.kind {
        case .number:
            NumberField(label: field.label, value: op.num(field.key, 0), step: field.step) { v in
                model.setStepField(part.id, step: index, key: field.key, value: .number(v))
            }
        case .bool:
            InspectorRow {
                Toggle(field.label, isOn: Binding(get: { op.truthy(field.key) }, set: { v in
                    model.setStepField(part.id, step: index, key: field.key, value: .bool(v))
                }))
            }
        }
    }

    /// Short numeric fields go two to a row, like Sketch's W | H.
    private static func rows(_ fields: [OpDisplay.Field]) -> [[OpDisplay.Field]] {
        var rows: [[OpDisplay.Field]] = []
        for f in fields {
            if f.kind == .number, f.label.count <= 8, let last = rows.last, last.count == 1,
               last[0].kind == .number, last[0].label.count <= 8 {
                rows[rows.count - 1].append(f)
            } else {
                rows.append([f])
            }
        }
        return rows
    }
}
