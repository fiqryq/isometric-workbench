import IsoDocument
import IsoGeometry
import IsoMath
import SwiftUI
import UniformTypeIdentifiers

struct DocumentView: View {
    @ObservedObject var document: SceneDocument
    @Environment(\.undoManager) private var undoManager
    @State private var showInspector = true
    @AppStorage("showTimeline") private var showTimeline = true
    @AppStorage("timelineHeight") private var timelineHeight = 190.0
    @State private var dragStartHeight: Double?

    var body: some View {
        let model = document.model
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 340)
        } detail: {
            VStack(spacing: 0) {
                Viewport(model: model)
                    .frame(minWidth: 420, minHeight: 320)
                Divider()
                TransportBar(model: model, showTimeline: $showTimeline)
                if showTimeline {
                    resizeHandle
                    TimelinePanel(model: model)
                        .frame(height: timelineHeight)
                }
                Divider()
                StatusBar(model: model)
            }
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 270, ideal: 310, max: 440)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToolPicker(model: model)
            }
            ToolbarItemGroup {
                Menu {
                    InsertMenuItems(model: model)
                } label: {
                    Label("Insert", systemImage: "plus.square.on.square")
                }
                .help("Add decals, dimensions or an SVG sketch")
                Button { model.zoomToFit() } label: { Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Zoom to fit (F)")
                Button { model.combineSelection() } label: { Label("Combine", systemImage: "square.on.square.intersection.dashed") }
                    .help("Combine the selected parts into the first one")
                    .disabled(model.selection.count < 2)
                Menu {
                    ExportMenuItems(model: model)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export the current frame")
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show or hide the inspector")
            }
        }
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

struct ToolPicker: View {
    @Bindable var model: SceneModel

    var body: some View {
        Picker("Tool", selection: $model.tool) {
            ForEach(Tool.allCases) { t in
                Label(t.title, systemImage: t.symbol)
                    .help("\(t.title) (\(String(t.key).uppercased()))")
                    .tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .help("Tools")
    }
}
