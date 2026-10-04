import AppKit
import IsoDocument
import IsoGeometry
import IsoMath
import SwiftUI

// MARK: - Inspector layout

enum InspectorMetrics {
    static let labelWidth: CGFloat = 64
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 8
    static let inset: CGFloat = 16
    static let radius: CGFloat = 7
    static let font = Font.system(size: 12)
    static let headerFont = Font.system(size: 13, weight: .semibold)
    static let fieldFill = Color(nsColor: NSColor(name: nil, dynamicProvider: fieldColor))
    static let fieldShape = RoundedRectangle(cornerRadius: radius, style: .continuous)

    nonisolated private static func fieldColor(_ appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.055)
    }
}

/// Lays out `LabeledContent` as a grey label with the control after it.
struct InspectorRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.label
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: InspectorMetrics.labelWidth, alignment: .leading)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: InspectorMetrics.rowHeight)
    }
}

extension LabeledContentStyle where Self == InspectorRowStyle {
    static var inspector: InspectorRowStyle { InspectorRowStyle() }
}

/// The scrolling column every inspector section sits in.
struct InspectorStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .labeledContentStyle(.inspector)
        .textFieldStyle(.plain)
        .toggleStyle(.inlineSwitch)
        .controlSize(.small)
        .font(InspectorMetrics.font)
    }
}

/// A titled group of rows. Sections are set apart by whitespace alone; one
/// with nothing in it shows a grey title, like Sketch's empty Borders.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String?
    let content: Content
    let accessory: Accessory
    private var dim = false

    init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    /// Greys the title when the section has no body.
    func dimmed(_ on: Bool = true) -> Self {
        var s = self
        s.dim = on
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if let title {
                HStack(spacing: 2) {
                    Text(title)
                        .font(InspectorMetrics.headerFont)
                        .foregroundStyle(dim ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    accessory
                }
                .frame(height: 22)
            }
            content
        }
        .padding(.horizontal, InspectorMetrics.inset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { EmptyView() }
    }
}

/// A row whose control carries its own title, such as a switch.
struct InspectorRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String = "", @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        if label.isEmpty {
            content
                .frame(maxWidth: .infinity, minHeight: InspectorMetrics.rowHeight, alignment: .leading)
        } else {
            LabeledContent { content } label: { Text(label) }
        }
    }
}

/// Two fields side by side at equal widths, like Sketch's X | Y.
struct FieldPair<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(@ViewBuilder _ leading: () -> Leading, @ViewBuilder _ trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: InspectorMetrics.rowSpacing) {
            leading.frame(maxWidth: .infinity)
            trailing.frame(maxWidth: .infinity)
        }
    }
}

/// The filled rounded box every inspector field sits in; `focused` rings it.
struct FieldBox<Content: View>: View {
    var focused = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: InspectorMetrics.rowHeight, maxHeight: InspectorMetrics.rowHeight)
            .background(InspectorMetrics.fieldShape.fill(InspectorMetrics.fieldFill))
            .overlay {
                if focused { InspectorMetrics.fieldShape.strokeBorder(Color.accentColor, lineWidth: 1.5) }
            }
    }
}

/// The grey label or icon at the leading edge of a field.
struct FieldLabel: View {
    let text: String
    var icon: String?

    var body: some View {
        Group {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(minWidth: 14)
            } else if !text.isEmpty {
                Text(text).lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

/// A read-only value in a field, label leading and value trailing.
struct ValueField: View {
    let label: String
    var icon: String?
    let value: String

    var body: some View {
        FieldBox {
            FieldLabel(text: label, icon: icon)
            Spacer(minLength: 4)
            Text(value).lineLimit(1).truncationMode(.middle).monospacedDigit()
        }
        .help(icon == nil ? "" : label)
    }
}

// MARK: - Buttons

/// Plain grey glyph with a hover wash, for section headers and icon rows.
struct InspectorIconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, active: active)
    }

    private struct Face: View {
        let configuration: Configuration
        let active: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(minWidth: 22, minHeight: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering && enabled ? 0.07 : 0)))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }

        private var tint: Color {
            if configuration.role == .destructive && hovering { return .red }
            return active ? .accentColor : .secondary
        }
    }
}

/// A small grey icon button, as in Sketch's section headers.
struct InspectorIconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ symbol: String, help: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) { Image(systemName: symbol) }
            .buttonStyle(InspectorIconButtonStyle())
            .help(help)
    }
}

/// An icon button that shows an on/off state, such as a part's eye or lock.
struct InspectorIconToggle: View {
    let on: String
    let off: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: { Image(systemName: isOn ? on : off) }
            .buttonStyle(InspectorIconButtonStyle(active: isOn))
            .help(help)
    }
}

/// A section header's add button.
struct SectionAddButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        InspectorIconButton("plus", help: help, action: action)
    }
}

/// A row of evenly spaced icon buttons, like Sketch's alignment bar.
struct IconButtonRow: View {
    struct Item {
        let symbol: String
        let help: String
        var disabled = false
        let action: () -> Void
    }

    let items: [Item]

    init(_ items: [Item]) { self.items = items }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(action: item.action) {
                    Image(systemName: item.symbol).frame(maxWidth: .infinity, minHeight: InspectorMetrics.rowHeight)
                }
                .buttonStyle(InspectorIconButtonStyle())
                .disabled(item.disabled)
                .help(item.help)
            }
        }
    }
}

/// A filled push button; `prominent` paints it with the accent colour.
struct FieldButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, prominent: prominent)
    }

    private struct Face: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? Color.white : configuration.role == .destructive ? Color.red : Color.primary)
                .padding(.horizontal, 8)
                .frame(minHeight: InspectorMetrics.rowHeight)
                .background(InspectorMetrics.fieldShape.fill(fill))
                .contentShape(InspectorMetrics.fieldShape)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if prominent { return Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1) }
            return .primary.opacity(configuration.isPressed ? 0.14 : hovering && enabled ? 0.09 : 0.06)
        }
    }
}

/// A filled button that stretches to its share of the row.
struct WideButton: View {
    let title: String
    var role: ButtonRole?
    var prominent = false
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(FieldButtonStyle(prominent: prominent))
    }
}

// MARK: - Toggles and choices

/// A small switch with its title after it, as in Sketch.
struct InlineSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
            configuration.label
                .lineLimit(1)
        }
    }
}

extension ToggleStyle where Self == InlineSwitchStyle {
    static var inlineSwitch: InlineSwitchStyle { InlineSwitchStyle() }
}

/// A pop-up drawn as a filled field: label or icon leading, the chosen
/// option, then up/down chevrons.
struct PopupField<Value: Hashable, Options: View>: View {
    let label: String
    var icon: String?
    let selection: Binding<Value>
    let options: Options

    init(_ label: String = "", icon: String? = nil, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        self.label = label
        self.icon = icon
        self.selection = selection
        self.options = options()
    }

    var body: some View {
        FieldBox {
            FieldLabel(text: label, icon: icon)
            Picker(label, selection: selection) { options }
                .pickerStyle(.menu)
                .labelsHidden()
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .tint(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
        }
        .help(icon == nil ? "" : label)
    }
}

/// One segment of `IconSegmented` or `ToggleSegments`.
private struct SegmentFace: View {
    let on: Bool
    let icon: String?
    let title: String?

    var body: some View {
        Group {
            if let icon { Image(systemName: icon) } else { Text(title ?? "").lineLimit(1) }
        }
        .font(.system(size: 12, weight: on ? .semibold : .regular))
        .foregroundStyle(on ? Color.white : Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: InspectorMetrics.radius - 2, style: .continuous)
            .fill(on ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
    }
}

private struct SegmentTrack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(2)
            .frame(height: InspectorMetrics.rowHeight)
            .background(InspectorMetrics.fieldShape.fill(InspectorMetrics.fieldFill))
    }
}

/// A segment's glyph or title, plus its tooltip.
struct Segment<Value: Hashable> {
    let value: Value
    var icon: String?
    var title: String?
    var help = ""

    static func icon(_ symbol: String, _ value: Value, help: String) -> Self { Segment(value: value, icon: symbol, help: help) }
    static func text(_ title: String, _ value: Value) -> Self { Segment(value: value, title: title, help: title) }
}

/// Sketch's segmented control: the chosen segment is a solid accent pill.
struct IconSegmented<Value: Hashable>: View {
    let selection: Binding<Value>
    let segments: [Segment<Value>]

    init(selection: Binding<Value>, _ segments: [Segment<Value>]) {
        self.selection = selection
        self.segments = segments
    }

    var body: some View {
        SegmentTrack {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                Button { if selection.wrappedValue != s.value { selection.wrappedValue = s.value } } label: {
                    SegmentFace(on: selection.wrappedValue == s.value, icon: s.icon, title: s.title)
                }
                .buttonStyle(.plain)
                .help(s.help)
            }
        }
    }
}

/// Segments that switch on and off independently, such as W · D · H.
struct ToggleSegments: View {
    let items: [(title: String, isOn: Binding<Bool>)]

    init(_ items: [(title: String, isOn: Binding<Bool>)]) { self.items = items }

    var body: some View {
        SegmentTrack {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button { item.isOn.wrappedValue.toggle() } label: {
                    SegmentFace(on: item.isOn.wrappedValue, icon: nil, title: item.title)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Secondary help text, kept to a line or two.
struct InspectorNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Fields

/// Brackets a drag on a slider or scrub label, so its edits reach the canvas
/// as they happen and undo as one step.
struct LiveEdit {
    var begin: () -> Void
    var end: () -> Void
}

extension EnvironmentValues {
    @Entry var liveEdit: LiveEdit? = nil
}

/// A number in a filled field with its label or icon inside, Sketch style.
/// Return or leaving the field commits; ↑/↓ step; dragging the label scrubs,
/// live when a `liveEdit` is in the environment.
/// `key` puts a keyframe diamond first; `suffix` is a grey unit after the value.
struct NumberField: View {
    let label: String
    var icon: String?
    let value: Double
    var step: Double
    var range: ClosedRange<Double>
    var suffix: String?
    var key: KeyButton?
    let onCommit: (Double) -> Void
    @Environment(\.liveEdit) private var live
    @State private var scrub: Double?
    @State private var scrubStart: Double?
    @State private var labelHover = false
    @FocusState private var focused: Bool

    init(label: String = "", icon: String? = nil, value: Double, step: Double = 1, range: ClosedRange<Double> = -100_000...100_000,
         suffix: String? = nil, key: KeyButton? = nil, onCommit: @escaping (Double) -> Void) {
        self.label = label
        self.icon = icon
        self.value = value
        self.step = step
        self.range = range
        self.suffix = suffix
        self.key = key
        self.onCommit = onCommit
    }

    var body: some View {
        FieldBox(focused: focused) {
            if let key { key }
            FieldLabel(text: label, icon: icon)
                .contentShape(Rectangle())
                .onHover { inside in
                    guard inside != labelHover else { return }
                    labelHover = inside
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .onDisappear { if labelHover { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                    if scrubStart == nil {
                        scrubStart = value
                        live?.begin()
                    }
                    let s = clamp((scrubStart ?? value) + (v.translation.width / 4).rounded() * step, range.lowerBound, range.upperBound)
                    if live == nil {
                        scrub = s
                    } else if s != value {
                        onCommit(s)
                    }
                }.onEnded { _ in
                    if let live { live.end() } else if let s = scrub, s != value { onCommit(s) }
                    scrub = nil
                    scrubStart = nil
                })
                .help(icon == nil ? "" : label)
            TextField(label, value: binding, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                .onKeyPress(.upArrow) { nudge(1) }
                .onKeyPress(.downArrow) { nudge(-1) }
            if let suffix {
                Text(suffix).foregroundStyle(.secondary).fixedSize().padding(.leading, -7)
            }
        }
    }

    private func nudge(_ sign: Double) -> KeyPress.Result {
        binding.wrappedValue = value + sign * step
        return .handled
    }

    private var binding: Binding<Double> {
        Binding(get: { scrub ?? value }, set: { v in
            let c = clamp(v, range.lowerBound, range.upperBound)
            if c != value { onCommit(c) }
        })
    }
}

/// A field that is also a slider: the accent fill shows where the value sits in
/// `range`. Dragging sets it live; a click types an exact value; ↑/↓ step while
/// typing. Either end of the range gives a tap on the trackpad.
struct SliderField: View {
    let label: String
    var icon: String?
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var suffix: String?
    var key: KeyButton?
    let onChange: (Double) -> Void

    @Environment(\.liveEdit) private var live
    @Environment(\.isEnabled) private var enabled
    @State private var width: CGFloat = 1
    @State private var dragging = false
    @State private var hovering = false
    @State private var typing = false
    @State private var sent: Double?
    @FocusState private var focused: Bool

    init(label: String, icon: String? = nil, value: Double, range: ClosedRange<Double>, step: Double = 1, suffix: String? = nil,
         key: KeyButton? = nil, onChange: @escaping (Double) -> Void) {
        self.label = label
        self.icon = icon
        self.value = value
        self.range = range
        self.step = step
        self.suffix = suffix
        self.key = key
        self.onChange = onChange
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? CGFloat(clamp((value - range.lowerBound) / span, 0, 1)) : 0
    }

    private var text: String {
        value.formatted(.number.precision(.fractionLength(0...(step < 1 ? 2 : 0))))
    }

    var body: some View {
        let fill = max(0, width * fraction)
        ZStack(alignment: .leading) {
            InspectorMetrics.fieldShape.fill(InspectorMetrics.fieldFill)
            Rectangle()
                .fill(Color.accentColor.opacity(dragging ? 0.3 : hovering ? 0.22 : 0.16))
                .frame(width: fill)
            Capsule()
                .fill(Color.accentColor)
                .frame(width: dragging ? 3 : 2, height: dragging ? 18 : 12)
                .offset(x: min(max(fill - 1.5, 2), width - 4))
                .opacity(hovering || dragging ? 1 : 0.55)
            HStack(spacing: 6) {
                if let key { key }
                FieldLabel(text: label, icon: icon)
                Spacer(minLength: 4)
                if typing {
                    TextField(label, value: Binding(get: { value }, set: { commit($0) }), format: .number.precision(.fractionLength(0...3)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($focused)
                        .onSubmit { typing = false }
                        .onExitCommand { typing = false }
                        .onKeyPress(.upArrow) { commit(value + step); return .handled }
                        .onKeyPress(.downArrow) { commit(value - step); return .handled }
                } else {
                    Text(text)
                        .monospacedDigit()
                        .fontWeight(dragging ? .semibold : .regular)
                        .foregroundStyle(dragging ? Color.accentColor : Color.primary)
                        .contentTransition(.numericText(value: value))
                }
                if let suffix {
                    Text(suffix).foregroundStyle(.secondary).fixedSize().padding(.leading, -4)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, minHeight: InspectorMetrics.rowHeight, maxHeight: InspectorMetrics.rowHeight)
        .clipShape(InspectorMetrics.fieldShape)
        .overlay {
            if focused { InspectorMetrics.fieldShape.strokeBorder(Color.accentColor, lineWidth: 1.5) }
        }
        .contentShape(InspectorMetrics.fieldShape)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
        .gesture(drag, including: typing ? .subviews : .all)
        .onHover { inside in
            if inside && enabled && !hovering {
                hovering = true
                NSCursor.resizeLeftRight.push()
            } else if !inside && hovering {
                hovering = false
                NSCursor.pop()
            }
        }
        .onDisappear { if hovering { NSCursor.pop() } }
        .onChange(of: focused) { _, on in if !on { typing = false } }
        .animation(.snappy(duration: 0.18), value: dragging)
        .animation(.snappy(duration: 0.18), value: hovering)
        .animation(dragging ? nil : .spring(duration: 0.3, bounce: 0.2), value: value)
        .opacity(enabled ? 1 : 0.45)
        .help(icon == nil ? "" : label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text + (suffix ?? ""))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(value + step)
            case .decrement: commit(value - step)
            @unknown default: break
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard !typing else { return }
                if !dragging {
                    guard abs(g.translation.width) >= 2 else { return }
                    dragging = true
                    sent = value
                    live?.begin()
                }
                let span = range.upperBound - range.lowerBound
                let v = clamp(((range.lowerBound + Double(g.location.x / width) * span) / step).rounded() * step,
                              range.lowerBound, range.upperBound)
                guard v != sent else { return }
                if v == range.lowerBound || v == range.upperBound {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
                sent = v
                onChange(v)
            }
            .onEnded { _ in
                if dragging {
                    dragging = false
                    sent = nil
                    live?.end()
                } else if enabled {
                    typing = true
                    focused = true
                }
            }
    }

    private func commit(_ v: Double) {
        let c = clamp(v, range.lowerBound, range.upperBound)
        if c != value { onChange(c) }
    }
}

/// Text that commits on Return or when focus leaves, so typing a name is
/// one undo step.
struct CommitField: View {
    let title: String
    var icon: String?
    let text: String
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    init(title: String, icon: String? = nil, text: String, onCommit: @escaping (String) -> Void) {
        self.title = title
        self.icon = icon
        self.text = text
        self.onCommit = onCommit
    }

    var body: some View {
        FieldBox(focused: focused) {
            FieldLabel(text: title, icon: icon).help(icon == nil ? "" : title)
            TextField(title, text: $draft)
                .labelsHidden()
                .focused($focused)
                .onAppear { draft = text }
                .onChange(of: text) { _, new in if !focused { draft = new } }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onSubmit(commit)
        }
    }

    private func commit() {
        if draft != text { onCommit(draft) }
    }
}

/// A round colour swatch that opens the colour panel.
struct ColorSwatch: View {
    let title: String
    let hex: String
    let onCommit: (String) -> Void

    var body: some View {
        ZStack {
            Circle().fill(Color(RGB(hex: hex)))
            Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
            // The native well takes the clicks and talks to the colour panel.
            ColorPicker(title, selection: Binding(get: { Color(RGB(hex: hex)) }, set: { color in
                let new = RGB(color).hex
                if new != RGB(hex: hex).hex { onCommit(new) }
            }), supportsOpacity: false)
            .labelsHidden()
            .controlSize(.mini)
            .opacity(0.02)
        }
        .frame(width: 16, height: 16)
        .clipShape(Circle())
        .help(title)
    }
}

/// A colour row bound to a `#rrggbb` string: round swatch, title, hex.
/// `onReset` adds a button that clears an override.
struct HexColorPicker: View {
    let title: String
    let hex: String
    let onCommit: (String) -> Void
    var onReset: (() -> Void)?

    var body: some View {
        FieldBox {
            ColorSwatch(title: title, hex: hex, onCommit: onCommit)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text(RGB(hex: hex).hex.dropFirst().uppercased())
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let onReset {
                Button(action: onReset) { Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .medium)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reset to the drawing's colour")
            }
        }
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
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(animated ? Color.accentColor : Color.secondary.opacity(0.45))
        }
        .buttonStyle(.plain)
        .help(keyed ? "Remove key at playhead" : "Add key at playhead")
    }
}
