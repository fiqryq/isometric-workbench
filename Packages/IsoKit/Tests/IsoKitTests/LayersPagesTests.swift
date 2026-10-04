import Foundation
import IsoDocument
import Testing

@Suite("Layers and pages")
struct LayersPagesTests {
    private func scene(_ names: [String]) -> SceneFile {
        var s = SceneFile()
        s.parts = names.map { Part(id: $0, name: $0.uppercased(), ops: [.box(w: 10, d: 10, h: 10)]) }
        return s
    }

    @Test("The outline keeps every part once and stays plain without groups")
    func outline() throws {
        var s = scene(["a", "b", "c"])
        #expect(s.outline == [.part("a"), .part("b"), .part("c")])

        s.layers = [.part("ghost"), .group(LayerGroup(id: "g", name: "G", children: [.part("c"), .part("a"), .part("c")]))]
        #expect(s.layerOrder == ["c", "a", "b"])

        s.setOutline(s.outline)
        #expect(s.parts.map(\.id) == ["c", "a", "b"])
        #expect(s.ancestors(of: "a").map(\.id) == ["g"])

        let back = try SceneFile.decode(s.encoded())
        #expect(back.outline == s.outline)
        #expect(back.parts.map(\.id) == ["c", "a", "b"])

        s.setOutline([.part("b"), .part("a"), .part("c")])
        #expect(s.layers.isEmpty)
        #expect(s.parts.map(\.id) == ["b", "a", "c"])
        #expect(s.json["layers"] == nil)
    }

    @Test("Hidden and locked groups apply to everything inside")
    func groupState() throws {
        var s = scene(["a", "b", "c"])
        let inner = LayerGroup(id: "inner", name: "Inner", children: [.part("b")])
        s.setOutline([.part("a"), .group(LayerGroup(id: "outer", name: "Outer", children: [.group(inner), .part("c")]))])
        #expect(!s.isHidden("b"))

        s.updateGroup("outer") { $0.hidden = true }
        #expect(s.isHidden("b") && s.isHidden("c") && !s.isHidden("a"))
        s.updateGroup("inner") { $0.locked = true }
        #expect(s.isLocked("b") && !s.isLocked("c"))
        #expect(s.allGroups.map(\.id) == ["outer", "inner"])

        s.drawOrder = .layers
        let back = try SceneFile.decode(s.encoded())
        #expect(back.drawOrder == .layers)
        #expect(back.group("inner")?.locked == true)
        #expect(back.group("outer")?.hidden == true)
    }

    @Test("Each page is its own canvas with its own parts, art, camera and timing")
    func pages() throws {
        var s = scene(["a", "b"])
        s.duration = 2
        s.parts[0].anim.base["x"] = 10
        s.parts[0].anim.keys["z"] = [Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 50)]
        s.guides = [Guide(a: .zero, b: Vec3(10, 0, 0))]
        #expect(s.allPages.count == 1)

        let second = s.addPage()
        #expect(s.pages.count == 2 && s.activePage == second)
        #expect(s.parts.isEmpty && s.guides.isEmpty && s.frames.isEmpty)
        #expect(s.duration == 2)

        s.duration = 6
        s.camera.base["spin"] = 45
        s.parts.append(Part(id: "c", name: "C", ops: [.box(w: 5, d: 5, h: 5)]))

        let first = s.pages[0].id
        s.activatePage(first)
        #expect(s.duration == 2)
        #expect(s.parts.map(\.id) == ["a", "b"])
        #expect(s.parts[0].anim.base("x") == 10 && s.parts[0].anim.isAnimated)
        #expect(s.guides.count == 1)
        #expect(s.camera.base("spin") == 0)

        let back = try SceneFile.decode(s.encoded())
        #expect(back.activePage == first && back.parts.map(\.id) == ["a", "b"])
        var other = back
        other.activatePage(second)
        #expect(other.duration == 6 && other.parts.map(\.id) == ["c"] && other.guides.isEmpty)

        let copy = s.addPage(duplicate: true)
        #expect(s.parts.map(\.id) == ["a", "b"] && s.parts[0].anim.isAnimated)
        #expect(s.pages.map(\.id) == [first, copy, second])
        s.movePage(copy, to: 2)
        #expect(s.pages.map(\.id) == [first, second, copy])
        s.renamePage(second, to: "Exploded")
        #expect(s.pages[1].name == "Exploded")

        s.deletePage(copy)
        #expect(s.activePage == second && s.duration == 6)
        s.deletePage(second)
        s.deletePage(first)
        #expect(s.pages.count == 1)
    }

    @Test("Pages from files where every page showed the same parts keep what they showed")
    func legacyPages() throws {
        let json: JSONValue = [
            "v": 2, "name": "Old",
            "parts": [["id": "a", "name": "A", "ops": [], "base": ["x": 5]]],
            "pages": [
                ["id": "p1", "name": "Page 1", "anims": ["a": ["base": ["x": 5]]], "hidden": []],
                ["id": "p2", "name": "Page 2", "anims": ["a": ["base": ["x": 80]]], "hidden": ["a"]],
            ],
            "activePage": "p1",
        ]
        var s = try SceneFile(json: json)
        #expect(s.parts.map(\.id) == ["a"])
        s.activatePage("p2")
        #expect(s.parts.map(\.id) == ["a"] && s.parts[0].anim.base("x") == 80 && s.parts[0].hidden)
        s.parts.removeAll()
        s.activatePage("p1")
        #expect(s.parts.count == 1 && s.parts[0].anim.base("x") == 5 && !s.parts[0].hidden)
    }
}
