import IsoDocument
import IsoExamples
import IsoGeometry
import IsoMath
import SwiftUI

struct SidebarView: View {
    @Bindable var model: SceneModel
    @Environment(\.newDocument) private var newDocument

    var body: some View {
        List(selection: $model.selection) {
            Section("Add") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)], spacing: 6) {
                    ForEach(PrimitiveSpec.all) { spec in
                        Button { model.addPrimitive(spec) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: Self.symbol(spec.id)).font(.system(size: 16))
                                Text(spec.name).font(.caption2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Add a \(spec.name.lowercased())")
                    }
                }
                .padding(.vertical, 4)
                .selectionDisabled()
            }
            Section("Examples") {
                ForEach(Example.all) { ex in
                    Button { open(ex) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ex.title)
                                Text(ex.fig).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.richtext")
                        }
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                }
            }
            Section("Parts") {
                ForEach(model.scene.parts) { part in
                    PartRow(model: model, part: part)
                        .tag(part.id)
                        .contextMenu { menu(for: part) }
                }
                .onMove { model.movePart(from: $0, to: $1) }
            }
            if !model.scene.shapes.isEmpty || !model.scene.decals.isEmpty {
                Section("Flat Art") {
                    ForEach(model.scene.shapes) { s in
                        artRow(s.name, symbol: s.hatch ? "square.dashed.inset.filled" : "square.on.square.dashed", ref: .shape(s.id))
                    }
                    ForEach(model.scene.decals) { d in
                        artRow(d.name, symbol: d.kind == .text ? "textformat" : d.kind == .svg ? "scribble.variable" : "photo", ref: .decal(d.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func open(_ ex: Example) {
        if model.scene.isEmpty {
            model.loadExample(ex)
        } else {
            let scene = ex.scene(style: model.scene.style, angle: model.scene.angle)
            newDocument { SceneDocument(scene: scene) }
        }
    }

    private func artRow(_ name: String, symbol: String, ref: AnnotationRef) -> some View {
        Button {
            model.selection = []
            model.annotation = ref
        } label: {
            Label(name, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(model.annotation == ref ? Color.accentColor.opacity(0.2) : .clear))
        .selectionDisabled()
        .contextMenu { Button("Delete", role: .destructive) { model.deleteAnnotation(ref) } }
    }

    @ViewBuilder private func menu(for part: Part) -> some View {
        Button("Duplicate") {
            if !model.selection.contains(part.id) { model.selection = [part.id] }
            model.duplicateSelection()
        }
        Button(part.hidden ? "Show" : "Hide") { model.updatePart(part.id, part.hidden ? "Show" : "Hide") { $0.hidden.toggle() } }
        Button(part.locked ? "Unlock" : "Lock") { model.updatePart(part.id, part.locked ? "Unlock" : "Lock") { $0.locked.toggle() } }
        Divider()
        Button("Delete", role: .destructive) {
            if !model.selection.contains(part.id) { model.selection = [part.id] }
            model.deleteSelection()
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "box": "cube"
        case "cylinder": "cylinder"
        case "sphere": "circle.circle"
        case "cone": "cone"
        case "tube": "cylinder.split.1x2"
        case "torus": "circle.dashed"
        case "prism": "hexagon"
        case "wedge": "triangle"
        case "stairs": "stairs"
        default: "square"
        }
    }
}

struct PartRow: View {
    let model: SceneModel
    let part: Part

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: part.ops.count > 1 ? "cube.transparent" : "cube")
                .foregroundStyle(.secondary)
            Text(part.name)
                .lineLimit(1)
                .foregroundStyle(part.hidden ? .secondary : .primary)
            Spacer(minLength: 4)
            if model.build.errors[part.id] != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(model.build.errors[part.id] ?? "")
            }
            if part.anim.isAnimated {
                Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(.secondary).help("Animated")
            }
            if part.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            Button {
                model.updatePart(part.id, part.hidden ? "Show" : "Hide") { $0.hidden.toggle() }
            } label: {
                Image(systemName: part.hidden ? "eye.slash" : "eye").font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }
}
