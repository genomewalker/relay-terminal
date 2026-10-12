import Foundation
import CryptoKit

/// Versioned, calibrated numeric classifier. No transcript text is an input.
struct RelayLocalDecisionModel: RelayDecisionBackend {
    static let featureNames = ["output_bytes_per_minute", "retries_in_window",
        "seconds_since_progress", "restarts_in_window", "active_request",
        "reachable", "durable_checkpoint"]

    struct Artifact: Codable, Sendable {
        let schema: String
        let identifier: String
        let task: String
        let featureNames: [String]
        let means: [Double]
        let scales: [Double]
        let weights: [Double]
        let intercept: Double
        let calibrationSlope: Double
        let calibrationIntercept: Double
        let waitThreshold: Double
        let rotateThreshold: Double
        let trainingDigest: String
        let splitDigest: String
        let calibrationDigest: String
        let policyDigest: String
        let independentlyLabeled: Bool
    }

    enum LoadError: Error { case invalidSize, untrustedDigest, invalidContract }
    let artifact: Artifact
    var identifier: String { artifact.identifier }

    init(data: Data, trustedSHA256: String) throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw LoadError.invalidSize }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard Self.isDigest(trustedSHA256), digest == trustedSHA256.lowercased() else {
            throw LoadError.untrustedDigest
        }
        let a = try JSONDecoder().decode(Artifact.self, from: data)
        guard a.schema == "relay.local-decision/1", a.task == "rotate_now",
              !a.identifier.isEmpty, a.identifier.utf8.count <= 100,
              a.independentlyLabeled, a.featureNames == Self.featureNames,
              [a.means, a.scales, a.weights].allSatisfy({ $0.count == Self.featureNames.count && $0.allSatisfy(\.isFinite) }),
              a.scales.allSatisfy({ $0 > 0 }),
              [a.intercept, a.calibrationSlope, a.calibrationIntercept,
               a.waitThreshold, a.rotateThreshold].allSatisfy(\.isFinite),
              a.calibrationSlope > 0, a.waitThreshold >= 0,
              a.waitThreshold < a.rotateThreshold, a.rotateThreshold <= 1,
              [a.trainingDigest, a.splitDigest, a.calibrationDigest, a.policyDigest].allSatisfy(Self.isDigest)
        else { throw LoadError.invalidContract }
        artifact = a
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }
    }

    func probability(telemetry: RelaySupervisorTelemetry) -> Double? {
        guard telemetry.outputBytesPerMinute >= 0, telemetry.retriesInWindow >= 0,
              telemetry.restartsInWindow >= 0, telemetry.secondsSinceProgress.isFinite,
              telemetry.secondsSinceProgress >= 0 else { return nil }
        let values = [Double(telemetry.outputBytesPerMinute), Double(telemetry.retriesInWindow),
            telemetry.secondsSinceProgress, Double(telemetry.restartsInWindow),
            telemetry.hasActiveRequest ? 1.0 : 0.0, telemetry.isReachable ? 1.0 : 0.0,
            telemetry.hasDurableCheckpoint ? 1.0 : 0.0]
        var margin = artifact.intercept
        for i in values.indices {
            margin += ((values[i] - artifact.means[i]) / artifact.scales[i]) * artifact.weights[i]
        }
        let z = artifact.calibrationSlope * margin + artifact.calibrationIntercept
        guard z.isFinite else { return nil }
        return z >= 0 ? 1 / (1 + exp(-z)) : exp(z) / (1 + exp(z))
    }

    func recommend(telemetry: RelaySupervisorTelemetry,
                   deterministic: RelaySupervisorRecommendation) async -> RelayDecisionBackendResult? {
        guard telemetry.identity == deterministic.identity,
              telemetry.observedAt == deterministic.observedAt,
              let score = probability(telemetry: telemetry) else { return nil }
        if score >= artifact.rotateThreshold {
            return RelayDecisionBackendResult(suggestedStage: min(.warn, deterministic.stage),
                summary: "Local model recommends reviewing rotation. Chitta must verify the handoff before any session change.")
        }
        if score <= artifact.waitThreshold {
            return RelayDecisionBackendResult(suggestedStage: .observe,
                summary: "Local model recommends waiting. Deterministic supervisor findings remain available.")
        }
        return nil
    }
}
