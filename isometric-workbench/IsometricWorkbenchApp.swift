import IsoDocument
import IsoExamples
import IsoGeometry
import IsoMath
import SwiftUI
import UniformTypeIdentifiers

@main
struct IsometricWorkbenchApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { SceneDocument() }) { file in
            DocumentView(document: file.document)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { WorkbenchCommands() }

        Settings {
            SettingsView()
        }
    }
}

extension FocusedValues {
    @Entry var sceneModel: SceneModel?
}

struct WorkbenchCommands: Commands {
    @FocusedValue(\.sceneModel) private var model

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export SVG…") { model.map { Exporter.save($0, as: .svg) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Export PDF…") { model.map { Exporter.save($0, as: .pdf) } }
                .disabled(model == nil)
            Button("Export PNG…") { model.map { Exporter.save($0, as: .png) } }
                .disabled(model == nil)
            Button("Export Animation…") { model?.presentVideoExport = true }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model == nil)
        }
        CommandGroup(after: .appInfo) {
            Button("Unlock Workbench Pro…") { model?.presentPaywall = true }
                .disabled(model == nil || Store.shared.isPro)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy as SVG") { model.map(Exporter.copySVG) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Duplicate") { model?.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(model?.selection.isEmpty ?? true)
        }
        CommandGroup(before: .toolbar) {
            Button("Zoom to Fit") { model?.zoomToFit() }
                .keyboardShortcut("0")
            Button("Zoom In") { model?.zoom(by: 1.25) }
                .keyboardShortcut("+")
            Button("Zoom Out") { model?.zoom(by: 0.8) }
                .keyboardShortcut("-")
            Divider()
        }
        CommandMenu("Tools") {
            ForEach(Tool.allCases) { t in
                Button(t.title) { model?.tool = t }
                    .disabled(model == nil)
            }
        }
        CommandMenu("Insert") {
            if let model {
                InsertMenuItems(model: model)
            } else {
                Button("Text Decal") {}.disabled(true)
            }
        }
        CommandMenu("Part") {
            Menu("Add Primitive") {
                ForEach(PrimitiveSpec.all) { spec in
                    Button(spec.name) { model?.addPrimitive(spec) }
                }
            }
            Divider()
            Button("Combine") { model?.combineSelection() }
                .keyboardShortcut("j")
                .disabled((model?.selection.count ?? 0) < 2)
            Button("Hide / Show") { model?.toggleHidden() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Lock / Unlock") { model?.toggleLocked() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Delete") { model?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model?.selection.isEmpty ?? true && model?.annotation == nil)
        }
        CommandMenu("Animation") {
            Button(model?.isPlaying == true ? "Pause" : "Play") { model?.togglePlay() }
                .keyboardShortcut(.return, modifiers: [.command])
            Button("Go to Start") { model?.seek(0) }
            Button("Add Keyframe") { model?.addKeyframe() }
                .keyboardShortcut("k")
            Divider()
            ForEach(AnimationPreset.allCases) { preset in
                Button(preset.title) { model?.applyPreset(preset) }
            }
        }
    }
}
