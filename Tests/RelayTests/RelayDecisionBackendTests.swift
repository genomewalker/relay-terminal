import Foundation
import Testing
@testable import Relay

@Test func decisionBackendRejectsStaleEvidenceAndEscalation() {
    let identity = RelaySupervisedSessionID(paneID: UUID(), sessionID: "test", generation: 1)
    let now = Date()
    let recommendation = RelaySupervisorRecommendation(
        identity: identity, stage: .warn, findings: [.tokenPressure],
        observedAt: now, requiresUserApproval: true, mayExecuteAutomatically: false
    )
    func telemetry(at date: Date) -> RelaySupervisorTelemetry {
        RelaySupervisorTelemetry(
            identity: identity, observedAt: date, hasActiveRequest: false,
            isReachable: true, outputBytesPerMinute: 0, retriesInWindow: 0,
            secondsSinceProgress: 0, contextTokens: nil, contextLimit: nil,
            restartsInWindow: 0, hasDurableCheckpoint: false
        )
    }
    let result = RelayDecisionBackendResult(suggestedStage: .warn, summary: "Review context pressure")
    #expect(RelayDecisionBackendPolicy.validate(result, recommendation: recommendation,
                                               telemetry: telemetry(at: now))?.source == .localDecisionBackend)
    #expect(RelayDecisionBackendPolicy.validate(result, recommendation: recommendation,
                                               telemetry: telemetry(at: now.addingTimeInterval(-1))) == nil)
    #expect(RelayDecisionBackendPolicy.validate(
        RelayDecisionBackendResult(suggestedStage: .terminateOrRestart, summary: "Restart"),
        recommendation: recommendation, telemetry: telemetry(at: now)
    ) == nil)
}
