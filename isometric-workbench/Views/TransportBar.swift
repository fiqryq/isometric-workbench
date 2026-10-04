import IsoDocument
import IsoGeometry
import IsoMath
import SwiftUI

struct TransportBar: View {
    @Bindable var model: SceneModel
    @Binding var showTimeline: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { model.seek(0) } label: { Image(systemName: "backward.end.fill") }
                .help("Go to start")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .help(model.isPlaying ? "Pause" : "Play")
            Toggle(isOn: $model.loops) { Image(systemName: "repeat") }
                .toggleStyle(.button)
                .help("Loop playback")

            if showTimeline { Spacer() } else { Timeline(model: model) }

            Text(String(format: "%5.2f / %.2f s", model.frameTime, model.scene.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)

            Button { model.addKeyframe() } label: { Image(systemName: "diamond.circle") }
                .help("Key the selected parts at the playhead")
                .disabled(model.selection.isEmpty)
            Toggle(isOn: $model.autoKey) { Image(systemName: "record.circle") }
                .toggleStyle(.button)
                .tint(.red)
                .help("Auto-key: edits write keyframes")

            Menu {
                ForEach(AnimationPreset.allCases) { preset in
                    if preset == .clear { Divider() }
                    Button(preset.title) { model.applyPreset(preset) }
                }
            } label: {
                Label("Animate", systemImage: "wand.and.stars")
            }
            .fixedSize()

            Toggle(isOn: $showTimeline) { Image(systemName: "timeline.selection") }
                .toggleStyle(.button)
                .help("Show or hide the timeline")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Scrubber with ticks for the selection's keyframes.
struct Timeline: View {
    let model: SceneModel

    var body: some View {
        let duration = model.scene.duration
        let keys = model.selectedParts.flatMap(\.anim.keyTimes) + (model.selection.isEmpty ? model.scene.camera.keyTimes : [])
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                Capsule().fill(Color.accentColor.opacity(0.5))
                    .frame(width: max(0, w * model.frameTime / duration), height: 4)
                ForEach(Array(Set(keys)).sorted(), id: \.self) { t in
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                        .position(x: w * t / duration, y: geo.size.height / 2)
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 16)
                    .position(x: w * model.frameTime / duration, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if model.isPlaying { model.pause() }
                model.seek(duration * Double(v.location.x / max(1, w)))
            })
        }
        .frame(height: 20)
    }
}

struct StatusBar: View {
    let model: SceneModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.status).lineLimit(1).truncationMode(.tail)
            Spacer()
            if model.build.isBuilding {
                ProgressView().controlSize(.mini)
                Text("Building…")
            }
            Text("\(model.scene.parts.count) part\(model.scene.parts.count == 1 ? "" : "s")")
            Text("\(Int((model.zoom * 100).rounded()))%").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
