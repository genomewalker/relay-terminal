import SwiftUI

/// UI for one explicitly selected child process. Dismissal does not resume
/// an account move; the caller must re-observe the pane and its pending work.
struct RelayAccountForcePanel: View {
    @StateObject private var coordinator: RelayAccountForceCoordinator
    let destination: String
    let close: () -> Void

    init(pane: PaneModel, context: RelayExecutionContext, selection: RelayAccountForceSelection,
         destination: String, permits: @escaping @MainActor @Sendable () -> Bool,
         revalidateDestination: @escaping @MainActor @Sendable () async -> Bool, close: @escaping () -> Void) {
        _coordinator = StateObject(wrappedValue: RelayAccountForceCoordinator(
            pane: pane, context: context, selection: selection, permits: permits, revalidateDestination: revalidateDestination))
        self.destination = destination
        self.close = close
    }

    var body: some View {
        Group {
            switch coordinator.state {
            case .idle, .loading:
                VStack(spacing: 12) { ProgressView(); Text("Checking selected process") }.padding(30)
            case .review:
                if let preview = coordinator.preview {
                    VStack(alignment: .leading) {
                        Text("Destination: " + RelayAccountForcePreview.quoted(destination)).padding(.horizontal)
                        RelayAccountForceReviewView(preview: preview,
                            run: { Task { await coordinator.runReviewed() } }, cancel: close)
                    }
                }
            case .dispatching:
                VStack(spacing: 12) { ProgressView(); Text("Checking the result; do not retry") }.padding(30)
            case .refused:
                result("The pane, process or permission could not be verified. Nothing was sent.")
            case .exited:
                result("The selected process exited. Relay must check remaining work and the saved conversation before moving the account.")
            case .blocked:
                result("The selected process was still present after the signal. Check it before taking another action.")
            case .unknown:
                result("The result is uncertain. Check the pane and process; this action will not be retried.")
            }
        }
        .task { await coordinator.prepare() }
    }

    private func result(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message)
            HStack { Spacer(); Button("Close", action: close) }
        }.padding(24).frame(minWidth: 420)
    }
}
