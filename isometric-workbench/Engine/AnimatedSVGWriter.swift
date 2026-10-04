import Foundation
import IsoDocument
import IsoMath

/// One self-contained SVG that plays in browsers: each distinct frame is a
/// group shown during its time window by a discrete SMIL `display`
/// animation, which Safari, Chrome and Firefox all loop (also inside `<img>`).
/// Without SMIL the first frame shows.
nonisolated enum AnimatedSVGWriter {
    struct Content: Equatable {
        var sheet: String
        var body: String
    }

    static func document(
        _ scene: SceneFile, composer: FrameComposer, plan: VideoPlan, settings: VideoSettings, progress: (Double) -> Void
    ) throws -> String {
        var style = scene.style
        let spans = try plan.spans(progress: progress) { t in
            var frame = composer.compose(scene, at: t)
            style = frame.style
            let sheet = frame.boards.map { SVGWriter.sheetSVG($0, style: frame.style) }.joined()
            frame.boards = []
            var clip = 0
            return Content(sheet: sheet, body: SVGWriter.content(frame, clip: &clip, named: false, merged: true))
        }

        let count = plan.times.count
        let o = plan.origin, w = Double(plan.width) / plan.scale, h = Double(plan.height) / plan.scale
        var out = #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(plan.width)" height="\#(plan.height)" viewBox="\#(n(o.x)) \#(n(o.y)) \#(n(w)) \#(n(h))">"#
        if !settings.transparent {
            out += #"<rect x="\#(n(o.x))" y="\#(n(o.y))" width="\#(n(w))" height="\#(n(h))" fill="\#(style.bg)"/>"#
        }
        // The sheet rarely changes, so it's drawn once under the frames.
        let sheet = spans.first?.content.sheet ?? ""
        let sheetHolds = spans.allSatisfy { $0.content.sheet == sheet }
        if sheetHolds { out += sheet }
        let dur = n(Double(count) / max(1, settings.fps.rounded()), 4)
        let at = { (f: Int) in n(Double(f) / Double(count), 6) }
        for (k, span) in spans.enumerated() {
            let id = "frame\(k + 1)"
            let body = ((sheetHolds ? "" : span.content.sheet) + span.content.body)
                .replacingOccurrences(of: #"id="hatch"#, with: #"id="\#(id)-hatch"#)
                .replacingOccurrences(of: "url(#hatch", with: "url(#\(id)-hatch")
            let a = span.start, b = span.end
            let timing: (values: String, times: String)? =
                if a == 0 && b == count { nil }
                else if a == 0 { ("inline;none", "0;\(at(b))") }
                else if b == count { ("none;inline", "0;\(at(a))") }
                else { ("none;inline;none", "0;\(at(a));\(at(b))") }
            out += #"<g id="\#(id)"\#(a == 0 ? "" : #" display="none""#)>"#
            if let timing {
                out += #"<animate attributeName="display" values="\#(timing.values)" keyTimes="\#(timing.times)" dur="\#(dur)s" calcMode="discrete" repeatCount="indefinite"/>"#
            }
            out += body + "</g>"
        }
        if settings.watermark { out += SVGWriter.watermarkSVG(plan.box, style: style) }
        progress(1)
        return out + "</svg>\n"
    }

    private static func n(_ v: Double, _ places: Double = 2) -> String {
        let k = pow(10, places)
        return jsNumberString(jsRound(v * k) / k)
    }
}
