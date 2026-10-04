import Foundation

/// One part of an example, as the plugin defines it.
public struct ExamplePart: Sendable {
    public struct Note: Sendable {
        public var label: String
        public var side: CalloutSide?
        public var target: Vec2?
        public var reach: Double?
    }

    public var name: String
    public var label: String?
    public var side: CalloutSide?
    public var target: Vec2?
    public var reach: Double?
    public var alignTo: String?
    public var fill: String?
    public var on: String?
    public var more: [Note] = []
    /// Keys that animate the part (offsets from where `ops` put it).
    public var keys: [String: [Keyframe]] = [:]
    public var ops: [Op]

    init(
        _ name: String, label: String? = nil, side: CalloutSide? = nil, target: Vec2? = nil, reach: Double? = nil,
        alignTo: String? = nil, fill: String? = nil, on: String? = nil, more: [Note] = [], keys: [String: [Keyframe]] = [:], ops: [Op]
    ) {
        self.name = name
        self.label = label
        self.side = side
        self.target = target
        self.reach = reach
        self.alignTo = alignTo
        self.fill = fill
        self.on = on
        self.more = more
        self.keys = keys
        self.ops = ops
    }
}

/// The plugin's example scenes, built only from its own operations, so every
/// part arrives as an editable solid with its full history.
public struct Example: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let fig: String
    public let year: String?
    public let parts: @Sendable () -> [ExamplePart]
    public let guides: (@Sendable () -> [Guide])?

    public static let all: [Example] = [
        Example(id: "logo", title: "Isometric Workbench logo", fig: "FIG.000", year: nil, parts: logoParts, guides: nil),
        Example(id: "keyswitch", title: "Mechanical keyswitch", fig: "FIG.008", year: nil, parts: keyswitchParts, guides: nil),
        Example(id: "camera", title: "Rangefinder camera", fig: "FIG.014", year: nil, parts: cameraParts, guides: nil),
        Example(id: "gear", title: "Spur gear", fig: "FIG.021", year: nil, parts: gearParts, guides: nil),
        Example(id: "handheld", title: "Handheld game console", fig: "FIG.027", year: nil, parts: handheldParts, guides: nil),
        Example(id: "floppy", title: "3.5\" floppy disk", fig: "FIG.001", year: "1986", parts: floppyParts, guides: floppyGuides),
    ]

    public static func named(_ id: String) -> Example? { all.first { $0.id == id } }

    /// A new document with the example on a drawing sheet, with callouts and
    /// guides.
    public func scene(style: Style = Style(), angle: Double = 30) -> SceneFile {
        var s = SceneFile()
        s.name = title
        s.style = style
        s.angle = angle
        var sheet = Artboard(name: title, marks: true)
        sheet.fig = fig
        sheet.title = title
        if let year { sheet.year = year }
        s.parts = parts().map { ep in
            var p = Part(name: ep.name, ops: ep.ops)
            p.style.fill = ep.fill
            p.on = ep.on
            p.anim.keys = ep.keys
            if let label = ep.label {
                p.callouts.append(Callout(text: label, side: ep.side, reach: ep.reach ?? 70, target: ep.target, alignTo: ep.alignTo))
            }
            for m in ep.more {
                p.callouts.append(Callout(text: m.label, side: m.side, reach: m.reach ?? 70, target: m.target))
            }
            return p
        }
        s.guides = guides?() ?? []
        sheet.children = s.parts.map(\.id)
        s.frames = [sheet]
        return s
    }
}

// MARK: - Logo

/// The app's mark, "Exploded Stack": a cube split into three slabs and pulled
/// apart. The base shows a section cut through its socket, the core is a
/// blueprint tint and the cap is bevelled. It is also the app icon. It assembles and explodes again on a loop.
@Sendable func logoParts() -> [ExamplePart] {
    let s = 120.0, h = 34.0, g = 50.0
    let zCore = h + g, zCap = zCore + h + g
    /// Exploded at 0 and 4 s, assembled from 1.4 to 2.6 s.
    func travel(_ closed: Double) -> [String: [Keyframe]] {
        ["z": [Keyframe(t: 0, v: 0), Keyframe(t: 1.4, v: -closed), Keyframe(t: 2.6, v: -closed), Keyframe(t: 4, v: 0)]]
    }
    return [
        ExamplePart("Base", ops: [
            exBox(-s / 2, -s / 2, 0, s, s, h),
            .push(axis: .z, at: h, depth: -18, loops: [exCircle(0, 0, 14, 40)]),
            .cut(.quarter, fx: 50, fy: 50),
        ]),
        ExamplePart("Core", label: "Isometric Workbench", side: .right, target: Vec2(0.78, 0.5), reach: 90, fill: "#D9E0FB", keys: travel(g), ops: [
            exBox(-s / 2, -s / 2, zCore, s, s, h),
        ]),
        ExamplePart("Cap", keys: travel(2 * g), ops: [
            exBox(-s / 2, -s / 2, zCap, s, s, h),
            .loopCut(id: "CAP", axis: .z, count: 1, slide: 20, scales: [100, 100, 78]),
        ]),
    ]
}

// MARK: - Keyswitch

@Sendable func keyswitchParts() -> [ExamplePart] {
    let g = 50.0, gk = 104.0  // explode gaps (the wide keycap needs more air)
    let f: Loop = [[-14, -20], [16, -20], [16, -12], [-6, -12], [-6, -3], [10, -3], [10, 5], [-6, 5], [-6, 20], [-14, 20]].map { Vec2($0[0], $0[1]) }
    func coil(_ z: Double) -> Op { exAt([.revolve(segments: 24, axis: 19, loops: [exCircle(0, 2.8, 2.8, 8)])], 0, 0, z) }
    let cross: Loop = [[-2.5, -9], [2.5, -9], [2.5, -2.5], [9, -2.5], [9, 2.5], [2.5, 2.5], [2.5, 9], [-2.5, 9], [-2.5, 2.5], [-9, 2.5], [-9, -2.5], [-2.5, -2.5]].map { Vec2($0[0], $0[1]) }
    let zB = 8 + g, zS = zB + 36 + g, zT0 = zS + 48 + g, zH = zT0 + 56 + g, zK = zH + 30 + gk
    return [
        ExamplePart("Plate & contact", label: "Plate & contact", side: .left, target: Vec2(0.12, 0.5), ops: [
            exBox(-80, -80, 0, 160, 160, 8), exBox(18, -66, 8, 56, 12, 4),
        ]),
        ExamplePart("Housing (bottom)", label: "Housing", side: .right, ops: [
            exBox(-55, -55, zB, 110, 110, 34),
            .push(axis: .z, at: zB + 34, depth: -28, loops: [exRect(-48, -48, 96, 96)]),
            exCyl(0, 0, zB + 6, 9, 30, 28),
            .push(axis: .z, at: zB + 36, depth: -24, loops: [exCircle(0, 0, 4, 20)]),
            .cut(.quarter, fx: 50, fy: 50),
        ]),
        ExamplePart("Spring", label: "Spring", side: .left, ops: (0..<6).map { coil(zS + Double($0) * 8) }),
        ExamplePart("Stem", label: "Stem", side: .right, ops: [
            exBox(-24, -18, zT0, 48, 36, 10),
            exBox(-14, -12, zT0 + 10, 28, 24, 22),
            exAt([.extrude(plane: .top, depth: 24, loops: [cross])], 0, 0, zT0 + 32),
        ]),
        ExamplePart("Housing (top)", label: "Housing top", side: .left, target: Vec2(0.2, 0.55), ops: [
            exBox(-55, -55, zH, 110, 110, 30),
            .loopCut(id: "HT", axis: .z, count: 1, slide: 20, scales: [100, 100, 82]),
            exAt([.box(w: 96, d: 96, h: 22)], -48, -48, zH - 1, "subtract"),
            .push(axis: .z, at: zH + 30, depth: -12, through: true, loops: [exRect(-15, -12, 30, 24)]),
            .cut(.quarter, fx: 50, fy: 50),
        ]),
        ExamplePart("Keycap", label: "Key cap", side: .right, target: Vec2(0.75, 0.6), ops: [
            exBox(-70, -70, zK, 140, 140, 62),
            .loopCut(id: "KC", axis: .z, count: 1, slide: -30, scales: [100, 100, 74]),
            exAt([.box(w: 124, d: 124, h: 40)], -62, -62, zK - 1, "subtract"),
            .push(axis: .z, at: zK + 62, depth: -3, loops: [f]),
        ]),
    ]
}

// MARK: - Camera

@Sendable func cameraParts() -> [ExamplePart] {
    let lens: Loop = [[0, 0], [42, 0], [42, 8], [38, 8], [38, 22], [34, 22], [34, 40], [26, 40], [26, 35], [0, 35]].map { Vec2($0[0], $0[1]) }
    return [
        ExamplePart("Camera", label: "Camera body", ops: exScale([
            .box(w: 200, d: 72, h: 118),
            .loopCut(id: "CB", axis: .z, count: 2, slide: -10, scales: [100, 100, 100, 100]),
            .segmentPush(loopId: "CB", segment: 1, face: .left, depth: -3),
            exBox(8, 6, 118, 184, 60, 12),
            exAt([.box(w: 72, d: 50, h: 28), .loopCut(id: "VF", axis: .z, count: 1, slide: 0, scales: [100, 100, 76])], 64, 11, 130),
            .merge([.revolve(segments: 40, axis: 0, loops: [lens])], name: "Lens", offset: Vec3(100, 72, 56), matrix: faceLeft),
            exCyl(160, 36, 130, 10, 8, 24),
            exCyl(34, 36, 130, 17, 10, 32),
            .push(axis: .y, at: 72, depth: -3, loops: [exRect(148, 82, 40, 22)]),
            .push(axis: .y, at: 72, depth: 6, loops: [exRect(8, 30, 30, 70)]),
        ], 1.7)),
    ]
}

// MARK: - Spur gear

@Sendable func gearParts() -> [ExamplePart] {
    let n = 20, bigR = 84.0, r = 72.0, cx = 90.0, cy = 90.0
    var pts: Loop = []
    for i in 0..<n {
        let a = Double(i) / Double(n) * Double.pi * 2, t = (Double.pi * 2) / Double(n)
        for (f, rad) in [(0.0, r), (0.18, bigR), (0.5, bigR), (0.68, r)] {
            pts.append(Vec2(cx + rad * cos(a + f * t), cy + rad * sin(a + f * t)))
        }
    }
    let spokes = (0..<5).map { i in
        let a = Double(i) / 5 * Double.pi * 2 + 0.3
        return exCircle(cx + 44 * cos(a), cy + 44 * sin(a), 13, 24)
    }
    return [
        ExamplePart("Gear", label: "Spur gear · 20T", ops: exScale([
            .extrude(plane: .top, depth: 22, loops: [pts]),
            exCyl(cx, cy, 0, 26, 40, 36),
            .push(axis: .z, at: 22, depth: -22, through: true, loops: spokes),
            .push(axis: .z, at: 40, depth: -40, through: true, loops: [exCircle(cx, cy, 10, 28)]),
            .cut(.quarter, fx: 50, fy: 50),
        ], 2.3)),
    ]
}

// MARK: - Handheld game console

@Sendable func handheldParts() -> [ExamplePart] {
    let w = 150.0, d = 240.0, h = 30.0, g = 84.0
    let cross: Loop = [[18, 0], [30, 0], [30, 18], [48, 18], [48, 30], [30, 30], [30, 48], [18, 48], [18, 30], [0, 30], [0, 18], [18, 18]].map { Vec2($0[0], $0[1]) }
    let slots = (0..<5).map { exRect(100 + Double($0) * 9, 14, 4, 30) }
    return [
        ExamplePart("Shell", label: "Shell · screen well & speaker grille", side: .right, target: Vec2(0.78, 0.55), ops: [
            .box(w: w, d: d, h: h),
            .loopCut(id: "SH", axis: .z, count: 1, slide: 0, scales: [100, 100, 95]),
            .push(axis: .z, at: h, depth: -4, loops: [exRect(16, 120, 118, 100)]),
            .push(axis: .z, at: h, depth: -3, loops: slots),
            .push(axis: .z, at: h, depth: -2, loops: [exRect(20, 66, 56, 56)]),
            .push(axis: .y, at: d, depth: -12, loops: [exRect(30, 10, 90, 12)]),
        ]),
        ExamplePart("Screen", label: "Screen glass", side: .left, target: Vec2(0.3, 0.5), ops: [
            exAt([.box(w: 110, d: 92, h: 4), .push(axis: .z, at: 4, depth: -1.5, loops: [exRect(14, 12, 82, 66)])], 20, 124, h + g),
        ]),
        ExamplePart("D-pad", label: "D-pad", target: Vec2(0.5, 0.5), ops: [
            exAt([.extrude(plane: .top, depth: 8, loops: [cross]), .loopCut(id: "DP", axis: .z, count: 1, slide: 0, scales: [100, 100, 92])], 24, 70, h + g),
        ]),
        ExamplePart("Buttons", label: "A / B buttons", target: Vec2(0.5, 0.5), ops: [
            exCyl(100, 98, h + g, 10, 8, 28),
            exCyl(122, 78, h + g, 10, 8, 28),
        ]),
        ExamplePart("Cartridge", label: "Cartridge", side: .left, target: Vec2(0.3, 0.5), ops: [
            exAt([.box(w: 86, d: 14, h: 70), .push(axis: .y, at: 14, depth: -2, loops: [exRect(10, 18, 66, 44)])], 32, d + 70, 8),
        ]),
    ]
}

// MARK: - Floppy disk

let floppyZ = (bottom: 0.0, liner1: 198.0, disk: 277.0, liner2: 419.0, top: 604.0)
let floppyW = 270.0, floppyD = 270.0

func pts(_ a: [[Double]]) -> Loop { a.map { Vec2($0[0], $0[1]) } }

@Sendable func floppyParts() -> [ExamplePart] {
    let W = floppyW, D = floppyD, cx = 135.0, cy = 135.0, Z = floppyZ
    let shell = "#F1F3FB", white = "#FFFFFF"
    let tt = 5.0, tb = 4.0  // top / bottom shell thickness
    let window = exRect(124, 192, 30, 66)
    let pegs: [(Double, Double)] = [(12, 47), (16, 247), (256, 224), (W - 16, 56)]
    func liner(_ z: Double) -> Op {
        exAt([
            .cylinder(r: 128, h: 1, segments: 72),
            .push(axis: .z, at: 1, depth: -1, through: true, loops: [exCircle(0, 0, 42, 40)]),
            .push(axis: .z, at: 1, depth: -1, through: true, loops: [exRect(-24, 20, 48, 120)]),
        ], cx, cy, z)
    }
    let spring = [Vec2(184, D - 1), Vec2(208, D - 14), Vec2(238, D - 1)]
    return [
        ExamplePart("Top shell", label: "Top shell", side: .right, target: Vec2(0.97, 0.5), fill: shell,
            more: [.init(label: "HD notch", side: .left, target: Vec2(0.5, 0.04))],
            ops: [exAt([
                .extrude(plane: .top, depth: tt, loops: [pts([[8, 0], [W, 0], [W, D], [96, D], [96, D - 7], [86, D - 7], [86, D], [0, D], [0, 8]])]),
                .push(axis: .z, at: tt, depth: -1.2, loops: [pts([[22, 6], [230, 6], [230, 156], [30, 156], [22, 148]])]),
                .push(axis: .z, at: tt, depth: -1.5, loops: [exRect(66, 186, 166, D - 186)]),
                .push(axis: .z, at: tt, depth: -1.5, loops: [exRect(10, D - 5, 30, 5)]),
                .push(axis: .z, at: tt, depth: -tt, through: true, loops: [window, exRect(4, 18, 12, 14), exRect(W - 18, 18, 12, 14)]),
                .push(axis: .z, at: tt, depth: -0.8, loops: [pts([[244, 226], [252, 226], [252, 238], [258, 238], [248, 250], [238, 238], [244, 238]])]),
            ], 0, 0, Z.top)]),
        ExamplePart("Label", fill: white, on: "Top shell", ops: [
            exAt([.extrude(plane: .top, depth: 0.6, loops: [exRoundRect(30, 13, 194, 137, 9)])], 0, 0, Z.top + tt - 1.2),
        ]),
        ExamplePart("Dust liner", label: "Dust liner", side: .left, target: Vec2(0.02, 0.5), fill: white, ops: [liner(Z.liner2)]),
        ExamplePart("Magnetic disk", label: "Magnetic disk", side: .right, target: Vec2(0.995, 0.42), fill: "#8C9EF6", ops: [exAt([
            .cylinder(r: 126, h: 1.5, segments: 80),
            .push(axis: .z, at: 1.5, depth: -1.5, through: true, loops: [exCircle(0, 0, 30, 40)]),
        ], cx, cy, Z.disk)]),
        ExamplePart("Hub", label: "Hub", side: .right, target: Vec2(0.5, 0.62), alignTo: "Magnetic disk", fill: "#E9EDFD", ops: [exAt([
            .cylinder(r: 38, h: 2.5, segments: 56),
            .push(axis: .z, at: 2.5, depth: -1, loops: [exCircle(0, 0, 31, 48)]),
            .push(axis: .z, at: 2.5, depth: -2.5, through: true, loops: [exCircle(0, 0, 5, 20)]),
            .push(axis: .z, at: 2.5, depth: -2.5, through: true, loops: [exRect(9, -21, 13, 9)]),
        ], cx, cy, Z.disk + 1.5)]),
        ExamplePart("Dust liner", label: "Dust liner", side: .left, target: Vec2(0.02, 0.4), fill: white, ops: [liner(Z.liner1)]),
        ExamplePart("Bottom shell", label: "Bottom shell", side: .left, target: Vec2(0.02, 0.45), fill: shell,
            more: [
                .init(label: "Write protect notch", side: .right, target: Vec2(0.985, 0.45)),
                .init(label: "Shutter spring", side: .below, target: Vec2(0.43, 0.87), reach: 64),
            ],
            ops: [exAt([
                .extrude(plane: .top, depth: tb, loops: [pts([
                    [8, 0], [W, 0], [W, D], [W - 16, D], [W - 16, D - 6], [W - 26, D - 6], [W - 26, D], [96, D], [96, D - 7], [86, D - 7], [86, D],
                    [0, D], [0, D - 18], [5, D - 18], [5, D - 30], [0, D - 30], [0, 8],
                ])]),
                exAt([.cylinder(r: 131, h: 3, segments: 80), exAt([.cylinder(r: 128, h: 3, segments: 80)], 0, 0, 0, "subtract")], cx, cy, tb),
                exAt([.cylinder(r: 47, h: 1.5, segments: 48)], cx, cy, tb),
                .push(axis: .z, at: tb + 1.5, depth: -(tb + 1.5), through: true, loops: [exCircle(cx, cy, 44, 44), window, exRect(W - 20, 6, 12, 28), exRect(9, D - 27, 7, 6)]),
                .push(axis: .z, at: tb, depth: -1.5, loops: [pts([[178, D], [244, D], [232, D - 18], [192, D - 18]])]),
                .push(axis: .z, at: tb - 1.5, depth: 1.4, loops: [exStrip(spring[0], spring[1], 2)]),
                .push(axis: .z, at: tb - 1.5, depth: 1.4, loops: [exStrip(spring[1], spring[2], 2)]),
                exAt([.cylinder(r: 4, h: 3, segments: 20), .push(axis: .z, at: 3, depth: -2, loops: [exCircle(0, 0, 1.8, 12)])], spring[1].x, spring[1].y, tb - 1.5),
            ] + pegs.map { x, y in
                exAt([.cylinder(r: 7, h: 3, segments: 24), .push(axis: .z, at: 3, depth: -2.5, loops: [exCircle(0, 0, 3.6, 16)])], x, y, tb)
            }, 0, 0, Z.bottom)]),
        ExamplePart("Lifter", label: "Lifter", side: .below, target: Vec2(0.45, 0.85), reach: 66, fill: white, on: "Bottom shell", ops: [
            exAt([.box(w: 62, d: 27, h: 0.8)], 186, 113, tb),
            exAt([.box(w: 62, d: 28, h: 0.8)], 186, 140, tb),
        ]),
        ExamplePart("Shutter", label: "Shutter", side: .left, target: Vec2(0.08, 0.4), fill: "#DCE2FB", ops: [exAt([
            .extrude(plane: .top, depth: 10, loops: [[Vec2(0, 0)] + Array(exRoundRect(100, 0, 40, 98, 12, 4).prefix(5)) + [Vec2(140, 98), Vec2(0, 98)]]),
            exAt([.box(w: 142, d: 91, h: 7.6)], -1, -1, 1.2, "subtract"),
            .push(axis: .z, at: 10, depth: -0.8, loops: [exRect(9, 4, 41, 82)]),
            .push(axis: .z, at: 10, depth: -10, through: true, loops: [exRect(13, 8, 33, 74)]),
            exAt([.box(w: 10, d: 8, h: 12)], 112, 92, -1, "subtract"),
        ], 54, D + 120, -2)]),
        ExamplePart("Write protect tab", label: "Write protect tab", side: .right, target: Vec2(0.6, 0.3), fill: "#A9B8FA", ops: [exAt([
            .box(w: 12, d: 20, h: 4),
            exAt([.box(w: 12, d: 6, h: 4)], 0, 12, 4),
        ], W - 20, -110, tb)]),
    ]
}

@Sendable func floppyGuides() -> [Guide] {
    let W = floppyW, D = floppyD, Z = floppyZ, cy = 135.0
    var out = [
        Guide(a: Vec3(16, 247, Z.top), b: Vec3(16, 247, 9), arrow: true),
        Guide(a: Vec3(W - 16, 56, Z.top), b: Vec3(W - 16, 56, 9), arrow: true),
        Guide(a: Vec3(62, D + 112, 6), b: Vec3(62, D + 12, 4), arrow: true),
        Guide(a: Vec3(188, D + 112, 6), b: Vec3(188, D + 12, 4), arrow: true),
        Guide(a: Vec3(W - 14, -88, 6), b: Vec3(W - 14, 8, 6), arrow: true),
    ]
    // Light streaks across the disk's coating, drawn on its surface.
    for (dy, x0, x1) in [(-96.0, -60.0, 70.0), (-62, -100, 40), (58, -20, 108), (92, -70, 64), (-30, 50, 118), (30, -118, -48)] {
        out.append(Guide(
            a: Vec3(135 + x0, cy + dy, Z.disk + 1.5), b: Vec3(135 + x1, cy + dy, Z.disk + 1.5),
            color: "#FFFFFF", opacity: 0.8, dash: [34, 40], above: "Magnetic disk"))
    }
    return out
}
