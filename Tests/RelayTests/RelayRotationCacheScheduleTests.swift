import Foundation
import Testing
@testable import Relay

@Suite struct RelayRotationCacheScheduleTests {
    private func evaluate(now: Double = 100, model: String = "gpt-6.1-sol",
                          ttlProvenance: String = "hook", includeResponse: Bool = true) async throws -> [String: Any] {
        let policy = try #require(RelayPinnedContextRotationPolicy.bundled(
            pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3")))
        var usage: [String: Any] = [
            "session": ["input": 100, "cached_input": 90, "uncached_input": 10,
                        "output": 10, "responses": 8, "turns": 4],
            "context_tokens": 188192, "model": model,
            "client": ["value": "codex", "provenance": "hook"],
            "in_flight_tool": ["value": false, "provenance": "transcript"],
            "turn_id_fresh": ["value": true, "provenance": "transcript"],
            "transcript_mtime_ms_at_stop": ["value": 99000, "provenance": "hook"],
            "last_model_request_ms": ["value": 1000, "provenance": "transcript"],
            "cache_ttl_ms": ["value": 300000, "provenance": ttlProvenance]
        ]
        if includeResponse {
            usage["last_model_response_ms"] = ["value": 2000, "provenance": "transcript"]
        }
        let status: [String: Any] = ["v": 1, "session_id": "schedule-fixture", "turn_seq": 12,
            "owner": "relay", "signal": NSNull(), "claim": NSNull(), "intent": NSNull(),
            "ack": NSNull(), "usage": usage]
        let output = try await policy.evaluate(status: JSONSerialization.data(withJSONObject: status),
                                               now: Date(timeIntervalSince1970: now))
        let result = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        return try #require(result["schedule"] as? [String: Any])
    }

    @Test func cacheScheduleUsesRequestTimeAndStopsAfterExpiry() async throws {
        let initial = try await evaluate()
        #expect(initial["next_evaluation_ms"] as? Int == 271000)
        #expect(initial["expires_at_ms"] as? Int == 301000)
        #expect(initial["refresh_capability"] as? String == "unverified")
        let approaching = try await evaluate(now: 271)
        #expect(approaching["next_evaluation_ms"] as? Int == 301000)
        let expired = try await evaluate(now: 301)
        #expect(expired["next_evaluation_ms"] is NSNull)
        #expect(expired["state"] as? String == "expiry_estimate_reached")
    }

    @Test func cacheScheduleFingerprintRejectsChangedModel() async throws {
        let first = try await evaluate()
        let same = try await evaluate(now: 101)
        let changed = try await evaluate(model: "other-model")
        #expect(first["fingerprint"] as? String == same["fingerprint"] as? String)
        #expect(first["fingerprint"] as? String != changed["fingerprint"] as? String)
        let binding = try #require(first["binding"] as? [String: Any])
        #expect(binding["session_id"] as? String == "schedule-fixture")
        #expect(binding["turn_seq"] as? Int == 12)
    }

    @Test func cacheScheduleDoesNotGuessMissingEvidence() async throws {
        for value in [try await evaluate(ttlProvenance: "assumed"),
                      try await evaluate(includeResponse: false),
                      try await evaluate(model: "")] {
            #expect(value["state"] as? String == "unknown")
            #expect(value["next_evaluation_ms"] is NSNull)
            #expect(value["binding"] is NSNull)
        }
    }
}
