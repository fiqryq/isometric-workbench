import Foundation

// Exploded teardowns that only the app ships. Each part is authored where it
// floats in the exploded view, like the floppy disk.

/// Where a point (x, y) on a flat w × d slab lands inside the slab's screen
/// bounds, as a callout target.
private func flat(_ x: Double, _ y: Double, _ w: Double, _ d: Double) -> Vec2 {
    Vec2((x - y + d) / (w + d), (x + y) / (w + d))
}

private func sphere(_ r: Double, _ segments: Double = 28) -> Op {
    Op(type: "sphere", ["r": .number(r), "segments": .number(segments)])
}

private func tube(_ r: Double, _ ri: Double, _ h: Double, _ segments: Double = 72) -> Op {
    Op(type: "tube", ["r": .number(r), "ri": .number(ri), "h": .number(h), "segments": .number(segments)])
}

/// A ring-shaped loop pair (outer, hole) for pushes and extrudes.
private func ring(_ cx: Double, _ cy: Double, _ r: Double, _ ri: Double, _ n: Int = 64) -> [Loop] {
    [exCircle(cx, cy, r, n), exCircle(cx, cy, ri, n)]
}

/// A plus-shaped loop: switch stems and screw heads.
private func plus(_ cx: Double, _ cy: Double, _ arm: Double, _ w: Double) -> Loop {
    let a = arm, h = w / 2
    return pts([[-h, -a], [h, -a], [h, -h], [a, -h], [a, h], [h, h], [h, a], [-h, a], [-h, h], [-a, h], [-a, -h], [-h, -h]])
        .map { Vec2($0.x + cx, $0.y + cy) }
}

private let shell = "#F1F3FB", white = "#FFFFFF", blue = "#8C9EF6", tint = "#D9E0FB", pale = "#E9EDFD"

// MARK: - Smartphone

private let phoneW = 150.0, phoneD = 300.0
private let phoneZ = (back: 0.0, coil: 80.0, frame: 160.0, inner: 264.0, camera: 330.0, display: 430.0)

@Sendable func phoneParts() -> [ExamplePart] {
    let W = phoneW, D = phoneD, Z = phoneZ
    let outline = exRoundRect(0, 0, W, D, 22, 6)
    let coil = Vec2(75, 122)
    return [
        ExamplePart("Display", label: "OLED display", side: .right, target: flat(W, 150, W, D), fill: shell,
            more: [.init(label: "Front camera", side: .left, target: flat(64, 280, W, D))],
            ops: [exAt([
                .extrude(plane: .top, depth: 5, loops: [outline]),
                .push(axis: .z, at: 5, depth: -1, loops: [exRoundRect(5, 5, W - 10, D - 10, 18, 6)]),
            ], 0, 0, Z.display)]),
        ExamplePart("Panel", fill: blue, on: "Display", ops: [exAt([
            .extrude(plane: .top, depth: 0.6, loops: [exRoundRect(5, 5, W - 10, D - 10, 18, 6)]),
            .push(axis: .z, at: 0.6, depth: -0.6, through: true, loops: [exRoundRect(55, 274, 40, 12, 6, 4)]),
        ], 0, 0, Z.display + 4)]),
        ExamplePart("Camera module", label: "Camera module", side: .left, target: flat(15, 28, 56, 56), alignTo: "Frame", fill: tint, ops: [exAt([
            .extrude(plane: .top, depth: 6, loops: [exRoundRect(0, 0, 56, 56, 10, 4)]),
            exCyl(40, 40, 6, 11.5, 7, 40), exCyl(15, 28, 6, 11.5, 7, 40), exCyl(40, 15, 6, 11.5, 7, 40),
            .push(axis: .z, at: 13, depth: -4, loops: [exCircle(40, 40, 7, 32), exCircle(15, 28, 7, 32), exCircle(40, 15, 7, 32)]),
            exCyl(14, 47, 6, 3.5, 2, 20),
        ], 84, 234, Z.camera)]),
        ExamplePart("Logic board", label: "Logic board", side: .right, target: Vec2(0.88, 0.64), alignTo: "Frame", fill: blue,
            more: [.init(label: "System on chip", side: .left, target: flat(36, 94, 134, 124), reach: 120)],
            ops: [exAt([
                .extrude(plane: .top, depth: 2, loops: [pts([[80, 292], [8, 292], [8, 168], [142, 168], [142, 228], [80, 228]])]),
                exAt([.box(w: 32, d: 32, h: 3), .push(axis: .z, at: 3, depth: -0.5, loops: [exRect(4, 4, 24, 24)])], 28, 246, 2),
                exAt([.box(w: 50, d: 44, h: 4), .push(axis: .z, at: 4, depth: -0.6, loops: [exRect(3, 3, 44, 38)])], 86, 176, 2),
                exBox(66, 204, 2, 14, 14, 2),
                exBox(14, 194, 2, 26, 8, 2.5),
                exBox(70, 174, 2, 16, 10, 2.5),
            ] + (0..<4).flatMap { r in (0..<3).map { c in exBox(23 - Double(c) * 6, 277 - Double(r) * 10, 2, 3, 5, 1.6) } },
            0, 0, Z.inner)]),
        ExamplePart("Battery", label: "Battery", side: .left, target: flat(0, 100, 126, 152), alignTo: "Frame", fill: tint,
            ops: [exAt([
                .extrude(plane: .top, depth: 6, loops: [exRoundRect(0, 0, 126, 128, 8, 4)]),
                .push(axis: .z, at: 6, depth: -0.5, loops: [exRoundRect(10, 52, 106, 64, 4, 3)]),
                exBox(56, 128, 2, 16, 16, 1.2),
                exBox(54, 144, 2, 20, 8, 2.6),
            ], 12, 26, Z.inner)]),
        ExamplePart("Taptic engine", fill: white, ops: [exAt([
            .box(w: 60, d: 14, h: 6),
            .push(axis: .z, at: 6, depth: -0.5, loops: [exRect(4, 3, 52, 8)]),
        ], 76, 6, Z.inner)]),
        ExamplePart("Speaker", fill: white, ops: [exAt([
            .box(w: 46, d: 14, h: 6),
            .push(axis: .z, at: 6, depth: -1, loops: (0..<6).map { exCircle(7 + Double($0) * 6.4, 7, 1.8, 12) }),
        ], 14, 6, Z.inner)]),
        ExamplePart("Frame", label: "Aluminium frame", side: .left, target: flat(0, 270, W, D), fill: shell,
            ops: [exAt([
                .extrude(plane: .top, depth: 9, loops: [outline, exRoundRect(5, 5, W - 10, D - 10, 18, 6)]),
                exBox(5, 160, 0, W - 10, 4, 7),
                exBox(W - 0.5, 176, 2, 2, 22, 5),
                exBox(W - 0.5, 204, 2, 2, 22, 5),
            ], 0, 0, Z.frame)]),
        ExamplePart("Charging coil", label: "Wireless charging coil", side: .right, target: Vec2(0.97, 0.45), alignTo: "Back glass", fill: blue, ops: [exAt([
            .cylinder(r: 44, h: 2, segments: 72),
            .push(axis: .z, at: 2, depth: -2, through: true, loops: [exCircle(0, 0, 22, 48)]),
            .push(axis: .z, at: 2, depth: -0.8, loops: ring(0, 0, 40, 38)),
            .push(axis: .z, at: 2, depth: -0.8, loops: ring(0, 0, 34, 32)),
            .push(axis: .z, at: 2, depth: -0.8, loops: ring(0, 0, 28, 26)),
            exBox(-6, 42, 0, 12, 44, 1),
        ], coil.x, coil.y, Z.coil)]),
        ExamplePart("Magnets", label: "Magnet array", side: .left, target: Vec2(0.03, 0.5), alignTo: "Back glass", fill: white, ops: [exAt(
            (0..<18).map { i in
                let a = Double(i) / 18 * Double.pi * 2
                return exCyl(52 * cos(a), 52 * sin(a), 0, 3.4, 2, 16)
            }, coil.x, coil.y, Z.coil)]),
        ExamplePart("Back glass", label: "Back glass", side: .left, target: flat(0, 240, W, D), fill: shell, ops: [exAt([
            .extrude(plane: .top, depth: 3, loops: [outline]),
            .push(axis: .z, at: 3, depth: -0.6, loops: [exRoundRect(80, 230, 62, 62, 16, 4)]),
            .push(axis: .z, at: 3, depth: -0.6, loops: ring(coil.x, coil.y, 56, 48)),
        ], 0, 0, Z.back)]),
    ]
}

@Sendable func phoneGuides() -> [Guide] {
    let Z = phoneZ, W = phoneW, D = phoneD
    return [
        Guide(a: Vec3(112, 262, Z.camera), b: Vec3(112, 262, Z.frame + 9), arrow: true),
        Guide(a: Vec3(4, D / 2, Z.display), b: Vec3(4, D / 2, Z.frame + 9), arrow: true),
        Guide(a: Vec3(W - 4, 240, Z.display), b: Vec3(W - 4, 240, Z.frame + 9), arrow: true),
        Guide(a: Vec3(75, 122, Z.coil), b: Vec3(75, 122, Z.back + 3), arrow: true),
    ]
}

// MARK: - Macro keypad

private let padW = 200.0, padD = 250.0
private let padZ = (base: 0.0, pcb: 100.0, plate: 186.0, sw: 240.0, caps: 340.0)
private let padKeys: [(Double, Double)] = [50.0, 100, 150].flatMap { x in [42.0, 92, 142].map { (x, $0) } }
private let padKnob = Vec2(150, 202)
private let padScreen = exRect(18, 184, 84, 38)

@Sendable func macropadParts() -> [ExamplePart] {
    let W = padW, D = padD, Z = padZ, K = padKnob
    let bosses: [(Double, Double)] = [(22, 22), (W - 22, 22), (22, D - 22), (W - 22, D - 22)]
    return [
        ExamplePart("Keycaps", label: "Keycaps", side: .left, target: Vec2(0.1, 0.55), alignTo: "Plate", fill: white, ops: padKeys.enumerated().map { i, k in
            exAt([
                .box(w: 38, d: 38, h: 18),
                .loopCut(id: "K\(i)", axis: .z, count: 1, slide: -30, scales: [100, 100, 76]),
                .push(axis: .z, at: 18, depth: -1.4, loops: [exCircle(19, 19, 10, 36)]),
            ], k.0 - 19, k.1 - 19, Z.caps)
        }),
        ExamplePart("Knob", label: "Knob", side: .right, target: Vec2(0.9, 0.5), alignTo: "Plate", fill: tint, ops: [exAt([
            .cylinder(r: 20, h: 22, segments: 64),
            .push(axis: .z, at: 22, depth: -22, through: true, loops: (0..<28).map { i in
                let a = Double(i) / 28 * Double.pi * 2
                return exCircle(20 * cos(a), 20 * sin(a), 1.3, 8)
            }),
            .push(axis: .z, at: 22, depth: -1.2, loops: [exCircle(0, 0, 15, 48)]),
            .push(axis: .z, at: 20.8, depth: -1, loops: [exRect(-1.2, -14, 2.4, 9)]),
        ], K.x, K.y, Z.caps)]),
        ExamplePart("Switches", label: "Mechanical switches", side: .left, target: Vec2(0.08, 0.6), alignTo: "Plate", fill: blue, ops: padKeys.map { k in
            exAt([
                exBox(-14, -14, 0, 28, 28, 6),
                exBox(-12.5, -12.5, 6, 25, 25, 7),
                exAt([.extrude(plane: .top, depth: 5, loops: [plus(0, 0, 5.5, 2.4)])], 0, 0, 13),
                .push(axis: .z, at: 13, depth: -1, loops: [exRect(-4, 6, 8, 4)]),
            ], k.0, k.1, Z.sw)
        }),
        ExamplePart("Encoder", label: "Rotary encoder", side: .right, target: Vec2(0.7, 0.3), alignTo: "Plate", fill: white, ops: [exAt([
            exBox(-8, -8, 0, 16, 16, 7),
            exCyl(0, 0, 7, 4.5, 6, 32),
            exCyl(0, 0, 13, 3, 12, 24),
        ], K.x, K.y, Z.sw)]),
        ExamplePart("OLED", label: "OLED screen", side: .left, target: Vec2(0.1, 0.5), alignTo: "Plate", fill: shell, ops: [exAt([
            .box(w: 84, d: 38, h: 3),
            .push(axis: .z, at: 3, depth: -0.6, loops: [exRect(4, 4, 76, 24)]),
        ], padScreen[0].x, padScreen[0].y, Z.sw)]),
        ExamplePart("Plate", label: "Switch plate", side: .right, target: flat(184, 162, 184, 234), fill: shell, ops: [exAt([
            exBox(8, 8, 0, W - 16, D - 16, 2),
            .push(axis: .z, at: 2, depth: -2, through: true, loops: padKeys.map { exRect($0.0 - 14, $0.1 - 14, 28, 28) }
                + [exCircle(K.x, K.y, 10, 32), padScreen]),
        ], 0, 0, Z.plate)]),
        ExamplePart("PCB", label: "PCB", side: .left, target: flat(0, 220, 184, 234), fill: blue,
            more: [.init(label: "Hot-swap sockets", side: .right, target: flat(133, 138, 184, 234), reach: 90)],
            ops: [exAt([exBox(8, 8, 0, W - 16, D - 16, 3)]
                + padKeys.flatMap { k in [exBox(k.0 - 9, k.1 + 4, 3, 16, 8, 3), exBox(k.0 + 12, k.1 - 8, 3, 3, 6, 1.4)] }
                + [
                    exAt([.box(w: 16, d: 16, h: 2), .push(axis: .z, at: 2, depth: -0.4, loops: [exCircle(3, 3, 1.4, 10)])], 110, 170, 3),
                    exBox(176, 38, 3, 16, 22, 4),
                    exBox(K.x - 9, K.y - 9, 3, 18, 18, 2),
                    exBox(40, 176, 3, 28, 4, 5),
                ], 0, 0, Z.pcb)]),
        ExamplePart("Case", label: "Case", side: .left, target: Vec2(0.05, 0.55), fill: shell,
            more: [.init(label: "USB-C", side: .right, target: Vec2(0.89, 0.53), reach: 90)],
            ops: [exAt([
                .extrude(plane: .top, depth: 26, loops: [exRoundRect(0, 0, W, D, 12, 4)]),
                .push(axis: .z, at: 26, depth: -22, loops: [exRoundRect(7, 7, W - 14, D - 14, 6, 4)]),
                .push(axis: .x, at: W, depth: -9, loops: [exRoundRect(37, 12, 24, 9, 4, 3)]),
            ] + bosses.map { x, y in
                exAt([.cylinder(r: 6, h: 10, segments: 24), .push(axis: .z, at: 10, depth: -8, loops: [exCircle(0, 0, 2.2, 12)])], x, y, 4)
            }, 0, 0, Z.base)]),
    ]
}

@Sendable func macropadGuides() -> [Guide] {
    let Z = padZ, K = padKnob
    let (x, y) = padKeys[5]
    return [
        Guide(a: Vec3(x, y, Z.caps), b: Vec3(x, y, Z.sw + 18), arrow: true),
        Guide(a: Vec3(x, y, Z.sw), b: Vec3(x, y, Z.plate + 2), arrow: true),
        Guide(a: Vec3(K.x, K.y, Z.caps), b: Vec3(K.x, K.y, Z.sw + 25), arrow: true),
        Guide(a: Vec3(22, 22, Z.pcb), b: Vec3(22, 22, Z.base + 14), arrow: true),
        Guide(a: Vec3(padW - 22, padD - 22, Z.pcb), b: Vec3(padW - 22, padD - 22, Z.base + 14), arrow: true),
    ]
}

// MARK: - Ball bearing

private let bearingZ = (shieldLow: 0.0, outer: 70.0, cage: 190.0, balls: 250.0, inner: 350.0, shieldHigh: 480.0)

@Sendable func bearingParts() -> [ExamplePart] {
    let Z = bearingZ
    let pitch = 93.0, ball = 18.0, groove = 18.9, mid = 22.5, w = 45.0
    func arc(_ from: Double, _ to: Double, _ n: Int = 18) -> Loop {
        (0...n).map { i in
            let a = (from + (to - from) * Double(i) / Double(n)) * Double.pi / 180
            return Vec2(pitch + groove * cos(a), mid + groove * sin(a))
        }
    }
    let tOut = acos(6 / groove) * 180 / Double.pi, tIn = acos(-6 / groove) * 180 / Double.pi
    let outer = pts([[101, 0], [133, 0], [135, 2], [135, w - 2], [133, w], [101, w], [99, w - 2]]) + arc(tOut, -tOut) + [Vec2(99, 2)]
    let inner = pts([[47, 0], [85, 0], [87, 2]]) + arc(-tIn, tIn - 360) + pts([[87, w - 2], [85, w], [47, w], [45, w - 2], [45, 2]])
    let angles = (0..<9).map { (45 + Double($0) * 40) * Double.pi / 180 }
    func shield(_ z: Double) -> Op {
        exAt([
            tube(132, 50, 3),
            .push(axis: .z, at: 3, depth: -1, loops: ring(0, 0, 118, 66)),
        ], 0, 0, z)
    }
    return [
        ExamplePart("Shield", label: "Shield ×2", side: .right, target: Vec2(0.96, 0.5), fill: shell, ops: [shield(Z.shieldHigh)]),
        ExamplePart("Inner race", label: "Inner race", side: .left, target: Vec2(0.05, 0.5), fill: tint,
            more: [.init(label: "Raceway", side: .right, target: Vec2(0.72, 0.62), reach: 110)],
            ops: [exAt([.revolve(segments: 80, axis: 0, loops: [inner])], 0, 0, Z.inner), .cut(.quarter, fx: 50, fy: 50)]),
    ] + angles.enumerated().map { i, a in
        // One part per ball: nine spheres in one union exceed the BSP's work cap.
        ExamplePart("Ball", label: i == 7 ? "Steel balls ×9" : nil, side: .right, target: Vec2(0.97, 0.5), fill: blue, ops: [
            exAt([sphere(ball)], pitch * cos(a), pitch * sin(a), Z.balls),
        ])
    } + [
        ExamplePart("Cage", label: "Cage", side: .left, target: Vec2(0.03, 0.5), fill: white, ops: [exAt([
            tube(104, 82, 16, 80),
            .push(axis: .z, at: 16, depth: -10, loops: angles.map { exCircle(pitch * cos($0), pitch * sin($0), 18.6, 32) }),
        ], 0, 0, Z.cage)]),
        ExamplePart("Outer race", label: "Outer race", side: .left, target: Vec2(0.03, 0.5), fill: tint,
            more: [.init(label: "Section", side: .right, target: Vec2(0.86, 0.66), reach: 90)],
            ops: [exAt([.revolve(segments: 96, axis: 0, loops: [outer])], 0, 0, Z.outer), .cut(.quarter, fx: 50, fy: 50)]),
        ExamplePart("Shield", fill: shell, ops: [shield(Z.shieldLow)]),
    ]
}

@Sendable func bearingGuides() -> [Guide] {
    [Guide(a: Vec3(0, 0, bearingZ.shieldHigh + 40), b: Vec3(0, 0, -30), opacity: 0.6, dash: [10, 8])]
}

// MARK: - Compact cassette

private let tapeW = 270.0, tapeD = 170.0
private let tapeZ = (bottom: 0.0, reels: 96.0, sheet: 190.0, top: 270.0, screws: 370.0)
private let tapeSpindles = [Vec2(78, 76), Vec2(192, 76)]
private let tapeScrews: [(Double, Double)] = [(16, 16), (254, 16), (16, 154), (254, 154), (135, 22)]

@Sendable func cassetteParts() -> [ExamplePart] {
    let W = tapeW, D = tapeD, Z = tapeZ, S = tapeSpindles
    let body = exRoundRect(0, 0, W, D, 8, 3)
    let rollers = [Vec2(30, 148), Vec2(240, 148)]
    func reel(_ c: Vec2, _ r: Double) -> [Op] {
        [
            exAt([
                .cylinder(r: r, h: 9, segments: 72),
                .push(axis: .z, at: 9, depth: -9, through: true, loops: [exCircle(0, 0, 17, 40)]),
            ], c.x, c.y, 1),
            exAt([tube(16, 11, 11, 40)] + (0..<6).map { i in
                let a = Double(i) / 6 * Double.pi * 2
                return exCyl(10.5 * cos(a), 10.5 * sin(a), 0, 2, 11, 12)
            }, c.x, c.y, 0),
        ]
    }
    let tape: [Loop] = [
        exStrip(Vec2(33, 88), Vec2(26, 148), 1.2),
        exStrip(Vec2(30, 152.6), Vec2(240, 152.6), 1.2),
        exStrip(Vec2(244, 148), Vec2(221, 84), 1.2),
    ]
    return [
        ExamplePart("Screws", label: "Screws ×5", side: .right, target: Vec2(0.98, 0.62), alignTo: "Top shell", fill: white, ops: tapeScrews.map { x, y in
            exAt([
                .cylinder(r: 2.2, h: 10, segments: 16),
                exCyl(0, 0, 10, 4.6, 2.4, 24),
                .push(axis: .z, at: 12.4, depth: -1.4, loops: [plus(0, 0, 3, 1.2)]),
            ], x, y, Z.screws)
        }),
        ExamplePart("Top shell", label: "Top shell", side: .left, target: Vec2(0.05, 0.45), fill: shell, ops: [exAt([
            .extrude(plane: .top, depth: 14, loops: [body]),
            exAt([.box(w: W - 14, d: D - 14, h: 11)], 7, 7, -0.01, "subtract"),
            .push(axis: .z, at: 14, depth: -14, through: true, loops: [exRect(104, 52, 62, 44)]),
            .push(axis: .z, at: 14, depth: -14, through: true, loops: S.map { exCircle($0.x, $0.y, 15, 40) }),
            .push(axis: .z, at: 14, depth: -1, loops: [exRoundRect(14, 12, W - 28, 30, 4, 3)]),
            .push(axis: .z, at: 14, depth: 2.5, loops: [pts([[72, D], [198, D], [186, D - 28], [84, D - 28]])]),
            .push(axis: .z, at: 14, depth: -14, through: true, loops: tapeScrews.map { exCircle($0.0, $0.1, 2.6, 16) }),
        ], 0, 0, Z.top)]),
        ExamplePart("Label", fill: white, on: "Top shell", ops: [
            exAt([.extrude(plane: .top, depth: 0.6, loops: [exRoundRect(18, 15, W - 36, 24, 3, 3)])], 0, 0, Z.top + 13),
        ]),
        ExamplePart("Window", label: "Window", side: .right, target: Vec2(0.8, 0.6), alignTo: "Top shell", fill: pale, on: "Top shell", ops: [
            exBox(104, 52, Z.top + 11, 62, 44, 2.4),
        ]),
        ExamplePart("Slip sheet", label: "Slip sheet", side: .left, target: Vec2(0.04, 0.4), alignTo: "Top shell", fill: white, ops: [exAt([
            exBox(14, 14, 0, W - 28, D - 28, 0.8),
            .push(axis: .z, at: 0.8, depth: -0.8, through: true, loops: S.map { exCircle($0.x, $0.y, 26, 40) }),
            .push(axis: .z, at: 0.8, depth: -0.8, through: true, loops: [exRect(110, 58, 50, 36)]),
        ], 0, 0, Z.sheet)]),
        ExamplePart("Tape reels", label: "Tape pack", side: .left, target: Vec2(0.02, 0.3), alignTo: "Top shell", fill: blue,
            more: [.init(label: "Hub", side: .right, target: Vec2(0.85, 0.5), reach: 110)],
            ops: [exAt(reel(S[0], 46) + reel(S[1], 30) + [.extrude(plane: .top, depth: 9, loops: tape)]
                + rollers.map { exCyl($0.x, $0.y, 0, 4.5, 11, 20) }, 0, 0, Z.reels)]),
        ExamplePart("Pressure pad", label: "Pressure pad", side: .below, target: Vec2(0.5, 0.9), reach: 70, fill: "#FCE3DD", on: "Bottom shell", ops: [exAt([
            .extrude(plane: .top, depth: 8, loops: [exStrip(Vec2(112, 152), Vec2(135, 157), 1), exStrip(Vec2(135, 157), Vec2(158, 152), 1)]),
            exBox(127, 157, 0, 16, 4, 8),
        ], 0, 0, Z.bottom + 3)]),
        ExamplePart("Bottom shell", label: "Bottom shell", side: .left, target: Vec2(0.05, 0.45), fill: shell,
            more: [.init(label: "Head openings", side: .right, target: Vec2(0.62, 0.96), reach: 90)],
            ops: [exAt([
                .extrude(plane: .top, depth: 14, loops: [body]),
                .push(axis: .z, at: 14, depth: -11, loops: [exRoundRect(7, 7, W - 14, D - 14, 5, 3)]),
                .push(axis: .z, at: 3, depth: -3, through: true, loops: S.map { exCircle($0.x, $0.y, 15, 40) }),
                .push(axis: .y, at: D, depth: -8, loops: [exRect(105, 5, 60, 10), exRect(56, 5, 22, 10), exRect(192, 5, 22, 10)]),
                exBox(118, 146, 3, 34, 4, 9),
            ] + rollers.map { exCyl($0.x, $0.y, 3, 2, 11, 12) } + tapeScrews.map { x, y in
                exAt([.cylinder(r: 6, h: 9, segments: 24), .push(axis: .z, at: 9, depth: -7, loops: [exCircle(0, 0, 2, 12)])], x, y, 3)
            }, 0, 0, Z.bottom)]),
    ]
}

@Sendable func cassetteGuides() -> [Guide] {
    let Z = tapeZ
    return [(16.0, 154.0), (254, 154), (254, 16)].map { x, y in
        Guide(a: Vec3(x, y, Z.screws), b: Vec3(x, y, Z.bottom + 12), arrow: true)
    } + tapeSpindles.map { c in
        Guide(a: Vec3(c.x, c.y, Z.reels - 8), b: Vec3(c.x, c.y, Z.bottom + 3), opacity: 0.6, dash: [8, 6])
    }
}

// MARK: - LED bulb

/// Authored in millimetres around the bulb's axis, drawn three times larger.
private let bulbK = 3.0
private let bulbZ = (base: 0.0, driver: 46.0, housing: 92.0, board: 142.0, dome: 174.0)

@Sendable func bulbParts() -> [ExamplePart] {
    let Z = bulbZ
    var thread: Loop = pts([[0, 0], [4, 0], [4, 2], [7, 2], [8, 5]])
    for i in 0..<5 {
        let z0 = 6 + 3.6 * Double(i)
        thread += [Vec2(12.6, z0), Vec2(13.9, z0 + 1.8)]
    }
    thread += pts([[12.6, 24], [13.6, 24], [13.6, 27], [0, 27]])
    let housing = pts([[11.5, 0], [14, 0], [29, 28], [30.5, 28], [30.5, 33], [27.5, 33], [27.5, 30.5], [11.5, 3]])
    let quarter = (0...16).map { Double($0) / 16 * Double.pi / 2 }
    let dome = pts([[28.5, -3], [30, -3]]) + quarter.map { Vec2(30 * cos($0), 36 * sin($0)) }
        + quarter.reversed().map { Vec2(28.5 * cos($0), 34.5 * sin($0)) }
    let leds = (0..<12).map { i -> (Double, Double) in
        let a = Double(i) / 12 * Double.pi * 2
        return (19 * cos(a), 19 * sin(a))
    } + (0..<6).map { i -> (Double, Double) in
        let a = (Double(i) / 6 + 1 / 12) * Double.pi * 2
        return (10 * cos(a), 10 * sin(a))
    }
    return [
        ExamplePart("Diffuser", label: "Diffuser dome", side: .right, target: Vec2(0.92, 0.6), fill: pale, ops: exScale([
            exAt([.revolve(segments: 72, axis: 0, loops: [dome])], 0, 0, Z.dome),
            .cut(.quarter, fx: 50, fy: 50),
        ], bulbK)),
        ExamplePart("LEDs", label: "SMD LEDs ×18", side: .left, target: Vec2(0.1, 0.5), fill: white, on: "LED board", ops: exScale(leds.map { x, y in
            exAt([.box(w: 3.4, d: 2.8, h: 1), .push(axis: .z, at: 1, depth: -0.3, loops: [exCircle(1.7, 1.4, 0.9, 12)])], x - 1.7, y - 1.4, Z.board + 1.6)
        }, bulbK)),
        ExamplePart("LED board", label: "Aluminium LED board", side: .right, target: Vec2(0.95, 0.5), fill: blue, ops: exScale([exAt([
            .cylinder(r: 27, h: 1.6, segments: 72),
            .push(axis: .z, at: 1.6, depth: -1.6, through: true, loops: [exCircle(0, 0, 3, 20), exCircle(-6, 0, 1.2, 12), exCircle(6, 0, 1.2, 12)]),
        ], 0, 0, Z.board)], bulbK)),
        ExamplePart("Heat sink", label: "Heat sink", side: .left, target: Vec2(0.08, 0.5), fill: tint,
            more: [.init(label: "Section", side: .right, target: Vec2(0.8, 0.55), reach: 100)],
            ops: exScale([
                exAt([.revolve(segments: 72, axis: 0, loops: [housing])], 0, 0, Z.housing),
                .cut(.quarter, fx: 50, fy: 50),
            ], bulbK)),
        ExamplePart("Driver", label: "Driver board", side: .right, target: Vec2(0.9, 0.5), fill: blue,
            more: [.init(label: "Capacitor", side: .left, target: Vec2(0.4, 0.3), reach: 110)],
            ops: exScale([exAt([
                exBox(-8, -1, 0, 16, 2, 30),
                .merge([.cylinder(r: 3.2, h: 8, segments: 24)], mode: "union", name: "cap", offset: Vec3(-3, 1, 20), matrix: faceLeft),
                .merge([.cylinder(r: 2.4, h: 5, segments: 20)], mode: "union", name: "coil", offset: Vec3(4, 1, 10), matrix: faceLeft),
                exBox(-6, 1, 6, 5, 3, 4),
                exBox(1, 1, 2, 3, 1.4, 1.4), exBox(1, 1, 5, 3, 1.4, 1.4),
                exBox(-7, 1, 13, 2, 1.4, 4), exBox(-4, 1, 13, 2, 1.4, 4),
            ], 0, 0, Z.driver)], bulbK)),
        ExamplePart("Base", label: "E27 screw base", side: .left, target: Vec2(0.05, 0.5), fill: shell,
            more: [.init(label: "Contact", side: .right, target: Vec2(0.55, 0.96), reach: 100)],
            ops: exScale([exAt([.revolve(segments: 48, axis: 0, loops: [thread])], 0, 0, Z.base)], bulbK)),
    ]
}

@Sendable func bulbGuides() -> [Guide] {
    [Guide(a: Vec3(0, 0, (bulbZ.dome + 46) * bulbK), b: Vec3(0, 0, -30), opacity: 0.6, dash: [10, 8])]
}
