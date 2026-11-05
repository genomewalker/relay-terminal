import SwiftUI

/// Native presentation of the provider session already running in this pane.
/// This view never creates an agent worker or substitutes a provider session.
struct RelayAgentConversationHostView: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject private var native = RelayNativeRegistry.shared
    var body: some View {
        if let binding = native.binding(for: pane) {
            RelayNativeConversationView(binding: binding).id(binding.identity.instance)
        } else {
            RelayAgentTimelineView(pane: pane)
        }
    }
}
