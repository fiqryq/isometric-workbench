import IsoDocument
import SwiftUI

/// Figma-style pages: a list at the top of the left sidebar, above the layers.
struct PagesPanel: View {
    let model: SceneModel
    @State private var renaming: Page.ID?
    @State private var draft = ""
    @State private var searching = false
    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    @FocusState private var searchFocused: Bool

    private static let rowHeight: CGFloat = 28

    var body: some View {
        let pages = model.pages
        let shown = pages.enumerated().filter { query.isEmpty || $0.element.name.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 0) {
            header
            if searching {
                TextField("Find page", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($searchFocused)
                    .onExitCommand(perform: closeSearch)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(shown, id: \.element.id) { index, page in
                        row(page, index: index, count: pages.count)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .frame(height: min(CGFloat(max(shown.count, 1)) * Self.rowHeight + 6, 5 * Self.rowHeight + 6))
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text("Pages").font(.system(size: 12, weight: .semibold))
            Spacer()
            headerButton("magnifyingglass", help: "Find a page") {
                if searching { closeSearch() } else {
                    searching = true
                    searchFocused = true
                }
            }
            headerButton("plus", help: "Add a page") { model.addPage() }
                .contextMenu {
                    Button("New Page") { model.addPage() }
                    Button("Duplicate Current Page") { model.addPage(duplicate: true) }
                }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 32)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    @ViewBuilder
    private func row(_ page: Page, index: Int, count: Int) -> some View {
        let active = page.id == model.activePageID
        Group {
            if renaming == page.id {
                TextField("Page name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { commit(page.id) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commit(page.id) } }
            } else {
                Text(page.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.system(size: 12, weight: active ? .semibold : .regular))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(active ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRenaming(page) }
        .onTapGesture { model.switchPage(page.id) }
        .help(page.name)
        .draggable(page.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != page.id, model.scene.pages.contains(where: { $0.id == id }) else { return false }
            model.edit("Move Page") { $0.movePage(id, to: index) }
            return true
        }
        .contextMenu {
            Button("Rename") { startRenaming(page) }
            Button("Duplicate") {
                model.switchPage(page.id)
                model.addPage(duplicate: true)
            }
            Divider()
            Button("Move Up") { model.movePage(page.id, by: -1) }.disabled(index == 0 || count < 2)
            Button("Move Down") { model.movePage(page.id, by: 1) }.disabled(index == count - 1)
            Divider()
            Button("Delete", role: .destructive) { model.deletePage(page.id) }.disabled(count < 2)
        }
    }

    private func closeSearch() {
        searching = false
        query = ""
    }

    private func startRenaming(_ page: Page) {
        draft = page.name
        renaming = page.id
        fieldFocused = true
    }

    private func commit(_ id: Page.ID) {
        guard renaming == id else { return }
        renaming = nil
        model.renamePage(id, to: draft)
    }
}
