import AppKit
import IsoDocument
import IsoGeometry
import IsoMath

/// Keys on the clipboard, relative to the earliest one.
struct CopiedKeys {
    struct Key {
        var owner: KeyRef.Owner
        var prop: String
        var dt: Double
        var frame: Keyframe
    }

    var keys: [Key]
}

extension SceneModel {
    static let cameraProps = ["spin"]

    func keyframe(_ k: KeyRef) -> Keyframe? {
        scene.animatable(k.owner)?.keys[k.prop]?.first { abs($0.t - k.t) < 1e-3 }
    }

    /// Every key of an owner at a time (a summary diamond).
    func keys(of owner: KeyRef.Owner, at t: Double) -> Set<KeyRef> {
        guard let a = scene.animatable(owner) else { return [] }
        var out: Set<KeyRef> = []
        for (prop, list) in a.keys {
            for k in list where abs(k.t - t) < 1e-3 { out.insert(KeyRef(owner: owner, prop: prop, t: k.t)) }
        }
        return out
    }

    func ownerName(_ owner: KeyRef.Owner) -> String {
        switch owner {
        case .camera: "Camera"
        case .part(let id): scene.parts.first { $0.id == id }?.name ?? "Part"
        }
    }

    /// Moves keys by `dt` seconds (snapped to frames, kept inside the
    /// timeline) as part of a gesture. `keys` are refs into `gestureBase`.
    @discardableResult
    func retimeKeys(_ keys: Set<KeyRef>, by dt: Double) -> Set<KeyRef> {
        guard let minT = keys.map(\.t).min(), let maxT = keys.map(\.t).max() else { return keys }
        let base = gestureBase
        let fps = max(1, scene.fps), dur = scene.duration
        let d = clamp(dt, -minT, dur - maxT)
        let target = clamp((minT + d) * fps, 0, dur * fps).rounded() / fps
        var delta = target - minT
        if maxT + delta > dur + 1e-9 { delta -= 1 / fps }
        let groups = Dictionary(grouping: keys) { KeyRef(owner: $0.owner, prop: $0.prop, t: 0) }
        updateGesture { s in
            for (g, refs) in groups {
                guard var list = base.animatable(g.owner)?.keys[g.prop] else { continue }
                let moving = list.filter { k in refs.contains { abs($0.t - k.t) < 1e-3 } }
                list.removeAll { k in refs.contains { abs($0.t - k.t) < 1e-3 } }
                for var k in moving {
                    k.t = jsRound((k.t + delta) * 1000) / 1000
                    list.removeAll { abs($0.t - k.t) < 1e-3 }
                    list.append(k)
                }
                list.sort { $0.t < $1.t }
                s.withAnimatable(g.owner) { $0.keys[g.prop] = list }
            }
        }
        return Set(keys.map { KeyRef(owner: $0.owner, prop: $0.prop, t: jsRound(($0.t + delta) * 1000) / 1000) })
    }

    func setEasing(_ e: Easing, for keys: Set<KeyRef>) {
        guard !keys.isEmpty else { return }
        edit("Change Easing") { s in
            for k in keys {
                s.withAnimatable(k.owner) { a in
                    guard var list = a.keys[k.prop], let i = list.firstIndex(where: { abs($0.t - k.t) < 1e-3 }) else { return }
                    list[i].e = e
                    a.keys[k.prop] = list
                }
            }
        }
        status = "Easing set to \(e.title) on \(keys.count) key\(keys.count == 1 ? "" : "s")."
    }

    func toggleKey(_ owner: KeyRef.Owner, _ prop: String) {
        let t = frameTime
        let has = scene.animatable(owner)?.keys[prop]?.contains { abs($0.t - t) < 1e-3 } ?? false
        edit(has ? "Remove Key" : "Add Key") { s in
            s.withAnimatable(owner) { a in
                if has {
                    if a.keys[prop]?.count == 1 { a.base[prop] = a.keys[prop]?.first?.v }
                    a.removeKey(prop, t: t)
                } else {
                    a.setKey(prop, t: t, v: a.value(prop, at: t))
                }
            }
        }
    }

    func copyKeys() -> CopiedKeys? {
        guard let t0 = pickedKeys.map(\.t).min() else { return nil }
        let keys = pickedKeys.compactMap { k in keyframe(k).map { CopiedKeys.Key(owner: k.owner, prop: k.prop, dt: k.t - t0, frame: $0) } }
        status = "Copied \(keys.count) key\(keys.count == 1 ? "" : "s")."
        return CopiedKeys(keys: keys)
    }

    func pasteKeys(_ copied: CopiedKeys) {
        let t = frameTime, dur = scene.duration
        var pasted: Set<KeyRef> = []
        edit("Paste Keys") { s in
            for k in copied.keys {
                let at = jsRound(min(dur, t + k.dt) * 1000) / 1000
                s.withAnimatable(k.owner) { $0.setKey(k.prop, t: at, v: k.frame.v, e: k.frame.e) }
                pasted.insert(KeyRef(owner: k.owner, prop: k.prop, t: at))
            }
        }
        pickedKeys = pasted.filter { $0.exists(in: scene) }
    }
}

extension Easing {
    var title: String {
        switch self {
        case .smooth: "Smooth"
        case .linear: "Linear"
        case .in: "Ease In"
        case .out: "Ease Out"
        case .back: "Back"
        case .hold: "Hold"
        }
    }
}
