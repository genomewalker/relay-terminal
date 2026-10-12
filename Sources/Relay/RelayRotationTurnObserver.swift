import Foundation

/// A lightweight hint only. A candidate carries no transcript or permission to
/// rotate; the controller must re-read the ledger and physical backend state.
struct RelayRotationTurnCandidate: Equatable, Sendable {
    let sessionID: String
    let client: String
    let hostID: String
    let paneID: String
    let eventSequence: UInt64
}

enum RelayRotationTurnGate {
    static func candidate(enrollment: RelayRetainedRotationEnrollment,
                          hostID: String, paneID: String, client: String,
                          sessionID: String?, eventName: String,
                          eventSequence: UInt64?, priorCursor: UInt64,
                          replayDepth: Int) -> RelayRotationTurnCandidate? {
        guard enrollment.valid, enrollment.hostID == hostID,
              enrollment.paneID.caseInsensitiveCompare(paneID) == .orderedSame,
              enrollment.client == client, enrollment.sessionID == sessionID,
              replayDepth == 0, ["Stop", "turn/completed"].contains(eventName),
              let sequence = eventSequence, sequence > priorCursor else { return nil }
        return RelayRotationTurnCandidate(sessionID: enrollment.sessionID,
            client: client, hostID: hostID, paneID: paneID, eventSequence: sequence)
    }
}

@MainActor final class RelayRotationTurnObserver {
    static let shared = RelayRotationTurnObserver()
    private var store: RelayRotationEnrollmentStore?
    private var onCandidate: ((RelayRotationTurnCandidate) -> Void)?

    /// No observer is active until runtime wiring supplies both durable store
    /// and callback. Clearing it disables dispatch without touching sessions.
    func configure(store: RelayRotationEnrollmentStore?,
                   onCandidate: ((RelayRotationTurnCandidate) -> Void)?) {
        self.store = store; self.onCandidate = onCandidate
    }

    func observe(hostID: String, paneID: String, client: String,
                 sessionID: String?, eventName: String,
                 eventSequence: UInt64?, priorCursor: UInt64,
                 replayDepth: Int) {
        guard let store, let onCandidate, let sessionID,
              let records = store.records(),
              let enrollment = records.first(where: { $0.sessionID == sessionID }) else { return }
        guard let value = RelayRotationTurnGate.candidate(enrollment: enrollment,
            hostID: hostID, paneID: paneID, client: client, sessionID: sessionID,
            eventName: eventName, eventSequence: eventSequence, priorCursor: priorCursor,
            replayDepth: replayDepth) else { return }
        onCandidate(value)
    }
}
