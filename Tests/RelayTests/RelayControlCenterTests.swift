import Foundation
import Testing
@testable import Relay

/// CC-S1: the read-only Control section.
@MainActor @Suite(.serialized) struct RelayControlCenterTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cc-s1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func auditLine(_ pane: UUID, _ event: String, _ at: Double) -> String {
        #"{"pane":""# + pane.uuidString + #"","event":""# + event + #"","at":"# + String(at) + "}\n"
    }

    private func row(_ id: UUID, host: String, account: String?) -> RelaySidePanelState.Pane {
        RelaySidePanelState.Pane(id: id.uuidString.lowercased(), name: "pane", host: host, directory: nil,
            contentKind: "terminal", terminalAvailable: true, agent: "claude", phase: "idle", connection: "Connected",
            selected: false, summary: "", account: account)
    }

    @Test func treeFollowsOwnershipNotBirthSession() throws {
        let w = WorkspaceModel(restoreSavedWorkspace: false)
        defer { w.shutdown() }
        w.newTab(profile: .sshConfigHost("cc-s1-a.invalid"))
        let b = w.createWorkspace(named: "QA empty")
        w.selectWorkspace(b)
        w.newTabInActiveSession(origin: .human)
        let made = try #require(w.selectedTab)
        #expect(w.workspaceID(forTab: made.id) == b)
        #expect(made.sessionID != b, "the QA-F01 case: born in another session")
        // The legacy grouping files the tab under its birth session.
        let legacy = w.sidePanelState().sessions.first { $0.tabs.contains { $0.id == made.id.uuidString.lowercased() } }
        #expect(legacy?.id == made.sessionID.uuidString.lowercased())

        let files = RelayControlCenterFiles(journalURL: try tempDirectory().appendingPathComponent("quota-failover-v1.json"))
        let state = RelayControlCenterState.live(workspace: w, files: files)
        let id = made.id.uuidString.lowercased()
        let holders = state.workspaces.filter { $0.tabs.contains { $0.id == id } }
        #expect(holders.map(\.id) == [b.uuidString.lowercased()])
        #expect(holders.first?.name == "QA empty")
        #expect(state.unowned.isEmpty)
        // Every tab in the window appears exactly once, under its owner.
        let listed = state.workspaces.flatMap { ws in ws.tabs.map { (ws.id, $0.id) } }
        #expect(listed.count == w.tabs.count)
        for tab in w.tabs {
            let owner = try #require(w.workspaceID(forTab: tab.id))
            #expect(listed.filter { $0.1 == tab.id.uuidString.lowercased() }.map(\.0) == [owner.uuidString.lowercased()])
        }
        let order = state.workspaces.map(\.id)
        #expect(order == w.ownership.orderedWorkspaces.map { $0.id.uuidString.lowercased() })
        let pane = try #require(holders.first?.tabs.first { $0.id == id }?.panes.first)
        #expect(pane.id == made.allPaneIDs.first?.uuidString.lowercased())
        let madePane = try #require(made.allPaneIDs.first)
        let profile = try #require(w.panes[madePane]?.profile)
        #expect(pane.hostKey == RelayAgentAccountDirectory.hostKey(profile))
    }

    @Test func auditFixtureCountsReasonsAndCache() throws {
        let dir = try tempDirectory()
        let journalURL = dir.appendingPathComponent("quota-failover-v1.json")
        let local = UUID(), remote = UUID(), closed = UUID()
        var text = ""
        for i in 0..<3 { text += auditLine(local, "deferred_account_mapping", Double(100 + i)) }
        for i in 0..<2 { text += auditLine(remote, "deferred_quota_unavailable", Double(200 + i)) }
        text += auditLine(remote, "deferred_account_mapping", 150)
        text += auditLine(closed, "deferred_quota_unavailable", 300)
        text += #"{"pane":"broken"# // an interrupted last append
        try Data(text.utf8).write(to: URL(fileURLWithPath: journalURL.path + ".audit.jsonl"))
        let record = RelayClaudeQuotaEngine.Record(pane: remote, host: "dandy.invalid", session: "s", process: "p",
            source: "business", target: "personal", sourceDir: "~/.claude-team", targetDir: "~/.claude",
            reset: Date(timeIntervalSinceReferenceDate: 500), state: .refused, operation: UUID(), detail: "fixture refusal",
            triggerResets: ["five_hour": Date(timeIntervalSinceReferenceDate: 500)])
        try JSONEncoder().encode(RelayClaudeQuotaEngine.Disk(records: [record])).write(to: journalURL)

        let files = RelayControlCenterFiles(journalURL: journalURL)
        let digest = files.audit()
        #expect(digest.entries == 7)
        #expect(digest.note?.contains("1 unreadable") == true)
        #expect(files.audit() == digest)
        #expect(files.auditParses == 1, "an unchanged audit is not re-parsed")

        var input = RelayControlCenterState.Inputs(ownership: .empty, tabs: [
            .init(id: UUID(), name: "T", panes: [
                .init(row: row(local, host: "This Mac", account: "business"), hostKey: "local", isClaude: true),
                .init(row: row(remote, host: "dandy", account: "personal"), hostKey: "dandy.invalid", isClaude: true),
            ])])
        input.audit = digest
        (input.journal, input.journalNote) = files.journal()
        input.accounts = ["dandy.invalid": [.init(provider: "claude", label: "business", dir: "~/.claude-team"),
                                            .init(provider: "claude", label: "personal", dir: "~/.claude")]]
        input.deferrals = ["local": "waiting for this host's account list"]
        let state = RelayControlCenterState.build(input)

        let mac = try #require(state.hosts.first { $0.key == "local" })
        #expect(mac.name == "This Mac")
        #expect(mac.accounts == nil, "unread accounts are not shown as built-in defaults")
        #expect(mac.counts == [.init(event: "deferred_account_mapping", count: 3)])
        #expect(mac.latest == .init(event: "deferred_account_mapping", at: Date(timeIntervalSinceReferenceDate: 102)))
        #expect(mac.deferral == "waiting for this host's account list")
        #expect(mac.current == [.init(event: "business", count: 1)])
        let dandy = try #require(state.hosts.first { $0.key == "dandy.invalid" })
        #expect(dandy.accounts == ["business · ~/.claude-team", "personal · ~/.claude"])
        #expect(dandy.counts == [.init(event: "deferred_quota_unavailable", count: 2), .init(event: "deferred_account_mapping", count: 1)])
        #expect(dandy.latest?.event == "deferred_quota_unavailable")
        #expect(state.otherPanesAudit == [.init(event: "deferred_quota_unavailable", count: 1)])
        #expect(state.auditNote?.contains("unreadable") == true)

        let pane = try #require(state.unowned.first?.panes.first { $0.id == remote.uuidString.lowercased() })
        #expect(pane.failover.journalState == "refused")
        #expect(pane.failover.journalDetail == "fixture refusal")
        #expect(pane.failover.counts.map(\.count).reduce(0, +) == 3)

        #expect(RelayControlCenterState.explain("deferred_account_mapping").hasPrefix("Transient"))
        #expect(RelayControlCenterState.explain("deferred_quota_unavailable").hasPrefix("Refused by design"))

        // A changed audit is parsed again.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: journalURL.path + ".audit.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + auditLine(local, "deferred_registry_loading", 400)).utf8))
        try handle.close()
        #expect(files.audit().entries == 8)
        #expect(files.auditParses == 2)
    }

    @Test func hiddenSectionMakesNoReads() throws {
        let w = WorkspaceModel(restoreSavedWorkspace: false)
        defer { w.shutdown() }
        let journalURL = try tempDirectory().appendingPathComponent("quota-failover-v1.json")
        try Data(auditLine(UUID(), "deferred_account_mapping", 1).utf8)
            .write(to: URL(fileURLWithPath: journalURL.path + ".audit.jsonl"))
        let files = RelayControlCenterFiles(journalURL: journalURL)
        let shepherdReads = RelayMikoShepherdCoordinator.shared.observationReads
        let feed = RelayControlCenterFeed.control(workspace: w, files: files)
        #expect(feed.value == .empty)
        #expect(!feed.isRefreshing)
        #expect(files.auditParses == 0, "a hidden section reads nothing")

        feed.setVisible(true)
        #expect(files.auditParses == 1)
        #expect(!feed.value.workspaces.isEmpty)
        feed.setVisible(false)
        #expect(!feed.isRefreshing)
        #expect(RelayMikoShepherdCoordinator.shared.observationReads == shepherdReads, "no screen observation")
    }

    @Test func contextRollStatesKeepTheirReasons() {
        func overview(_ state: String, _ context: RelayPaneContextObservation?) -> RelayPaneHealthCoordinator.PaneOverview {
            .init(paneID: "p", name: "p", observationState: state, worker: nil, context: context)
        }
        func ctx(_ supported: Bool, _ enabled: Bool, _ state: String, lifecycle: String? = nil, unavailable: String? = nil) -> RelayPaneContextObservation {
            .init(supported: supported, enabled: enabled, state: state, generation: nil, lifecycle: lifecycle,
                  refreshCapability: nil, unavailable: unavailable)
        }
        typealias C = RelayControlCenterState.ContextRoll
        #expect(RelayControlCenterState.contextRoll(overview("not_checked", nil)) == C(state: "unverified", reason: "Awaiting native check"))
        #expect(RelayControlCenterState.contextRoll(overview("fresh", ctx(false, false, "off", unavailable: "Native context status could not be verified")))
            == C(state: "unavailable", reason: "Native context status could not be verified"))
        #expect(RelayControlCenterState.contextRoll(overview("fresh", ctx(true, false, "off"))).state == "not_enrolled")
        #expect(RelayControlCenterState.contextRoll(overview("fresh", ctx(true, false, "human_takeover"))) == C(state: "not_enrolled", reason: "Paused by you"))
        #expect(RelayControlCenterState.contextRoll(overview("fresh", ctx(true, true, "on", lifecycle: "unavailable"))).state == "unavailable")
        #expect(RelayControlCenterState.contextRoll(overview("fresh", ctx(true, true, "on", lifecycle: "idle"))) == C(state: "supported", reason: "Enabled (idle)"))
    }

    @Test func mikoExchangesShowRequestIDsAndReceiptStates() {
        let pane = UUID(), other = UUID()
        let request = UUID().uuidString.lowercased()
        var done = RelayAssistantExchange(request: "a", origin: .agent(paneID: pane, label: "x"),
                                          requestID: request.replacingOccurrences(of: "-", with: ""))
        done.reply = "ok"
        var failed = RelayAssistantExchange(request: "b", origin: .supervisor(paneID: pane, label: "s"))
        failed.failed = true
        failed.reply = "boom"
        let foreign = RelayAssistantExchange(request: "c", origin: .agent(paneID: other, label: "y"))
        let waiting = RelayAssistantExchange(request: "d", origin: .agent(paneID: pane, label: "x"))
        var input = RelayControlCenterState.Inputs(ownership: .empty, tabs: [])
        input.exchanges = [done, failed, foreign, waiting]
        input.cardPending = true
        let rows = RelayControlCenterState.exchanges(input, pane: pane)
        #expect(rows.map(\.status) == ["completed", "failed", "waiting_for_approval"])
        #expect(rows[0].requestID == request)
        #expect(rows[0].origin == "agent ask")
        #expect(rows[1].requestID == nil)
        input.cardPending = false
        input.busy = true
        #expect(RelayControlCenterState.exchanges(input, pane: pane).last?.status == "running")
        var cancelled = RelayAssistantExchange(request: "e", origin: .agent(paneID: pane, label: "x"))
        cancelled.failed = true
        cancelled.reply = "Cancelled."
        #expect(RelayControlCenterState.status(cancelled, isLast: false, cardPending: false, busy: false) == "stopped")
    }

    /// The 48.82% incident: bound and quiet, high actual usage, nothing can manage it.
    @Test func the4882FixtureShowsEveryReasonAndManagementUnavailable() throws {
        let id = UUID()
        let usage = RelayAgentAccountUsage(provider: "claude", label: "personal", status: "ok", reason: nil,
            source: "claude get_usage", readAt: "2026-11-03T17:00:00Z",
            windows: [.init(name: "seven_day", usedPercent: 48.82, resetsAt: nil, windowMinutes: 10080)])
        let estimate = RelayControlCenterState.UsageReading(provenance: "estimated_tokens", scope: "this chat",
            window: "weekly", usedPercent: 12.5, source: nil, readAt: nil)
        var input = RelayControlCenterState.Inputs(ownership: .empty, tabs: [
            .init(id: UUID(), name: "T", panes: [.init(row: row(id, host: "This Mac", account: "personal"), hostKey: "local",
                isClaude: true, accountUsage: usage, estimates: [estimate], promptEmpty: false)])])
        input.health = [.init(paneID: id.uuidString.lowercased(), name: "root", observationState: "fresh", worker: nil,
            context: .init(supported: true, enabled: false, state: "not_enrolled", generation: nil, lifecycle: "unavailable",
                           refreshCapability: "unverified", unavailable: "Native context status could not be verified"))]
        let pane = try #require(RelayControlCenterState.build(input).unowned.first?.panes.first)
        let s = pane.supervision
        #expect(s.enabled == "false")
        #expect(s.enrollment == "not_enrolled")
        #expect(s.refreshCapability == "unverified")
        #expect(s.lifecycle == "unavailable")
        #expect(s.promptEmpty == "false")
        #expect(s.management == "management unavailable")
        #expect(s.blocked == ["enabled=false (state not_enrolled)", "refresh_capability=unverified", "lifecycle=unavailable",
                              "Native context status could not be verified"])
        let actual = try #require(s.usage.first { $0.provenance == "actual_dashboard" })
        #expect(actual.usedPercent == 48.82)
        #expect(actual.window == "weekly")
        #expect(actual.source == "claude get_usage")
        #expect(s.usage.filter { $0.provenance == "estimated_tokens" } == [estimate], "an estimate stays labelled as one")
        #expect(!s.usage.contains { $0.provenance == "actual_dashboard" && $0.usedPercent == 12.5 })
        let shown = [s.enabled, s.enrollment, s.refreshCapability, s.lifecycle, s.promptEmpty, s.management] + s.blocked
            + [pane.context.state, pane.context.reason]
        for text in shown {
            #expect(!text.localizedCaseInsensitiveContains("supervised"))
            #expect(text != "OK" && !text.contains(" OK"))
        }
        // Without a health fact, prompt_empty is not guessed from the screen.
        input.tabs[0].panes[0].promptEmpty = nil
        let unread = try #require(RelayControlCenterState.build(input).unowned.first?.panes.first)
        #expect(unread.supervision.promptEmpty.hasPrefix("not read here"))
    }

    @Test func controlSectionHasNoWritePath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Relay/RelayControlCenter.swift"), encoding: .utf8)
        for forbidden in ["Button(", "Toggle(", "Menu(", "onTapGesture", "onSubmit", "runCard", "cancelCard", "checkNow",
                          "setDisabled", "relay_", "route(", "submit", "save(", "appendAudit", ".write(", "Stepper("] {
            #expect(!source.contains(forbidden), "Control section must not contain \(forbidden)")
        }
        let panel = try String(contentsOf: root.appendingPathComponent("Sources/Relay/PerformancePanel.swift"), encoding: .utf8)
        #expect(panel.contains(#"case "Control": RelayControlCenterView(workspace: workspace)"#))
    }
}
