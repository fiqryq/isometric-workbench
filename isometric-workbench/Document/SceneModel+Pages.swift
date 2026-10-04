import Foundation
import IsoDocument
import IsoGeometry
import IsoMath

extension SceneModel {
    var pages: [Page] { scene.allPages }

    var activePageID: Page.ID { scene.activePage ?? pages[0].id }

    var activePageName: String { pages.first { $0.id == activePageID }?.name ?? "Page 1" }

    /// Switching pages is navigation, so it isn't an undo step; undoing an edit made
    /// on another page brings that page back.
    func switchPage(_ id: Page.ID) {
        guard id != activePageID else { return }
        pause()
        scene.activatePage(id)
        afterPageChange()
    }

    func switchPage(by offset: Int) {
        let all = pages
        guard let i = all.firstIndex(where: { $0.id == activePageID }) else { return }
        let j = i + offset
        if all.indices.contains(j) { switchPage(all[j].id) }
    }

    func addPage(duplicate: Bool = false) {
        pause()
        edit(duplicate ? "Duplicate Page" : "Add Page") { $0.addPage(duplicate: duplicate) }
        afterPageChange()
        status = "\(activePageName) added"
    }

    func deletePage(_ id: Page.ID) {
        guard pages.count > 1 else { return }
        let name = pages.first { $0.id == id }?.name ?? "Page"
        pause()
        edit("Delete Page") { $0.deletePage(id) }
        afterPageChange()
        status = "\(name) deleted"
    }

    func renamePage(_ id: Page.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit("Rename Page") { $0.renamePage(id, to: trimmed) }
    }

    func movePage(_ id: Page.ID, by offset: Int) {
        guard let i = scene.pages.firstIndex(where: { $0.id == id }) else { return }
        edit("Move Page") { $0.movePage(id, to: i + offset) }
    }

    private func afterPageChange() {
        prune()
        seek(min(time, scene.duration))
    }
}
