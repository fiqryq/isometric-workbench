#!/usr/bin/env swift
// Renders the macOS app icon into Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift

import AppKit

// Brand colours; the mark matches the "Isometric Workbench logo" example scene.
let ink = CGColor(srgbRed: 0x2d / 255, green: 0x55 / 255, blue: 0xe8 / 255, alpha: 1)
let paper = CGColor(srgbRed: 0xfb / 255, green: 0xfb / 255, blue: 0xfa / 255, alpha: 1)

let cos30 = cos(Double.pi / 6)

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

/// The Exploded Stack mark: a cube split into three slabs and pulled apart, the
/// base cut open on a quarter section, the cap bevelled. Matches the "Isometric
/// Workbench logo" example scene. Lengths are in cube-edge units.
/// `solid` drops the outlines and shades each face in blue, for 16 and 32 px.
func drawMark(in ctx: CGContext, height: Double, centre: CGPoint, line: Double, solid: Bool) {
    let h = 34.0 / 120, g = 50.0 / 120, ring = 0.6, taper = 0.78
    let top = 3 * h + 2 * g
    // Screen height of the whole stack: the cube's diamond (1 unit) plus its height.
    let unit = height / (1 + top)
    // The front-bottom corner sits on the bottom edge of `height`.
    let origin = CGPoint(x: centre.x, y: centre.y - height / 2 + unit / 2)
    func iso(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        CGPoint(x: origin.x + (x - y) * cos30 * unit, y: origin.y + z * unit - (x + y - 1) * 0.5 * unit)
    }
    func face(_ pts: [(Double, Double, Double)], _ fill: CGColor, hatched: Bool = false) {
        let path = polygon(pts.map { iso($0.0, $0.1, $0.2) })
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        if hatched && !solid {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let b = path.boundingBox, step = unit * 0.075
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(line * 0.6)
            var x = b.minX - b.height
            while x < b.maxX {
                ctx.move(to: CGPoint(x: x, y: b.minY))
                ctx.addLine(to: CGPoint(x: x + b.height, y: b.maxY))
                x += step
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        guard !solid else { return }
        ctx.addPath(path)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(line)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }
    func rgb(_ hex: Int) -> CGColor {
        CGColor(srgbRed: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, alpha: 1)
    }
    let white = solid ? rgb(0xa9bcf7) : rgb(0xffffff)
    let left = solid ? ink : rgb(0xf1f4fd)
    let right = solid ? rgb(0x1c3aa8) : rgb(0xe2e8fc)
    let coreTop = solid ? rgb(0xa9bcf7) : rgb(0xd9e0fb)
    let coreLeft = solid ? ink : rgb(0xd0d8f9)
    let coreRight = solid ? rgb(0x1c3aa8) : rgb(0xc1ccf6)

    // Base: the front quarter is cut away, its two cut faces hatched.
    face([(0, 0, h), (1, 0, h), (1, 0.5, h), (0.5, 0.5, h), (0.5, 1, h), (0, 1, h)], white)
    face([(0.5, 0.5, 0), (1, 0.5, 0), (1, 0.5, h), (0.5, 0.5, h)], left, hatched: true)
    face([(0.5, 0.5, 0), (0.5, 1, 0), (0.5, 1, h), (0.5, 0.5, h)], right, hatched: true)
    face([(0, 1, 0), (0.5, 1, 0), (0.5, 1, h), (0, 1, h)], left)
    face([(1, 0, 0), (1, 0.5, 0), (1, 0.5, h), (1, 0, h)], right)

    // Core.
    let zc = h + g
    face([(0, 0, zc + h), (1, 0, zc + h), (1, 1, zc + h), (0, 1, zc + h)], coreTop)
    face([(0, 1, zc), (1, 1, zc), (1, 1, zc + h), (0, 1, zc + h)], coreLeft)
    face([(1, 0, zc), (1, 1, zc), (1, 1, zc + h), (1, 0, zc + h)], coreRight)

    // Cap: straight up to the ring, then tapered to a smaller top.
    let zk = zc + h + g, zr = zk + h * ring, zt = zk + h
    let a = (1 - taper) / 2, b = 1 - a
    face([(0, 1, zk), (1, 1, zk), (1, 1, zr), (0, 1, zr)], left)
    face([(1, 0, zk), (1, 1, zk), (1, 1, zr), (1, 0, zr)], right)
    face([(0, 1, zr), (1, 1, zr), (b, b, zt), (a, b, zt)], left)
    face([(1, 0, zr), (1, 1, zr), (b, b, zt), (b, a, zt)], right)
    face([(0, 0, zr), (0, 1, zr), (a, b, zt), (a, a, zt)], white)
    face([(0, 0, zr), (1, 0, zr), (b, a, zt), (a, a, zt)], white)
    face([(a, a, zt), (b, a, zt), (b, b, zt), (a, b, zt)], white)
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

    // 16 and 32 px draw the stack solid so the slabs and gaps still read.
    let small = pixels <= 32
    drawMark(in: ctx, height: small ? 720 : 640, centre: CGPoint(x: 512, y: 512), line: pixels <= 128 ? 14 : 7, solid: small)
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
