import Foundation
import IsoDocument
import IsoGeometry

/// A row nested under a part in the Layers panel.
enum LayerChild: Hashable, Identifiable {
    case step(Int, Op)
    case callout(Callout)
    case annotation(AnnotationRef)

    var id: String {
        switch self {
        case .step(let i, _): "step-\(i)"
        case .callout(let c): "callout-\(c.id)"
        case .annotation(let a): a.layerID
        }
    }
}

extension AnnotationRef {
    var layerID: String {
        switch self {
        case .shape(let id): "shape-\(id)"
        case .decal(let id): "decal-\(id)"
        case .dimension(let id): "dimension-\(id)"
        }
    }
}

extension SceneFile {
    /// Steps, callouts, then the dimensions and flat art attached to the part.
    func layerChildren(of part: Part) -> [LayerChild] {
        part.ops.enumerated().map { .step($0, $1) }
            + part.callouts.map(LayerChild.callout)
            + dimensions.filter { $0.part == part.id }.map { .annotation(.dimension($0.id)) }
            + shapes.filter { $0.host == part.id }.map { .annotation(.shape($0.id)) }
            + decals.filter { $0.host == part.id }.map { .annotation(.decal($0.id)) }
    }

    /// Flat art (and stray dimensions) that no part hosts.
    var looseAnnotations: [AnnotationRef] {
        let ids = Set(parts.map(\.id))
        let free = { (host: Part.ID?) in host.map { !ids.contains($0) } ?? true }
        return shapes.filter { free($0.host) }.map { .shape($0.id) }
            + decals.filter { free($0.host) }.map { .decal($0.id) }
            + dimensions.filter { !ids.contains($0.part) }.map { .dimension($0.id) }
    }

    /// The part an annotation is listed under, if any.
    func layerHost(_ a: AnnotationRef) -> Part.ID? {
        let host: Part.ID? = switch a {
        case .shape(let id): shapes.first { $0.id == id }?.host
        case .decal(let id): decals.first { $0.id == id }?.host
        case .dimension(let id): dimensions.first { $0.id == id }?.part
        }
        return host.flatMap { partIndex($0) == nil ? nil : $0 }
    }

    func layerName(_ a: AnnotationRef) -> String {
        switch a {
        case .shape(let id): shapes.first { $0.id == id }?.name ?? "Shape"
        case .decal(let id): decals.first { $0.id == id }?.name ?? "Decal"
        case .dimension: "Dimensions"
        }
    }

    func layerSymbol(_ a: AnnotationRef) -> String {
        switch a {
        case .shape(let id):
            shapes.first { $0.id == id }?.hatch == true ? "square.dashed.inset.filled" : "square.on.square.dashed"
        case .decal(let id):
            switch decals.first(where: { $0.id == id })?.kind {
            case .svg: "scribble.variable"
            case .image: "photo"
            default: "textformat"
            }
        case .dimension: "ruler"
        }
    }
}

extension SceneModel {
    func renameLayer(_ a: AnnotationRef, to name: String) {
        switch a {
        case .shape(let id): updateShape(id, "Rename") { $0.name = name }
        case .decal(let id): updateDecal(id, "Rename") { $0.name = name }
        case .dimension: break
        }
    }

    func renameCallout(_ part: Part.ID, _ id: Callout.ID, to text: String) {
        updatePart(part, "Edit Callout") { p in
            guard let i = p.callouts.firstIndex(where: { $0.id == id }) else { return }
            p.callouts[i].text = text
        }
    }

    func deleteCallout(_ part: Part.ID, _ id: Callout.ID) {
        updatePart(part, "Delete Callout") { $0.callouts.removeAll { $0.id == id } }
    }

    /// Drag reorder in the Layers panel: moves the part (with the rest of the
    /// selection when it's part of it) to before `offset`, into the frame of
    /// the part it lands `beside`.
    func moveLayer(_ id: Part.ID, to offset: Int, beside: Part.ID) {
        let ids = selection.contains(id) ? selection : [id]
        let from = IndexSet(scene.parts.indices.filter { ids.contains(scene.parts[$0].id) })
        guard !from.isEmpty else { return }
        movePart(from: from, to: offset)
        let target = scene.frames.index(holding: beside).map { scene.frames[$0].id }
        if ids.contains(where: { id in scene.frames.index(holding: id).map { scene.frames[$0].id } != target }) {
            edit(target == nil ? "Move out of Frame" : "Move into Frame") { $0.frames.place(scene.parts.map(\.id).filter(ids.contains), in: target) }
        }
    }

    /// Moves the part (with the rest of the selection when it's part of it) into a frame.
    func moveIntoFrame(_ id: Part.ID, _ frame: Artboard.ID) {
        let ids = selection.contains(id) ? selection : [id]
        edit("Move into Frame") { s in s.frames.place(s.parts.map(\.id).filter(ids.contains), in: frame) }
    }
}
