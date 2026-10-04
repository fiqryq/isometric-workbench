import Foundation
import IsoExamples
import IsoRender
import Testing

@Suite("Examples and documents")
struct DocumentTests {
    @Test("Examples produce the plugin's ops", arguments: Example.all.filter(\.inPlugin).map(\.id))
    func exampleOps(_ id: String) throws {
        let example = try #require(Example.named(id))
        let js = try JSOracle.shared.json("E.EXAMPLES[\"\(id)\"].parts().map((p) => p.ops)").array ?? []
        let swift = example.parts()
        #expect(swift.count == js.count)
        for (part, jsOps) in zip(swift, js) {
            let expected = (jsOps.array ?? []).compactMap { $0.object.map(Op.init) }
            #expect(part.ops.count == expected.count, "\(part.name) op count")
            for (a, b) in zip(part.ops, expected) {
                #expect(approxEqual(a.json, b.json), "\(part.name) · \(a.type)")
            }
        }
    }

    @Test("Every example part evaluates and renders like the plugin", arguments: Example.all.filter(\.inPlugin).map(\.id))
    func exampleGeometry(_ id: String) throws {
        let example = try #require(Example.named(id))
        for (i, part) in example.parts().enumerated() {
            let prepared = try PreparedMesh.build(part.ops)
            let runs = try Renderer.render(prepared, options: RenderOptions())
            let js = try JSOracle.shared.json("E.renderSolid({ angle: 30, smooth: 40, ops: E.EXAMPLES[\"\(id)\"].parts()[\(i)].ops })").array ?? []
            #expect(runs.count == js.count, "\(part.name) runs")
            #expect(runs.map(\.edges.count) == js.map { $0["edges"]?.array?.count ?? -1 }, "\(part.name) edges")
        }
    }

    @Test("Every example part builds a solid and draws", arguments: Example.all.map(\.id))
    func exampleRenders(_ id: String) throws {
        let example = try #require(Example.named(id))
        for part in example.parts() {
            let prepared = try PreparedMesh.build(part.ops)
            #expect(!prepared.mesh.isEmpty, "\(part.name) is empty")
            let runs = try Renderer.render(prepared, options: RenderOptions())
            #expect(!runs.isEmpty, "\(part.name) draws nothing")
        }
    }

    @Test("A scene survives a save / open round trip")
    func roundTrip() throws {
        var scene = Example.named("floppy")!.scene()
        scene.extra["future"] = ["kept": true]
        scene.parts[0].extra["custom"] = 42
        scene.apply(.explode) { (try? Evaluator.evaluate($0.ops))?.bounds ?? .empty }
        let decoded = try SceneFile.decode(scene.encoded())
        #expect(decoded == scene)
        #expect(decoded.parts.contains { $0.anim.isAnimated })
    }

    @Test("Web Studio files open")
    func webStudioFile() throws {
        let json = """
            {"v":1,"name":"3.5\\" floppy disk","style":{"ink":"#2d55e8","fill":"#ffffff","weight":1.4,"gap":6,"bg":"#fbfbfa"},
             "duration":4,"fps":24,"camera":{"base":{"spin":0},"keys":{"spin":[{"t":0,"v":0,"e":"linear"},{"t":4,"v":360,"e":"linear"}]}},
             "parts":[{"id":"k3x9a1b","name":"Top shell","ops":[{"type":"box","w":10,"d":10,"h":5}],
               "base":{"x":0,"y":0,"z":0,"spin":0,"tilt":0,"roll":0,"opacity":100},
               "keys":{"z":[{"t":0.48,"v":60,"e":"smooth"},{"t":2.88,"v":0,"e":"smooth"}]},
               "fill":"#f1f3fb","label":"Top shell","side":"right","target":[0.97,0.5],"hidden":false}]}
            """
        let scene = try SceneFile.decode(Data(json.utf8))
        #expect(scene.style.weight == 1.4)
        #expect(scene.parts[0].callouts.first?.text == "Top shell")
        #expect(scene.parts[0].style.fill == "#f1f3fb")
        #expect(scene.camera.value("spin", at: 2) == 180)
        #expect(scene.parts[0].anim.value("z", at: 0) == 60)
        #expect(abs(scene.parts[0].anim.value("z", at: 1.68) - 30) < 1e-9)
    }

    @Test("A solid copied from the plugin opens as a part")
    func pluginSolid() throws {
        let json = """
            {"v":1,"name":"Box","angle":30,"smooth":40,"style":{"stroke":"#2D55E8","fill":"#FFFFFF","strokeWeight":1.25,"gap":6},
             "ops":[{"type":"box","w":160,"d":160,"h":40}],"rot":{"x":10,"y":0,"z":45},"dx":0,"dy":0}
            """
        let scene = try SceneFile.decode(Data(json.utf8))
        #expect(scene.parts.count == 1)
        #expect(scene.parts[0].anim.base("spin") == 45)
        #expect(scene.parts[0].anim.base("tilt") == 10)
    }

    @Test("Sketches extrude into parts that sit on the sketch", arguments: Axis.allCases)
    func sketchExtrude(_ axis: Axis) throws {
        let loop = Sketch.rectangle(Vec2(10, 20), Vec2(70, 50))
        let made = Sketch.extrudedPart([loop], axis: axis, at: 5, depth: 30)
        let b = try Evaluator.evaluate([made.op]).bounds
        let lo = b.min + made.position, hi = b.max + made.position
        let k = axis.index
        #expect(abs(lo[k] - 5) < 1e-6 && abs(hi[k] - 35) < 1e-6)
        let others = (0..<3).filter { $0 != k }
        #expect(abs(lo[others[0]] - 10) < 1e-6 && abs(hi[others[0]] - 70) < 1e-6)
        #expect(abs(lo[others[1]] - 20) < 1e-6 && abs(hi[others[1]] - 50) < 1e-6)
    }

    @Test("Revolved sketches stand on the sketch's base")
    func sketchRevolve() throws {
        let made = try #require(Sketch.revolvedPart([Sketch.rectangle(Vec2(40, 0), Vec2(60, 30))], axis: .y, at: 0))
        let b = try Evaluator.evaluate([made.op]).bounds
        #expect(abs(b.min.z + made.position.z) < 1e-6)
        #expect(abs(b.max.z + made.position.z - 30) < 1e-6)
        #expect(abs(b.max.x - 20) < 1e-3)
    }

    @Test("SVG files from other apps import")
    func svgImport() throws {
        let rel = try SVGImport.segments(fromPathData: "m10 10 h20 v20 h-20 z")
        let b = Loop2D.bounds(SVGPath.loops(rel))
        #expect(b == Box2(minX: 10, minY: 10, maxX: 30, maxY: 30))
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
              <defs><rect width="999" height="999"/></defs>
              <g transform="translate(50 0)"><circle cx="0" cy="50" r="20"/></g>
              <path d="M0 0a10 10 0 01 20 0z"/>
            </svg>
            """
        let segs = try SVGImport.segments(fromDocument: Data(svg.utf8))
        let loops = SVGPath.loops(segs)
        #expect(loops.count == 2)
        let circle = Loop2D.bounds([loops[0]])
        #expect(abs(circle.minX - 30) < 0.5 && abs(circle.maxX - 70) < 0.5 && abs(circle.midY - 50) < 0.5)
        let arc = Loop2D.bounds([loops[1]])
        #expect(abs(arc.minY + 10) < 0.5 && abs(arc.maxX - 20) < 0.5)
    }

    @Test("Annotations survive a round trip")
    func annotations() throws {
        var scene = SceneFile()
        let part = Part(name: "Box", ops: [.box(w: 10, d: 10, h: 10)])
        scene.parts = [part]
        scene.dimensions = [DimensionLine(part: part.id, height: false, units: .mm, scale: 0.5, decimals: 1)]
        scene.shapes = [FlatShape(axis: .y, at: 4, loops: [Sketch.ellipse(.zero, Vec2(10, 6))], host: part.id, hatch: true)]
        scene.decals = [Decal(name: "Logo", kind: .text, content: "ACME", axis: .x, at: 10, center: Vec2(5, 5), host: part.id)]
        let decoded = try SceneFile.decode(scene.encoded())
        #expect(decoded.dimensions == scene.dimensions)
        #expect(decoded.decals == scene.decals)
        #expect(decoded.shapes.count == 1 && decoded.shapes[0].hatch && decoded.shapes[0].host == part.id)
        #expect(scene.dimensions[0].format(25) == "12.5 mm")
        #expect(DimensionLine(part: "").format(25) == "25")
    }

    @Test("Explode keeps the core still and moves the rest")
    func explode() throws {
        var scene = Example.named("keyswitch")!.scene()
        let msg = scene.apply(.explode) { (try? Evaluator.evaluate($0.ops))?.bounds ?? .empty }
        #expect(msg.hasPrefix("Explode"))
        let animated = scene.parts.filter { $0.anim.isAnimated("z") }
        #expect(animated.count >= 4)
    }
}

func approxEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
    switch (a, b) {
    case (.number(let x), .number(let y)): return abs(x - y) <= 1e-9 * max(1, abs(x))
    case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(approxEqual)
    case (.object(let x), .object(let y)):
        return Set(x.keys) == Set(y.keys) && x.allSatisfy { k, v in approxEqual(v, y[k]!) }
    default: return a == b
    }
}
