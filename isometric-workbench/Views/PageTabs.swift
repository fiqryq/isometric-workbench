import IsoDocument
import SwiftUI

/// Figma-style pages: one tab per page above the canvas.
struct PageTabs: View {
    let model: SceneModel
    @State private var renaming: Page.ID?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let pages = model.pages
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        tab(page, index: index, count: pages.count)
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider().frame(height: 16)
            Button { model.addPage() } label: {
                Image(systemName: "plus").frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Add a page")
            .contextMenu {
                Button("New Page") { model.addPage() }
                Button("Duplicate Current Page") { model.addPage(duplicate: true) }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 30)
        .background(.bar)
    }

    @ViewBuilder
    private func tab(_ page: Page, index: Int, count: Int) -> some View {
        let active = page.id == model.activePageID
        Group {
            if renaming == page.id {
                TextField("Page name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .frame(width: max(60, CGFloat(draft.count) * 7.5))
                    .onSubmit { commit(page.id) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commit(page.id) } }
            } else {
                Text(page.name)
                    .lineLimit(1)
                    .foregroundStyle(active ? .primary : .secondary)
            }
        }
        .font(.callout.weight(active ? .semibold : .regular))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.primary.opacity(0.08) : .clear))
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
            Button("Move Left") { model.movePage(page.id, by: -1) }.disabled(index == 0 || count < 2)
            Button("Move Right") { model.movePage(page.id, by: 1) }.disabled(index == count - 1)
            Divider()
            Button("Delete", role: .destructive) { model.deletePage(page.id) }.disabled(count < 2)
        }
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
