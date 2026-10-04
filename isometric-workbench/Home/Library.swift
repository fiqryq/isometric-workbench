import AppKit
import Foundation
import IsoDocument
import Observation
import UniformTypeIdentifiers

struct LibraryFile: Identifiable, Hashable {
    var url: URL
    var modified: Date
    /// Folder name, or nil for Drafts (or for a recent file outside the library).
    var folder: String?

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The Home window's files: Drafts are scenes at the library root, folders are
/// one level of subfolders, and Trash is a hidden folder inside it.
@MainActor
@Observable
final class Library {
    static let shared = Library(root: Library.defaultRoot)

    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Isometric Workbench", isDirectory: true)
    }

    static let fileExtension = "isoscene"

    let root: URL
    private(set) var drafts: [LibraryFile] = []
    private(set) var folders: [String] = []
    private(set) var folderFiles: [String: [LibraryFile]] = [:]
    private(set) var trashed: [LibraryFile] = []
    private(set) var recents: [LibraryFile] = []

    var trash: URL { root.appendingPathComponent(".Trash", isDirectory: true) }

    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    var allFiles: [LibraryFile] { drafts + folders.flatMap { folderFiles[$0] ?? [] } }

    func reload() {
        let newDrafts = scan(root, folder: nil)
        let names = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var byFolder: [String: [LibraryFile]] = [:]
        for name in names { byFolder[name] = scan(root.appendingPathComponent(name, isDirectory: true), folder: name) }
        let newTrash = scan(trash, folder: nil)
        let newRecents = NSDocumentController.shared.recentDocumentURLs.compactMap { url -> LibraryFile? in
            guard let modified = modificationDate(url) else { return nil }
            return LibraryFile(url: url, modified: modified, folder: folderName(of: url))
        }
        if newDrafts != drafts { drafts = newDrafts }
        if names != folders { folders = names }
        if byFolder != folderFiles { folderFiles = byFolder }
        if newTrash != trashed { trashed = newTrash }
        if newRecents != recents { recents = newRecents }
    }

    // MARK: - Files

    /// Writes a new scene into Drafts (or a folder) and returns its URL.
    @discardableResult
    func create(_ scene: SceneFile, name: String, in folder: String? = nil) throws -> URL {
        let url = uniqueURL(name, in: directory(folder))
        var scene = scene
        scene.name = url.deletingPathExtension().lastPathComponent
        try scene.encoded().write(to: url, options: .atomic)
        reload()
        return url
    }

    /// Copies scenes from elsewhere into Drafts or a folder.
    func importFiles(_ urls: [URL], into folder: String? = nil) throws {
        for url in urls {
            let scene = try SceneFile.decode(Data(contentsOf: url))
            try create(scene, name: url.deletingPathExtension().lastPathComponent, in: folder)
        }
    }

    func rename(_ file: LibraryFile, to name: String) throws {
        let trimmed = sanitized(name)
        guard !trimmed.isEmpty, trimmed != file.name else { return }
        try fm.moveItem(at: file.url, to: uniqueURL(trimmed, in: file.url.deletingLastPathComponent()))
        reload()
    }

    @discardableResult
    func duplicate(_ file: LibraryFile) throws -> URL {
        let copy = uniqueURL("\(file.name) copy", in: file.url.deletingLastPathComponent())
        try fm.copyItem(at: file.url, to: copy)
        reload()
        return copy
    }

    func move(_ file: LibraryFile, to folder: String?) throws {
        let dir = directory(folder)
        guard file.url.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL else { return }
        try fm.moveItem(at: file.url, to: uniqueURL(file.name, in: dir))
        reload()
    }

    func moveToTrash(_ file: LibraryFile) throws {
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try fm.moveItem(at: file.url, to: uniqueURL(file.name, in: trash))
        reload()
    }

    /// Puts a trashed file back in Drafts.
    func restore(_ file: LibraryFile) throws {
        try fm.moveItem(at: file.url, to: uniqueURL(file.name, in: root))
        reload()
    }

    func deleteForever(_ file: LibraryFile) throws {
        try fm.removeItem(at: file.url)
        reload()
    }

    func emptyTrash() throws {
        for file in trashed { try fm.removeItem(at: file.url) }
        reload()
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(named name: String = "New Folder") throws -> String {
        let base = sanitized(name).isEmpty ? "New Folder" : sanitized(name)
        var candidate = base, n = 2
        while fm.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(n)"
            n += 1
        }
        try fm.createDirectory(at: root.appendingPathComponent(candidate, isDirectory: true), withIntermediateDirectories: false)
        reload()
        return candidate
    }

    func renameFolder(_ folder: String, to name: String) throws {
        let trimmed = sanitized(name)
        guard !trimmed.isEmpty, trimmed != folder, !fm.fileExists(atPath: root.appendingPathComponent(trimmed).path) else { return }
        try fm.moveItem(at: root.appendingPathComponent(folder, isDirectory: true), to: root.appendingPathComponent(trimmed, isDirectory: true))
        reload()
    }

    /// Moves the folder's files to Trash, then removes the folder.
    func deleteFolder(_ folder: String) throws {
        for file in folderFiles[folder] ?? [] { try moveToTrash(file) }
        try fm.removeItem(at: root.appendingPathComponent(folder, isDirectory: true))
        reload()
    }

    // MARK: - Helpers

    func directory(_ folder: String?) -> URL {
        folder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
    }

    func isInLibrary(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    private func folderName(of url: URL) -> String? {
        guard isInLibrary(url) else { return nil }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return parent == root.standardizedFileURL ? nil : parent.lastPathComponent
    }

    private func scan(_ dir: URL, folder: String?) -> [LibraryFile] {
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.pathExtension == Self.fileExtension }.compactMap { url in
            modificationDate(url).map { LibraryFile(url: url, modified: $0, folder: folder) }
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func uniqueURL(_ name: String, in dir: URL) -> URL {
        let base = sanitized(name).isEmpty ? "Untitled" : sanitized(name)
        var url = dir.appendingPathComponent(base).appendingPathExtension(Self.fileExtension)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(Self.fileExtension)
            n += 1
        }
        return url
    }
}
