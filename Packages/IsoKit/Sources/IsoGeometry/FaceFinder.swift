import Foundation

public enum FaceFinder {
    /// The visible face facing +axis under a screen point (relative to the
    /// part's origin); returns its plane offset — the plugin's `faceUnder`.
    public static func planeOffset(
        under sx: Double, _ sy: Double, axis: Axis, in mesh: Mesh, angle t: IsoAngle, view: ViewTransform
    ) -> Double? {
        let k = axis.index
        let toViewer = t.toViewer
        var best: (at: Double, depth: Double)? = nil
        for p in mesh {
            if p.n[k] < 0.999 || view.applyNormal(p.n).dot(toViewer) <= 0 { continue }
            let at = p.v[0][k]
            guard let w = t.screenToPlane(sx, sy, axis: axis, at: at, view: view) else { continue }
            var inside = true
            var i = 0
            while i < p.v.count && inside {
                let a = p.v[i], b = p.v[(i + 1) % p.v.count]
                if (b - a).cross(w - a).dot(p.n) < -1e-3 { inside = false }
                i += 1
            }
            if !inside { continue }
            let depth = view.apply(w).dot(toViewer)
            if best == nil || depth > best!.depth { best = (at, depth) }
        }
        return best?.at
    }
}
