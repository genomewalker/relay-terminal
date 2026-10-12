import Foundation
import CryptoKit
import Testing
@testable import Relay

private func localModelFixture(labeled: Bool = true, weights: [Double]? = nil) throws -> (Data, String) {
    let n = RelayLocalDecisionModel.featureNames.count
    let a = RelayLocalDecisionModel.Artifact(
        schema: "relay.local-decision/1", identifier: "synthetic-test-only", task: "rotate_now",
        featureNames: RelayLocalDecisionModel.featureNames,
        means: Array(repeating: 0, count: n), scales: Array(repeating: 1, count: n),
        weights: weights ?? Array(repeating: 0, count: n), intercept: 2,
        calibrationSlope: 2, calibrationIntercept: -1,
        waitThreshold: 0.2, rotateThreshold: 0.8,
        trainingDigest: String(repeating: "a", count: 64), splitDigest: String(repeating: "b", count: 64),
        calibrationDigest: String(repeating: "c", count: 64), policyDigest: String(repeating: "d", count: 64),
        independentlyLabeled: labeled
    )
    let data = try JSONEncoder().encode(a)
    let pin = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (data, pin)
}

@Test func localDecisionModelRequiresPinnedEvaluatedContract() throws {
    let (data, pin) = try localModelFixture()
    _ = try RelayLocalDecisionModel(data: data, trustedSHA256: pin)
    #expect(throws: RelayLocalDecisionModel.LoadError.self) {
        try RelayLocalDecisionModel(data: data, trustedSHA256: String(repeating: "0", count: 64))
    }
    for fixture in [try localModelFixture(labeled: false), try localModelFixture(weights: [1])] {
        #expect(throws: RelayLocalDecisionModel.LoadError.self) {
            try RelayLocalDecisionModel(data: fixture.0, trustedSHA256: fixture.1)
        }
    }
}

@Test func localDecisionModelCalibratesRawMarginAndRejectsInvalidEvidence() async throws {
    let (data, pin) = try localModelFixture()
    let model = try RelayLocalDecisionModel(data: data, trustedSHA256: pin)
    let identity = RelaySupervisedSessionID(paneID: UUID(), sessionID: "test", generation: 1)
    let now = Date()
    func telemetry(progress: Double = 0, at date: Date? = nil) -> RelaySupervisorTelemetry {
        RelaySupervisorTelemetry(identity: identity, observedAt: date ?? now,
            hasActiveRequest: false, isReachable: true, outputBytesPerMinute: 0,
            retriesInWindow: 0, secondsSinceProgress: progress, contextTokens: nil,
            contextLimit: nil, restartsInWindow: 0, hasDurableCheckpoint: false)
    }
    #expect(abs((model.probability(telemetry: telemetry()) ?? 0) - 1 / (1 + exp(-3))) < 1e-12)
    #expect(model.probability(telemetry: telemetry(progress: .nan)) == nil)
    let recommendation = RelaySupervisorRecommendation(identity: identity, stage: .warn,
        findings: [.tokenPressure], observedAt: now, requiresUserApproval: true, mayExecuteAutomatically: false)
    #expect(await model.recommend(telemetry: telemetry(), deterministic: recommendation) != nil)
    #expect(await model.recommend(telemetry: telemetry(at: now.addingTimeInterval(-1)), deterministic: recommendation) == nil)
}

@Test func localDecisionModelConfigurationLoadsAndFailsClosed() async throws {
    let (data, pin) = try localModelFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("model.json")
    try data.write(to: file)
    let service = RelaySupervisorIntelligenceService()
    let loaded = await service.configureLocalModel(path: file.path, sha256: pin)
    #expect(loaded.contains("Loaded synthetic-test-only"))
    let invalid = await service.configureLocalModel(path: file.path, sha256: "invalid")
    #expect(invalid.contains("unavailable"))
    let cleared = await service.configureLocalModel(path: "", sha256: "")
    #expect(cleared.contains("No local decision artifact configured"))
}
