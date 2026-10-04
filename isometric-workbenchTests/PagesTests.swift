import Foundation
import IsoDocument
import IsoExamples
import IsoGeometry
import Testing
@testable import isometric_workbench

@MainActor
struct PagesTests {
    @Test("Each page is its own canvas, the view follows the page, and page edits undo")
    func pages() throws {
        let floppy = try #require(Example.named("floppy"))
        let model = SceneDocument(scene: floppy.scene()).model
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let first = model.activePageID
        let before = model.exportFrame().items.map(\.box)
        #expect(model.pages.count == 1)
        model.selection = [model.scene.parts[0].id]
        model.zoom = 3
        model.pan = Vec2(120, -40)

        undo.beginUndoGrouping()
        model.addPage()
        undo.endUndoGrouping()
        let second = model.activePageID
        #expect(model.pages.count == 2 && second != first)
        #expect(model.pages.map(\.name) == ["Page 1", "Page 2"])
        #expect(model.scene.parts.isEmpty && model.selection.isEmpty)
        #expect(model.exportFrame().items.isEmpty)

        model.addPrimitive(PrimitiveSpec.all[0])
        let id = model.scene.parts[0].id
        model.edit("Lengthen") { $0.duration = 9 }
        model.seek(8)

        model.switchPage(first)
        #expect(model.scene.duration == floppy.scene().duration)
        #expect(model.time <= model.scene.duration)
        #expect(model.exportFrame().items.map(\.box) == before)
        #expect(!model.scene.parts.contains { $0.id == id })
        #expect(model.zoom == 3 && model.pan == Vec2(120, -40))

        model.switchPage(by: 1)
        #expect(model.activePageID == second)
        #expect(model.scene.parts.map(\.id) == [id])
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
