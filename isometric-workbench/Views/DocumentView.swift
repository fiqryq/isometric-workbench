import IsoDocument
import IsoGeometry
import IsoMath
import SwiftUI
import UniformTypeIdentifiers

struct DocumentView: View {
    @ObservedObject var document: SceneDocument
    var fileURL: URL?
    @Environment(\.undoManager) private var undoManager
    @AppStorage("showLayers") private var showLayers = true
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("showTimeline") private var showTimeline = true
    @AppStorage("layersWidth") private var layersWidth = 240.0
    @AppStorage("inspectorWidth") private var inspectorWidth = 300.0
    @AppStorage("timelineHeight") private var timelineHeight = 190.0
    @State private var dragStartHeight: Double?

    var body: some View {
        let model = document.model
        HStack(spacing: 0) {
            if showLayers {
                SidebarView(model: model, title: title, showLayers: $showLayers)
                    .frame(width: layersWidth)
                    .background(Chrome.panelBackground)
                SideResizer(width: $layersWidth, range: 200...380, direction: 1)
            }
            VStack(spacing: 0) {
                Viewport(model: model)
                    .frame(minWidth: 420, minHeight: 320)
                    .overlay(alignment: .top) {
                        CanvasToolbar(model: model, showLayers: $showLayers, showInspector: $showInspector, showTimeline: $showTimeline)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            // Leave the traffic lights clear when the layers are hidden.
                            .padding(.leading, showLayers ? 0 : Chrome.trafficLightsWidth)
                    }
                    .overlay(alignment: .bottomLeading) {
                        CanvasStatus(model: model).padding(10)
                    }
                if showTimeline {
                    Divider()
                    TransportBar(model: model, showTimeline: $showTimeline)
                    resizeHandle
                    TimelinePanel(model: model)
                        .frame(height: timelineHeight)
                }
            }
            if showInspector {
                SideResizer(width: $inspectorWidth, range: 270...440, direction: -1)
                VStack(spacing: 0) {
                    InspectorHeader(model: model, showInspector: $showInspector)
                    InspectorView(model: model)
                }
                .frame(width: inspectorWidth)
                .background(Chrome.panelBackground)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: Binding(get: { model.presentVideoExport }, set: { model.presentVideoExport = $0 })) {
            VideoExportSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.presentPaywall }, set: { model.presentPaywall = $0 })) {
            PaywallView()
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .focusedSceneValue(\.sceneModel, model)
    }

    private var title: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }
}

/// The inspector's top row, as in Sketch: play on the left, export and
/// hiding the column on the right.
struct InspectorHeader: View {
    let model: SceneModel
    @Binding var showInspector: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button { model.togglePlay() } label: { icon(model.isPlaying ? "pause.fill" : "play.fill", size: 12) }
                .help(model.isPlaying ? "Pause" : "Play")
            Spacer()
            Menu {
                ExportMenuItems(model: model)
            } label: {
                icon("square.and.arrow.up")
            }
            .help("Export")
            Button { showInspector = false } label: { icon("sidebar.right") }
                .help("Hide the inspector (⌥⌘I)")
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(InspectorIconButtonStyle())
        .padding(.horizontal, 10)
        .frame(height: Chrome.headerHeight)
        .background(WindowDragArea())
    }

    private func icon(_ symbol: String, size: CGFloat = 13) -> some View {
        Image(systemName: symbol).font(.system(size: size, weight: .regular)).foregroundStyle(.primary.opacity(0.75)).frame(width: 28, height: 28)
    }
}

extension DocumentView {
    fileprivate var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                let start = dragStartHeight ?? timelineHeight
                if dragStartHeight == nil { dragStartHeight = start }
                timelineHeight = clamp(start - v.translation.height, 90, 520)
            }.onEnded { _ in dragStartHeight = nil })
    }
}

struct ExportMenuItems: View {
    let model: SceneModel

    var body: some View {
        Button("Export SVG…") { Exporter.save(model, as: .svg) }
        Button("Export PDF…") { Exporter.save(model, as: .pdf) }
        Button("Export PNG…") { Exporter.save(model, as: .png) }
        Divider()
        Button("Export Animation…") { model.presentVideoExport = true }
        Divider()
        Button("Copy as SVG") { Exporter.copySVG(model) }
    }
}
