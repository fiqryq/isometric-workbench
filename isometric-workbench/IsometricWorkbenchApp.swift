import IsoDocument
import IsoExamples
import IsoGeometry
import IsoMath
import SwiftUI
import UniformTypeIdentifiers

@main
enum Launcher {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
        } else {
            IsometricWorkbenchApp.main()
        }
    }
}

/// Hosts the unit tests with no windows, so no UI (tooltips, timers,
/// thumbnails) runs underneath them.
struct TestHostApp: App {
    init() {
        // A test host that restores old document windows can't quit cleanly.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct IsometricWorkbenchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        // Listen for purchases (e.g. Ask to Buy approvals) from launch.
        _ = Store.shared
    }

    var body: some Scene {
        Window("Home", id: HomeWindow.id) {
            HomeView()
                .frame(minWidth: 760, minHeight: 480)
                .modifier(CaptureOpenWindow())
        }
        .defaultSize(width: 1180, height: 760)
        .commands { HomeCommands() }

        DocumentGroup(newDocument: { SceneDocument() }) { file in
            DocumentView(document: file.document, fileURL: file.fileURL)
        }
        .windowStyle(.hiddenTitleBar)
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

struct CaptureOpenWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { HomeWindow.openAction = openWindow }
    }
}

struct HomeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { HomeActions.createBlank() }
                .keyboardShortcut("n")
            Button("Open…") { NSDocumentController.shared.openDocument(nil) }
                .keyboardShortcut("o")
        }
        CommandGroup(before: .windowList) {
            Button("Home") { openWindow(id: HomeWindow.id) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
        }
    }
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
            Menu("Align") {
                ForEach(AlignEdge.allCases, id: \.self) { e in
                    Button(e.title) { model?.align(e) }.disabled(!(model?.canAlign ?? false))
                }
                Divider()
                Button("Distribute Horizontally") { model?.distribute(horizontally: true) }.disabled(!(model?.canDistribute ?? false))
                Button("Distribute Vertically") { model?.distribute(horizontally: false) }.disabled(!(model?.canDistribute ?? false))
            }
            Button("Frame Selection") { model?.frameSelection() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(model == nil)
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
        CommandMenu("Page") {
            Button("New Page") { model?.addPage() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Duplicate Page") { model?.addPage(duplicate: true) }
                .disabled(model == nil)
            Button("Delete Page") { model.map { $0.deletePage($0.activePageID) } }
                .disabled((model?.pages.count ?? 0) < 2)
            Divider()
            Button("Previous Page") { model?.switchPage(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Next Page") { model?.switchPage(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model == nil)
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
