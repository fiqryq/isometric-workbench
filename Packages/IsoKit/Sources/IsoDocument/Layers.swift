import Foundation

/// How parts are stacked when drawn.
public enum DrawOrder: String, Sendable, Hashable, CaseIterable {
    /// Sorted by distance from the viewer every frame (correct for 3D).
    case depth
    /// The layer list decides: later layers draw on top, like Figma.
    case layers
}

/// A folder in the layer list. Hiding or locking it hides or locks everything inside.
public struct LayerGroup: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var hidden: Bool
    public var locked: Bool
    public var collapsed: Bool
    /// Back to front, like `SceneFile.layers`.
    public var children: [LayerNode]

    public init(id: String = makeID(), name: String, hidden: Bool = false, locked: Bool = false, collapsed: Bool = false, children: [LayerNode] = []) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.locked = locked
        self.collapsed = collapsed
        self.children = children
    }

    init(json: JSONValue) {
        id = json["id"]?.string ?? makeID()
        name = json["name"]?.string ?? "Group"
        hidden = json["hidden"]?.isTruthy ?? false
        locked = json["locked"]?.isTruthy ?? false
        collapsed = json["collapsed"]?.isTruthy ?? false
        children = (json["children"]?.array ?? []).compactMap(LayerNode.init(json:))
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(name), "children": .array(children.map(\.json))]
        if hidden { o["hidden"] = true }
        if locked { o["locked"] = true }
        if collapsed { o["collapsed"] = true }
        return .object(o)
    }
}

/// One row of the layer tree: a part (by id) or a group.
public indirect enum LayerNode: Sendable, Hashable, Identifiable {
    case part(Part.ID)
    case group(LayerGroup)

    public var id: String {
        switch self {
        case .part(let id): id
        case .group(let g): g.id
        }
    }

    public var group: LayerGroup? {
        if case .group(let g) = self { return g }
        return nil
    }

    /// Part ids inside this node, back to front.
    public var partIDs: [Part.ID] {
        switch self {
        case .part(let id): [id]
        case .group(let g): g.children.flatMap(\.partIDs)
        }
    }

    init?(json: JSONValue) {
        if let id = json.string {
            self = .part(id)
        } else if json.object != nil {
            self = .group(LayerGroup(json: json))
        } else {
            return nil
        }
    }

    var json: JSONValue {
        switch self {
        case .part(let id): .string(id)
        case .group(let g): g.json
        }
    }
}

extension SceneFile {
    /// The layer tree, back to front, with every part exactly once: unknown or repeated
    /// ids are dropped and parts missing from `layers` are added on top in `parts` order.
    public var outline: [LayerNode] {
        var known = Set(parts.map(\.id))
        func clean(_ nodes: [LayerNode]) -> [LayerNode] {
            nodes.compactMap { node in
                switch node {
                case .part(let id):
                    return known.remove(id) != nil ? node : nil
                case .group(var g):
                    g.children = clean(g.children)
                    return .group(g)
                }
            }
        }
        var tree = clean(layers)
        tree += parts.filter { known.contains($0.id) }.map { .part($0.id) }
        return tree
    }

    /// Part ids in layer order, back to front.
    public var layerOrder: [Part.ID] { outline.flatMap(\.partIDs) }

    /// Groups that contain `id` (a part or group), outermost first.
    public func ancestors(of id: String) -> [LayerGroup] {
        func search(_ nodes: [LayerNode], _ path: [LayerGroup]) -> [LayerGroup]? {
            for node in nodes {
                if node.id == id { return path }
                if case .group(let g) = node, let found = search(g.children, path + [g]) { return found }
            }
            return nil
        }
        return search(outline, []) ?? []
    }

    public func group(_ id: String) -> LayerGroup? {
        func search(_ nodes: [LayerNode]) -> LayerGroup? {
            for case .group(let g) in nodes {
                if g.id == id { return g }
                if let found = search(g.children) { return found }
            }
            return nil
        }
        return search(layers)
    }

    /// Every group in the tree, depth first.
    public var allGroups: [LayerGroup] {
        func collect(_ nodes: [LayerNode]) -> [LayerGroup] {
            nodes.flatMap { node -> [LayerGroup] in
                guard case .group(let g) = node else { return [] }
                return [g] + collect(g.children)
            }
        }
        return collect(layers)
    }

    /// Hidden itself or inside a hidden group.
    public func isHidden(_ partID: Part.ID) -> Bool {
        guard let i = partIndex(partID) else { return true }
        return parts[i].hidden || ancestors(of: partID).contains(where: \.hidden)
    }

    /// Locked itself or inside a locked group.
    public func isLocked(_ partID: Part.ID) -> Bool {
        guard let i = partIndex(partID) else { return false }
        return parts[i].locked || ancestors(of: partID).contains(where: \.locked)
    }

    /// Edits the group with `id` in place; returns false if there's no such group.
    @discardableResult
    public mutating func updateGroup(_ id: String, _ body: (inout LayerGroup) -> Void) -> Bool {
        func visit(_ nodes: inout [LayerNode]) -> Bool {
            for i in nodes.indices {
                guard case .group(var g) = nodes[i] else { continue }
                if g.id == id {
                    body(&g)
                    nodes[i] = .group(g)
                    return true
                }
                if visit(&g.children) {
                    nodes[i] = .group(g)
                    return true
                }
            }
            return false
        }
        var tree = outline
        guard visit(&tree) else { return false }
        setOutline(tree)
        return true
    }

    /// Replaces the layer tree and reorders `parts` to match it. With no groups the
    /// tree is stored only as part order, so files stay readable by the web Studio.
    public mutating func setOutline(_ tree: [LayerNode]) {
        layers = tree
        let order = outline
        let ids = order.flatMap(\.partIDs)
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        parts.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        layers = order.contains { $0.group != nil } ? order : []
    }
}
