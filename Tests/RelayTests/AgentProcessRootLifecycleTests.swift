import Foundation
import Testing
@testable import Relay

@MainActor @Suite struct AgentProcessRootLifecycleTests {
    @Test func capturedLiveJournalReplaysToOriginalShell() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("remote/relayd/internal/daemon/testdata/agent-process-legacy-exit.json")
        let events = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        for event in events { pane.receivedAgentEvent(try JSONSerialization.data(withJSONObject: event)) }
        #expect(events.count == 130)
        #expect(pane.networkAgentRoots.isEmpty)
        #expect(pane.kind == .shell)
        #expect(pane.phase == .quiet)
    }

    private func payload(_ root: String, _ event: String, _ sequence: UInt64,
        source: String = "process-tree") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["agent": "claude", "relay_event_seq": sequence,
            "event": ["root_id": root, "hook_event_name": event, "source": source,
                "occurred_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence)))]] )
    }

    @Test func legacyExitRestoresShellWithoutTouchingOtherIncarnations() throws {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        try pane.receivedAgentEvent(payload("claude:206865:956839242", "SessionStart", 1543))
        try pane.receivedAgentEvent(payload("claude:206865:unavailable", "SessionEnd", 1544))
        #expect(pane.networkAgentRoots.isEmpty)
        #expect(pane.kind == .shell)
        #expect(pane.phase == .quiet)
    }

    @Test func oldExitCannotRetireNewerRootRestoredFromSnapshot() throws {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        let started = try JSONSerialization.jsonObject(with: payload("claude:77:new", "SessionStart", 20))
        pane.receivedAgentEvent(try JSONSerialization.data(withJSONObject: ["agent": "relay", "relay_event_seq": 20,
            "event": ["type": "RelayStateSnapshot", "events": [started]]]))
        try pane.receivedAgentEvent(payload("claude:77:unavailable", "SessionEnd", 10))
        try pane.receivedAgentEvent(payload("claude:77:new", "SessionEnd", 11))
        #expect(pane.networkAgentRoots == ["claude:77:new"])
        #expect(pane.kind == .claude)
        try pane.receivedAgentEvent(payload("claude:77:new", "SessionEnd", 21))
        #expect(pane.networkAgentRoots.isEmpty)
        #expect(pane.kind == .shell)
    }

    @Test func legacyExitPreservesHooksAndOtherProcesses() throws {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        try pane.receivedAgentEvent(payload("claude:77:old", "SessionStart", 1))
        try pane.receivedAgentEvent(payload("claude:88:other", "SessionStart", 2))
        try pane.receivedAgentEvent(payload("claude:77:hook", "SessionStart", 3, source: "hook"))
        try pane.receivedAgentEvent(payload("claude:77:unavailable", "SessionEnd", 4))
        #expect(pane.networkAgentRoots == ["claude:77:hook", "claude:88:other"])
    }

    /// The 8e4b42ae journal from dandy-07 (2026-10-30): the conversation's
    /// root stays alive while two 1 s roots of the same provider start and
    /// end. Only the last root's exit may say the session ended.
    @Test func shortLivedSecondRootDoesNotEndTheRunningConversation() throws {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        try pane.receivedAgentEvent(payload("claude:821285:3684655", "SessionStart", 1))
        try pane.receivedAgentEvent(payload("claude:3243653:4874836", "SessionStart", 6))
        try pane.receivedAgentEvent(payload("claude:3243653:4874836", "SessionEnd", 7))
        try pane.receivedAgentEvent(payload("claude:4069236:5281863", "SessionStart", 8))
        try pane.receivedAgentEvent(payload("claude:4069236:5281863", "SessionEnd", 9))
        #expect(pane.networkAgentRoots == ["claude:821285:3684655"])
        #expect(pane.kind == .claude)
        #expect(pane.activitySummary != "Claude session ended")
        try pane.receivedAgentEvent(payload("claude:821285:3684655", "SessionEnd", 10))
        #expect(pane.networkAgentRoots.isEmpty)
        #expect(pane.activitySummary == "Claude session ended")
    }

    @Test func emptySnapshotClearsStalePresentation() throws {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        try pane.receivedAgentEvent(payload("claude:77:old", "SessionStart", 1))
        pane.receivedAgentEvent(Data(#"{"agent":"relay","relay_event_seq":2,"event":{"type":"RelayStateSnapshot","events":[]}}"#.utf8))
        #expect(pane.networkAgentRoots.isEmpty)
        #expect(pane.kind == .shell)
        #expect(pane.phase == .quiet)
    }

    @Test func legacySavedCursorRequestsRepairReplayAndNewRootsSurvivePersistence() throws {
        let old = PersistedAgentPaneState(cursor: 1544, kind: .claude, phase: .active,
            summary: "Claude session ended", subagents: [], activities: [], resourceUsage: nil,
            progressPercent: nil, pendingApprovals: 0)
        let decoded = try JSONDecoder().decode(PersistedAgentPaneState.self, from: JSONEncoder().encode(old))
        #expect(decoded.cursor == 1544)
        #expect(decoded.replayCursor == 0)
        let root = PersistedAgentProcessRoot(id: "claude:77:new", kind: .claude,
            observation: .init(provider: "claude", source: "process-tree", sequence: 20, occurredAt: Date()))
        let current = PersistedAgentPaneState(processRootIdentityVersion: 1, processRoots: [root],
            cursor: 21, kind: .claude, phase: .active, summary: "Working", subagents: [],
            activities: [], resourceUsage: nil, progressPercent: nil, pendingApprovals: 0)
        let restored = try JSONDecoder().decode(PersistedAgentPaneState.self, from: JSONEncoder().encode(current))
        #expect(restored.replayCursor == 21)
        #expect(restored.processRoots?.first?.id == "claude:77:new")
        #expect(restored.processRoots?.first?.observation.sequence == 20)
    }
}
