import AppKit
import IsoDocument
import IsoGeometry
import IsoMath
import UniformTypeIdentifiers

enum Exporter {
    static func save(_ model: SceneModel, as type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = model.scene.name
        panel.title = "Export \(type.preferredFilenameExtension?.uppercased() ?? "")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: Data? = switch type {
        case .svg: model.svg().data(using: .utf8)
        case .pdf: model.pdf()
        default: model.png()
        }
        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            model.status = "Exported \(url.lastPathComponent)."
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// SVG markup on the pasteboard pastes into Figma as editable vectors.
    static func copySVG(_ model: SceneModel) {
        let svg = model.svg()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(svg, forType: .string)
        pb.setData(Data(svg.utf8), forType: NSPasteboard.PasteboardType(UTType.svg.identifier))
        model.status = "Copied the frame as SVG — paste it into Figma."
    }
}
