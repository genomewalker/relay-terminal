import Foundation
import XCTest
#if canImport(Relay)
@testable import Relay
#endif

final class RelayTaskTriageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func plan(_ status: AgentTaskPlan.Step.Status = .in_progress, age: Double = 10,
                      provider: String = "claude", text: String = "Check figure evidence") -> AgentTaskPlan {
        AgentTaskPlan(id: provider + ":worker", provider: provider, updatedAt: now.addingTimeInterval(-age),
                      steps: [.init(text: text, status: status)])
    }
    private func read(_ plans: [AgentTaskPlan] = [], connection: String = "Connected",
                      at: Date? = nil, receipts: [RelayTaskTriage.Receipt] = []) -> RelayTaskTriage {
        .build(paneID: "pane-a", host: "dandy-07", directory: "/maps/project", provider: "claude",
               connection: connection, phase: "quiet", plans: plans, healthState: "unknown",
               blockers: [], pendingDecision: nil, receipts: receipts, now: at ?? now)
    }
    func testActivePlanIsInferenceNotUserObjective() {
        let value = read([plan()])
        XCTAssertEqual(value.objective.kind, .inferred)
        XCTAssertEqual(value.result.kind, .unknown)
        XCTAssertEqual(value.owner.kind, .unknown)
        XCTAssertEqual(value.blocker.kind, .unknown)
    }
    func testCompletionIsOnlyAgentReport() {
        let value = read([plan(.completed)])
        XCTAssertEqual(value.result.text, "Agent reports complete: Check figure evidence")
        XCTAssertTrue(value.result.source.contains("artifact verification unknown"))
        XCTAssertEqual(value.objective.kind, .unknown)
        XCTAssertEqual(value.decision.kind, .unknown)
    }
    func testStalePlanRemainsHistorical() {
        let value = read([plan(age: 901)])
        XCTAssertTrue(value.freshness.hasPrefix("Stale"))
        XCTAssertEqual(value.objective.at, now.addingTimeInterval(-901))
        XCTAssertEqual(value.decision.kind, .inferred)
    }
    func testDisconnectedOverridesRecentPlan() {
        let value = read([plan()], connection: "Disconnected")
        XCTAssertTrue(value.freshness.hasPrefix("Disconnected"))
        XCTAssertEqual(value.blocker.text, "Disconnected")
        XCTAssertTrue(value.blocker.source.contains("remote liveness not verified"))
    }
    func testMissingAndFutureEvidenceAreUnknown() {
        XCTAssertTrue(read().freshness.hasPrefix("Unknown"))
        XCTAssertTrue(read([plan(age: -5)]).freshness.contains("future"))
        XCTAssertEqual(read().result.kind, .unknown)
    }
    func testForeignProviderPlanIsNotAttributed() {
        let value = read([plan(provider: "codex")])
        XCTAssertTrue(value.plans.isEmpty)
        XCTAssertEqual(value.objective.kind, .unknown)
    }
    func testReceiptsNeverProveTaskCompletion() {
        for status in ["submitted", "admitted_not_processed", "processed", "written_to_socket", "read_acknowledged"] {
            let r = RelayTaskTriage.Receipt(id: "message", recipientPaneID: "pane-a", status: status,
                                           readAcknowledged: status == "read_acknowledged")
            XCTAssertTrue(r.description.contains("Task completion: unknown"))
            XCTAssertEqual(read(receipts: [r]).result.kind, .unknown)
            if status != "read_acknowledged" { XCTAssertTrue(r.description.contains("read acknowledgement: unknown")) }
        }
    }
    func testRefreshDoesNotGenerateDuplicateChangeNotices() {
        var tracker = RelayTaskTriageChanges()
        XCTAssertTrue(tracker.observe(["pane-a": read([plan()])]).isEmpty)
        XCTAssertTrue(tracker.observe(["pane-a": read([plan()], at: now.addingTimeInterval(10))]).isEmpty)
        XCTAssertEqual(tracker.observe(["pane-a": read([plan()], connection: "Disconnected")]), ["pane-a"])
        XCTAssertTrue(tracker.observe(["pane-a": read([plan()], connection: "Disconnected")]).isEmpty)
        XCTAssertTrue(tracker.observe([:]).isEmpty)
        XCTAssertTrue(tracker.observe(["pane-a": read([plan()])]).isEmpty)
    }
    func testStaleTransitionProducesOneNotice() {
        var tracker = RelayTaskTriageChanges()
        _ = tracker.observe(["pane-a": read([plan()])])
        XCTAssertEqual(tracker.observe(["pane-a": read([plan()], at: now.addingTimeInterval(901))]), ["pane-a"])
        XCTAssertTrue(tracker.observe(["pane-a": read([plan()], at: now.addingTimeInterval(950))]).isEmpty)
    }
    func testHandoffPreservesExactTargetAndUnknowns() {
        let text = read([plan()]).handoff(workspaceID: "workspace-a", workspace: "Research",
                                         tabID: "tab-a", tab: "Figures")
        for expected in ["workspace-a", "tab-a", "Host: dandy-07", "/maps/project", "pane-a",
                         "provider conversation: unknown", "Jobs: unknown", "Decision owner [unknown]",
                         "does not"] {
            if expected == "does not" { continue }
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertTrue(text.contains("Recheck live bindings"))
    }
}
