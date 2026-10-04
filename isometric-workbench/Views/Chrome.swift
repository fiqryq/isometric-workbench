import AppKit
import IsoMath
import SwiftUI

// MARK: - Window chrome (Sketch style)

enum Chrome {
    /// Height of the sidebars' top rows, which also hold the traffic lights.
    static let headerHeight: CGFloat = 44
    /// Room the traffic lights take at the top left of the window.
    static let trafficLightsWidth: CGFloat = 78
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
}

/// Empty space that drags the window, for areas where the hidden title bar used to be.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}

extension View {
    /// A floating capsule: Liquid Glass where available, frosted material before.
    @ViewBuilder func pillSurface() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}

/// Round icon button for the floating pills: hover wash, accent tint when active.
struct PillButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, active: active)
    }

    private struct Face: View {
        let configuration: Configuration
        let active: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if active { return .accentColor.opacity(configuration.isPressed ? 0.24 : 0.16) }
            return .primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0)
        }
    }
}

/// A sidebar's inner edge: a hairline you can drag to resize the column.
struct SideResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// +1 when the column sits to the left of the handle, -1 when to the right.
    let direction: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .padding(.horizontal, -2)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { v in
                let s = start ?? width
                if start == nil { start = s }
                width = clamp(s + direction * v.translation.width, range.lowerBound, range.upperBound)
            }.onEnded { _ in start = nil })
    }
}
