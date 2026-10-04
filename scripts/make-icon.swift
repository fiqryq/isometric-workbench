#!/usr/bin/env swift
// Renders the macOS app icon into Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift

import AppKit

let ink = CGColor(srgbRed: 0x2d / 255, green: 0x55 / 255, blue: 0xe8 / 255, alpha: 1)
let paper = CGColor(srgbRed: 0xfb / 255, green: 0xfb / 255, blue: 0xfa / 255, alpha: 1)
let tint = CGColor(srgbRed: 0xdf / 255, green: 0xe6 / 255, blue: 0xfc / 255, alpha: 1)
let white = CGColor(gray: 1, alpha: 1)

let cos30 = cos(Double.pi / 6)

/// Isometric projection on a 1024 canvas, CG coordinates (y up).
func iso(_ x: Double, _ y: Double, _ z: Double, unit: Double = 226, origin: CGPoint = CGPoint(x: 534, y: 512)) -> CGPoint {
    CGPoint(x: origin.x + (x - y) * cos30 * unit,
            y: origin.y + z * unit - (x + y) * 0.5 * unit)
}

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

/// A box from (x0,y0,z0) to (x1,y1,z1); returns its three visible faces: top, left (y = y1), right (x = x1).
func box(_ x0: Double, _ y0: Double, _ z0: Double, _ x1: Double, _ y1: Double, _ z1: Double) -> (top: CGPath, left: CGPath, right: CGPath) {
    let top = polygon([iso(x0, y0, z1), iso(x1, y0, z1), iso(x1, y1, z1), iso(x0, y1, z1)])
    let left = polygon([iso(x0, y1, z0), iso(x1, y1, z0), iso(x1, y1, z1), iso(x0, y1, z1)])
    let right = polygon([iso(x1, y0, z0), iso(x1, y1, z0), iso(x1, y1, z1), iso(x1, y0, z1)])
    return (top, left, right)
}

func drawIcon(in ctx: CGContext) {
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

    // Isometric grid.
    ctx.setStrokeColor(ink.copy(alpha: 0.09)!)
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

    let stroke = 15.0
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    func paint(_ faces: (top: CGPath, left: CGPath, right: CGPath)) {
        for (face, fill) in [(faces.top, white), (faces.left, tint), (faces.right, white)] {
            ctx.addPath(face)
            ctx.setFillColor(fill)
            ctx.fillPath()
        }
        ctx.saveGState()
        ctx.addPath(faces.right)
        ctx.clip()
        ctx.setStrokeColor(ink.copy(alpha: 0.55)!)
        ctx.setLineWidth(6)
        for i in stride(from: -1200.0, through: 1200, by: 34) {
            ctx.move(to: CGPoint(x: i, y: 0))
            ctx.addLine(to: CGPoint(x: i + 1024, y: 1024))
        }
        ctx.strokePath()
        ctx.restoreGState()
        for face in [faces.top, faces.left, faces.right] {
            ctx.addPath(face)
        }
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(stroke)
        ctx.strokePath()
    }

    // A slab with a block pushed up out of its back half.
    paint(box(-0.75, -0.75, -0.55, 0.75, 0.75, -0.05))
    paint(box(-0.75, -0.75, -0.05, 0.75, 0.05, 0.75))

    // Dimension line along the slab's left edge.
    let offset = 0.28
    let a = iso(-0.75, 0.75 + offset, -0.55)
    let b = iso(0.75, 0.75 + offset, -0.55)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(8)
    for (p, q) in [(iso(-0.75, 0.80, -0.55), iso(-0.75, 0.75 + offset + 0.08, -0.55)),
                   (iso(0.75, 0.80, -0.55), iso(0.75, 0.75 + offset + 0.08, -0.55))] {
        ctx.move(to: p)
        ctx.addLine(to: q)
    }
    ctx.move(to: a)
    ctx.addLine(to: b)
    ctx.strokePath()
    let dx = b.x - a.x, dy = b.y - a.y
    let len = (dx * dx + dy * dy).squareRoot()
    let ux = dx / len, uy = dy / len
    let head = 34.0, wing = 15.0
    ctx.setFillColor(ink)
    for (tip, dir) in [(a, 1.0), (b, -1.0)] {
        let base = CGPoint(x: tip.x + ux * head * dir, y: tip.y + uy * head * dir)
        ctx.addPath(polygon([tip,
                             CGPoint(x: base.x - uy * wing, y: base.y + ux * wing),
                             CGPoint(x: base.x + uy * wing, y: base.y - ux * wing)]))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx)
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
