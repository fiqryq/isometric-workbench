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

            Spacer()

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

            Button { showTimeline = false } label: { Image(systemName: "chevron.down") }
                .help("Hide the timeline (⇧⌘T)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Quiet status line in the canvas corner, in place of a status bar.
struct CanvasStatus: View {
    let model: SceneModel

    var body: some View {
        HStack(spacing: 8) {
            if model.build.isBuilding {
                ProgressView().controlSize(.mini)
            }
            Text(model.status).lineLimit(1).truncationMode(.tail)
            Text("·")
            Text("\(model.scene.parts.count) part\(model.scene.parts.count == 1 ? "" : "s")")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }
}
