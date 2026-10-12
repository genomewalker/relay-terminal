import Foundation
import Testing
import CryptoKit
@testable import Relay

@Suite struct RelayContextRotationPolicyTests {
    @Test func packagedReviewedPolicyMakesNoDollarClaim() async throws {
        let policy = try #require(RelayPinnedContextRotationPolicy.bundled(
            pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3")))
        let status = Data(#"{"v":1,"session_id":"fixture","turn_seq":12,"owner":"relay","signal":null,"claim":null,"intent":null,"ack":null,"usage":{"session":{"input":100,"cached_input":90,"uncached_input":10,"output":10,"responses":8,"turns":4},"context_tokens":300000,"client":{"value":"codex","provenance":"hook"},"in_flight_tool":{"value":false,"provenance":"transcript"},"turn_id_fresh":{"value":true,"provenance":"transcript"},"transcript_mtime_ms_at_stop":{"value":99000,"provenance":"hook"}}}"#.utf8)
        let output = try await policy.evaluate(status: status, now: Date(timeIntervalSince1970: 100))
        let result = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(result["decision"] as? String == "rotate")
        let economics = try #require(result["economics"] as? [String: Any])
        #expect(economics["cache_cold"] is NSNull, "Codex must not inherit an assumed Claude cache TTL")
        #expect(result["total_cost_usd"] == nil)
        let signal = try #require(result["signal"] as? [String: Any])
        #expect(signal["session_id"] as? String == "fixture")
        #expect(signal["epoch"] as? String == "turn-12")
    }

    @Test func changedPolicyBytesCannotExecute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("policy.py")
        let reviewed = Data("print('reviewed')".utf8)
        let pin = SHA256.hash(data: reviewed).map { String(format: "%02x", $0) }.joined()
        try Data("raise RuntimeError('changed source must not run')".utf8).write(to: file)
        let policy = RelayPinnedContextRotationPolicy(pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
            policyFile: file, reviewedSHA256: pin)
        do {
            _ = try await policy.evaluate(status: Data("{}".utf8), now: Date())
            Issue.record("Changed source accepted")
        } catch RelayRotationAdapterError.mismatchedEvidence { }
        catch { Issue.record("Rejected for an unexpected reason: \(error)") }
    }
}
