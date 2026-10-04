import IsoGeometry
import SwiftUI

/// Sketch-style floating tool pills along the top of the canvas.
struct CanvasToolbar: View {
    @Bindable var model: SceneModel
    @Binding var showLayers: Bool
    @Binding var showInspector: Bool
    @Binding var showTimeline: Bool
    @State private var lastShape: Tool = .rectangle

    private static let shapes: [Tool] = [.rectangle, .ellipse, .polygon]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !showLayers {
                pill { iconButton("sidebar.left", help: "Show the layers (⌃⌘S)") { showLayers = true }.keyboardShortcut("s", modifiers: [.command, .control]) }
            }
            pill { insertMenu }
            pill { tools }
            pill {
                iconButton("square.on.square.intersection.dashed", help: "Combine the selected parts into the first one", action: model.combineSelection)
                    .disabled(model.selection.count < 2)
                iconButton("arrow.up.left.and.down.right.magnifyingglass", help: "Zoom to fit (F)") { model.zoomToFit() }
            }
            Spacer(minLength: 8)
            pill {
                iconButton("timeline.selection", help: showTimeline ? "Hide the timeline (⇧⌘T)" : "Show the timeline (⇧⌘T)", active: showTimeline) {
                    showTimeline.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            pill { zoomMenu }
            if !showInspector {
                pill { iconButton("sidebar.right", help: "Show the inspector (⌥⌘I)") { showInspector = true }.keyboardShortcut("i", modifiers: [.command, .option]) }
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PillButtonStyle())
        .onChange(of: model.tool) { _, t in if Self.shapes.contains(t) { lastShape = t } }
    }

    private var insertMenu: some View {
        Menu {
            Section("Primitives") {
                ForEach(PrimitiveSpec.all) { spec in
                    Button { model.addPrimitive(spec) } label: { Label(spec.name, systemImage: SidebarView.symbol(spec.id)) }
                }
            }
            Section("Annotations") {
                InsertMenuItems(model: model)
            }
        } label: {
            glyph("plus")
        }
        .help("Insert a primitive, decal, dimension or SVG sketch")
    }

    @ViewBuilder private var tools: some View {
        let shape = Self.shapes.contains(model.tool) ? model.tool : lastShape
        toolButton(.select)
        toolButton(.frame)
        HStack(spacing: 0) {
            toolButton(shape)
            Menu {
                ForEach(Self.shapes) { t in
                    Toggle(isOn: Binding(get: { model.tool == t }, set: { _ in model.tool = t })) {
                        Label(t.title, systemImage: t.symbol)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 32)
            }
            .help("Shape tools")
        }
        toolButton(.pen)
        toolButton(.rings)
    }

    private var zoomMenu: some View {
        Menu {
            Button("Zoom In") { model.zoom(by: 1.25) }
            Button("Zoom Out") { model.zoom(by: 0.8) }
            Button("Zoom to Fit") { model.zoomToFit() }
        } label: {
            HStack(spacing: 6) {
                Text("\(Int((model.zoom * 100).rounded()))%").monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        .help("Zoom")
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(4)
            .fixedSize()
            .pillSurface()
    }

    private func toolButton(_ tool: Tool) -> some View {
        iconButton(tool.symbol, help: "\(tool.title) (\(String(tool.key).uppercased()))", active: model.tool == tool) { model.tool = tool }
    }

    private func iconButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph(symbol) }
            .buttonStyle(PillButtonStyle(active: active))
            .help(help)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .frame(width: 32, height: 32)
    }
}
