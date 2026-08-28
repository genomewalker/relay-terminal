import AppKit
import SwiftUI

/// The recursive workspace can create many split containers. Keeping this
/// interaction in a separate compilation unit prevents the older compiler
/// used by the release runner from repeatedly type-checking it with the much
/// larger workspace view hierarchy.
struct RelaySplitContainer<First: View, Second: View>: View {
    let axis: SplitAxis
    let ratio: Double
    let update: (Double, Bool) -> Void
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @State private var dragStartRatio: Double?
    @State private var dragPreviewRatio: Double?
    @FocusState private var dividerFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let divider: CGFloat = 6
            let available = max(1, total - divider)
            let firstLength = available * ratio
            ZStack(alignment: .topLeading) {
                paneStack(
                    size: proxy.size,
                    divider: divider,
                    available: available,
                    firstLength: firstLength
                )
                preview(size: proxy.size, divider: divider, available: available)
            }
        }
    }

    @ViewBuilder
    private func paneStack(
        size: CGSize,
        divider: CGFloat,
        available: CGFloat,
        firstLength: CGFloat
    ) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) {
                first().frame(width: firstLength, height: size.height)
                splitDivider(total: available).frame(width: divider, height: size.height)
                second().frame(width: available - firstLength, height: size.height)
            }
            .frame(width: size.width, height: size.height)
        } else {
            VStack(spacing: 0) {
                first().frame(width: size.width, height: firstLength)
                splitDivider(total: available).frame(width: size.width, height: divider)
                second().frame(width: size.width, height: available - firstLength)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    @ViewBuilder
    private func preview(size: CGSize, divider: CGFloat, available: CGFloat) -> some View {
        if let preview = dragPreviewRatio {
            Capsule()
                .fill(RelayTheme.blue.opacity(0.9))
                .frame(
                    width: axis == .horizontal ? 2 : size.width,
                    height: axis == .horizontal ? size.height : 2
                )
                .position(
                    x: axis == .horizontal ? available * preview + divider * 0.5 : size.width * 0.5,
                    y: axis == .horizontal ? size.height * 0.5 : available * preview + divider * 0.5
                )
                .shadow(color: RelayTheme.blue.opacity(0.35), radius: 4)
                .allowsHitTesting(false)
        }
    }

    private func splitDivider(total: CGFloat) -> some View {
        let visual = AnyView(
            Rectangle()
                .fill(RelayTheme.canvas)
                .overlay {
                    Capsule()
                        .fill(dividerFocused ? RelayTheme.accent.opacity(0.85) : RelayTheme.line.opacity(0.8))
                        .frame(width: axis == .horizontal ? 1 : 24, height: axis == .horizontal ? 24 : 1)
                }
                .contentShape(Rectangle().inset(by: -4))
        )

        let pointer = AnyView(visual.onHover { hovering in
            if axis == .horizontal {
                (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            } else {
                (hovering ? NSCursor.resizeUpDown : NSCursor.arrow).set()
            }
        })

        let draggable = AnyView(pointer
            .highPriorityGesture(TapGesture(count: 2).onEnded { update(0.5, true) })
            .simultaneousGesture(dividerDrag(total: total)))

        let accessible = AnyView(draggable
            .help("Drag to resize · double-click to center")
            .focusable()
            .focused($dividerFocused)
            .focusEffectDisabled()
            .accessibilityElement()
            .accessibilityLabel(axis == .horizontal ? "Vertical pane divider" : "Horizontal pane divider")
            .accessibilityValue("\(Int(ratio * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: update(min(0.9, ratio + 0.05), true)
                case .decrement: update(max(0.1, ratio - 0.05), true)
                @unknown default: break
                }
            })

        return AnyView(accessible.onMoveCommand { direction in
            switch (axis, direction) {
            case (.horizontal, .left), (.vertical, .up):
                update(max(0.1, ratio - 0.05), true)
            case (.horizontal, .right), (.vertical, .down):
                update(min(0.9, ratio + 0.05), true)
            default:
                break
            }
        })
    }

    private func dividerDrag(total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                let start = dragStartRatio ?? ratio
                if dragStartRatio == nil { dragStartRatio = ratio }
                dragPreviewRatio = min(max(start + delta / total, 0.12), 0.88)
            }
            .onEnded { value in
                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                update((dragStartRatio ?? ratio) + delta / total, true)
                dragStartRatio = nil
                dragPreviewRatio = nil
            }
    }
}
