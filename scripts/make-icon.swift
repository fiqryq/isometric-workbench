#!/usr/bin/env swift
// Renders the macOS app icon into Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift

import AppKit

// Brand colours and mark geometry match design/logo/build_kit.py.
let ink = CGColor(srgbRed: 0x2d / 255, green: 0x55 / 255, blue: 0xe8 / 255, alpha: 1)
let redline = CGColor(srgbRed: 0xe0 / 255, green: 0x4a / 255, blue: 0x2f / 255, alpha: 1)
let paper = CGColor(srgbRed: 0xfb / 255, green: 0xfb / 255, blue: 0xfa / 255, alpha: 1)

let cos30 = cos(Double.pi / 6)

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

/// The Lift mark: an open block whose top face has lifted off. `gap` and `seam` are in cube-edge units.
func drawMark(in ctx: CGContext, height: Double, centre: CGPoint, gap: Double, seam: Double) {
    let unit = height / (2 + gap)
    let origin = CGPoint(x: centre.x, y: centre.y - height / 2 + unit)
    func iso(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        CGPoint(x: origin.x + (x - y) * cos30 * unit, y: origin.y + z * unit - (x + y) * 0.5 * unit)
    }
    let s = seam, z = 1 + gap
    ctx.setFillColor(ink)
    ctx.addPath(polygon([iso(0, 1, 0), iso(1 - s, 1, 0), iso(1 - s, 1, 1), iso(0, 1, 1)]))
    ctx.addPath(polygon([iso(1, 0, 0), iso(1, 1 - s, 0), iso(1, 1 - s, 1), iso(1, 0, 1)]))
    ctx.fillPath()
    ctx.setFillColor(redline)
    ctx.addPath(polygon([iso(0, 0, z), iso(1, 0, z), iso(1, 1, z), iso(0, 1, z)]))
    ctx.fillPath()
}

func drawIcon(in ctx: CGContext, pixels: Int) {
    // macOS icon grid: 824pt body centred on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(squircle)
    ctx.setFillColor(paper)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Isometric grid; below 128 px it only adds noise.
    if pixels >= 128 {
        ctx.setStrokeColor(ink.copy(alpha: 0.08)!)
        ctx.setLineWidth(3)
        let step = 62.0
        for i in -20...20 {
            let c = 512 + Double(i) * step
            for slope in [0.5773502692, -0.5773502692] {
                ctx.move(to: CGPoint(x: 0, y: c - slope * 512))
                ctx.addLine(to: CGPoint(x: 1024, y: c + slope * 512))
            }
        }
        ctx.strokePath()
    }

    // 16 and 32 px use the opened-up small cut so the lift and seam survive.
    let small = pixels <= 32
    drawMark(in: ctx, height: small ? 560 : 520, centre: CGPoint(x: 512, y: 520),
             gap: small ? 0.5 : 0.36, seam: small ? 0.08 : 0.04)
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx, pixels: pixels)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("isometric-workbench/Assets.xcassets/AppIcon.appiconset")

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(pixels: points * scale).write(to: set.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: set.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(set.path)")
