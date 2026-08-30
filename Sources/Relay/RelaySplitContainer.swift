import AppKit
import SwiftUI

struct RelaySplitGeometry: Equatable {
    let size: CGSize
    let divider: CGFloat
    let available: CGFloat
    let ratio: CGFloat
    let firstLength: CGFloat
    let secondLength: CGFloat

    init(proposedSize: CGSize, axis: SplitAxis, ratio: Double, divider requestedDivider: CGFloat = 6) {
        // SwiftUI can briefly propose negative or non-finite dimensions while
        // replacing a tab tree or entering full screen. Passing those values
        // into frame(width:height:) reaches AppKit before TerminalView can
        // reject them and corrupts the whole pane hierarchy.
        let width = proposedSize.width.isFinite ? max(0, proposedSize.width) : 0
        let height = proposedSize.height.isFinite ? max(0, proposedSize.height) : 0
        size = CGSize(width: width, height: height)

        let total = axis == .horizontal ? width : height
        let safeDivider = requestedDivider.isFinite ? max(0, requestedDivider) : 0
        divider = min(safeDivider, total)
        available = max(0, total - divider)

        let finiteRatio = ratio.isFinite ? ratio : 0.5
        self.ratio = CGFloat(min(max(finiteRatio, 0.12), 0.88))
        firstLength = max(0, available * self.ratio)
        secondLength = max(0, available - firstLength)
    }
}

/// The recursive workspace can create many split containers. Keeping this
/// interaction in a separate compilation unit prevents the older compiler
/// used by the release runner from repeatedly type-checking it with the much
/// larger workspace view hierarchy.
struct RelaySplitContainer: View {
    let axis: SplitAxis
    let ratio: Double
    let update: (Double, Bool) -> Void
    private let first: AnyView
    private let second: AnyView
    @State private var dragStartRatio: Double?
    @State private var dragPreviewRatio: Double?
    @FocusState private var dividerFocused: Bool

    init<First: View, Second: View>(
        axis: SplitAxis,
        ratio: Double,
        update: @escaping (Double, Bool) -> Void,
        @ViewBuilder first: () -> First,
        @ViewBuilder second: () -> Second
    ) {
        self.axis = axis
        self.ratio = ratio
        self.update = update
        self.first = AnyView(first())
        self.second = AnyView(second())
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = RelaySplitGeometry(
                proposedSize: proxy.size,
                axis: axis,
                ratio: ratio
            )
            ZStack(alignment: .topLeading) {
                paneStack(
                    size: geometry.size,
                    divider: geometry.divider,
                    firstLength: geometry.firstLength,
                    secondLength: geometry.secondLength
                )
                preview(
                    size: geometry.size,
                    divider: geometry.divider,
                    available: geometry.available
                )
            }
        }
    }

    @ViewBuilder
    private func paneStack(
        size: CGSize,
        divider: CGFloat,
        firstLength: CGFloat,
        secondLength: CGFloat
    ) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) {
                first.frame(width: firstLength, height: size.height)
                splitDivider(total: max(firstLength + secondLength, 1))
                    .frame(width: divider, height: size.height)
                second.frame(width: secondLength, height: size.height)
            }
            .frame(width: size.width, height: size.height)
        } else {
            VStack(spacing: 0) {
                first.frame(width: size.width, height: firstLength)
                splitDivider(total: max(firstLength + secondLength, 1))
                    .frame(width: size.width, height: divider)
                second.frame(width: size.width, height: secondLength)
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
