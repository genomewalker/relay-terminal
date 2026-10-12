import Foundation

/// A model recommendation carries no execution permission. Chitta owns the handoff.
struct RelayModelShadow: Sendable {
    struct Snapshot: Sendable {
        var sessionID: String
        var sequence: UInt64
        var observedAt: Date
        var capsuleReady: Bool?
    }

    struct Proposal: Equatable, Sendable {
        enum Decision: String, Sendable { case rotateNow, wait, abstain }
        var decision: Decision
        var probability: Double?
        var capsuleReady: Bool?
        // Always false during the experiment, irrespective of model scores.
        let automaticExecutionEligible = false
    }

    var maximumAge: TimeInterval = 30

    func evaluate(snapshot: Snapshot, currentSessionID: String,
                  currentSequence: UInt64, calibratedProbability: Double?,
                  threshold: Double, now: Date = Date()) -> Proposal {
        let age = now.timeIntervalSince(snapshot.observedAt)
        guard maximumAge.isFinite, maximumAge >= 0,
              age >= 0, age <= maximumAge,
              snapshot.sessionID == currentSessionID,
              snapshot.sequence == currentSequence,
              threshold.isFinite, (0...1).contains(threshold),
              let score = calibratedProbability, score.isFinite,
              (0...1).contains(score) else {
            return Proposal(decision: .abstain, probability: nil,
                            capsuleReady: snapshot.capsuleReady)
        }
        return Proposal(decision: score >= threshold ? .rotateNow : .wait,
                        probability: score, capsuleReady: snapshot.capsuleReady)
    }
}
