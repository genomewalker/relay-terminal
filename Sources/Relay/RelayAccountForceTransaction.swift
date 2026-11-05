import Foundation

/// One user-reviewed card, one action ID, at most one dispatch. The caller's
/// lease wrapper must hold the input/control lease through the dispatch and
/// recheck captured host, pane, input revision and grants before invoking it.
/// Even an error after dispatch is terminal and must never be retried with a
/// new ID. Host-side durable reservation is the second replay fence.
@MainActor final class RelayAccountForceTransaction {
    enum Result: Equatable {
        case refused, exited, blocked, unknown
    }

    let preview: RelayAccountForcePreview
    let actionID: UUID
    private(set) var consumed = false

    init(preview: RelayAccountForcePreview, actionID: UUID = UUID()) {
        self.preview = preview
        self.actionID = actionID
    }

    /// Called only by the app's Run action. An exited result confirms only the
    /// selected process observation, not that the provider or pane is idle.
    func run(withLease: @MainActor (_ execute: @MainActor () async -> Result) async -> Result,
             dispatch: @escaping @MainActor (RelayAccountForcePreview, UUID) async throws -> String) async -> Result {
        guard !consumed, preview.isValid else { return .refused }
        consumed = true
        var dispatched = false
        let outcome = await withLease {
            guard !dispatched, !Task.isCancelled else { return .refused }
            dispatched = true
            do {
                switch try await dispatch(preview, actionID) {
                case "exited": return .exited
                case "blocked": return .blocked
                default: return .unknown
                }
            } catch {
                return .unknown
            }
        }
        // A lease refusal before dispatch is safe; once dispatch begins, a
        // lost lease or response is uncertain and cannot be labelled refused.
        guard dispatched else { return .refused }
        return outcome == .refused ? .unknown : outcome
    }
}
