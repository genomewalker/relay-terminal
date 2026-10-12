import XCTest
@testable import Relay

final class RelayRotationMetricsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100)
    private func fixture(context: Any = 20_000, turns: Int = 4,
                         pending: Bool = false, sequence: Int = 12) throws -> Data {
        let counters: [String: Any] = ["input": 30_000, "cached_input": 28_000,
                                     "uncached_input": 2_000, "output": 500]
        var session = counters
        session["turns"] = turns
        session["responses"] = 8
        let usage: [String: Any] = ["turn": counters, "session": session,
            "context_tokens": context, "model": "test-model",
            "client": ["value": "codex", "provenance": "hook"],
            "transcript_mtime_ms_at_stop": ["value": 99_000, "provenance": "hook"],
            "in_flight_tool": ["value": pending, "provenance": "transcript"],
            "turn_id_fresh": ["value": true, "provenance": "transcript"]]
        return try JSONSerialization.data(withJSONObject: ["value": ["v": 1,
            "session_id": "exact-session", "client": "codex", "turn_seq": sequence, "usage": usage,
            "usage_history": [["seq": sequence, "session_id": "exact-session",
                               "turn_id": "completed-turn", "usage": usage]]]])
    }
    private func cost(total: Double = 0.60, session: String = "exact-session",
                      seq: Int = 12, provenance: String = "measured_billing") -> RelayRotationCostObservation {
        RelayRotationCostObservation(sessionID: session, turnSequence: seq, model: "test-model",
            totalCostUSD: total, lastTurnCostUSD: nil, provenance: provenance)
    }
    private func adapt(_ data: Data, cost: RelayRotationCostObservation?, idle: Bool = true,
                       age: TimeInterval = 0) -> RelayRotationMetricResult {
        RelayRotationMetricAdapter.adapt(data, expectedSessionID: "exact-session",
            expectedTurnSequence: 12, backendIdle: idle, observedAt: now.addingTimeInterval(-age),
            now: now, cost: cost)
    }
    func testRealNestedContractRequiresIndependentMeasuredCost() throws {
        let data = try fixture()
        XCTAssertEqual(adapt(data, cost: nil), .abstain("measured_cost_absent"))
        guard case let .ready(input) = adapt(data, cost: cost()) else { return XCTFail("valid evidence rejected") }
        XCTAssertEqual(input.contextSizeTokens, 20_000)
        XCTAssertEqual(input.lastTurnTokens, 30_500)
        XCTAssertEqual(input.nTurns, 4)
        let encoded = try JSONEncoder().encode(input)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["session_id"] as? String, "exact-session")
        XCTAssertEqual(json["total_cost_usd"] as? Double, 0.60)
        XCTAssertNil(json["last_turn_cost"], "Absent cost must not be averaged or guessed")
    }
    func testCostEvidenceCannotCrossSessionWatermarkOrProvenance() throws {
        let data = try fixture()
        for evidence in [cost(session: "other-session"), cost(seq: 11), cost(provenance: "estimated")] {
            XCTAssertEqual(adapt(data, cost: evidence), .abstain("cost_unverified"))
        }
    }
    func testNonFiniteNegativeAndMalformedMetricsAbstain() throws {
        let data = try fixture()
        for value in [Double.nan, .infinity, -0.01] {
            XCTAssertEqual(adapt(data, cost: cost(total: value)), .abstain("cost_unverified"))
        }
        XCTAssertEqual(adapt(try fixture(context: -1), cost: cost()), .abstain("invalid_or_early_usage"))
        XCTAssertEqual(adapt(try fixture(context: NSNull()), cost: cost()), .abstain("invalid_or_early_usage"))
        XCTAssertEqual(adapt(Data("{}".utf8), cost: cost()), .abstain("invalid_status"))
    }
    func testPendingEarlyStaleAndWrongBoundaryCannotReachPolicy() throws {
        XCTAssertEqual(adapt(try fixture(pending: true), cost: cost()), .abstain("completed_turn_unverified"))
        XCTAssertEqual(adapt(try fixture(turns: 2), cost: cost()), .abstain("invalid_or_early_usage"))
        XCTAssertEqual(adapt(try fixture(), cost: cost(), idle: false), .abstain("not_idle_or_stale"))
        XCTAssertEqual(adapt(try fixture(), cost: cost(), age: 31), .abstain("not_idle_or_stale"))
        XCTAssertEqual(adapt(try fixture(), cost: cost(), age: -1), .abstain("not_idle_or_stale"))
        XCTAssertEqual(adapt(try fixture(sequence: 11), cost: cost()), .abstain("watermark_mismatch"))
    }
    func testCompactionUsesActualContextRatherThanPriorMaximum() throws {
        guard case let .ready(input) = adapt(try fixture(context: 1_000), cost: cost()) else {
            return XCTFail("legitimate context shrink rejected")
        }
        XCTAssertEqual(input.contextSizeTokens, 1_000)
    }
    func testPreviousLedgerTurnCannotStandInForBackendCompletion() throws {
        XCTAssertEqual(RelayRotationMetricAdapter.adapt(try fixture(), expectedSessionID: "exact-session",
            expectedTurnSequence: 12, backendIdle: true, observedAt: now, now: now,
            cost: cost(), expectedTurnID: "new-backend-turn"), .abstain("completed_turn_mismatch"))
    }
    func testContextPolicyUsesNestedCountersWithoutInventingCost() throws {
        let result = RelayRotationMetricAdapter.contextStatus(try fixture(),
            expectedSessionID: "exact-session", expectedTurnSequence: 12,
            expectedTurnID: "completed-turn", expectedClient: "codex",
            backendIdle: true, observedAt: now, now: now)
        guard case let .ready(raw) = result else { return XCTFail("context evidence rejected") }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertNotNil(json["usage"])
        XCTAssertNil(json["total_cost_usd"])
        XCTAssertEqual(RelayRotationMetricAdapter.contextStatus(try fixture(),
            expectedSessionID: "exact-session", expectedTurnSequence: 12,
            expectedTurnID: "completed-turn", expectedClient: "claude",
            backendIdle: true, observedAt: now, now: now), .abstain("context_provenance_unverified"))
    }
}
