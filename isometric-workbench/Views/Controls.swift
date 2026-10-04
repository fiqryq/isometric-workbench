import AppKit
import IsoDocument
import IsoGeometry
import IsoMath
import SwiftUI

/// A number with a stepper that reports edits once, on commit.
struct NumberField: View {
    let label: String
    let value: Double
    var step: Double = 1
    var range: ClosedRange<Double> = -100_000...100_000
    let onCommit: (Double) -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, value: binding, format: .number.precision(.fractionLength(0...3)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                Stepper(label, value: binding, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private var binding: Binding<Double> {
        Binding(get: { value }, set: { v in
            let c = clamp(v, range.lowerBound, range.upperBound)
            if c != value { onCommit(c) }
        })
    }
}

/// Text that commits on Return or when focus leaves, so typing a name is
/// one undo step.
struct CommitField: View {
    let title: String
    let text: String
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        if draft != text { onCommit(draft) }
    }
}

/// A colour well bound to a `#rrggbb` string.
struct HexColorPicker: View {
    let title: String
    let hex: String
    let onCommit: (String) -> Void

    var body: some View {
        ColorPicker(title, selection: Binding(get: { Color(RGB(hex: hex)) }, set: { color in
            let new = RGB(color).hex
            if new != RGB(hex: hex).hex { onCommit(new) }
        }), supportsOpacity: false)
    }
}

extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

extension RGB {
    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }
}

/// Diamond showing whether a property has a key at the playhead.
struct KeyButton: View {
    let animated: Bool
    let keyed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: keyed ? "diamond.fill" : "diamond")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(animated ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(keyed ? "Remove key at playhead" : "Add key at playhead")
    }
}
