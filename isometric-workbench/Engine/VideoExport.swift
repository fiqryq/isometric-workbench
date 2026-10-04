import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import IsoDocument
import IsoGeometry
import IsoMath
import IsoRender
import UniformTypeIdentifiers

nonisolated enum VideoFormat: String, CaseIterable, Identifiable, Sendable {
    case h264, hevc, prores, gif, png, lottie, svg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: "MP4 · H.264"
        case .hevc: "MP4 · HEVC"
        case .prores: "MOV · ProRes 4444"
        case .gif: "Animated GIF"
        case .png: "PNG Sequence"
        case .lottie: "Lottie JSON"
        case .svg: "Animated SVG"
        }
    }

    var contentType: UTType {
        switch self {
        case .h264, .hevc: .mpeg4Movie
        case .prores: .quickTimeMovie
        case .gif: .gif
        case .png: .folder
        case .lottie: .json
        case .svg: .svg
        }
    }

    /// Keeps the paper transparent.
    var supportsAlpha: Bool { self == .prores || self == .png || isVector }

    /// Drawn as paths, one group per distinct frame, rather than as pixels.
    var isVector: Bool { self == .lottie || self == .svg }

    var maxSide: Int {
        switch self {
        case .h264: 4096
        case .gif: 1600
        default: 8192
        }
    }
}

nonisolated struct VideoSettings: Sendable, Hashable {
    var format: VideoFormat = .h264
    /// Output height in pixels; the width follows the drawing.
    var height = 1080
    var fps = 30.0
    var start = 0.0
    var end = 4.0
    var transparent = false
    var watermark = false
}

/// The region and size every frame is drawn at.
nonisolated struct VideoPlan: Sendable {
    let box: Box2
    let width: Int
    let height: Int
    let scale: Double
    let times: [Double]

    /// The scene point at the canvas's top-left, with the box centred in the
    /// (even-rounded) canvas.
    var origin: Vec2 {
        Vec2(box.minX - (Double(width) / scale - box.width) / 2, box.minY - (Double(height) / scale - box.height) / 2)
    }

    /// Each distinct frame with the frame numbers `[start, end)` it holds
    /// for; consecutive equal frames merge. Checks for cancellation.
    func spans<Content: Equatable>(
        progress: (Double) -> Void, _ content: (Double) throws -> Content
    ) throws -> [FrameSpan<Content>] {
        var out: [FrameSpan<Content>] = []
        for (i, t) in times.enumerated() {
            try Task.checkCancellation()
            let c = try content(t)
            if let last = out.last, last.content == c {
                out[out.count - 1].end = i + 1
            } else {
                out.append(FrameSpan(content: c, start: i, end: i + 1))
            }
            progress(Double(i + 1) / Double(times.count) * 0.95)
        }
        return out
    }
}

nonisolated struct FrameSpan<Content: Equatable> {
    var content: Content
    var start: Int
    var end: Int
}

nonisolated enum VideoExportError: LocalizedError {
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .writer(let m): m
        }
    }
}

nonisolated enum VideoExporter {
    /// Frame times and a fixed box that holds the whole animation (the
    /// frames when there are any).
    static func plan(_ scene: SceneFile, composer: FrameComposer, settings: VideoSettings) -> VideoPlan {
        let fps = max(1, settings.fps.rounded())
        let count = max(1, Int(((settings.end - settings.start) * fps).rounded()))
        let times = (0..<count).map { settings.start + Double($0) / fps }
        var box = Box2.empty
        let stride = max(1, count / 48)
        for i in Swift.stride(from: 0, to: count, by: stride) + [count - 1] {
            let f = composer.compose(scene, at: times[i])
            if !f.boards.isEmpty {
                box = f.bounds
                break
            }
            box = box.union(f.bounds)
        }
        if box.isEmpty { box = Box2(minX: -300, minY: -200, maxX: 300, maxY: 200) }
        var h = Double(max(16, settings.height))
        var w = h * box.width / max(1, box.height)
        let side = Double(settings.format.maxSide)
        if max(w, h) > side {
            let k = side / max(w, h)
            w *= k
            h *= k
        }
        let even = { (v: Double) -> Int in max(16, Int((v / 2).rounded()) * 2) }
        let width = even(w), height = even(h)
        let scale = min(Double(width) / box.width, Double(height) / box.height)
        return VideoPlan(box: box, width: width, height: height, scale: scale, times: times)
    }

    /// Paints one frame into a bitmap context of the plan's size.
    static func draw(_ frame: Frame, plan: VideoPlan, settings: VideoSettings, in ctx: CGContext) {
        let rect = CGRect(x: 0, y: 0, width: plan.width, height: plan.height)
        ctx.clear(rect)
        if !(settings.transparent && settings.format.supportsAlpha) {
            ctx.setFillColor(RGB(hex: frame.style.bg).cgColor)
            ctx.fill(rect)
        }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(plan.height))
        ctx.scaleBy(x: plan.scale, y: -plan.scale)
        ctx.translateBy(x: -plan.origin.x, y: -plan.origin.y)
        ctx.setShouldSmoothFonts(false)
        FramePainter.paint(frame, in: ctx, background: false)
        if settings.watermark { FramePainter.paintWatermark(plan.box, style: frame.style, in: ctx) }
        ctx.restoreGState()
    }

    /// Renders and encodes the animation. Runs off the main actor; checks
    /// for cancellation between frames and removes partial output.
    static func run(
        scene: SceneFile, seed: [[Op]: PreparedMesh], settings: VideoSettings, to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let geometry = OfflineGeometry(seed: seed)
        let composer = geometry.composer
        let plan = plan(scene, composer: composer, settings: settings)
        do {
            switch settings.format {
            case .h264, .hevc, .prores:
                try await encodeVideo(scene, composer, plan, settings, url, progress)
            case .gif:
                try encodeGIF(scene, composer, plan, settings, url, progress)
            case .png:
                try writePNGs(scene, composer, plan, settings, url, progress)
            case .lottie:
                try LottieWriter.document(scene, composer: composer, plan: plan, settings: settings, progress: progress)
                    .write(to: url, atomically: true, encoding: .utf8)
            case .svg:
                try AnimatedSVGWriter.document(scene, composer: composer, plan: plan, settings: settings, progress: progress)
                    .write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func bitmap(_ plan: VideoPlan) -> CGContext? {
        CGContext(
            data: nil, width: plan.width, height: plan.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func encodeVideo(
        _ scene: SceneFile, _ composer: FrameComposer, _ plan: VideoPlan, _ settings: VideoSettings, _ url: URL,
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: settings.format == .prores ? .mov : .mp4)
        let fps = Int32(max(1, settings.fps.rounded()))
        var output: [String: Any] = [AVVideoWidthKey: plan.width, AVVideoHeightKey: plan.height]
        switch settings.format {
        case .h264:
            output[AVVideoCodecKey] = AVVideoCodecType.h264
            output[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate(plan, fps), AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        case .hevc:
            output[AVVideoCodecKey] = AVVideoCodecType.hevc
            output[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate(plan, fps) * 2 / 3, AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ]
        default:
            output[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: output)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: plan.width, kCVPixelBufferHeightKey as String: plan.height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw VideoExportError.writer("This Mac can't encode \(settings.format.title) at \(plan.width)×\(plan.height).") }
        writer.add(input)
        guard writer.startWriting() else { throw VideoExportError.writer(writer.error?.localizedDescription ?? "Couldn't start the video file.") }
        writer.startSession(atSourceTime: .zero)

        let n = plan.times.count
        do {
            for (i, t) in plan.times.enumerated() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard let pool = adaptor.pixelBufferPool else { throw VideoExportError.writer(writer.error?.localizedDescription ?? "The encoder stopped.") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let pb = buffer else { throw VideoExportError.writer("Out of memory for video frames.") }
                CVPixelBufferLockBaseAddress(pb, [])
                if let ctx = CGContext(
                    data: CVPixelBufferGetBaseAddress(pb), width: plan.width, height: plan.height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                {
                    draw(composer.compose(scene, at: t), plan: plan, settings: settings, in: ctx)
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                guard adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)) else {
                    throw VideoExportError.writer(writer.error?.localizedDescription ?? "Couldn't write frame \(i + 1).")
                }
                progress(Double(i + 1) / Double(n))
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw VideoExportError.writer(writer.error?.localizedDescription ?? "The video couldn't be finished.")
        }
    }

    private static func bitrate(_ plan: VideoPlan, _ fps: Int32) -> Int {
        // Line art compresses well; ~0.12 bits per pixel per frame is crisp.
        Int(min(80_000_000, max(2_000_000, Double(plan.width * plan.height) * Double(fps) * 0.12)))
    }

    private static func encodeGIF(
        _ scene: SceneFile, _ composer: FrameComposer, _ plan: VideoPlan, _ settings: VideoSettings, _ url: URL,
        _ progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let n = plan.times.count
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, n, nil),
              let ctx = bitmap(plan) else { throw VideoExportError.writer("Couldn't create the GIF.") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = 1 / max(1, settings.fps.rounded())
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for (i, t) in plan.times.enumerated() {
            try Task.checkCancellation()
            draw(composer.compose(scene, at: t), plan: plan, settings: settings, in: ctx)
            guard let img = ctx.makeImage() else { continue }
            CGImageDestinationAddImage(dest, img, props)
            progress(Double(i + 1) / Double(n) * 0.95)
        }
        guard CGImageDestinationFinalize(dest) else { throw VideoExportError.writer("Couldn't finish the GIF.") }
        progress(1)
    }

    private static func writePNGs(
        _ scene: SceneFile, _ composer: FrameComposer, _ plan: VideoPlan, _ settings: VideoSettings, _ url: URL,
        _ progress: @escaping @Sendable (Double) -> Void
    ) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let ctx = bitmap(plan) else { throw VideoExportError.writer("Out of memory for frames.") }
        let n = plan.times.count
        let base = url.deletingPathExtension().lastPathComponent
        for (i, t) in plan.times.enumerated() {
            try Task.checkCancellation()
            draw(composer.compose(scene, at: t), plan: plan, settings: settings, in: ctx)
            guard let img = ctx.makeImage() else { continue }
            let file = url.appendingPathComponent(String(format: "%@_%04d.png", base, i + 1))
            guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            progress(Double(i + 1) / Double(n))
        }
    }
}

/// A running export, observed by the export sheet.
@MainActor
@Observable
final class VideoExportJob {
    enum State: Equatable {
        case idle, running, finished(URL), failed(String), cancelled
    }

    private(set) var state = State.idle
    private(set) var progress = 0.0
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { state == .running }

    func start(scene: SceneFile, seed: [[Op]: PreparedMesh], settings: VideoSettings, to url: URL) {
        task?.cancel()
        state = .running
        progress = 0
        let reporter = ProgressThrottle { [weak self] p in
            Task { @MainActor in self?.progress = p }
        }
        task = Task { [weak self] in
            let outcome: State
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await VideoExporter.run(scene: scene, seed: seed, settings: settings, to: url, progress: reporter.report)
                }.value
                outcome = .finished(url)
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard let self, self.state == .running else { return }
            self.progress = outcome == .finished(url) ? 1 : self.progress
            self.state = outcome
        }
    }

    func cancel() {
        task?.cancel()
        if state == .running { state = .cancelled }
    }

    func reset() {
        if !isRunning { state = .idle }
    }
}

/// Forwards progress at most once per percent.
nonisolated final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    private let send: @Sendable (Double) -> Void

    init(_ send: @escaping @Sendable (Double) -> Void) { self.send = send }

    func report(_ p: Double) {
        let step = Int(p * 100)
        lock.lock()
        let changed = step != last
        last = step
        lock.unlock()
        if changed { send(p) }
    }
}
