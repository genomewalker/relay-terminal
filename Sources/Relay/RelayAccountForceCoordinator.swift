import Foundation
import Combine

/// Kept off until queue-safe exit/resume and protected host routing are ready.
enum RelayAccountForceFeature { static let enabled = false }

/// One app-owned selection and review. It does not exit or resume the agent;
/// after a selected process exits, the move must independently re-observe all
/// work, the provider, queue and draft before doing anything else.
@MainActor final class RelayAccountForceCoordinator: ObservableObject {
    enum State: Equatable { case idle, loading, review, dispatching, refused, exited, blocked, unknown }
    @Published private(set) var state: State = .idle
    @Published private(set) var preview: RelayAccountForcePreview?

    private let pane: PaneModel
    private let context: RelayExecutionContext
    private let selection: RelayAccountForceSelection
    private let permits: @MainActor @Sendable () -> Bool
    private let revalidateDestination: @MainActor @Sendable () async -> Bool
    private let journal: RelayAccountForceJournal
    private var transaction: RelayAccountForceTransaction?
    private var revision: UInt64?
    private var screen: TerminalIOBridge.MaintenanceScreenToken?

    /// `permits` must re-evaluate caller control grants and pause state. For a
    /// Miko request this includes both input and termination on every dispatch.
    init(pane: PaneModel, context: RelayExecutionContext, selection: RelayAccountForceSelection,
         permits: @escaping @MainActor @Sendable () -> Bool,
         revalidateDestination: @escaping @MainActor @Sendable () async -> Bool,
         journal: RelayAccountForceJournal = RelayAccountForceJournal()) {
        self.pane = pane
        self.context = context
        self.selection = selection
        self.permits = permits
        self.revalidateDestination = revalidateDestination
        self.journal = journal
    }

    func prepare() async {
        guard state == .idle else { return }
        guard permits(), pane.id == selection.paneID, pane.profile == context.profile,
              pane.pendingAgentApprovals == 0, let snapshot = pane.runtime.accountForceScreenSnapshot() else {
            state = .refused; return
        }
        state = .loading
        let capturedRevision = pane.agentInputRevision
        do {
            let value = try await RelayAccountForceHost.preview(context: context, selection: selection)
            guard state == .loading, permits(), pane.profile == context.profile,
                  pane.agentInputRevision == capturedRevision, pane.pendingAgentApprovals == 0,
                  pane.runtime.accountForceScreenIsCurrent(snapshot.token), !Task.isCancelled else {
                state = .refused; return
            }
            revision = capturedRevision
            screen = snapshot.token
            preview = value
            transaction = RelayAccountForceTransaction(preview: value)
            state = .review
        } catch { state = .refused }
    }

    /// Invoked only by the Run button for this exact preview, never directly
    /// from a model-provided tool payload.
    func runReviewed() async {
        guard state == .review, let transaction, let revision, let screen else { return }
        state = .dispatching
        guard await revalidateDestination(), permits(), !Task.isCancelled else { state = .refused; return }
        let result = await transaction.run(withLease: { execute in
            await self.pane.runtime.withAccountForceLease(expectedPane: self.pane, profile: self.context.profile,
                inputRevision: revision, screen: screen, permits: self.permits, execute: execute)
        }, dispatch: { value, actionID in
            try self.journal.reserve(preview: value, actionID: actionID)
            return try await RelayAccountForceHost.commit(context: self.context, preview: value, actionID: actionID)
        })
        switch result {
        case .refused: state = .refused
        case .exited: state = .exited
        case .blocked: state = .blocked
        case .unknown: state = .unknown
        }
    }
}
