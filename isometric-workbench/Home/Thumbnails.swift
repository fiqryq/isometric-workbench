import AppKit
import CryptoKit
import Foundation
import IsoDocument
import IsoGeometry
import IsoMath
import Observation

nonisolated enum Thumbnailer {
    /// The scene's first frame, fitted inside `size` points at 2×.
    static func render(_ scene: SceneFile, size: CGSize) -> CGImage? {
        guard !scene.isEmpty else { return nil }
        var scene = scene
        scene.sheet.visible = false
        let frame = OfflineGeometry().composer.compose(scene, at: 0)
        let b = frame.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        let scale = min(size.width / b.width, size.height / b.height) * 2
        let w = max(1, Int((b.width * scale).rounded(.up))), h = max(1, Int((b.height * scale).rounded(.up)))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        FramePainter.paint(frame, in: ctx)
        return ctx.makeImage()
    }

    static func render(fileAt url: URL, size: CGSize) -> CGImage? {
        guard let data = try? Data(contentsOf: url), let scene = try? SceneFile.decode(data) else { return nil }
        return render(scene, size: size)
    }
}

/// Thumbnails for the Home window, cached in memory and in Caches by path and date.
@MainActor
@Observable
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    nonisolated static let cardSize = CGSize(width: 280, height: 170)

    private(set) var images: [String: NSImage] = [:]
    /// Keys with nothing to show (empty or unreadable scenes).
    private(set) var blank: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []

    private let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func key(_ file: LibraryFile) -> String { "\(file.url.path)|\(file.modified.timeIntervalSince1970)" }

    func image(_ key: String) -> NSImage? { images[key] }

    func load(_ file: LibraryFile) async {
        let key = Self.key(file)
        let cached = directory.appendingPathComponent(Self.hash(key)).appendingPathExtension("png")
        let url = file.url
        await load(key) {
            if let image = NSImage(contentsOf: cached) { return image }
            guard let cg = Thumbnailer.render(fileAt: url, size: Self.cardSize) else { return nil }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: cached)
            return NSImage(cgImage: cg, size: .zero)
        }
    }

    func load(scene: SceneFile, key: String) async {
        await load(key) {
            Thumbnailer.render(scene, size: Self.cardSize).map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    private func load(_ key: String, _ work: @escaping @Sendable () -> NSImage?) async {
        guard images[key] == nil, !loading.contains(key) else { return }
        loading.insert(key)
        let image = await Task.detached(priority: .utility, operation: work).value
        loading.remove(key)
        if let image { images[key] = image } else { blank.insert(key) }
    }

    nonisolated private static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
