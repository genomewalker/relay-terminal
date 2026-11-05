import XCTest
@testable import Relay

final class RelayClaudeQuotaIdleTests: XCTestCase {
    static let pane = UUID(uuidString: "a561ece8-0000-4000-8000-000000000001")!
    static func proof(_ state: Int) throws -> RelayAgentMaintenanceProbe {
        let json = #"{"version":1,"pane_id":"a561ece8-0000-4000-8000-000000000001","provider":"claude","process_id":2311512,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"active","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"a561ece8-0000-4000-8000-000000000001","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"claude","process_id":2311512,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"background_work":false,"subagent_work":false,"harness_status":"idle","resume_command":"claude --resume exact-session","move_command":"CLAUDE_CONFIG_DIR=/tmp/max claude --resume exact-session"}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var proof = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        if state == 0 { proof.lifecycle = "quiet" }
        if state == 1 { proof.harnessStatus = "working" }
        return proof
    }
    static func idle(_ state: Int) throws -> Bool {
        RelayAgentMaintenancePolicy.deferral(try proof(state), paneID: pane, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60) == nil
    }
    func testA561ece8EndedSummaryStaleActivePhaseWithCurrentIdleHarness() throws {
        // Incident: dandy-07, pid 2311512, empty prompt, 0.7% CPU,
        // "Claude session ended" while cached phase remained active. The
        // summary and CPU are insufficient; process-bound idle is required.
        XCTAssertTrue(try Self.idle(2)) // QF8
        let target = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-max")
        XCTAssertNil(RelayAgentAccountMovePolicy.refusal(try Self.proof(2), paneID: Self.pane, target: target,
            emptyPrompt: true, hasDraft: false, pendingApprovals: 0, inputAge: 60))
    }
    func testBusyOrUnknownEvidenceStillRefuses() throws {
        XCTAssertFalse(try Self.idle(1)) // QF9
        var proof = try Self.proof(2)
        proof.harnessStatus = nil
        XCTAssertNotNil(RelayAgentMaintenancePolicy.deferral(proof, paneID: Self.pane, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60))
        proof = try Self.proof(2)
        for field in 0..<6 {
            var changed = proof
            if field == 0 { changed.backgroundWork = true }
            if field == 1 { changed.subagentWork = true }
            if field == 2 { changed.subagentWork = nil }
            if field == 3 { changed.lifecycle = "quiet"; changed.harnessStatus = "working" }
            XCTAssertNotNil(RelayAgentMaintenancePolicy.deferral(changed, paneID: Self.pane,
                emptyPrompt: field != 4, hasDraft: field == 5, pendingApprovals: 0, inputAge: 60))
        }
    }
}
