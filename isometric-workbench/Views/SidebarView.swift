import SwiftUI

/// The document window's left column, Sketch style: the window controls and
/// document name, then Pages above Layers.
struct SidebarView: View {
    let model: SceneModel
    let title: String
    @Binding var showLayers: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            document
            PagesPanel(model: model)
            Divider()
            LayersView(model: model)
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button { showLayers = false } label: {
                Image(systemName: "sidebar.left").font(.system(size: 14)).frame(width: 30, height: 30)
            }
            .buttonStyle(PillButtonStyle())
            .help("Hide the layers (⌃⌘S)")
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
        .padding(.leading, Chrome.trafficLightsWidth)
        .padding(.trailing, 8)
        .frame(height: Chrome.headerHeight)
        .background(WindowDragArea())
    }

    private var document: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .help(title)
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
