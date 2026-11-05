import Foundation
import Testing
@testable import Relay

/// CC-S2: the Control section's actions and Miko's budget supervision.
@MainActor private final class ScriptModel: RelayAssistantModel {
    var script: [(RelayAssistantModelRequest) -> RelayAssistantModelStep]
    private(set) var requests = 0
    init(_ script: [(RelayAssistantModelRequest) -> RelayAssistantModelStep]) { self.script = script }
    func step(_ request: RelayAssistantModelRequest) async throws -> RelayAssistantModelStep {
        requests += 1
        return script[(requests - 1) % script.count](request)
    }
}

@MainActor private final class CardExecutor: RelayAssistantActionExecutor {
    var instance: UUID? = UUID()
    private(set) var calls: [(method: String, path: String, body: Data)] = []
    func permits(_ capability: MCPWorkspaceCapability) -> Bool { true }
    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        calls.append((method, path, body))
        return (200, Data(#"{"status":"submitted_outcome_unknown"}"#.utf8))
    }
}

@MainActor private final class Clock { var value = Date(timeIntervalSince1970: 1_000_000) }

@MainActor @Suite(.serialized) struct RelayControlCenterActionsTests {
    // MARK: Card fixture (item 1)

    private struct CardFixture {
        let workspace: WorkspaceModel
        let pane: UUID
        let model: ScriptModel
        let executor: CardExecutor
        let assistant: RelayAssistantHarness
        let supervision: RelayMikoSupervision
        let clock: Clock
        let actions: RelayControlCenterActions
    }

    private func cardFixture() throws -> CardFixture {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let pane = try #require(workspace.activePaneID)
        let model = ScriptModel([{ _ in
            let input: [String: RelayPaneHealthJSON] = ["pane_id": .string(pane.uuidString.lowercased()), "text": .string("echo hi")]
            let call = RelayPaneHealthToolCall(type: "tool_use", id: "toolu_1", name: "send_command", input: .object(input))
            return RelayAssistantModelStep(stopReason: "tool_use", content: [.object(["type": .string("tool_use"),
                "id": .string("toolu_1"), "name": .string("send_command"), "input": .object(input)])],
                toolCalls: [call], chargedMicrousd: 1)
        }, { _ in
            RelayAssistantModelStep(stopReason: "end_turn", content: [.object(["type": .string("text"), "text": .string("done")])],
                                    toolCalls: [], chargedMicrousd: 1)
        }])
        let executor = CardExecutor()
        let clock = Clock()
        let supervision = RelayMikoSupervision(url: nil)
        let audit = RelayCallerControl(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-s2-audit-" + UUID().uuidString))
        let facts = RelayAssistantFacts(health: { _ in .object(["connection": .string("connected")]) },
            holdReason: { _ in "No hold" }, rotation: { _ in nil }, binding: { _ in "agent-session-1" })
        let assistant = RelayAssistantHarness(policy: { .init(autonomy: .cardsForWrites) }, budget: RelayMikoActionBudget(),
            workspace: workspace, facts: facts, model: { _ in (model, "h-test") }, audit: audit, executor: { executor },
            promptProof: { _ in .init(empty: true, inputRevision: 7) }, cardTimeout: 300,
            supervision: supervision, now: { clock.value })
        workspace.haikuAssistantStorage = assistant
        let actions = RelayControlCenterActions(workspace: workspace, supervision: supervision)
        return CardFixture(workspace: workspace, pane: pane, model: model, executor: executor, assistant: assistant,
                           supervision: supervision, clock: clock, actions: actions)
    }

    private func waitForCard(_ assistant: RelayAssistantHarness) async throws -> RelayAssistantActionCard {
        for _ in 0..<1000 {
            if let card = assistant.pendingCard { return card }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw RelayAssistantToolError(message: "no card")
    }

    @Test func controlRunAndCancelAreTheHarnessRunCardAndCancelCard() async throws {
        let f = try cardFixture()
        defer { f.workspace.shutdown() }

        // The card appears in the Control tree under its pane, with the card's own rows.
        let task = Task { await f.assistant.run("say hi", origin: .user) }
        let card = try await waitForCard(f.assistant)
        var input = RelayControlCenterState.Inputs(ownership: .empty, tabs: [])
        input.pendingCard = card
        let shown = RelayControlCenterState.pendingCard(card, origin: .user)
        #expect(shown.id == card.id && shown.expiresAt == card.expiresAt && shown.paneID == f.pane.uuidString.lowercased())
        #expect(RelayControlCenterState.card(for: f.pane, input) == shown)
        #expect(RelayControlCenterState.card(for: UUID(), input) == nil)

        // Cancel is cancelCard(): nothing executes.
        #expect(f.actions.cancelCard(id: card.id))
        _ = await task.value
        #expect(f.assistant.pendingCard == nil && f.executor.calls.isEmpty)

        // Run is runCard(): exactly the shown request once; a second click does nothing.
        let g = try cardFixture()
        defer { g.workspace.shutdown() }
        let second = Task { await g.assistant.run("say hi again", origin: .user) }
        let card2 = try await waitForCard(g.assistant)
        #expect(card2.blockedReason == nil)
        #expect(g.actions.runCard(id: card2.id))
        _ = g.actions.runCard(id: card2.id)
        _ = await second.value
        #expect(g.executor.calls.count == 1)
        let call = try #require(g.executor.calls.first)
        #expect(call.method == card2.method && call.path == card2.path && call.body == card2.body)
    }

    @Test func anExpiredCardCanOnlyExpireFromControl() async throws {
        let f = try cardFixture()
        defer { f.workspace.shutdown() }
        let task = Task { await f.assistant.run("say hi", origin: .user) }
        let card = try await waitForCard(f.assistant)
        f.clock.value = card.expiresAt.addingTimeInterval(1)
        f.actions.runCard(id: card.id)
        _ = await task.value
        #expect(f.executor.calls.isEmpty, "an expired card never runs")
        #expect(f.assistant.pendingCard == nil)
    }

    @Test func aPaneOriginCardIsStillACardThatOnlyTheUserResolves() async throws {
        let f = try cardFixture()
        defer { f.workspace.shutdown() }
        let asker = f.pane
        let task = Task { await f.assistant.run("tell it", origin: .agent(paneID: asker, label: "agent")) }
        let card = try await waitForCard(f.assistant)
        #expect(f.executor.calls.isEmpty, "a pane-origin request waits for the user")
        let shown = RelayControlCenterState.pendingCard(card, origin: f.assistant.pendingCardOrigin)
        #expect(shown.origin.hasPrefix("pane agent ask"))
        f.actions.cancelCard(id: card.id)
        _ = await task.value
        #expect(f.executor.calls.isEmpty)
    }

    // MARK: Pause (item 2)

    @Test func pauseIsTheSettingsTogglesOwnCallAndStopsMiko() throws {
        let f = try cardFixture()
        defer { f.workspace.shutdown() }
        #expect(!f.supervision.current.disabledTools.contains("*"))
        f.actions.setMikoPaused(true)
        #expect(f.supervision.current.disabledTools.contains("*"))
        #expect(f.supervision.current.revertedTo == nil)
        let paused = f.supervision.current
        #expect(paused.author == "user" && paused.reason == "Pause Miko")
        f.actions.setMikoPaused(false)
        #expect(!f.supervision.current.disabledTools.contains("*"))
        #expect(f.supervision.current.reason == "Resume Miko")
        // The Settings toggle calls the same function.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/Relay/RelayMikoPolicySettingsView.swift"), encoding: .utf8)
        #expect(settings.contains("supervision.setMikoPaused(paused)"))
        let control = try String(contentsOf: root.appendingPathComponent("Sources/Relay/RelayControlCenterActions.swift"), encoding: .utf8)
        #expect(control.contains("supervision.setMikoPaused(paused)"))
    }

    @Test func pausedMikoRefusesToRun() async throws {
        let f = try cardFixture()
        defer { f.workspace.shutdown() }
        f.actions.setMikoPaused(true)
        let exchange = await f.assistant.run("hello", origin: .user)
        #expect(exchange == nil && f.model.requests == 0, "paused Miko makes no model call")
    }

    // MARK: Native status fixtures (items 3 and 5)

    private func settingsJSON(threshold: Int64 = 100_000) throws -> Any {
        var settings = RelayCapacityManagement.Settings()
        settings.thresholdTokens = threshold
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONSerialization.jsonObject(with: encoder.encode(settings))
    }

    private struct NativeState {
        var enabled = true, managed = true, supported = true
        var state = "idle", reason = "ok"
        var measured: Int64? = 150_000
        var due = true
        var operation: [String: Any]?
        var entry: [String: Any]?
        var revision = 1
    }

    private func statusResult(_ n: NativeState, sessionID: String = "session-1") throws -> [String: Any] {
        var decision: [String: Any] = ["v": 1, "state": "due", "context_due": n.due, "quota_due": false, "ranking": "",
            "rebalance_due": false, "return_due": false, "target_account": "", "target_config": "", "mode": "context",
            "reasons": [], "limiting_windows": [], "next_observation_ms": 0, "retirement": "", "ready": false]
        if let measured = n.measured { decision["measured_tokens"] = measured }
        var result: [String: Any] = ["v": 1, "revision": n.revision, "settings": try settingsJSON(), "state": n.state, "reason": n.reason,
            "supported": n.supported, "managed": n.managed, "enabled": n.enabled, "ready": false,
            "capabilities": ["provider_version": "", "admission": false, "complete_work": false, "scheduled_tasks": false,
                             "preservation": false, "pickup": false, "reason": "fixture"],
            "decision": decision, "accounts": [], "registered_accounts": ["personal", "team"],
            "source": ["provider": "claude", "pane": "PANE", "session": sessionID, "binding": "b1"]]
        if let operation = n.operation { result["operation"] = operation }
        if let entry = n.entry { result["entry"] = entry }
        return result
    }

    /// Records every native request and answers it from `answer`.
    @MainActor private final class Native {
        var requests: [(operation: String, pane: String?, revision: UInt64?, target: String?)] = []
        var lastID = ""
        var answer: (String) throws -> [String: Any]
        var pane = ""
        init(_ answer: @escaping (String) throws -> [String: Any]) { self.answer = answer }
        var operations: [String] { requests.map { $0.operation } }
        func exchange() -> (Data) async throws -> Data {
            { [self] payload in
                let root = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
                let id = try #require(root["request_id"] as? String)
                lastID = ((root["host_accounts"] as? [String: Any])?["request"] as? [String: Any])?["id"] as? String ?? ""
                let forward = try #require(root["host_accounts"] as? [String: Any])
                let request = try #require(forward["request"] as? [String: Any])
                let operation = try #require(request["operation"] as? String)
                requests.append((operation, request["pane_id"] as? String, (request["expected_revision"] as? NSNumber)?.uint64Value,
                                 request["target_account"] as? String))
                var result = try answer(operation)
                if var source = result["source"] as? [String: Any], source["pane"] as? String == "PANE" {
                    source["pane"] = pane
                    result["source"] = source
                }
                return try JSONSerialization.data(withJSONObject: ["request_id": id, "result": result])
            }
        }
    }

    // MARK: Context roll (item 3)

    @Test func rollCallsTheCheckedContextRefreshWithTheNativeReceiptAndRefusal() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let pane = try #require(workspace.activePane)
        let native = Native { _ in try self.statusResult(NativeState()) }
        native.pane = pane.id.uuidString.lowercased()
        let coordinator = RelayCapacityManagementCoordinator(readExchange: native.exchange(),
                                                              budget: RelayBudgetSupervisor(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let actions = RelayControlCenterActions(workspace: workspace, capacity: coordinator)

        native.answer = { operation in
            try self.statusResult(NativeState(state: operation == "capacity_manual_refresh" ? "held" : "idle",
                                              reason: operation == "capacity_manual_refresh" ? "native_retirement_contract_unavailable" : "ok"))
        }
        let receipt = await actions.roll(paneID: pane.id.uuidString.lowercased())
        #expect(native.operations == ["capacity_status", "capacity_manual_refresh"])
        let sent = try #require(native.requests.last)
        #expect(sent.pane == pane.id.uuidString.lowercased() && sent.revision == 1 && sent.target == nil, "no account change rides on a refresh")
        #expect(receipt == "held: native_retirement_contract_unavailable", "the native refusal is shown as is")
        #expect(actions.receipts[RelayControlCenterActions.key(pane.id.uuidString.lowercased(), "roll")] == receipt)

        // Transport failure is a held outcome, never a retry.
        native.requests = []
        native.answer = { _ in throw RelayHostRotationRPC.Failure.unavailable }
        let failed = await actions.roll(paneID: pane.id.uuidString.lowercased())
        #expect(failed.hasPrefix("Native operation held or outcome unknown"))
        #expect(native.operations == ["capacity_status"], "no refresh was sent after a failed read")

        // Only the panel's own operations are accepted, never a move.
        native.requests = []
        let refused = await coordinator.userAction("capacity_manual_move", pane: pane)
        #expect(refused.hasPrefix("Refused") && native.requests.isEmpty)
        // An unknown pane is refused before any request.
        let unknown = await actions.roll(paneID: UUID().uuidString.lowercased())
        #expect(unknown == "Refused" && native.requests.isEmpty)
    }

    @Test func planningControlsAreTheCapacityPanelsOperations() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let pane = try #require(workspace.activePane)
        let native = Native { _ in try self.statusResult(NativeState()) }
        native.pane = pane.id.uuidString.lowercased()
        let coordinator = RelayCapacityManagementCoordinator(readExchange: native.exchange(),
                                                              budget: RelayBudgetSupervisor(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let actions = RelayControlCenterActions(workspace: workspace, capacity: coordinator)
        let id = pane.id.uuidString.lowercased()
        for operation in ["capacity_enroll", "capacity_pause", "capacity_resume"] {
            native.requests = []
            await actions.nativeAction(operation, paneID: id, label: "plan")
            #expect(native.operations == ["capacity_status", operation])
        }
        native.requests = []
        _ = await actions.setContextPolicy(paneID: id, contextEnabled: false, thresholdTokens: 200_000)
        #expect(native.operations == ["capacity_status", "capacity_configure"])
    }

    // MARK: Account move (item 4)

    @Test func moveIsTheAgentAccountsMenusCallWithUserOrigin() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let pane = try #require(workspace.activePane)
        let mover = RelayAgentAccountMove()
        var seen: [(UUID, String)] = []
        mover.capacityRoute = { _ in true }
        mover.capacityAction = { pane, target in seen.append((pane.id, target.label)); return "native_retirement_contract_unavailable" }
        mover.sendExit = { _, _, _, _ in Issue.record("the legacy exit must not run"); return false }
        let actions = RelayControlCenterActions(workspace: workspace, mover: mover)
        let target = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")
        let outcome = try #require(await actions.move(paneID: pane.id.uuidString.lowercased(), to: target))
        // The same outcome move(... origin: .user ...) gives: "held" through the combined lane, receipt shown.
        #expect(outcome.state == "held" && seen.count == 1 && seen[0] == (pane.id, "personal"))
        #expect(actions.receipts[RelayControlCenterActions.key(pane.id.uuidString.lowercased(), "move")] == "held: native_retirement_contract_unavailable")
        // Its refusals are the existing policy's: Miko, maintenance and an ungranted MCP origin cannot move.
        for origin in [RelayAgentAccountMoveOrigin.assistant, .maintenance] {
            #expect(RelayAgentAccountMovePolicy.originRefusal(origin, inputGranted: true) != nil)
        }
        #expect(RelayAgentAccountMovePolicy.originRefusal(.mcp, inputGranted: false) != nil)
        #expect(RelayAgentAccountMovePolicy.originRefusal(.user, inputGranted: false) == nil)
        // A pane that is not open is refused before any move.
        #expect(await actions.move(paneID: UUID().uuidString.lowercased(), to: target) == nil)
        #expect(seen.count == 1)
    }

    // MARK: Negatives: no tool, peer or pane-text path reaches the actions

    @Test func noToolRouteOrPaneTextReachesTheActionsOrTheSupervisorsSettings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Relay")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        let allowedForActions: Set<String> = ["RelayControlCenterActions.swift", "RelayControlCenter.swift"]
        let allowedForBudget: Set<String> = ["RelayBudgetSupervisor.swift", "RelayControlCenter.swift",
            "RelayControlCenterActions.swift", "RelayCapacityManagement.swift", "RelayAttentionNotifier.swift"]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            if !allowedForActions.contains(file) {
                #expect(!text.contains("RelayControlCenterActions"), "\(file) must not reach the Control actions")
            }
            if !allowedForBudget.contains(file) {
                #expect(!text.contains("accountNoticePercent") && !text.contains("noticeKey"), "\(file) must not set the notice level")
            }
        }
        // The supervisor's user setting is not a Miko tool, and no tool name mentions it.
        let names = Set(RelayAssistantToolName.allCases.map(\.rawValue)).union(RelayMikoToolCatalog.names)
        #expect(!names.contains { $0.contains("budget") || $0.contains("notice") || $0.contains("control_center") })
        // Account moves stay user-only: the assistant origin is refused and the only caller with .user is the Control/Accounts UI.
        #expect(RelayAgentAccountMovePolicy.originRefusal(.assistant, inputGranted: true) != nil)
        // The Control actions file has exactly the existing entry points and no route or tool name.
        let actions = try String(contentsOf: sources.appendingPathComponent("RelayControlCenterActions.swift"), encoding: .utf8)
        for forbidden in ["relay_", "Authorization", "URLSession", "route(", "mcpWorkspaceGrant", "origin: .mcp", "origin: .assistant"] {
            #expect(!actions.contains(forbidden), "Control actions must not contain \(forbidden)")
        }
    }

    // MARK: Item 5: the 48.82% incident

    private struct Supervised {
        let workspace: WorkspaceModel
        let pane: PaneModel
        let native: Native
        let coordinator: RelayCapacityManagementCoordinator
        let budget: RelayBudgetSupervisor
        var notices: Box<[RelayBudgetNotice]>
        var prompt: Box<Bool?>
        var paused: Box<Bool>
        var approval: Box<Bool>
        var context: Box<RelayPaneContextObservation?>
    }
    @MainActor final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    private func supervised(native state: NativeState = NativeState(), operationAfter: (@MainActor (String) -> [String: Any])? = nil) throws -> Supervised {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let pane = try #require(workspace.activePane)
        var live = state
        var nativeRef: Native?
        let native = Native { operation in
            if operation == "capacity_observe", let operationAfter { live.operation = operationAfter(nativeRef?.lastID ?? "") }
            return try self.statusResult(live)
        }
        nativeRef = native
        native.pane = pane.id.uuidString.lowercased()
        let budget = RelayBudgetSupervisor(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let notices = Box<[RelayBudgetNotice]>([])
        let prompt = Box<Bool?>(true), paused = Box(false), approval = Box(false)
        // The incident: 48.82% weekly on the account, enrolled nowhere, nothing verified.
        let context = Box<RelayPaneContextObservation?>(.init(supported: true, enabled: false, state: "not_enrolled", generation: nil,
            lifecycle: "unavailable", refreshCapability: "unverified", unavailable: "Native context status could not be verified"))
        budget.promptEmpty = { _ in prompt.value }
        budget.mikoPaused = { paused.value }
        budget.approvalPending = { _, _ in approval.value }
        budget.overview = { pane in .init(paneID: pane.id.uuidString.lowercased(), name: "root", observationState: "fresh",
                                          worker: nil, context: context.value) }
        budget.accountUsage = { _ in [.init(provenance: "actual_dashboard", scope: "account personal (all chats on it)",
            window: "weekly", usedPercent: 48.82, source: "claude get_usage", readAt: nil)] }
        budget.notify = { notices.value.append($0) }
        let coordinator = RelayCapacityManagementCoordinator(readExchange: native.exchange(), budget: budget)
        return Supervised(workspace: workspace, pane: pane, native: native, coordinator: coordinator, budget: budget,
                          notices: notices, prompt: prompt, paused: paused, approval: approval, context: context)
    }

    private func enroll(_ s: Supervised) {
        s.context.value = .init(supported: true, enabled: true, state: "enrolled", generation: 1, lifecycle: "idle",
                                refreshCapability: "supported", unavailable: nil)
    }

    private func observes(_ s: Supervised) -> Int { s.native.operations.filter { $0 == "capacity_observe" }.count }

    @Test func unenrolledOrUnverifiedPaneNotifiesWithReasonsAndNativeSubmissionIsUnchanged() async throws {
        let s = try supervised()
        defer { s.workspace.shutdown() }
        // The native policy submits (enabled, due) exactly as in M12; Miko's holds are notices only.
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date())
        #expect(observes(s) == 1, "the native submission is not gated by the holds")
        #expect(s.notices.value.count == 1)
        let notice = try #require(s.notices.value.first)
        #expect(notice.holds.contains("enabled=false (state not_enrolled)"))
        #expect(notice.holds.contains("refresh_capability=unverified"))
        #expect(notice.holds.contains("lifecycle=unavailable"))
        #expect(notice.holds.contains("Native context status could not be verified"))
        #expect(notice.signals.contains { $0.hasPrefix("long context: 150000 measured tokens") })
        #expect(notice.signals.contains { $0.contains("48.82%") && $0.contains("actual_dashboard") && $0.contains("not attributed to this chat") })
        // It persists until resolved, without notifying again for the same condition.
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date().addingTimeInterval(60))
        #expect(s.notices.value.count == 1 && observes(s) == 1, "sticky: still exactly one")
        #expect(s.budget.notices[s.pane.id] != nil && s.budget.assessments[s.pane.id]?.managementUnavailable == true)
        // The Control state says so and never "supervised" or "OK".
        var input = RelayControlCenterState.Inputs(ownership: .empty, tabs: [])
        input.tabs = [.init(id: UUID(), name: "T", panes: [.init(row: .init(id: s.pane.id.uuidString.lowercased(), name: "p", host: "This Mac",
            directory: nil, contentKind: "terminal", terminalAvailable: true, agent: "claude", phase: "idle", connection: "Connected",
            selected: false, summary: "", account: "personal"), hostKey: "local", isClaude: true)])]
        input.health = [.init(paneID: s.pane.id.uuidString.lowercased(), name: "root", observationState: "fresh", worker: nil, context: s.context.value)]
        input.assessments = s.budget.assessments
        input.budgetNotices = Array(s.budget.notices.values)
        let state = RelayControlCenterState.build(input)
        let row = try #require(state.unowned.first?.panes.first)
        #expect(row.supervision.management == "management unavailable")
        #expect(row.supervision.holds == notice.holds && row.supervision.signals == notice.signals)
        #expect(state.notices.map(\.paneID) == [s.pane.id])
        for text in [row.supervision.management] + row.supervision.holds {
            #expect(!text.localizedCaseInsensitiveContains("supervised") && text != "OK")
        }
        // Enrolling and verifying resolves it: the notice goes away.
        enroll(s)
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date().addingTimeInterval(120))
        #expect(s.budget.notices[s.pane.id] == nil)
    }

    private func completedOperation(_ id: String, receipt: Any = "r1", session: String = "session-1") -> [String: Any] {
        ["state": "completed", "reason": "", "receipt": receipt, "plan": ["id": id, "source": ["session": session]]]
    }

    @Test func enrolledSupportedAuthorizedOverThresholdRollsExactlyOnceAndNeverClaimsResumption() async throws {
        let s = try supervised(operationAfter: { self.completedOperation($0) })
        defer { s.workspace.shutdown() }
        enroll(s)
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date())
        #expect(observes(s) == 1, "exactly one roll through the existing capacity_observe submission")
        let roll = try #require(s.budget.rolls[s.pane.id])
        #expect(roll.completed, "\(roll.checks)")
        #expect(roll.receipt == "completed")
        #expect(roll.label == "operation reported completed; resumption unverified")
        #expect(!roll.label.localizedCaseInsensitiveContains("task resumed") && !roll.label.contains("verified resumed"))
        #expect(s.notices.value.isEmpty, "a manageable pane is not a 'management unavailable' notice")
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date().addingTimeInterval(60))
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date().addingTimeInterval(120))
        #expect(observes(s) == 1, "never a second roll")
        // No model or account change as a side effect.
        #expect(Set(s.native.operations).isSubset(of: ["capacity_status", "capacity_observe"]))
        #expect(s.native.requests.allSatisfy { $0.target == nil })
    }

    @Test func aRollThatIsHeldOrForAnotherOperationIsNotConfirmed() async throws {
        let s = try supervised(operationAfter: { _ in
            ["state": "held", "reason": "target_capacity_or_reset_fence_unavailable"] })
        defer { s.workspace.shutdown() }
        enroll(s)
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date())
        let roll = try #require(s.budget.rolls[s.pane.id])
        #expect(!roll.completed && roll.receipt == "held: target_capacity_or_reset_fence_unavailable")
        #expect(roll.label.hasPrefix("operation not confirmed complete"))
        // A completed operation whose plan id is not the submitted id is not this roll's.
        let s2 = try supervised(operationAfter: { _ in self.completedOperation("someone-elses-operation") })
        defer { s2.workspace.shutdown() }
        enroll(s2)
        await s2.coordinator.evaluate(s2.pane, workspace: s2.workspace, now: Date())
        let other = try #require(s2.budget.rolls[s2.pane.id])
        #expect(!other.completed && other.checks.contains { $0.hasPrefix("NOT verified: plan id") })
    }

    private func decoded(source: [String: Any]?, operation: [String: Any]?) throws -> RelayCapacityManagement.Status {
        var result = try statusResult(NativeState(operation: operation))
        result["source"] = source
        return try RelayCapacityManagement.decode(
            JSONSerialization.data(withJSONObject: ["request_id": "r", "result": result]), requestID: "r")
    }

    @Test func verificationRequiresIdentityAndACorrelatedReceipt() throws {
        let pane = UUID(), pid = pane.uuidString.lowercased()
        let good: [String: Any] = ["pane": pid, "provider": "claude", "session": "session-1", "binding": "b1"]
        func run(before: [String: Any]?, after: [String: Any]?, operation: [String: Any]?, id: String = "op1")
            throws -> (Bool, String, [String]) {
            RelayBudgetSupervisor.verify(paneID: pane, before: try decoded(source: before, operation: nil),
                                         after: try decoded(source: after, operation: operation), operationID: id)
        }
        let op = completedOperation("op1")
        // Positive: still labelled "resumption unverified".
        let ok = try run(before: good, after: good, operation: op)
        #expect(ok.0 && ok.1 == RelayBudgetSupervisor.completedLabel)
        // Two absent providers are not equal.
        var noProvider = good; noProvider["provider"] = nil
        #expect(try run(before: noProvider, after: noProvider, operation: op).0 == false)
        var emptyProvider = good; emptyProvider["provider"] = ""
        #expect(try run(before: emptyProvider, after: emptyProvider, operation: op).0 == false)
        // A missing binding is not allowed.
        var noBinding = good; noBinding["binding"] = nil
        #expect(try run(before: good, after: noBinding, operation: op).0 == false)
        #expect(try run(before: noBinding, after: good, operation: op).0 == false)
        // A different operation id.
        #expect(try run(before: good, after: good, operation: op, id: "op2").0 == false)
        // Receipts that are false, empty or missing prove nothing.
        #expect(try run(before: good, after: good, operation: completedOperation("op1", receipt: false)).0 == false)
        #expect(try run(before: good, after: good, operation: completedOperation("op1", receipt: "")).0 == false)
        var missing = completedOperation("op1"); missing["receipt"] = nil
        #expect(try run(before: good, after: good, operation: missing).0 == false)
        // An object receipt is not even a valid native response.
        #expect(throws: (any Error).self) { _ = try decoded(source: good, operation: completedOperation("op1", receipt: ["id": "x"])) }
        // The fixture receipt "r1" alone, without a correlated plan id, is not proof.
        var bare = completedOperation("op1"); bare["plan"] = ["source": ["session": "session-1"]]
        #expect(try run(before: good, after: good, operation: bare).0 == false)
        // Another pane's identity.
        var otherPane = good; otherPane["pane"] = UUID().uuidString.lowercased()
        #expect(try run(before: good, after: otherPane, operation: op).0 == false)
    }

    @Test func aPersistentHoldNotifiesOnceWhateverTheNumbersDoAndAgainAfterItResolves() async throws {
        let s = try supervised(native: NativeState(measured: 150_000, due: false))
        defer { s.workspace.shutdown() }
        var percent = 48.82
        s.budget.accountUsage = { _ in [.init(provenance: "actual_dashboard", scope: "account personal (all chats on it)",
            window: "weekly", usedPercent: percent, source: nil, readAt: nil)] }
        let t0 = Date()
        for step in 0..<4 {
            percent += 3
            s.native.answer = { _ in try self.statusResult(NativeState(measured: 150_000 + Int64(step) * 40_000, due: false)) }
            await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: t0.addingTimeInterval(Double(step) * 60))
        }
        #expect(s.notices.value.count == 1, "rising tokens and percentages are not a new condition")
        #expect(s.budget.notices[s.pane.id]?.signals.contains { $0.contains("%") && $0.contains("weekly") } == true)
        #expect(s.budget.notices[s.pane.id]?.signals.joined().contains(String(format: "%.2f", percent)) == true, "latest numbers kept for display")
        // Resolved: enrolled and manageable, so the notice goes.
        enroll(s)
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: t0.addingTimeInterval(600))
        #expect(s.budget.notices[s.pane.id] == nil)
        // It recurs: a new banner.
        s.context.value = nil
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: t0.addingTimeInterval(700))
        #expect(s.notices.value.count == 2)
    }

    @Test func anAccountTotalAloneNeverTitlesAPaneAsCostly() {
        let id = UUID()
        let account = RelayBudgetNotice(paneID: id, name: "root", signals: ["account usage weekly 48.82% [actual_dashboard] x"],
            signalKeys: ["account_usage:weekly"], holds: ["enabled=false (state not_enrolled)"], at: Date())
        #expect(account.accountOnly && account.title.contains("account usage is high (account total, all chats)"))
        #expect(!account.title.contains("is costly"))
        let pane = RelayBudgetNotice(paneID: id, name: "root", signals: ["long context: 1"],
            signalKeys: ["long_context", "account_usage:weekly"], holds: ["x"], at: Date())
        #expect(!pane.accountOnly && pane.title == "Relay: root is costly and cannot be managed")
    }

    @Test func aStaleCardClickNeverActsOnALaterCard() async throws {
        let f = try cardFixture()
        defer { f.workspace.shutdown() }
        let first = Task { await f.assistant.run("one", origin: .user) }
        let a = try await waitForCard(f.assistant)
        f.assistant.cancelCard()               // A is resolved elsewhere before the feed refreshes
        _ = await first.value
        let second = Task { await f.assistant.run("two", origin: .user) }
        let b = try await waitForCard(f.assistant)
        #expect(a.id != b.id)
        #expect(f.actions.runCard(id: a.id) == false)
        #expect(f.assistant.pendingCard?.id == b.id && f.executor.calls.isEmpty, "a stale Run does nothing to B")
        #expect(f.actions.cancelCard(id: a.id) == false)
        #expect(f.assistant.pendingCard?.id == b.id, "a stale Cancel does nothing to B")
        #expect(f.actions.cancelCard(id: b.id), "the matching current card still works")
        _ = await second.value
        #expect(f.assistant.pendingCard == nil && f.executor.calls.isEmpty)
        #expect(f.actions.runCard(id: b.id) == false, "nothing is pending any more")
    }

    @Test func everyHoldIsANoticeAndNeverStopsTheNativeAutomaticSubmission() async throws {
        let cases: [(String, (Supervised) -> Void, String)] = [
            ("opt out", { _ in }, "disabled by you for this pane (opt_out)"),
            ("human takeover", { _ in }, "disabled by your input in this pane (human takeover)"),
            ("approval", { $0.approval.value = true }, "held for approval"),
            ("paused", { $0.paused.value = true }, "Miko is paused by you"),
            ("prompt not empty", { $0.prompt.value = false }, "prompt not empty"),
            ("prompt unknown", { $0.prompt.value = nil }, "prompt_empty unknown"),
        ]
        for (name, arrange, reason) in cases {
            var state = NativeState()
            if name == "opt out" { state.entry = ["opt_out": true] }
            if name == "human takeover" { state.entry = ["human_takeover": true] }
            let s = try supervised(native: state)
            defer { s.workspace.shutdown() }
            enroll(s)
            arrange(s)
            await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date())
            await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date().addingTimeInterval(60))
            #expect(observes(s) == 1, "\(name): the due native submission goes out exactly once")
            let notice = try #require(s.notices.value.first, "\(name): the user is still told")
            #expect(notice.holds.contains { $0.hasPrefix(reason) }, "\(name): \(notice.holds)")
            #expect(Set(s.native.operations).isSubset(of: ["capacity_status", "capacity_observe"]))
            #expect(s.native.requests.allSatisfy { $0.target == nil }, "\(name): no account change")
        }
    }

    @Test func everyDueLaneIsSubmittedUnchangedWhateverTheHolds() async throws {
        // context, quota, return and rebalance: each alone is a due lane, held or not.
        for lane in ["context_due", "quota_due", "return_due", "rebalance_due"] {
            let s = try supervised(native: NativeState(measured: nil, due: false))
            defer { s.workspace.shutdown() }
            s.native.answer = { _ in
                var result = try self.statusResult(NativeState(measured: nil, due: false))
                var decision = try #require(result["decision"] as? [String: Any])
                decision[lane] = true
                result["decision"] = decision
                return result
            }
            s.prompt.value = nil   // unknown prompt: the live case
            await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date())
            #expect(observes(s) == 1, "\(lane)")
        }
        let note = RelayBudgetSupervisor.gateNote
        #expect(note.contains("runs as before") && note.contains("do not stop Relay's native automatic requests"))
        #expect(!note.contains("incomplete") && !note.localizedCaseInsensitiveContains("holds every"))
    }

    @Test func aPendingApprovalCardForTheSamePaneHoldsTheRoll() async throws {
        let f = try cardFixture()
        defer { f.workspace.shutdown() }
        let task = Task { await f.assistant.run("say hi", origin: .agent(paneID: f.pane, label: "agent")) }
        let shownCard = try await waitForCard(f.assistant)
        let supervisor = RelayBudgetSupervisor(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let pane = try #require(f.workspace.panes[f.pane])
        #expect(supervisor.approvalPending(pane, f.workspace), "the default source sees the pane's own card")
        #expect(!supervisor.approvalPending(PaneModel(id: UUID(), profile: pane.profile), f.workspace))
        f.actions.cancelCard(id: shownCard.id)
        _ = await task.value
        #expect(!supervisor.approvalPending(pane, f.workspace))
    }

    @Test func noTurnOrWakeupIsGeneratedAndTheCadenceIsOneStatusReadPerObservation() async throws {
        let f = try cardFixture()
        defer { f.workspace.shutdown() }
        let s = try supervised(native: NativeState(due: false))
        defer { s.workspace.shutdown() }
        enroll(s)
        for step in 0..<5 { await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: Date().addingTimeInterval(Double(step) * 60)) }
        #expect(s.native.operations == Array(repeating: "capacity_status", count: 5), "one native read each, no polling")
        #expect(f.model.requests == 0 && f.assistant.exchanges.isEmpty, "no Miko turn")
        // The supervisor has no timer, no model and no harness of its own.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Relay/RelayBudgetSupervisor.swift"), encoding: .utf8)
        for forbidden in ["Timer", "Task.sleep", "Task {", ".run(", "submitAgent", "capacity_manual_move",
                          "targetAccount", "RelayAgentAccountMove"] {
            #expect(!source.contains(forbidden), "the supervisor must not contain \(forbidden)")
        }
    }

    @Test func fastRiseAndDefaultsDoNotEnableAnyAutomaticAction() async throws {
        let s = try supervised(native: NativeState(measured: 20_000, due: false))
        defer { s.workspace.shutdown() }
        let t0 = Date()
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: t0)
        #expect(s.budget.assessments[s.pane.id]?.signals.contains { $0.hasPrefix("fast rise") } == false)
        s.native.answer = { _ in try self.statusResult(NativeState(measured: 60_000, due: false)) }
        await s.coordinator.evaluate(s.pane, workspace: s.workspace, now: t0.addingTimeInterval(120))
        #expect(s.budget.assessments[s.pane.id]?.signals.contains { $0.hasPrefix("fast rise: +40000 tokens in 120 s") } == true)
        #expect(s.native.operations.allSatisfy { $0 == "capacity_status" }, "a signal alone starts nothing")
        // The user's notice level defaults to a notification threshold, never an action.
        #expect(s.budget.accountNoticePercent == RelayBudgetSupervisor.defaultAccountNoticePercent)
        let native = RelayCapacityManagement.Settings()
        #expect(native.quotaEnabled == false && native.newPaneDefault == true, "the native defaults are untouched by this slice")
    }

    // MARK: Per-chat usage, queued asks

    @Test func perChatUsageIsUnavailableAndNoPercentIsDerived() throws {
        let id = UUID()
        let usage = RelayAgentAccountUsage(provider: "claude", label: "personal", status: "ok", reason: nil, source: "claude get_usage",
            readAt: "2026-11-03T17:00:00Z", windows: [.init(name: "seven_day", usedPercent: 48.82, resetsAt: nil, windowMinutes: 10080)])
        var input = RelayControlCenterState.Inputs(ownership: .empty, tabs: [
            .init(id: UUID(), name: "T", panes: [.init(row: .init(id: id.uuidString.lowercased(), name: "p", host: "This Mac", directory: nil,
                contentKind: "terminal", terminalAvailable: true, agent: "claude", phase: "idle", connection: "Connected", selected: false,
                summary: "", account: "personal"), hostKey: "local", isClaude: true, accountUsage: usage)])])
        input.capacity[id] = try RelayCapacityManagement.decode(
            JSONSerialization.data(withJSONObject: ["request_id": "r", "result": statusResult(NativeState())]), requestID: "r")
        let pane = try #require(RelayControlCenterState.build(input).unowned.first?.panes.first)
        #expect(pane.supervision.perChat.hasPrefix("per-chat usage unavailable"))
        #expect(pane.supervision.usage.allSatisfy { $0.provenance == "actual_dashboard" && $0.scope.contains("all chats") },
                "only the labelled account reading is shown; nothing per chat is derived from it or from tokens")
        #expect(pane.capacity?.measuredTokens == 150_000, "tokens are shown as tokens")
        #expect(pane.supervision.usage.map(\.usedPercent) == [48.82])
    }

    @Test func queuedAsksAreDisclosedAsNotListed() throws {
        let text = RelayControlCenterState.askDisclosure
        #expect(text.contains("not listed here") && text.contains("does not mean no ask is pending"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Relay/RelayControlCenter.swift"), encoding: .utf8)
        #expect(view.contains("Text(RelayControlCenterState.askDisclosure)"), "the section always shows it")
        var input = RelayControlCenterState.Inputs(ownership: .empty, tabs: [])
        input.busy = true
        #expect(RelayControlCenterState.build(input).mikoBusy, "whether Miko is busy is shown")
    }
}
