import Foundation
import Testing
@testable import Relay

/// 0.5.60: tool-requested pane recovery never moves the user's focus, and a
/// hook-reported subagent with no evidence on the host stops holding an
/// installed update once relayd shows the session idle with no subagent work.
@MainActor
struct RelayRecoveryFocusTests {
    private let host = "recover-focus.invalid"

    private func catalogPane(_ id: UUID, tabID: UUID?, workspaceID: UUID?) -> RemoteCatalogPane {
        RemoteCatalogPane(paneID: id.uuidString.lowercased(), workspaceID: workspaceID?.uuidString.lowercased(),
                          tabID: tabID?.uuidString.lowercased(), parentPaneID: nil, title: "Claude",
                          contentKind: "terminal", command: nil, directory: "/work", state: "running",
                          workerPID: 42, shellPID: 43, lastSequence: 0, recoverable: true, unfiled: false)
    }

    /// Two tabs; the second is selected, as the user left it.
    private func twoTabs() throws -> (WorkspaceModel, other: TabModel, selected: TabModel) {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.newTab(profile: .sshConfigHost(host))
        let other = try #require(workspace.selectedTab)
        workspace.newTab(profile: .sshConfigHost(host))
        let selected = try #require(workspace.selectedTab)
        return (workspace, other, selected)
    }

    @Test func toolRecoveryOfANewPaneKeepsTheUsersSelection() throws {
        let (workspace, _, selected) = try twoTabs()
        defer { workspace.shutdown() }
        let activePane = workspace.activePaneID
        let paneID = UUID(), tabID = UUID()
        let pane = catalogPane(paneID, tabID: tabID, workspaceID: nil)
        #expect(RelayPaneRecoveryAttachment.attach(workspace: workspace, profile: .sshConfigHost(host),
                                                   pane: pane, sessionLabel: "dandy-07"))
        #expect(workspace.panes[paneID] != nil)
        #expect(workspace.tabs.contains { $0.id == tabID })
        #expect(workspace.selectedTabID == selected.id)
        #expect(workspace.activePaneID == activePane)
    }

    @Test func toolRecoveryOfAnOpenPaneInAnotherTabKeepsTheUsersSelection() throws {
        let (workspace, other, selected) = try twoTabs()
        defer { workspace.shutdown() }
        let activePane = workspace.activePaneID
        let target = try #require(other.allPaneIDs.first.flatMap { workspace.panes[$0] })
        let remote = catalogPane(target.id, tabID: other.id, workspaceID: other.sessionID)
        #expect(RelayPaneRecoveryAttachment.attach(workspace: workspace, profile: target.profile,
                                                   pane: remote, sessionLabel: "dandy-07"))
        #expect(workspace.selectedTabID == selected.id)
        #expect(workspace.activePaneID == activePane)
    }

    @Test func theUsersOwnOpenStillSelectsTheRecoveredPane() throws {
        let (workspace, _, selected) = try twoTabs()
        defer { workspace.shutdown() }
        let paneID = UUID(), tabID = UUID()
        #expect(workspace.attachRemotePane(profile: .sshConfigHost(host),
            remotePane: catalogPane(paneID, tabID: tabID, workspaceID: nil), workspaceID: nil,
            sessionLabel: "dandy-07", intoSessionID: selected.sessionID))
        #expect(workspace.selectedTabID == tabID)
        #expect(workspace.activePaneID == paneID)
    }
}

struct RelaySubagentHostEvidenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func proof(subagentWork: Bool? = false, harness: String? = "idle",
                       backgroundWork: Bool? = false) -> RelayAgentMaintenanceProbe {
        var proof = RelayAgentMaintenanceProbe(version: 1)
        proof.provider = "claude"
        proof.subagentWork = subagentWork
        proof.harnessStatus = harness
        proof.backgroundWork = backgroundWork
        return proof
    }

    private func active(startedSecondsAgo age: TimeInterval) -> SubagentActivity {
        SubagentActivity(id: UUID().uuidString, label: "Triage", startedAt: now.addingTimeInterval(-age),
                         provider: .claude, phase: .active, reportedChild: true)
    }

    @Test func staleEntriesWithoutHostWorkNoLongerHoldTheUpdate() {
        // 27e6852d: seven hook-reported "active" subagents, no files on the
        // host, Claude idle. Before 0.5.60 this explained no footer agents.
        let stuck = (0..<7).map { _ in active(startedSecondsAgo: 5 * 3600) }
        #expect(RelayAgentMaintenancePolicy.countedActiveSubagents(stuck, proof: proof(), now: now) == 0)
        #expect(RelayAgentMaintenancePolicy.explainedFooterAgents(proof(), subagents: stuck, now: now)
                == RelayAgentMaintenancePrompt.waitingSessionsExplained)
        #expect(RelayAgentMaintenancePolicy.explainedFooterAgents(proof(), activeSubagents: 7) == 0)
    }

    @Test func aRecentEntryStillCountsWhileItsHostFilesMayBeMissing() {
        let entries = [active(startedSecondsAgo: 5 * 3600), active(startedSecondsAgo: 60)]
        #expect(RelayAgentMaintenancePolicy.countedActiveSubagents(entries, proof: proof(), now: now) == 1)
        #expect(RelayAgentMaintenancePolicy.explainedFooterAgents(proof(), subagents: entries, now: now) == 0)
    }

    @Test func unknownOrBusyHostFactsDiscountNothing() {
        let stuck = [active(startedSecondsAgo: 5 * 3600)]
        for facts in [proof(subagentWork: nil), proof(subagentWork: true), proof(harness: nil),
                      proof(harness: "busy")] {
            #expect(RelayAgentMaintenancePolicy.countedActiveSubagents(stuck, proof: facts, now: now) == 1)
            #expect(RelayAgentMaintenancePolicy.explainedFooterAgents(facts, subagents: stuck, now: now) == 0)
        }
        var codex = proof(); codex.provider = "codex"
        #expect(RelayAgentMaintenancePolicy.countedActiveSubagents(stuck, proof: codex, now: now) == 1)
    }

    @Test func finishedEntriesNeverCount() {
        var done = active(startedSecondsAgo: 30)
        done.phase = .quiet
        #expect(RelayAgentMaintenancePolicy.countedActiveSubagents([done], proof: proof(subagentWork: true), now: now) == 0)
    }

    @Test func heldReceiptsNameTheFactsWithoutLabels() {
        let entries = [active(startedSecondsAgo: 5 * 3600), active(startedSecondsAgo: 60)]
        let facts = RelayAgentMaintenancePolicy.footerAgentFacts(proof(subagentWork: nil), subagents: entries, now: now)
        #expect(facts == "harness_status=idle subagent_work=unknown background_work=false " +
                "background_agent_jobs=unknown active_subagents=2 of 2 reported")
        #expect(!facts.contains("Triage"))
        #expect(RelayAgentMaintenancePolicy.footerAgentFacts(proof(), subagents: entries, now: now)
                .hasSuffix("active_subagents=1 of 2 reported"))
    }
}
