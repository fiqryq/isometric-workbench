@_exported import IsoDocument
import Foundation

// Shorthands from the plugin's examples (`exRect`, `exAt`, …).

func exRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Loop {
    [Vec2(x, y), Vec2(x + w, y), Vec2(x + w, y + h), Vec2(x, y + h)]
}

func exCircle(_ cx: Double, _ cy: Double, _ r: Double, _ n: Int = 32) -> Loop {
    (0..<n).map { i in
        let a = Double(i) / Double(n) * Double.pi * 2
        return Vec2(cx + r * cos(a), cy + r * sin(a))
    }
}

func exAt(_ ops: [Op], _ ox: Double, _ oy: Double, _ oz: Double, _ mode: String = "union") -> Op {
    .merge(ops, mode: mode, name: "part", offset: Vec3(ox, oy, oz))
}

func exBox(_ x: Double, _ y: Double, _ z: Double, _ w: Double, _ d: Double, _ h: Double) -> Op {
    exAt([.box(w: w, d: d, h: h)], x, y, z)
}

func exCyl(_ x: Double, _ y: Double, _ z: Double, _ r: Double, _ h: Double, _ segments: Double = 32) -> Op {
    exAt([.cylinder(r: r, h: h, segments: segments)], x, y, z)
}

/// A rectangle with rounded corners, as one loop.
func exRoundRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double, _ n: Int = 4) -> Loop {
    var pts: Loop = []
    for (cx, cy, a0) in [(x + w - r, y + r, -90.0), (x + w - r, y + h - r, 0), (x + r, y + h - r, 90), (x + r, y + r, 180)] {
        for i in 0...n {
            let a = ((a0 + (90 * Double(i)) / Double(n)) * Double.pi) / 180
            pts.append(Vec2(cx + r * cos(a), cy + r * sin(a)))
        }
    }
    return pts
}

/// A thin straight bar from a to b, `w` wide — for wires and springs.
func exStrip(_ a: Vec2, _ b: Vec2, _ w: Double) -> Loop {
    let dx = b.x - a.x, dy = b.y - a.y
    var l = hypot(dx, dy)
    if l == 0 { l = 1 }
    let nx = (-dy / l) * (w / 2), ny = (dx / l) * (w / 2)
    return [Vec2(a.x + nx, a.y + ny), Vec2(b.x + nx, b.y + ny), Vec2(b.x - nx, b.y - ny), Vec2(a.x - nx, a.y - ny)]
}

/// Scales every length in a list of ops (sizes, depths, offsets, outlines),
/// so an example can be authored small and placed at any size.
func exScale(_ ops: [Op], _ k: Double) -> [Op] {
    let lengths = ["w", "d", "h", "r", "depth", "at", "ox", "oy", "oz"]
    func s(_ v: Double) -> Double { jsRound(v * k * 100) / 100 }
    return ops.map { op in
        var o = op
        for key in lengths { if case .number(let v) = o[key] { o[key] = .number(s(v)) } }
        if o.type == "revolve", case .number(let v) = o["axis"] { o["axis"] = .number(s(v)) }
        if o["loops"] != nil { o["loops"] = JSONValue(loops: o.loops().map { $0.map { Vec2(s($0.x), s($0.y)) } }) }
        if o["ops"] != nil { o["ops"] = .array(exScale(o.subOps, k).map(\.json)) }
        return o
    }
}

/// Rotates a model so its vertical axis points along +y (towards the left face).
let faceLeft = Mat3(Vec3(1, 0, 0), Vec3(0, 0, 1), Vec3(0, -1, 0))
