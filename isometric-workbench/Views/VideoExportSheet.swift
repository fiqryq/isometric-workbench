import AppKit
import IsoDocument
import IsoGeometry
import IsoMath
import SwiftUI
import UniformTypeIdentifiers

struct VideoExportSheet: View {
    let model: SceneModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = VideoSettings()
    @State private var job = VideoExportJob()
    @State private var showPaywall = false
    private var store: Store { Store.shared }

    private static let heights = [360, 480, 720, 1080, 1440, 2160]
    private static let gifHeights = [240, 360, 480, 600, 800]
    private static let rates = [12.0, 15, 20, 24, 25, 30, 50, 60]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Format", selection: $settings.format) {
                        ForEach(VideoFormat.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Height", selection: $settings.height) {
                        ForEach(settings.format == .gif ? Self.gifHeights : Self.heights, id: \.self) { h in
                            Text(label(for: h)).tag(h)
                        }
                    }
                    Picker("Frame rate", selection: $settings.fps) {
                        ForEach(Self.rates, id: \.self) { Text("\(Int($0)) fps").tag($0) }
                    }
                    if settings.format.supportsAlpha {
                        Toggle("Transparent background", isOn: $settings.transparent)
                    }
                }
                Section("Range") {
                    NumberField(label: "Start (s)", value: settings.start, step: 0.5, range: 0...model.scene.duration) { v in
                        settings.start = min(v, settings.end - 1 / settings.fps)
                    }
                    NumberField(label: "End (s)", value: settings.end, step: 0.5, range: 0...model.scene.duration) { v in
                        settings.end = max(v, settings.start + 1 / settings.fps)
                    }
                    LabeledContent("Output", value: summary)
                }
                if !store.isPro {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "seal").foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Free exports run up to \(Int(Limits.freeVideoSeconds)) seconds at \(Limits.freeVideoHeight)p and carry a small mark.")
                                Button("Unlock Workbench Pro…") { showPaywall = true }
                                    .buttonStyle(.link)
                            }
                        }
                        .font(.callout)
                    }
                }
                if job.state != .idle { statusSection }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if job.isRunning {
                    Button("Stop", role: .cancel) { job.cancel() }
                } else {
                    Button("Close", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.isRunning || model.scene.parts.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 440)
        .onAppear {
            settings.end = model.scene.duration
            settings.fps = Self.rates.min { abs($0 - model.scene.fps) < abs($1 - model.scene.fps) } ?? 30
        }
        .onChange(of: settings.format) { _, f in
            let list = f == .gif ? Self.gifHeights : Self.heights
            if !list.contains(settings.height) { settings.height = f == .gif ? 480 : 1080 }
            if f == .gif && settings.fps > 30 { settings.fps = 20 }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    private func label(for h: Int) -> String {
        let locked = !store.isPro && h > Limits.freeVideoHeight
        let name = switch h {
        case 2160: "2160p (4K)"
        default: "\(h)p"
        }
        return locked ? "\(name) — Pro" : name
    }

    /// Settings with the free limits applied.
    private var effective: VideoSettings {
        var s = settings
        if !store.isPro {
            s.height = min(s.height, Limits.freeVideoHeight)
            s.end = min(s.end, s.start + Limits.freeVideoSeconds)
            s.watermark = true
        }
        return s
    }

    private var summary: String {
        let s = effective
        let frames = max(1, Int(((s.end - s.start) * s.fps).rounded()))
        let secs = String(format: "%.2g s", s.end - s.start)
        return "\(frames) frames · \(secs) · \(s.height)p"
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            switch job.state {
            case .running:
                ProgressView(value: job.progress) {
                    Text("Rendering… \(Int(job.progress * 100))%")
                }
            case .finished(let url):
                HStack {
                    Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .cancelled:
                Label("Export stopped.", systemImage: "stop.circle").foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
        }
    }

    private func export() {
        let s = effective
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = model.scene.name.isEmpty ? "Animation" : model.scene.name
        if s.format == .png {
            panel.title = "Export PNG Sequence"
            panel.message = "Frames are saved in a new folder with this name."
            panel.allowedContentTypes = [.folder]
        } else {
            panel.title = "Export \(s.format.title)"
            panel.allowedContentTypes = [s.format.contentType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.status = "Exporting \(url.lastPathComponent)…"
        job.start(scene: model.scene, seed: model.build.builtMeshes(model.scene), settings: s, to: url)
    }
}

// MARK: - Pro

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: Store { Store.shared }

    private let features: [(String, String)] = [
        ("photo", "Full-resolution PNG, PDF and SVG with no mark"),
        ("film", "Video of any length, up to 4K, in H.264, HEVC or ProRes 4444"),
        ("square.stack.3d.down.right", "Transparent ProRes and PNG sequences for compositing"),
        ("gift", "One purchase — every future export format included"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workbench Pro").font(.title2.weight(.semibold))
                    Text("Export without limits.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(features, id: \.1) { icon, text in
                    Label(text, systemImage: icon)
                }
            }
            if let message = store.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restore Purchase") { Task { await store.restore() } }
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await store.purchase()
                        if store.isPro { dismiss() }
                    }
                } label: {
                    if store.isPurchasing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(store.product == nil ? "Unlock Pro" : "Unlock for \(store.priceText)")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.isPurchasing || store.isPro)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onChange(of: store.isPro) { _, pro in if pro { dismiss() } }
    }
}

struct SettingsView: View {
    private var store: Store { Store.shared }
    @State private var showPaywall = false

    var body: some View {
        Form {
            Section("Workbench Pro") {
                if store.isPro {
                    Label("Pro is unlocked. Thank you!", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Text("Free exports are limited to \(Int(Limits.freeImageSide)) px images and \(Int(Limits.freeVideoSeconds)) s, \(Limits.freeVideoHeight)p video, with a small mark.")
                        .foregroundStyle(.secondary)
                    Button("Unlock Workbench Pro…") { showPaywall = true }
                }
                Button("Restore Purchase") { Task { await store.restore() } }
                if let message = store.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }
}
