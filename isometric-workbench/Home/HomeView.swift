import AppKit
import IsoDocument
import IsoExamples
import SwiftUI
import UniformTypeIdentifiers

enum HomeSection: Hashable {
    case recents, drafts, trash
    case folder(String)

    var title: String {
        switch self {
        case .recents: "Recents"
        case .drafts: "Drafts"
        case .trash: "Trash"
        case .folder(let name): name
        }
    }

    var symbol: String {
        switch self {
        case .recents: "clock"
        case .drafts: "doc.text"
        case .trash: "trash"
        case .folder: "folder"
        }
    }
}

enum HomeSort: String, CaseIterable {
    case modified = "Last modified"
    case name = "Name"
}

/// Figma-style file browser: recents, drafts, folders and trash.
struct HomeView: View {
    @State private var library = Library.shared
    @State private var section: HomeSection? = .recents
    @State private var search = ""
    @State private var selection: URL?
    @State private var renamingFile: LibraryFile?
    @State private var renamingFolder: String?
    @State private var draft = ""
    @State private var error: String?
    @AppStorage("homeSort") private var sort = HomeSort.modified
    @AppStorage("homeShowTemplates") private var showTemplates = true

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .navigationTitle(section?.title ?? "Home")
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort", selection: $sort) {
                    ForEach(HomeSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .help("Sort files")
                Button { importFiles() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Copy scenes from another folder into this one")
                Menu {
                    CreateMenuItems(folder: currentFolder)
                } label: {
                    Label("Create", systemImage: "plus")
                } primaryAction: {
                    HomeActions.createBlank(in: currentFolder)
                }
                .menuIndicator(.visible)
                .help("Create a new file")
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .task {
            while !Task.isCancelled {
                library.reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("Rename", isPresented: Binding(get: { renamingFile != nil || renamingFolder != nil }, set: { if !$0 { renamingFile = nil; renamingFolder = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var currentFolder: String? {
        if case .folder(let name) = section { return name }
        return nil
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Section {
                row(.recents)
                row(.drafts)
            }
            Section {
                ForEach(library.folders, id: \.self) { name in
                    row(.folder(name))
                        .contextMenu {
                            Button("Rename…") { draft = name; renamingFolder = name }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.directory(name)]) }
                            Divider()
                            Button("Delete Folder", role: .destructive) { attempt { try library.deleteFolder(name); section = .drafts } }
                        }
                        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: name) }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { attempt { section = .folder(try library.createFolder()) } } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New folder")
                }
            }
            Section {
                row(.trash)
            }
        }
        .contextMenu {
            Button("New Folder") { attempt { section = .folder(try library.createFolder()) } }
            Button("Show Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.root]) }
        }
    }

    private func row(_ s: HomeSection) -> some View {
        Label(s.title, systemImage: s.symbol)
            .badge(s == .trash && !library.trashed.isEmpty ? library.trashed.count : 0)
            .tag(s)
            .dropDestination(for: URL.self) { urls, _ in
                s == .drafts ? drop(urls, into: nil) : false
            }
    }

    // MARK: - Detail

    private var files: [LibraryFile] {
        let list: [LibraryFile]
        if !search.isEmpty {
            list = (library.allFiles + library.recents.filter { !library.isInLibrary($0.url) })
                .filter { $0.name.localizedCaseInsensitiveContains(search) }
        } else {
            switch section ?? .recents {
            case .recents:
                let recent = library.recents
                let rest = library.allFiles.filter { f in !recent.contains { $0.url.standardizedFileURL == f.url.standardizedFileURL } }
                list = recent + rest
            case .drafts: list = library.drafts
            case .trash: list = library.trashed
            case .folder(let name): list = library.folderFiles[name] ?? []
            }
        }
        switch sort {
        case .modified: return list.sorted { $0.modified > $1.modified }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if showTemplates, search.isEmpty, section != .trash {
                    TemplateStrip(folder: currentFolder) { showTemplates = false }
                }
                let files = files
                if files.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(files) { file in
                            FileCard(file: file, selected: selection == file.url, inTrash: section == .trash && search.isEmpty)
                                .onTapGesture(count: 2) { open(file) }
                                .onTapGesture { selection = file.url }
                                .contextMenu { menu(for: file) }
                                .draggable(file.url)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onTapGesture { selection = nil }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: (section ?? .recents).symbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(search.isEmpty ? (section ?? .recents).title : "Results for “\(search)”")
                .font(.system(size: 26, weight: .bold))
            if let folder = currentFolder, search.isEmpty {
                Menu {
                    Button("Rename…") { draft = folder; renamingFolder = folder }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.directory(folder)]) }
                    Divider()
                    Button("Delete Folder", role: .destructive) { attempt { try library.deleteFolder(folder); section = .drafts } }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Spacer()
            if section == .trash, !library.trashed.isEmpty, search.isEmpty {
                Button("Empty Trash", role: .destructive) { attempt { try library.emptyTrash() } }
            } else if !showTemplates, section != .trash {
                Button("Show Templates") { showTemplates = true }
                    .buttonStyle(.link)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: section == .trash ? "trash" : "square.dashed")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(section == .trash ? "Trash is empty" : search.isEmpty ? "No files yet" : "No matching files")
                .font(.title3.weight(.semibold))
            if section != .trash, search.isEmpty {
                Text("Create a file or start from a template.")
                    .foregroundStyle(.secondary)
                Button("Create File") { HomeActions.createBlank(in: currentFolder) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    @ViewBuilder
    private func menu(for file: LibraryFile) -> some View {
        if section == .trash, search.isEmpty {
            Button("Put Back") { attempt { try library.restore(file) } }
            Button("Delete Forever", role: .destructive) { attempt { try library.deleteForever(file) } }
        } else {
            Button("Open") { open(file) }
            if library.isInLibrary(file.url) {
                Button("Rename…") { draft = file.name; renamingFile = file }
                Button("Duplicate") { attempt { try library.duplicate(file) } }
                Menu("Move to") {
                    Button("Drafts") { attempt { try library.move(file, to: nil) } }.disabled(file.folder == nil)
                    if !library.folders.isEmpty { Divider() }
                    ForEach(library.folders, id: \.self) { name in
                        Button(name) { attempt { try library.move(file, to: name) } }.disabled(file.folder == name)
                    }
                    Divider()
                    Button("New Folder…") {
                        attempt {
                            let name = try library.createFolder()
                            try library.move(file, to: name)
                        }
                    }
                }
            } else {
                Button("Copy to Drafts") { attempt { try library.importFiles([file.url]) } }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            if library.isInLibrary(file.url) {
                Divider()
                Button("Move to Trash", role: .destructive) { attempt { try library.moveToTrash(file) } }
            }
        }
    }

    // MARK: - Actions

    private func open(_ file: LibraryFile) {
        guard !(section == .trash && search.isEmpty) else { return }
        HomeActions.open(file.url)
    }

    private func drop(_ urls: [URL], into folder: String?) -> Bool {
        let inside = urls.compactMap { url in library.allFiles.first { $0.url.standardizedFileURL == url.standardizedFileURL } }
        guard !inside.isEmpty else { return false }
        attempt { for file in inside { try library.move(file, to: folder) } }
        return true
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.isoScene, .json]
        panel.allowsMultipleSelection = true
        panel.message = "Choose scenes to copy into \(currentFolder ?? "Drafts")"
        guard panel.runModal() == .OK else { return }
        attempt { try library.importFiles(panel.urls, into: currentFolder) }
    }

    private func commitRename() {
        if let file = renamingFile { attempt { try library.rename(file, to: draft) } }
        if let folder = renamingFolder {
            attempt {
                try library.renameFolder(folder, to: draft)
                if section == .folder(folder) { section = .folder(draft.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
        renamingFile = nil
        renamingFolder = nil
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Cards

struct FileCard: View {
    let file: LibraryFile
    let selected: Bool
    var inTrash = false
    @State private var cache = ThumbnailCache.shared

    var body: some View {
        let key = ThumbnailCache.key(file)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(nsColor: .quaternarySystemFill)
                if let image = cache.image(key) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(10)
                } else if cache.blank.contains(key) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 150)
            .clipped()
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .opacity(inTrash ? 0.7 : 1)
        .task(id: key) { await cache.load(file) }
        .help(file.url.path)
    }

    private var subtitle: String {
        let edited = "Edited \(file.modified.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
        return file.folder.map { "\($0) · \(edited)" } ?? edited
    }
}

struct TemplateStrip: View {
    let folder: String?
    let dismiss: () -> Void
    @State private var cache = ThumbnailCache.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Get started with a template")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide templates")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    templateCard(title: "Blank canvas", key: nil) { HomeActions.createBlank(in: folder) }
                    ForEach(Example.all) { ex in
                        templateCard(title: ex.title, key: "example:\(ex.id)") {
                            HomeActions.create(ex.scene(), name: ex.title, in: folder)
                        }
                        .task { await cache.load(scene: ex.scene(), key: "example:\(ex.id)") }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .quaternarySystemFill)))
    }

    private func templateCard(title: String, key: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    if let key, let image = cache.image(key) {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(8)
                    } else if key == nil {
                        Image(systemName: "plus").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 180, height: 104)
                .clipped()
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: 180, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(key == nil ? "Create a blank file" : "Create a file from \(title)")
    }
}

struct CreateMenuItems: View {
    let folder: String?

    var body: some View {
        Button("Blank Canvas") { HomeActions.createBlank(in: folder) }
        Divider()
        ForEach(Example.all) { ex in
            Button(ex.title) { HomeActions.create(ex.scene(), name: ex.title, in: folder) }
        }
    }
}

/// Creating and opening library files as documents.
@MainActor
enum HomeActions {
    static func createBlank(in folder: String? = nil) {
        create(SceneFile(), name: "Untitled", in: folder)
    }

    static func create(_ scene: SceneFile, name: String, in folder: String? = nil) {
        do {
            open(try Library.shared.create(scene, name: name, in: folder))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            guard let message = error?.localizedDescription else { return }
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "The file couldn't be opened."
                alert.informativeText = message
                alert.runModal()
            }
        }
    }
}

/// Opens the Home window from places without a SwiftUI environment (the Dock menu).
@MainActor
enum HomeWindow {
    static let id = "home"
    static var openAction: OpenWindowAction?

    static func show() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }), window.isVisible || window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        } else {
            openAction?(id: id)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { HomeWindow.show() }
        return false
    }
}
