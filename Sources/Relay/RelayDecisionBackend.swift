import Foundation

/// Models interpret harness evidence. They never receive a lifecycle executor.
/// Chitta remains responsible for capsules, memory and verified handoffs.
protocol RelayDecisionBackend: Sendable {
    var identifier: String { get }
    func recommend(
        telemetry: RelaySupervisorTelemetry,
        deterministic: RelaySupervisorRecommendation
    ) async -> RelayDecisionBackendResult?
}

struct RelayDecisionBackendResult: Sendable {
    let suggestedStage: RelaySupervisorStage
    let summary: String
}

/// A provider's output goes through the same policy as the system model.
/// Installation is an explicit app configuration operation, not telemetry input.
enum RelayDecisionBackendPolicy {
    static func validate(
        _ result: RelayDecisionBackendResult,
        recommendation: RelaySupervisorRecommendation,
        telemetry: RelaySupervisorTelemetry
    ) -> RelaySupervisorAdvisory? {
        guard telemetry.identity == recommendation.identity,
              telemetry.observedAt == recommendation.observedAt else { return nil }
        return RelaySupervisorAdvisoryPolicy.validate(
            suggestedStage: result.suggestedStage,
            summary: result.summary,
            source: .localDecisionBackend,
            recommendation: recommendation,
            currentIdentity: telemetry.identity
        )
    }
}
