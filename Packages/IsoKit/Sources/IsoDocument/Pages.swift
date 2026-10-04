import Foundation

/// One page of a document. Pages share the parts (geometry, style, callouts) but
/// each has its own camera, timing, frames, and per-part transform, keys and visibility.
public struct Page: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var duration: Double
    public var fps: Double
    public var camera: Animatable
    public var frames: [Artboard]
    /// Part id → transform and keys on this page.
    public var anims: [Part.ID: Animatable]
    public var hidden: Set<Part.ID>

    public init(id: String = makeID(), name: String, duration: Double = 4, fps: Double = 24, camera: Animatable = Animatable(base: ["spin": 0]),
                frames: [Artboard] = [], anims: [Part.ID: Animatable] = [:], hidden: Set<Part.ID> = []) {
        self.id = id
        self.name = name
        self.duration = duration
        self.fps = fps
        self.camera = camera
        self.frames = frames
        self.anims = anims
        self.hidden = hidden
    }

    init(json: JSONValue) {
        id = json["id"]?.string ?? makeID()
        name = json["name"]?.string ?? "Page"
        duration = max(0.1, json["duration"]?.jsNumber ?? 4)
        fps = max(1, json["fps"]?.jsNumber ?? 24)
        camera = Animatable(json: json["camera"])
        frames = json["frames"]?.array.map { $0.map(Artboard.init(json:)) } ?? Artboard.legacySheet(json["sheet"]).map { [$0] } ?? []
        var anims: [Part.ID: Animatable] = [:]
        for (id, a) in json["anims"]?.object ?? [:] { anims[id] = Animatable(json: a) }
        self.anims = anims
        hidden = Set((json["hidden"]?.array ?? []).compactMap(\.string))
    }

    var json: JSONValue {
        var anims: [String: JSONValue] = [:]
        for (id, a) in self.anims { anims[id] = ["base": a.baseJSON, "keys": a.keysJSON] }
        return [
            "id": .string(id), "name": .string(name), "duration": .number(duration), "fps": .number(fps),
            "camera": ["base": camera.baseJSON, "keys": camera.keysJSON], "frames": .array(frames.map(\.json)),
            "anims": .object(anims), "hidden": .array(hidden.sorted().map(JSONValue.string)),
        ]
    }
}

extension SceneFile {
    /// The pages, with the active one up to date. A document without pages has one implicit page.
    public var allPages: [Page] {
        var s = self
        s.storeActivePage()
        return s.pages.isEmpty ? [s.currentPageState(id: "page", name: "Page 1")] : s.pages
    }

    public var activePageIndex: Int? { pages.firstIndex { $0.id == activePage } }

    /// The editable fields (duration, camera, part transforms…) as a page.
    func currentPageState(id: String, name: String) -> Page {
        Page(id: id, name: name, duration: duration, fps: fps, camera: camera, frames: frames,
             anims: Dictionary(uniqueKeysWithValues: parts.map { ($0.id, $0.anim) }),
             hidden: Set(parts.filter(\.hidden).map(\.id)))
    }

    /// Writes the editable fields back into the active page.
    public mutating func storeActivePage() {
        guard let i = activePageIndex else { return }
        let p = pages[i]
        pages[i] = currentPageState(id: p.id, name: p.name)
    }

    /// Makes `id` the active page, loading its camera, timing, frames and part transforms.
    /// Parts the page doesn't know about keep their current transform.
    public mutating func activatePage(_ id: Page.ID) {
        guard id != activePage, let page = pages.first(where: { $0.id == id }) else { return }
        storeActivePage()
        duration = page.duration
        fps = page.fps
        camera = page.camera
        frames = page.frames
        for i in parts.indices {
            if let a = page.anims[parts[i].id] {
                parts[i].anim = a
                parts[i].hidden = page.hidden.contains(parts[i].id)
            }
        }
        activePage = id
    }

    /// Adds a page after the active one and makes it active. A duplicate copies the
    /// animation; otherwise parts start where they are now, with no keys.
    @discardableResult
    public mutating func addPage(name: String? = nil, duplicate: Bool = false) -> Page.ID {
        if pages.isEmpty {
            let first = makeID()
            pages = [currentPageState(id: first, name: "Page 1")]
            activePage = first
        }
        storeActivePage()
        let source = pages[activePageIndex ?? 0]
        var page = source
        page.id = makeID()
        page.name = name ?? (duplicate ? "\(source.name) copy" : uniquePageName())
        if !duplicate {
            page.camera.keys = [:]
            for (id, a) in page.anims {
                var still = a
                still.keys = [:]
                page.anims[id] = still
            }
        }
        pages.insert(page, at: (activePageIndex ?? pages.count - 1) + 1)
        activatePage(page.id)
        return page.id
    }

    /// Removes a page; the last page can't be removed.
    public mutating func deletePage(_ id: Page.ID) {
        guard pages.count > 1, let i = pages.firstIndex(where: { $0.id == id }) else { return }
        if id == activePage { activatePage(pages[i == 0 ? 1 : i - 1].id) }
        pages.remove(at: i)
    }

    /// Renames a page; `id` may be the implicit page's id from `allPages`.
    public mutating func renamePage(_ id: Page.ID, to name: String) {
        if pages.isEmpty {
            addFirstPage()
            pages[0].name = name
            return
        }
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].name = name
    }

    /// Moves a page to a new position in the tab order.
    public mutating func movePage(_ id: Page.ID, to index: Int) {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let page = pages.remove(at: from)
        pages.insert(page, at: min(max(0, index), pages.count))
    }

    mutating func addFirstPage() {
        let first = makeID()
        pages = [currentPageState(id: first, name: "Page 1")]
        activePage = first
    }

    func uniquePageName() -> String {
        let names = Set(pages.map(\.name))
        var n = pages.count + 1
        while names.contains("Page \(n)") { n += 1 }
        return "Page \(n)"
    }
}
