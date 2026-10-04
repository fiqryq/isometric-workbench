import AVFoundation
import Foundation
import ImageIO
import IsoDocument
import IsoExamples
import IsoGeometry
import IsoMath
import IsoRender
import Testing
@testable import isometric_workbench

@MainActor
struct WorkbenchTests {
    @Test("Every example exports a full frame", arguments: Example.all.map(\.id))
    func exampleExports(_ id: String) throws {
        let ex = try #require(Example.named(id))
        let model = SceneDocument(scene: ex.scene()).model
        let frame = model.exportFrame()
        #expect(frame.complete)
        #expect(frame.items.count == ex.parts().count)
        #expect(frame.boards.count == 1)
        #expect(frame.callouts.count >= 1)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = try #require(model.png(scale: 1))
        try png.write(to: dir.appendingPathComponent("\(id).png"))
        let svg = model.svg()
        #expect(svg.hasPrefix("<svg"))
        try svg.write(to: dir.appendingPathComponent("\(id).svg"), atomically: true, encoding: .utf8)
        #expect(model.pdf().count > 1000)
        let file = model.scene.encoded()
        #expect(try SceneFile.decode(file) == model.scene)
        try file.write(to: dir.appendingPathComponent("\(id).isoscene"))
        print("exported \(dir.path)/\(id).png")
    }

    @Test("Edits undo and redo as single steps")
    func undo() throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = SceneDocument().model
        model.undoManager = undo
        undo.beginUndoGrouping()
        model.addPrimitive(PrimitiveSpec.all[0])
        undo.endUndoGrouping()
        #expect(model.scene.parts.count == 1)
        undo.beginUndoGrouping()
        model.beginGesture()
        for x in stride(from: 0.0, through: 50, by: 10) {
            model.updateGesture { $0.parts[0].anim.base["x"] = x }
        }
        model.endGesture("Move")
        undo.endUndoGrouping()
        #expect(model.scene.parts[0].anim.base("x") == 50)
        undo.undo()
        #expect(model.scene.parts[0].anim.base("x") == 0)
        undo.undo()
        #expect(model.scene.parts.isEmpty)
        undo.redo()
        #expect(model.scene.parts.count == 1)
    }

    @Test("Sketches, flat art, dimensions and loop rings")
    func features() throws {
        var scene = SceneFile()
        let box = Part(name: "Block", ops: [.box(w: 120, d: 80, h: 60), .loopCut(id: "L1", axis: .z, count: 3)])
        scene.parts = [box]
        let model = SceneDocument(scene: scene).model
        let b = try #require(model.build.meshNow(for: box)).bounds

        // Segment push and ring taper on the loop cut.
        let info = try #require(model.loopInfos(box).first)
        #expect(info.knots.count == 5)
        model.toggleSegment(SegmentPick(partID: box.id, loopID: "L1", segment: 1, face: .right), extend: false)
        model.pushPickedSegments(depth: 12)
        #expect(model.scene.parts[0].ops.last?.type == "segpush")
        for k in 1...3 { model.toggleRing(RingPick(partID: box.id, loopID: "L1", knot: k), extend: true) }
        model.taperPickedRings(from: 100, to: 70)
        #expect(model.ringScale(RingPick(partID: box.id, loopID: "L1", knot: 3)) == 70)

        // A sketch on the top face pushes out of it.
        model.finishSketch([Sketch.rectangle(Vec2(20, 20), Vec2(60, 50))], plane: SketchPlane(axis: .z, at: b.max.z, host: box.id), name: "Rectangle")
        model.extrudeSketch(depth: 20)
        #expect(model.scene.parts[0].ops.last?.type == "push")

        // World sketches make new parts or flat art.
        model.finishSketch([Sketch.ellipse(Vec2(200, 0), Vec2(260, 60))], plane: SketchPlane(axis: .z, at: 0), name: "Ellipse")
        model.extrudeSketch(depth: 30)
        model.finishSketch([Sketch.rectangle(Vec2(-160, 0), Vec2(-130, 70))], plane: SketchPlane(axis: .y, at: 0), name: "Profile")
        model.revolveSketch()
        #expect(model.scene.parts.count == 3)
        model.finishSketch([Sketch.polygon(Vec2(0, 140), Vec2(90, 220), sides: 6)], plane: SketchPlane(axis: .z, at: 0), name: "Polygon")
        model.keepSketch(hatch: true)
        #expect(model.scene.shapes.count == 1)

        // Decals and dimensions.
        model.selection = [box.id]
        model.addTextDecal()
        let svgURL = FileManager.default.temporaryDirectory.appendingPathComponent("star.svg")
        try #"<svg xmlns="http://www.w3.org/2000/svg"><path d="m50 0 12 38h40l-32 24 12 38-32-24-32 24 12-38L-2 38h40z"/></svg>"#
            .write(to: svgURL, atomically: true, encoding: .utf8)
        model.pickedFaces = []
        model.selection = [box.id]
        model.addDecal(fromFile: svgURL)
        #expect(model.scene.decals.count == 2)
        let svgDecal = try #require(model.scene.decals.last)
        model.updateDecal(svgDecal.id) { $0.axis = .x; $0.at = b.max.x; $0.center = Vec2(40, 30) }
        model.selection = [box.id]
        model.addDimensions()
        #expect(model.scene.dimensions.count == 1)

        let frame = model.exportFrame()
        #expect(frame.complete)
        #expect(frame.dimensions.first?.spans.count == 3)
        // The segment push widens the block from 120 to 130.
        #expect(frame.dimensions.first?.spans.map(\.label) == ["130", "80", "80"])
        #expect(frame.allOverlays.count == 3)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #require(model.png(scale: 2)).write(to: dir.appendingPathComponent("features.png"))
        let svg = model.svg()
        #expect(svg.contains(">130</text>") && svg.contains("clipPath") && svg.contains(">LABEL</text>"))
        try svg.write(to: dir.appendingPathComponent("features.svg"), atomically: true, encoding: .utf8)
        #expect(try SceneFile.decode(model.scene.encoded()) == model.scene)
        print("exported \(dir.path)/features.png")
    }

    @Test("Timeline keys retime, ease, paste and delete")
    func timelineKeys() throws {
        var scene = SceneFile()
        scene.fps = 24
        scene.duration = 4
        var p = Part(name: "A", ops: [.box(w: 20, d: 20, h: 20)])
        p.anim.setKey("x", t: 0, v: 0)
        p.anim.setKey("x", t: 1, v: 100)
        p.anim.setKey("z", t: 1, v: 40)
        scene.parts = [p]
        let model = SceneDocument(scene: scene).model
        let owner = KeyRef.Owner.part(p.id)

        // A summary diamond at 1 s moves both keys; times snap to frames.
        let at1 = model.keys(of: owner, at: 1)
        #expect(at1.count == 2)
        model.beginGesture()
        let moved = model.retimeKeys(at1, by: 0.51)
        model.endGesture("Move Keys")
        #expect(moved.allSatisfy { abs($0.t - 1.5) < 1e-9 })
        #expect(model.scene.parts[0].anim.keys["x"]?.map(\.t) == [0, 1.5])
        #expect(model.scene.parts[0].anim.keys["z"]?.map(\.t) == [1.5])

        // Keys can't leave the timeline.
        model.beginGesture()
        let clamped = model.retimeKeys(moved, by: 10)
        model.endGesture("Move Keys")
        #expect(clamped.allSatisfy { $0.t == 4 })

        let first = KeyRef(owner: owner, prop: "x", t: 0)
        model.setEasing(.hold, for: [first])
        #expect(model.scene.parts[0].anim.value("x", at: 2) == 0)

        model.pickedKeys = [first]
        let copied = try #require(model.copyKeys())
        model.seek(2)
        model.pasteKeys(copied)
        #expect(model.scene.parts[0].anim.keys["x"]?.map(\.t) == [0, 2, 4])
        #expect(model.scene.parts[0].anim.keys["x"]?[1].e == .hold)

        model.pickedKeys = model.keys(of: owner, at: 4)
        model.deletePickedKeys()
        #expect(model.scene.parts[0].anim.keys["z"] == nil)
        #expect(model.scene.parts[0].anim.base["z"] == 40)
    }

    @Test("Video, GIF and PNG sequence export", arguments: VideoFormat.allCases.filter { !$0.isVector })
    func videoExport(_ format: VideoFormat) async throws {
        var scene = try #require(Example.named("floppy")).scene()
        scene.duration = 1
        scene.apply(.turntable, selection: [], bounds: { _ in .empty })
        let model = SceneDocument(scene: scene).model
        _ = model.exportFrame()
        var settings = VideoSettings(format: format, height: 240, fps: 12, start: 0, end: 1, transparent: format.supportsAlpha, watermark: true)
        settings.watermark = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = format == .png ? "" : ".\(format.contentType.preferredFilenameExtension ?? "bin")"
        let url = dir.appendingPathComponent("turntable-\(format.rawValue)\(ext)")
        let progress = ProgressThrottle { _ in }
        try await VideoExporter.run(scene: model.scene, seed: model.build.builtMeshes(model.scene), settings: settings, to: url, progress: progress.report)

        switch format {
        case .png:
            let files = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".png") }
            #expect(files.count == 12)
        case .gif:
            let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetCount(src) == 12)
        default:
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            #expect(size.height == 240 && Int(size.width) % 2 == 0)
            let duration = try await asset.load(.duration)
            #expect(abs(duration.seconds - 1) < 0.1)
        }
        print("exported \(url.path)")
    }

    @Test("Combining keeps parts where they are")
    func combine() throws {
        var scene = SceneFile()
        var a = Part(name: "A", ops: [.box(w: 40, d: 40, h: 40)])
        a.anim.base["x"] = 10
        var b = Part(name: "B", ops: [.box(w: 20, d: 20, h: 20)])
        b.anim.base["x"] = 100
        b.anim.base["spin"] = 90
        scene.parts = [a, b]
        let model = SceneDocument(scene: scene).model
        let before = model.exportFrame().contentBox
        model.selection = [a.id, b.id]
        model.combineSelection()
        #expect(model.scene.parts.count == 1)
        let after = model.exportFrame().contentBox
        #expect(abs(before.minX - after.minX) < 0.5 && abs(before.maxX - after.maxX) < 0.5)
        #expect(abs(before.minY - after.minY) < 0.5 && abs(before.maxY - after.maxY) < 0.5)
    }
}
