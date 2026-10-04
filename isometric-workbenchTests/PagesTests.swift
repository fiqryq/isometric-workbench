import Foundation
import IsoDocument
import IsoExamples
import IsoGeometry
import Testing
@testable import isometric_workbench

@MainActor
struct PagesTests {
    @Test("Pages share parts but each keeps its own animation, and page edits undo")
    func pages() throws {
        let floppy = try #require(Example.named("floppy"))
        let model = SceneDocument(scene: floppy.scene()).model
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let first = model.activePageID
        let before = model.exportFrame().items.map(\.box)
        #expect(model.pages.count == 1)

        undo.beginUndoGrouping()
        model.addPage()
        undo.endUndoGrouping()
        let second = model.activePageID
        #expect(model.pages.count == 2 && second != first)
        #expect(model.pages.map(\.name) == ["Page 1", "Page 2"])
        #expect(!model.scene.parts.contains { $0.anim.isAnimated })

        let id = model.scene.parts[0].id
        model.updatePart(id, "Move") { $0.anim.base["z"] = 300 }
        model.edit("Lengthen") { $0.duration = 9 }
        model.seek(8)
        let moved = model.exportFrame().items.first { $0.part.id == id }!.box

        model.switchPage(first)
        #expect(model.scene.duration == floppy.scene().duration)
        #expect(model.time <= model.scene.duration)
        #expect(model.exportFrame().items.map(\.box) == before)

        model.switchPage(by: 1)
        #expect(model.activePageID == second)
        #expect(model.exportFrame().items.first { $0.part.id == id }!.box == moved)
        #expect(model.svg().contains("<svg"))

        undo.beginUndoGrouping()
        model.deletePage(second)
        undo.endUndoGrouping()
        #expect(model.pages.count == 1 && model.activePageID == first)
        undo.undo()
        #expect(model.pages.count == 2 && model.activePageID == second)
        #expect(model.scene.duration == 9)

        model.renamePage(second, to: "  Exploded  ")
        model.movePage(second, by: -1)
        #expect(model.pages.map(\.name) == ["Exploded", "Page 1"])

        let reopened = try SceneFile.decode(model.scene.encoded())
        #expect(reopened.allPages.map(\.name) == ["Exploded", "Page 1"])
        #expect(reopened.activePage == second && reopened.duration == 9)
    }
}
