import CoreGraphics
import Foundation
import ImageIO
import IsoDocument
import IsoExamples
import IsoGeometry
import IsoMath
import Testing
import UniformTypeIdentifiers
@testable import isometric_workbench

@MainActor
struct AnimationExportTests {
    /// The floppy example on a 1 s turntable — every frame differs.
    private func turntable() throws -> SceneFile {
        var scene = try #require(Example.named("floppy")).scene()
        scene.duration = 1
        scene.apply(.turntable, selection: [], bounds: { _ in .empty })
        return scene
    }

    /// A still block with a hatched ring (a hole, so even-odd), a text decal
    /// and an image decal.
    private func still() throws -> SceneFile {
        var scene = SceneFile()
        scene.duration = 1
        let box = Part(name: "Block", ops: [.box(w: 120, d: 80, h: 60)])
        scene.parts = [box]
        let outer: Loop = [Vec2(-200, -40), Vec2(-120, -40), Vec2(-120, 40), Vec2(-200, 40)]
        let inner: Loop = [Vec2(-180, -20), Vec2(-180, 20), Vec2(-140, 20), Vec2(-140, -20)]
        scene.shapes = [FlatShape(name: "Ring", axis: .z, at: 0, loops: [outer, inner], fill: "#ffffff", hatch: true)]
        scene.decals = [
            Decal(name: "Label", kind: .text, content: "LID", axis: .z, at: 60, center: Vec2(60, 40), size: 14, host: box.id),
            Decal(name: "Badge", kind: .image, image: try png(), axis: .z, at: 0, center: Vec2(0, 140), size: 40),
        ]
        return scene
    }

    private func png() throws -> Data {
        let ctx = try #require(CGContext(
            data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func export(_ scene: SceneFile, _ format: VideoFormat, name: String, transparent: Bool = false) async throws -> URL {
        let model = SceneDocument(scene: scene).model
        _ = model.exportFrame()
        let settings = VideoSettings(format: format, height: 240, fps: 12, start: 0, end: 1, transparent: transparent, watermark: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).\(format.contentType.preferredFilenameExtension ?? "bin")")
        let progress = ProgressThrottle { _ in }
        try await VideoExporter.run(scene: model.scene, seed: model.build.builtMeshes(model.scene), settings: settings, to: url, progress: progress.report)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        print("exported \(url.path) (\(size / 1024) KB)")
        return url
    }

    // MARK: - Lottie

    private func lottie(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func layers(_ root: [String: Any]) throws -> [[String: Any]] {
        try #require(root["layers"] as? [[String: Any]])
    }

    /// Every shape item type in a layer, groups included.
    private func shapeTypes(_ items: [[String: Any]]) -> [String] {
        items.flatMap { item -> [String] in
            let ty = item["ty"] as? String ?? ""
            return [ty] + shapeTypes(item["it"] as? [[String: Any]] ?? [])
        }
    }

    private func items(_ items: [[String: Any]], _ ty: String) -> [[String: Any]] {
        items.flatMap { item in (item["ty"] as? String == ty ? [item] : []) + self.items(item["it"] as? [[String: Any]] ?? [], ty) }
    }

    /// Frame layers' ranges tile `[0, op)` and none is empty.
    private func checkFrames(_ root: [String: Any]) throws -> [(Int, Int)] {
        let all = try layers(root)
        for l in all { #expect((l["ip"] as? Int ?? 0) < (l["op"] as? Int ?? 0)) }
        let frames = all.filter { ($0["nm"] as? String ?? "").hasPrefix("Frame ") }
        let ranges = Set(frames.map { "\($0["ip"] as? Int ?? -1):\($0["op"] as? Int ?? -1)" })
            .map { s in s.split(separator: ":").map { Int($0)! } }.map { ($0[0], $0[1]) }.sorted { $0.0 < $1.0 }
        var next = 0
        for (ip, op) in ranges {
            #expect(ip == next)
            next = op
        }
        #expect(next == root["op"] as? Int)
        for l in all {
            #expect(l["masksProperties"] == nil && l["hasMask"] == nil && l["tt"] == nil && l["td"] == nil)
        }
        return ranges
    }

    @Test("Lottie of an animated scene: one layer per distinct frame")
    func lottieTurntable() async throws {
        let root = try lottie(try await export(try turntable(), .lottie, name: "turntable-lottie"))
        #expect(root["v"] as? String == "5.7.0")
        #expect(root["fr"] as? Int == 12 && root["ip"] as? Int == 0 && root["op"] as? Int == 12)
        #expect(root["h"] as? Int == 240 && (root["w"] as? Int ?? 0) > 0)
        let ranges = try checkFrames(root)
        #expect(ranges.count > 1)
        let all = try layers(root)
        let types = Set(all.flatMap { shapeTypes($0["shapes"] as? [[String: Any]] ?? []) })
        #expect(types.isSuperset(of: ["gr", "sh", "st", "fl", "tr"]))
        #expect(all.contains { $0["nm"] as? String == "Background" })
        let mark = try #require(all.first { $0["nm"] as? String == "Watermark" })
        #expect(items(mark["shapes"] as? [[String: Any]] ?? [], "sh").count > 20)
        // Layers list top first: the watermark over the frames over the background.
        #expect(all.first?["nm"] as? String == "Watermark" && all.last?["nm"] as? String == "Background")
    }

    @Test("Lottie of a still scene: one frame, clipped hatch, outlined text, embedded image")
    func lottieStill() async throws {
        let root = try lottie(try await export(try still(), .lottie, name: "still-lottie", transparent: true))
        let ranges = try checkFrames(root)
        #expect(ranges.count == 1)
        let all = try layers(root)
        #expect(!all.contains { $0["nm"] as? String == "Background" })
        let shapes = all.flatMap { $0["shapes"] as? [[String: Any]] ?? [] }
        #expect(items(shapes, "fl").contains { $0["r"] as? Int == 2 })

        let assets = try #require(root["assets"] as? [[String: Any]])
        #expect(assets.count == 1 && assets[0]["e"] as? Int == 1)
        #expect((assets[0]["p"] as? String ?? "").hasPrefix("data:image/png;base64,"))
        let image = try #require(all.first { $0["ty"] as? Int == 2 })
        #expect(image["refId"] as? String == assets[0]["id"] as? String)
        let parent = try #require(all.first { $0["ind"] as? Int == image["parent"] as? Int })
        #expect(parent["ty"] as? Int == 3)
    }

    @Test("Hatch is clipped even-odd to every loop")
    func clippedHatch() {
        let outer: Loop = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)]
        let hole: Loop = [Vec2(30, 30), Vec2(30, 70), Vec2(70, 70), Vec2(70, 30)]
        let segs = LottieWriter.clippedHatch([outer, hole], gap: 10)
        #expect(!segs.isEmpty)
        for (a, b) in segs {
            let m = (a + b) * 0.5
            let inHole = m.x > 30 && m.x < 70 && m.y > 30 && m.y < 70
            #expect(!inHole && m.x >= -1e-9 && m.x <= 100 + 1e-9 && m.y >= -1e-9 && m.y <= 100 + 1e-9)
        }
    }

    @Test("Affine maps split into rotations and scales")
    func decompose() {
        for t in [
            CGAffineTransform(a: 0.87, b: 0.5, c: -0.87, d: 0.5, tx: 0, ty: 0),
            CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0),
            CGAffineTransform(a: 0.3, b: -1.2, c: 0.7, d: 0.4, tx: 0, ty: 0),
        ] {
            let m = LottieWriter.decompose(t)
            let r = { (a: Double) in CGAffineTransform(rotationAngle: a) }
            let back = r(m.theta).concatenating(CGAffineTransform(scaleX: m.sx, y: m.sy)).concatenating(r(m.phi))
            for (x, y) in [(back.a, t.a), (back.b, t.b), (back.c, t.c), (back.d, t.d)] { #expect(abs(x - y) < 1e-9) }
        }
    }

    // MARK: - Animated SVG

    @Test("Animated SVG: well-formed, a looping group per distinct frame")
    func animatedSVG() async throws {
        let url = try await export(try turntable(), .svg, name: "turntable-animated")
        let scan = try SVGScan(url)
        #expect(scan.frames > 1)
        #expect(scan.animations == scan.frames)
        #expect(scan.repeatCounts == ["indefinite"])
        #expect(scan.ids.count == Set(scan.ids).count)
        #expect(Set(scan.references).isSubset(of: Set(scan.ids)))
        #expect(scan.text.contains(FramePainter.watermarkText))
    }

    @Test("Animated SVG of a still scene has one frame and unique clip ids")
    func animatedSVGStill() async throws {
        let scan = try SVGScan(try await export(try still(), .svg, name: "still-animated"))
        #expect(scan.frames == 1 && scan.animations == 0)
        #expect(scan.ids.count == Set(scan.ids).count)
        #expect(scan.ids.contains { $0.hasPrefix("frame1-hatch") })
        #expect(Set(scan.references).isSubset(of: Set(scan.ids)))
    }
}

nonisolated private final class SVGScan: NSObject, XMLParserDelegate {
    var ids: [String] = []
    var references: [String] = []
    var frames = 0
    var animations = 0
    var repeatCounts: Set<String> = []
    var text = ""

    init(_ url: URL) throws {
        super.init()
        let parser = try #require(XMLParser(contentsOf: url))
        parser.delegate = self
        #expect(parser.parse(), "\(parser.parserError.map(String.init(describing:)) ?? "")")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if let id = attributes["id"] {
            ids.append(id)
            if name == "g" && id.hasPrefix("frame") && !id.contains("-") { frames += 1 }
        }
        if let clip = attributes["clip-path"], clip.hasPrefix("url(#") { references.append(String(clip.dropFirst(5).dropLast())) }
        if name == "animate" {
            animations += 1
            repeatCounts.insert(attributes["repeatCount"] ?? "")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
}
