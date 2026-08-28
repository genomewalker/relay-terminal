import SwiftUI

/// Owns only the high-frequency pointer translation for a floating card.
/// Keeping this state below model-observing views prevents every mouse sample
/// from invalidating transcript, terminal, and inbox view trees.
struct SmoothFloatingPanelDrag<Content: View>: View {
    private struct TransientDrag: Equatable {
        var translation: CGSize = .zero
        var isActive = false
    }

    @Binding private var settledOffset: CGSize
    private let headerHeight: CGFloat
    private let onDragActivityChanged: (Bool) -> Void
    private let content: Content
    @GestureState private var drag = TransientDrag()

    init(
        settledOffset: Binding<CGSize>,
        headerHeight: CGFloat,
        onDragActivityChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder content: () -> Content
    ) {
        self._settledOffset = settledOffset
        self.headerHeight = headerHeight
        self.onDragActivityChanged = onDragActivityChanged
        self.content = content()
    }

    var body: some View {
        content
            .offset(
                x: settledOffset.width + drag.translation.width,
                y: settledOffset.height + drag.translation.height
            )
            .transaction { $0.animation = nil }
            .simultaneousGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .updating($drag) { value, state, transaction in
                        guard value.startLocation.y <= headerHeight else { return }
                        transaction.animation = nil
                        state = TransientDrag(translation: value.translation, isActive: true)
                    }
                    .onEnded { value in
                        guard value.startLocation.y <= headerHeight else { return }
                        settledOffset = CGSize(
                            width: settledOffset.width + value.translation.width,
                            height: settledOffset.height + value.translation.height
                        )
                    }
            )
            .onChange(of: drag.isActive) { _, active in
                onDragActivityChanged(active)
            }
    }
}
