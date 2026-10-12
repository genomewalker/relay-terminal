import SwiftUI

/// Native presentation of the provider session already running in this pane.
/// This view never creates an agent worker or substitutes a provider session.
struct RelayAgentConversationHostView: View {
    @ObservedObject var pane: PaneModel
    var body: some View {
        RelayAgentTimelineView(pane: pane)
    }
}
