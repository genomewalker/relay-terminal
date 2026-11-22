import SwiftUI

/// "2 held" in the pane header: messages written in the conversation composer
/// while the agent worked. They go out only from an open, focused composer,
/// so the header keeps them visible after the conversation view is closed.
struct RelayHeldMessagesBadge: View {
    @ObservedObject var pane: PaneModel
    let open: () -> Void

    var body: some View {
        if let state = pane.composerStateIfCreated {
            Count(state: state, conversationVisible: pane.nativeConversationVisible, open: open)
        }
    }

    private struct Count: View {
        @ObservedObject var state: PaneComposerState
        let conversationVisible: Bool
        let open: () -> Void

        var body: some View {
            let count = state.queue.items.count
            if count > 0 {
                Button(action: { if !conversationVisible { open() } }) {
                    Label(RelayHeldMessagesBadge.title(count: count, paused: state.queue.paused),
                          systemImage: state.queue.paused ? "pause.circle" : "tray.full")
                        .font(RelayTheme.font(size: 9.5, weight: .medium))
                        .foregroundStyle(state.queue.paused ? RelayTheme.coral : RelayTheme.textMuted)
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help(RelayHeldMessagesBadge.help(paused: state.queue.paused))
                .accessibilityIdentifier("relay.pane.held-messages")
            }
        }
    }

    static func title(count: Int, paused: Bool) -> String {
        "\(count) held" + (paused ? " · paused" : "")
    }

    static func help(paused: Bool) -> String {
        paused
            ? "Held messages are paused. Open the conversation to resume or cancel them."
            : "Held messages send from the conversation composer when the agent is idle and the composer has focus. Open the conversation to send them."
    }
}
