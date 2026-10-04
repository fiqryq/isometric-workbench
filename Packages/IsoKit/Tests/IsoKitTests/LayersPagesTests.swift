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

    @Test("Pages share parts but keep their own camera, timing and transforms")
    func pages() throws {
        var s = scene(["a", "b"])
        s.duration = 2
        s.parts[0].anim.base["x"] = 10
        s.parts[0].anim.keys["z"] = [Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 50)]
        #expect(s.allPages.count == 1)

        let second = s.addPage()
        #expect(s.pages.count == 2 && s.activePage == second)
        #expect(s.parts[0].anim.base("x") == 10)
        #expect(!s.parts[0].anim.isAnimated)

        s.duration = 6
        s.parts[0].anim.base["x"] = 99
        s.parts[1].hidden = true
        s.camera.base["spin"] = 45
        s.parts.append(Part(id: "c", name: "C", ops: [.box(w: 5, d: 5, h: 5)]))

        let first = s.pages[0].id
        s.activatePage(first)
        #expect(s.duration == 2)
        #expect(s.parts[0].anim.base("x") == 10)
        #expect(s.parts[0].anim.isAnimated)
        #expect(!s.parts[1].hidden)
        #expect(s.camera.base("spin") == 0)
        #expect(s.parts.count == 3)

        let back = try SceneFile.decode(s.encoded())
        #expect(back.activePage == first)
        var other = back
        other.activatePage(second)
        #expect(other.duration == 6 && other.parts[0].anim.base("x") == 99 && other.parts[1].hidden)

        let copy = s.addPage(duplicate: true)
        #expect(s.parts[0].anim.isAnimated)
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
}
