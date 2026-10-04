import CoreGraphics
import Foundation
import IsoDocument
import IsoExamples
import Testing
@testable import isometric_workbench

@MainActor
struct LibraryTests {
    private func makeLibrary() throws -> Library {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        return Library(root: root)
    }

    @Test("Files are created, renamed, duplicated, moved between folders, trashed and restored")
    func fileLifecycle() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.root) }

        let a = try library.create(SceneFile(), name: "Untitled")
        let b = try library.create(SceneFile(), name: "Untitled")
        #expect(a.lastPathComponent == "Untitled.isoscene" && b.lastPathComponent == "Untitled 2.isoscene")
        #expect(try SceneFile.decode(Data(contentsOf: b)).name == "Untitled 2")
        #expect(library.drafts.count == 2)

        let file = try #require(library.drafts.first { $0.url == a })
        try library.rename(file, to: "Bracket/v2")
        #expect(library.drafts.map(\.name).sorted() == ["Bracket-v2", "Untitled 2"])

        let folder = try library.createFolder(named: "Client work")
        #expect(try library.createFolder(named: "Client work") == "Client work 2")
        let bracket = try #require(library.drafts.first { $0.name == "Bracket-v2" })
        try library.move(bracket, to: folder)
        #expect(library.drafts.map(\.name) == ["Untitled 2"])
        #expect(library.folderFiles[folder]?.map(\.name) == ["Bracket-v2"])
        #expect(library.folderFiles[folder]?.first?.folder == folder)

        let copy = try library.duplicate(try #require(library.folderFiles[folder]?.first))
        #expect(copy.lastPathComponent == "Bracket-v2 copy.isoscene")

        try library.renameFolder(folder, to: "Clients")
        #expect(library.folders == ["Client work 2", "Clients"])
        #expect(library.folderFiles["Clients"]?.count == 2)

        try library.moveToTrash(try #require(library.drafts.first))
        #expect(library.drafts.isEmpty && library.trashed.count == 1)
        try library.restore(try #require(library.trashed.first))
        #expect(library.drafts.count == 1 && library.trashed.isEmpty)

        try library.deleteFolder("Clients")
        #expect(library.folders == ["Client work 2"])
        #expect(library.trashed.count == 2)
        try library.emptyTrash()
        #expect(library.trashed.isEmpty)
        #expect(library.allFiles.count == 1)
    }

    @Test("Imported scenes are copied in, and thumbnails render the content")
    func importAndThumbnail() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let floppy = try #require(Example.named("floppy")).scene()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).isoscene")
        try floppy.encoded().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try library.importFiles([outside], into: nil)
        let file = try #require(library.drafts.first)
        #expect(FileManager.default.fileExists(atPath: outside.path))

        let image = try #require(Thumbnailer.render(fileAt: file.url, size: ThumbnailCache.cardSize))
        #expect(image.width <= Int(ThumbnailCache.cardSize.width * 2) + 1)
        #expect(image.height <= Int(ThumbnailCache.cardSize.height * 2) + 1)
        #expect(max(image.width, image.height) > 200)
        #expect(Thumbnailer.render(SceneFile(), size: ThumbnailCache.cardSize) == nil)
    }
}
