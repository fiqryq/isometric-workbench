import Foundation
import IsoGeometry
import IsoRender
import Testing

/// The models from the plugin's `test/preview.js`, plus every primitive and
/// transform, written once in JS and fed to both engines.
let parityModelsJS = """
(() => {
  const circle = (cx, cy, r, n = 40) => Array.from({ length: n }, (_, i) => [cx + r * Math.cos(i / n * 2 * Math.PI), cy + r * Math.sin(i / n * 2 * Math.PI)]);
  const rect = (x, y, w, h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
  const box = { type: "box", w: 160, d: 120, h: 60 };
  return {
    "box + pocket + quarter cut": [
      { type: "box", w: 160, d: 160, h: 60 },
      { type: "push", axis: "z", at: 60, depth: -30, loops: [circle(80, 80, 45)] },
      { type: "cut", preset: "quarter", fx: 50, fy: 50 },
    ],
    "hollow housing, left-half section": [
      { type: "box", w: 140, d: 140, h: 90 },
      { type: "push", axis: "z", at: 90, depth: -80, loops: [rect(15, 15, 110, 110)] },
      { type: "push", axis: "z", at: 10, through: true, depth: -10, loops: [circle(70, 70, 25)] },
      { type: "cut", preset: "left", fy: 50 },
    ],
    "revolved vase": [
      { type: "revolve", segments: 48, axis: 0, loops: [[[0, 0], [60, 0], [60, 20], [30, 40], [40, 110], [32, 110], [22, 42], [0, 30]]] },
      { type: "cut", preset: "quarter", fx: 50, fy: 50 },
    ],
    "extruded profile with holes + right-face extrude": [
      { type: "extrude", plane: "top", depth: 30, loops: [rect(0, 0, 120, 80), rect(20, 20, 30, 40), [[70, 10], [110, 10], [110, 70], [90, 70], [90, 30], [70, 30]]] },
      { type: "push", axis: "x", at: 120, depth: 25, loops: [rect(10, 5, 40, 20)] },
    ],
    "union box + cylinder, then subtract": [
      { type: "box", w: 120, d: 80, h: 30 },
      { type: "merge", mode: "union", ox: 60, oy: 40, oz: 30, ops: [{ type: "cylinder", r: 25, h: 50, segments: 40 }] },
      { type: "merge", mode: "subtract", ox: 60, oy: 40, oz: 40, ops: [{ type: "cylinder", r: 15, h: 60, segments: 40 }] },
    ],
    "loop cut taper": [
      { type: "box", w: 150, d: 150, h: 70 },
      { type: "loopcut", id: "a", axis: "z", count: 1, slide: -40, scales: [100, 100, 70] },
    ],
    "loop cut ×3, middle band extruded": [
      { type: "box", w: 120, d: 120, h: 120 },
      { type: "loopcut", id: "b", axis: "z", count: 3, slide: 0, scales: [100, 100, 100, 100, 100] },
      { type: "segpush", loopId: "b", segment: 1, face: "left", depth: 14 },
      { type: "segpush", loopId: "b", segment: 1, face: "right", depth: 14 },
    ],
    "cylinder vase from loop cuts": [
      { type: "cylinder", r: 45, h: 140, segments: 48 },
      { type: "loopcut", id: "c", axis: "z", count: 3, slide: 0, scales: [70, 120, 80, 60, 75] },
    ],
    "loops across X, top segment pushed in": [
      { type: "box", w: 180, d: 100, h: 40 },
      { type: "loopcut", id: "d", axis: "x", count: 2, slide: 0, scales: [100, 100, 100, 100] },
      { type: "segpush", loopId: "d", segment: 1, face: "top", depth: -15 },
    ],
    "face push": [
      { type: "box", w: 100, d: 100, h: 50 },
      { type: "facepush", n: [0, 0, 1], w: 50, bounds: [], depth: 20, name: "top" },
    ],
    "sphere": [{ type: "sphere", r: 60, segments: 32 }],
    "cone": [{ type: "cone", r1: 60, r2: 0, h: 100, segments: 40 }],
    "frustum": [{ type: "cone", r1: 60, r2: 30, h: 100, segments: 40 }],
    "tube": [{ type: "tube", r: 60, ri: 40, h: 80, segments: 48 }],
    "torus": [{ type: "torus", R: 60, r: 18, segments: 40, sides: 16 }],
    "prism": [{ type: "prism", r: 60, h: 60, sides: 6 }],
    "wedge": [{ type: "wedge", w: 160, d: 120, h: 80 }],
    "stairs": [{ type: "stairs", w: 120, d: 160, h: 100, steps: 5 }],
    "move + scale + size": [box, { type: "move", x: 10, y: -5, z: 3 }, { type: "scale", x: 50, y: 120, z: 100 }, { type: "size", w: 90, d: 40, h: 25 }],
    "mirror copy": [{ type: "wedge", w: 100, d: 60, h: 50 }, { type: "mirror", axis: "x", copy: true, gap: 10 }],
    "mirror flip": [{ type: "wedge", w: 100, d: 60, h: 50 }, { type: "mirror", axis: "y", copy: false }],
    "array": [{ type: "cylinder", r: 20, h: 30, segments: 24 }, { type: "array", axis: "y", count: 3, gap: 15 }],
    "radial": [{ type: "box", w: 30, d: 20, h: 20 }, { type: "radial", count: 6, radius: 80, angle: 360 }],
    "section top": [{ type: "cylinder", r: 50, h: 80, segments: 32 }, { type: "cut", preset: "top", fz: 60 }],
    "section right": [box, { type: "cut", preset: "right", fx: 30 }],
    "disabled step": [box, { type: "cut", preset: "quarter", fx: 50, fy: 50, enabled: false }],
  };
})()
"""

struct ParityCase: CustomTestStringConvertible, Sendable {
    let name: String
    let ops: [Op]
    var testDescription: String { name }
}

let parityCases: [ParityCase] = {
    let models = (try? JSOracle.shared.json(parityModelsJS))?.object ?? [:]
    return models.keys.sorted().map { name in
        ParityCase(name: name, ops: (models[name]?.array ?? []).compactMap { $0.object.map(Op.init) })
    }
}()

func vec(_ j: JSONValue?) -> [Double] { (j?.array ?? []).map { $0.number ?? .nan } }

func expectClose(_ a: Double, _ b: Double, tol: Double = 1e-6, _ what: @autoclosure () -> String) {
    #expect(abs(a - b) <= tol * max(1, abs(a), abs(b)), "\(what()): \(a) vs \(b)")
}

@Suite("Engine parity with the Figma plugin")
struct EngineParityTests {
    @Test("evaluateOps matches polygon for polygon", arguments: parityCases)
    func meshParity(_ c: ParityCase) throws {
        #expect(!c.ops.isEmpty)
        let js = try JSOracle.shared.json("E.evaluateOps(\(c.ops.jsLiteral))").array ?? []
        let swift = try Evaluator.evaluate(c.ops)
        #expect(swift.count == js.count, "polygon count")
        guard swift.count == js.count else { return }
        for (i, (p, q)) in zip(swift, js).enumerated() {
            let qv = q["v"]?.array ?? []
            #expect(p.v.count == qv.count, "poly \(i) vertex count")
            #expect(p.kind.rawValue == q["kind"]?.string)
            guard p.v.count == qv.count else { return }
            for (a, b) in zip(p.v, qv) {
                let bv = vec(b)
                for k in 0..<3 { expectClose(a[k], bv[k], "poly \(i)") }
            }
            expectClose(p.w, q["w"]?.number ?? .nan, "poly \(i) w")
        }
    }

    @Test("renderSolid matches run for run", arguments: parityCases)
    func renderParity(_ c: ParityCase) throws {
        try compareRender(c.ops, rot: .zero, pivot: .zero, angle: 30)
    }

    @Test("rotated and 2:1 renders match")
    func rotatedRenders() throws {
        let byName = Dictionary(uniqueKeysWithValues: parityCases.map { ($0.name, $0.ops) })
        try compareRender(byName["hollow housing, left-half section"]!, rot: Vec3(20, 0, 35), pivot: Vec3(70, 70, 45), angle: 30)
        try compareRender(byName["revolved vase"]!, rot: Vec3(0, 60, 0), pivot: Vec3(0, 0, 55), angle: 30)
        try compareRender(byName["loop cut ×3, middle band extruded"]!, rot: .zero, pivot: .zero, angle: 26.565)
        try compareRender(byName["torus"]!, rot: Vec3(-30, 10, 120), pivot: Vec3(0, 0, 18), angle: 26.565)
    }

    func compareRender(_ ops: [Op], rot: Vec3, pivot: Vec3, angle: Double) throws {
        let data: JSONValue = [
            "angle": .number(angle), "smooth": 40, "ops": .array(ops.map(\.json)),
            "rot": ["x": .number(rot.x), "y": .number(rot.y), "z": .number(rot.z)],
            "pivot": JSONValue(vec: pivot),
        ]
        let js = try JSOracle.shared.json("E.renderSolid(\(data.jsonString))").array ?? []
        let prepared = try PreparedMesh.build(ops)
        let runs = try Renderer.render(prepared, options: RenderOptions(rotation: rot, pivot: pivot, angle: IsoAngle(degrees: angle), smooth: 40))
        #expect(runs.count == js.count, "run count")
        guard runs.count == js.count else { return }
        for (i, (r, q)) in zip(runs, js).enumerated() {
            #expect(r.kind.rawValue == q["kind"]?.string, "run \(i) kind")
            expectClose(r.shade, q["shade"]?.number ?? .nan, "run \(i) shade")
            #expect(r.faceKey == q["faceKey"]?.string, "run \(i) face key")
            let qp = q["polys"]?.array ?? [], qe = q["edges"]?.array ?? []
            #expect(r.polys.count == qp.count, "run \(i) polys")
            #expect(r.edges.count == qe.count, "run \(i) edges")
            for (poly, jp) in zip(r.polys, qp) {
                for (a, b) in zip(poly, jp.array ?? []) {
                    let bv = vec(b)
                    expectClose(a.x, bv[0], "run \(i) x")
                    expectClose(a.y, bv[1], "run \(i) y")
                }
            }
        }
    }

    @Test("History labels match opView", arguments: parityCases)
    func labels(_ c: ParityCase) throws {
        for op in c.ops {
            let js = try JSOracle.shared.json("E.opView(\(op.jsLiteral))")
            let d = op.display
            #expect(d.label == js["label"]?.string)
            #expect(d.fields.map(\.key) == (js["fields"]?.array ?? []).compactMap { $0["key"]?.string })
        }
    }

    @Test("SVG paths sample into the same loops")
    func paths() throws {
        let data = "M0 0 L100 0 Q120 0 120 20 L120 80 C120 100 100 100 80 100 L0 100 Z M20 20 H60 V60 H20 Z"
        let js = try JSOracle.shared.json("E.sampleSegs(E.parsePath(\(JSONValue.string(data).jsonString)))").array ?? []
        let swift = try SVGPath.loops(fromPathData: data)
        #expect(swift.count == js.count)
        for (l, jl) in zip(swift, js) {
            let pts = jl.array ?? []
            #expect(l.count == pts.count)
            for (a, b) in zip(l, pts) {
                let bv = vec(b)
                expectClose(a.x, bv[0], "x")
                expectClose(a.y, bv[1], "y")
            }
        }
    }

    @Test("Screen → plane and face finding match")
    func planes() throws {
        let t = IsoAngle.isometric
        for axis in Axis.allCases {
            let js = vec(try JSOracle.shared.json("E.screenToPlane(12.5, -40, \"\(axis.rawValue)\", 20, E.trig(30))"))
            let p = t.screenToPlane(12.5, -40, axis: axis, at: 20)
            for k in 0..<3 { expectClose(p[k], js[k], "\(axis)") }
        }
        let ops: [Op] = [.box(w: 160, d: 160, h: 40)]
        let view = ViewTransform(rotation: Vec3(10, 0, 25), pivot: Vec3(80, 80, 20))
        let js = try JSOracle.shared.json(
            "E.faceUnder(E.evaluateOps(\(ops.jsLiteral)), 0, 40, \"z\", E.trig(30), E.viewOf({ rot: { x: 10, y: 0, z: 25 }, pivot: [80, 80, 20] }))")
        let swift = FaceFinder.planeOffset(under: 0, 40, axis: .z, in: try Evaluator.evaluate(ops), angle: t, view: view)
        #expect(swift == js.number)
    }
}
