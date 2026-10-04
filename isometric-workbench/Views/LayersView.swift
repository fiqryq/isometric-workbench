import AppKit
import IsoDocument
import IsoGeometry
import SwiftUI
import UniformTypeIdentifiers

private let rowHeight: CGFloat = 28

/// The document's layer list, Figma style: one row per part with its steps,
/// callouts and attached annotations folded underneath, then loose flat art.
struct LayersView: View {
    @Bindable var model: SceneModel
    @State private var expanded: Set<Part.ID> = []
    /// Frames start open, like Figma's.
    @State private var closedFrames: Set<Artboard.ID> = []
    @State private var renamingID: String?
    @State private var anchor: Part.ID?
    @State private var dropSpot: DropSpot?

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.scene.parts.isEmpty && model.scene.frames.isEmpty && model.scene.looseAnnotations.isEmpty {
                empty
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Layers").font(.system(size: 12, weight: .semibold))
            Spacer()
            if !expanded.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded = [] }
                } label: {
                    Image(systemName: "rectangle.compress.vertical").font(.system(size: 11))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Collapse all layers")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 32)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.3.layers.3d").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text("No layers yet").font(.system(size: 12, weight: .medium))
            Text("Add a primitive to start.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.scene.frames) { f in
                            frameBlock(f)
                        }
                        ForEach(Array(model.scene.parts.enumerated()), id: \.element.id) { i, part in
                            if model.scene.frames.index(holding: part.id) == nil {
                                partBlock(part, index: i, depth: 0)
                            }
                        }
                        ForEach(model.scene.looseAnnotations, id: \.self) { a in
                            annotationRow(a, depth: 0)
                        }
                    }
                    .padding(.vertical, 2)
                    .frame(minHeight: geo.size.height, alignment: .top)
                    // Clicking empty space deselects.
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = []
                                model.annotation = nil
                            }
                    }
                }
            }
            .onChange(of: model.selection) { _, sel in
                if sel.count == 1, let id = sel.first { proxy.scrollTo(id) }
            }
            .onChange(of: model.annotation) { _, a in
                guard let a else { return }
                if let host = model.scene.layerHost(a) { expanded.insert(host) }
                Task { proxy.scrollTo(a.layerID) }
            }
        }
    }

    // MARK: - Frames

    private func frameBlock(_ f: Artboard) -> some View {
        let open = !closedFrames.contains(f.id)
        return VStack(spacing: 0) {
            LayerRow(
                depth: 0, symbol: "number", tint: .blue, name: f.name,
                selected: model.selectedFrames.contains(f.id),
                expanded: Binding(
                    get: { !closedFrames.contains(f.id) },
                    set: { if $0 { closedFrames.remove(f.id) } else { closedFrames.insert(f.id) } }),
                renaming: renaming(f.id),
                onSelect: { model.selectFrame(f.id) },
                onRename: { name in model.editFrame(f.id, "Rename Frame") { $0.name = name } }
            ) { _ in }
            .id(f.id)
            .onDrop(of: [.text], delegate: FrameDrop(frame: f.id, model: model))
            .contextMenu {
                Button("Rename") { renamingID = f.id }
                Divider()
                Button("Remove Frame") { model.deleteFrame(f.id, keepParts: true) }
                Button("Delete Frame and Parts", role: .destructive) { model.deleteFrame(f.id, keepParts: false) }
            }
            if open {
                ForEach(Array(model.scene.parts.enumerated()), id: \.element.id) { i, part in
                    if f.children.contains(part.id) {
                        partBlock(part, index: i, depth: 1)
                    }
                }
            }
        }
    }

    // MARK: - Parts

    private func partBlock(_ part: Part, index: Int, depth: Int) -> some View {
        let open = expanded.contains(part.id)
        let selected = model.selection.contains(part.id)
        return VStack(spacing: 0) {
            partRow(part, depth: depth)
            if open {
                ForEach(model.scene.layerChildren(of: part)) { child in
                    childRow(child, of: part, depth: depth + 1)
                }
            }
        }
        .background {
            if selected && open {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.08)).padding(.horizontal, 6)
            }
        }
        .overlay(alignment: dropSpot?.after == true ? .bottom : .top) {
            if dropSpot?.id == part.id {
                Capsule().fill(Color.accentColor).frame(height: 2).padding(.leading, 30).padding(.trailing, 8)
            }
        }
        .onDrop(of: [.text], delegate: LayerDrop(id: part.id, index: index, model: model, spot: $dropSpot))
    }

    private func partRow(_ part: Part, depth: Int) -> some View {
        LayerRow(
            depth: depth, symbol: SidebarView.symbol(part.ops.first?.type ?? ""), tint: .purple, name: part.name,
            selected: model.selection.contains(part.id) && model.annotation == nil, dimmed: part.hidden,
            expanded: Binding(
                get: { expanded.contains(part.id) },
                set: { if $0 { expanded.insert(part.id) } else { expanded.remove(part.id) } }),
            renaming: renaming(part.id),
            onSelect: { select(part.id) },
            onRename: { name in model.updatePart(part.id, "Rename") { $0.name = name } }
        ) { hovering in
            if let error = model.build.errors[part.id] {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange).help(error)
            }
            if part.anim.isAnimated {
                Image(systemName: "diamond.fill").font(.system(size: 7)).foregroundStyle(.secondary).help("Animated")
            }
            LayerToggle(symbol: part.locked ? "lock.fill" : "lock.open", help: part.locked ? "Unlock" : "Lock", visible: hovering || part.locked) {
                model.updatePart(part.id, part.locked ? "Unlock" : "Lock") { $0.locked.toggle() }
            }
            LayerToggle(symbol: part.hidden ? "eye.slash" : "eye", help: part.hidden ? "Show" : "Hide", visible: hovering || part.hidden) {
                model.updatePart(part.id, part.hidden ? "Show" : "Hide") { $0.hidden.toggle() }
            }
        }
        .id(part.id)
        .onDrag { NSItemProvider(object: part.id as NSString) }
        .contextMenu { menu(for: part) }
    }

    @ViewBuilder private func menu(for part: Part) -> some View {
        Button("Rename") { renamingID = part.id }
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

    // MARK: - Children

    @ViewBuilder private func childRow(_ child: LayerChild, of part: Part, depth: Int) -> some View {
        switch child {
        case .step(let i, let op):
            LayerRow(
                depth: depth, symbol: op.layerSymbol, name: op.display.label, dimmed: !op.enabled,
                onSelect: { focus(part.id) }
            ) { hovering in
                if i > 0 {
                    LayerToggle(symbol: op.enabled ? "eye" : "eye.slash", help: op.enabled ? "Turn off step" : "Turn on step", visible: hovering || !op.enabled) {
                        model.toggleStep(part.id, step: i)
                    }
                }
            }
            .contextMenu {
                Button(op.enabled ? "Turn Off Step" : "Turn On Step") { model.toggleStep(part.id, step: i) }.disabled(i == 0)
                Button("Move Up") { model.moveStep(part.id, step: i, by: -1) }.disabled(i <= 1)
                Button("Move Down") { model.moveStep(part.id, step: i, by: 1) }.disabled(i == 0 || i == part.ops.count - 1)
                Divider()
                Button("Delete Step", role: .destructive) { model.deleteStep(part.id, step: i) }.disabled(part.ops.count <= 1)
            }
        case .callout(let c):
            LayerRow(
                depth: depth, symbol: "text.bubble", tint: .orange, name: c.text.isEmpty ? "Callout" : c.text,
                renaming: renaming(child.id),
                onSelect: { focus(part.id) },
                onRename: { model.renameCallout(part.id, c.id, to: $0) }
            ) { _ in }
            .contextMenu {
                Button("Edit Text") { renamingID = child.id }
                Divider()
                Button("Delete", role: .destructive) { model.deleteCallout(part.id, c.id) }
            }
        case .annotation(let a):
            annotationRow(a, depth: depth)
        }
    }

    private func annotationRow(_ a: AnnotationRef, depth: Int) -> some View {
        let renamable = if case .dimension = a { false } else { true }
        return LayerRow(
            depth: depth, symbol: model.scene.layerSymbol(a), tint: Self.tint(a), name: model.scene.layerName(a),
            selected: model.annotation == a,
            renaming: renaming(a.layerID),
            onSelect: {
                model.selection = []
                model.annotation = a
            },
            onRename: renamable ? { model.renameLayer(a, to: $0) } : nil
        ) { _ in }
        .id(a.layerID)
        .contextMenu {
            if renamable { Button("Rename") { renamingID = a.layerID } }
            Button("Delete", role: .destructive) { model.deleteAnnotation(a) }
        }
    }

    private static func tint(_ a: AnnotationRef) -> Color {
        switch a {
        case .shape: .teal
        case .decal: .pink
        case .dimension: .green
        }
    }

    // MARK: - Selection

    /// Click selects, ⌘-click toggles, ⇧-click selects the range from the last click.
    private func select(_ id: Part.ID) {
        let flags = NSEvent.modifierFlags
        model.annotation = nil
        if flags.contains(.command) {
            if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
        } else if flags.contains(.shift), let anchor, let a = model.scene.partIndex(anchor), let b = model.scene.partIndex(id) {
            model.selection = Set(model.scene.parts[min(a, b)...max(a, b)].map(\.id))
            return
        } else {
            model.selection = [id]
        }
        anchor = id
    }

    private func focus(_ id: Part.ID) {
        model.annotation = nil
        model.selection = [id]
        anchor = id
    }

    private func renaming(_ id: String) -> Binding<Bool> {
        Binding(get: { renamingID == id }, set: { on in
            if on { renamingID = id } else if renamingID == id { renamingID = nil }
        })
    }
}

// MARK: - Row

struct LayerRow<Trailing: View>: View {
    let depth: Int
    let symbol: String
    let tint: Color
    let name: String
    let selected: Bool
    let dimmed: Bool
    let expanded: Binding<Bool>?
    @Binding var renaming: Bool
    let onSelect: () -> Void
    let onRename: ((String) -> Void)?
    let trailing: (Bool) -> Trailing

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    init(
        depth: Int, symbol: String, tint: Color = .secondary, name: String, selected: Bool = false, dimmed: Bool = false,
        expanded: Binding<Bool>? = nil, renaming: Binding<Bool> = .constant(false),
        onSelect: @escaping () -> Void, onRename: ((String) -> Void)? = nil,
        @ViewBuilder trailing: @escaping (Bool) -> Trailing
    ) {
        self.depth = depth
        self.symbol = symbol
        self.tint = tint
        self.name = name
        self.selected = selected
        self.dimmed = dimmed
        self.expanded = expanded
        _renaming = renaming
        self.onSelect = onSelect
        self.onRename = onRename
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 0) {
            clickable(Color.clear.frame(width: 6 + CGFloat(depth) * 16))
            disclosure
            clickable(HStack(spacing: 0) {
                Group {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white : tint)
                        .frame(width: 16)
                        .padding(.trailing, 6)
                    if renaming {
                        field
                    } else {
                        Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                }
                .opacity(dimmed ? 0.45 : 1)
                Spacer(minLength: 4)
            })
            HStack(spacing: 2) { trailing(hovering) }
                .environment(\.colorScheme, selected ? .dark : colorScheme)
        }
        .padding(.trailing, 10)
        .frame(height: rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor : hovering ? Color.primary.opacity(0.06) : .clear)
                .padding(.horizontal, 6)
        }
        .background(alignment: .leading) { guides }
        .onHover { hovering = $0 }
    }

    /// Sketch-style tree lines: one hairline per ancestor, under its chevron.
    private var guides: some View {
        Canvas { ctx, size in
            for level in 0..<depth {
                let x = 6 + CGFloat(level) * 16 + 8
                ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.22)))
            }
        }
        .allowsHitTesting(false)
    }

    /// Click selects, double-click renames. Kept off the row's buttons so
    /// toggling the eye or lock doesn't change the selection.
    private func clickable(_ content: some View) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { if onRename != nil { renaming = true } }, including: renaming ? .subviews : .all)
            .simultaneousGesture(TapGesture().onEnded(onSelect), including: renaming ? .subviews : .all)
    }

    @ViewBuilder private var disclosure: some View {
        if let expanded {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.wrappedValue.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    .frame(width: 16, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
        } else {
            clickable(Color.clear.frame(width: 16))
        }
    }

    private var field: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($focused)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 1))
            .task {
                draft = name
                focused = true
            }
            .onSubmit(commit)
            .onExitCommand { renaming = false }
            .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        guard renaming else { return }
        renaming = false
        let s = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, s != name { onRename?(s) }
    }
}

/// Lock / eye button: shown on hover, or always while it's on.
struct LayerToggle: View {
    let symbol: String
    let help: String
    var visible = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(visible ? 1 : 0)
        .help(help)
    }
}

// MARK: - Reorder

/// Dropping a part on a frame's row moves it into that frame.
private struct FrameDrop: DropDelegate {
    let frame: Artboard.ID
    let model: SceneModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let model = model, frame = frame
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let id = (obj as? NSString) as String? else { return }
            Task { @MainActor in model.moveIntoFrame(id, frame) }
        }
        return true
    }
}

private struct DropSpot: Equatable {
    var id: Part.ID
    var after: Bool
}

/// Drops a dragged part before or after this one (after when below the
/// middle of its row, which includes its expanded children).
private struct LayerDrop: DropDelegate {
    let id: Part.ID
    let index: Int
    let model: SceneModel
    @Binding var spot: DropSpot?

    private func after(_ info: DropInfo) -> Bool { info.location.y > rowHeight / 2 }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let s = DropSpot(id: id, after: after(info))
        if spot != s { spot = s }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if spot?.id == id { spot = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        spot = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let to = index + (after(info) ? 1 : 0)
        let model = model
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let id = (obj as? NSString) as String? else { return }
            Task { @MainActor in model.moveLayer(id, to: to, beside: self.id) }
        }
        return true
    }
}

extension Op {
    /// Icon for the step's row in the Layers panel.
    var layerSymbol: String {
        switch type {
        case "extrude": "square.stack.3d.up"
        case "revolve": "arrow.triangle.2.circlepath"
        case "push", "facepush", "segpush":
            truthy("through") ? "scissors" : num("depth", 0) >= 0 ? "arrow.up.square" : "arrow.down.square"
        case "cut": "square.split.diagonal"
        case "merge": string("mode") == "subtract" ? "minus.square" : "plus.square"
        case "size": "ruler"
        case "move": "arrow.up.and.down.and.arrow.left.and.right"
        case "scale": "arrow.up.left.and.arrow.down.right"
        case "mirror": "arrow.left.and.right"
        case "array": "rectangle.split.3x1"
        case "radial": "circle.grid.cross"
        case "loopcut": "rectangle.split.1x2"
        default: SidebarView.symbol(type)
        }
    }
}
