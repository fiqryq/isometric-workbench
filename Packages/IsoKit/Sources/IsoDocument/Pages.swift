import Foundation

/// One page of a document: its own canvas, as in Figma. Each page has its own
/// parts, flat art, guides, dimensions, layers, frames, camera and timing; the
/// style and projection angle are document-wide.
public struct Page: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var duration: Double
    public var fps: Double
    public var camera: Animatable
    public var frames: [Artboard]
    public var parts: [Part]
    public var guides: [Guide]
    public var dimensions: [DimensionLine]
    public var shapes: [FlatShape]
    public var decals: [Decal]
    public var layers: [LayerNode]
    /// Set on pages from files where every page showed the document's parts;
    /// resolved into `parts` on load.
    var legacy: LegacyPageState?

    public init(id: String = makeID(), name: String, duration: Double = 4, fps: Double = 24, camera: Animatable = Animatable(base: ["spin": 0]),
                frames: [Artboard] = [], parts: [Part] = [], guides: [Guide] = [], dimensions: [DimensionLine] = [],
                shapes: [FlatShape] = [], decals: [Decal] = [], layers: [LayerNode] = []) {
        self.id = id
        self.name = name
        self.duration = duration
        self.fps = fps
        self.camera = camera
        self.frames = frames
        self.parts = parts
        self.guides = guides
        self.dimensions = dimensions
        self.shapes = shapes
        self.decals = decals
        self.layers = layers
    }

    init(json: JSONValue) {
        id = json["id"]?.string ?? makeID()
        name = json["name"]?.string ?? "Page"
        duration = max(0.1, json["duration"]?.jsNumber ?? 4)
        fps = max(1, json["fps"]?.jsNumber ?? 24)
        camera = Animatable(json: json["camera"])
        frames = json["frames"]?.array.map { $0.map(Artboard.init(json:)) } ?? Artboard.legacySheet(json["sheet"]).map { [$0] } ?? []
        parts = (json["parts"]?.array ?? []).map(Part.init(json:))
        guides = (json["guides"]?.array ?? []).map(Guide.init(json:))
        dimensions = (json["dimensions"]?.array ?? []).map(DimensionLine.init(json:))
        shapes = (json["shapes"]?.array ?? []).map(FlatShape.init(json:))
        decals = (json["decals"]?.array ?? []).map(Decal.init(json:))
        layers = (json["layers"]?.array ?? []).compactMap(LayerNode.init(json:))
        if json["parts"] == nil {
            var anims: [Part.ID: Animatable] = [:]
            for (id, a) in json["anims"]?.object ?? [:] { anims[id] = Animatable(json: a) }
            legacy = LegacyPageState(anims: anims, hidden: Set((json["hidden"]?.array ?? []).compactMap(\.string)))
        }
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "duration": .number(duration), "fps": .number(fps),
            "camera": ["base": camera.baseJSON, "keys": camera.keysJSON], "frames": .array(frames.map(\.json)),
            "parts": .array(parts.map(\.json)),
        ]
        if !guides.isEmpty { o["guides"] = .array(guides.map(\.json)) }
        if !dimensions.isEmpty { o["dimensions"] = .array(dimensions.map(\.json)) }
        if !shapes.isEmpty { o["shapes"] = .array(shapes.map(\.json)) }
        if !decals.isEmpty { o["decals"] = .array(decals.map(\.json)) }
        if !layers.isEmpty { o["layers"] = .array(layers.map(\.json)) }
        return .object(o)
    }
}

/// What an old shared-parts page stored: part id → transform and keys, and hidden ids.
struct LegacyPageState: Sendable, Hashable {
    var anims: [Part.ID: Animatable]
    var hidden: Set<Part.ID>
}

extension SceneFile {
    /// The pages, with the active one up to date. A document without pages has one implicit page.
    public var allPages: [Page] {
        var s = self
        s.storeActivePage()
        return s.pages.isEmpty ? [s.currentPageState(id: "page", name: "Page 1")] : s.pages
    }

    public var activePageIndex: Int? { pages.firstIndex { $0.id == activePage } }

    /// The editable fields (parts, art, camera, timing…) as a page.
    func currentPageState(id: String, name: String) -> Page {
        Page(id: id, name: name, duration: duration, fps: fps, camera: camera, frames: frames, parts: parts, guides: guides,
             dimensions: dimensions, shapes: shapes, decals: decals, layers: layers)
    }

    /// Writes the editable fields back into the active page.
    public mutating func storeActivePage() {
        guard let i = activePageIndex else { return }
        let p = pages[i]
        pages[i] = currentPageState(id: p.id, name: p.name)
    }

    /// Makes `id` the active page, loading everything on it.
    public mutating func activatePage(_ id: Page.ID) {
        guard id != activePage, let page = pages.first(where: { $0.id == id }) else { return }
        storeActivePage()
        duration = page.duration
        fps = page.fps
        camera = page.camera
        frames = page.frames
        parts = page.parts
        guides = page.guides
        dimensions = page.dimensions
        shapes = page.shapes
        decals = page.decals
        layers = page.layers
        activePage = id
    }

    /// Fills pages read from files where every page showed the document's parts,
    /// so each keeps what it showed.
    mutating func resolveLegacyPages() {
        for i in pages.indices {
            guard let legacy = pages[i].legacy else { continue }
            pages[i].legacy = nil
            pages[i].parts = parts.map { p in
                var p = p
                if let a = legacy.anims[p.id] {
                    p.anim = a
                    p.hidden = legacy.hidden.contains(p.id)
                }
                return p
            }
            pages[i].guides = guides
            pages[i].dimensions = dimensions
            pages[i].shapes = shapes
            pages[i].decals = decals
            pages[i].layers = layers
        }
    }

    /// Adds a page after the active one and makes it active. A new page is an
    /// empty canvas with the same timing; a duplicate copies everything.
    @discardableResult
    public mutating func addPage(name: String? = nil, duplicate: Bool = false) -> Page.ID {
        if pages.isEmpty {
            let first = makeID()
            pages = [currentPageState(id: first, name: "Page 1")]
            activePage = first
        }
        storeActivePage()
        let source = pages[activePageIndex ?? 0]
        var page = duplicate ? source : Page(name: "", duration: source.duration, fps: source.fps)
        page.id = makeID()
        page.name = name ?? (duplicate ? "\(source.name) copy" : uniquePageName())
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
