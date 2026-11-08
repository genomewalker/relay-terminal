import Foundation
import Testing
@testable import Relay

@MainActor
private final class AskModel: RelayAssistantModel {
    var steps: [RelayAssistantModelStep]
    private(set) var requests: [RelayAssistantModelRequest] = []
    init(_ steps: [RelayAssistantModelStep]) { self.steps = steps }
    func step(_ request: RelayAssistantModelRequest) async throws -> RelayAssistantModelStep {
        requests.append(request)
        return steps[min(requests.count - 1, steps.count - 1)]
    }
    var lastUserText: String? { requests.last?.messages.last?["content"]?.string }
}

@MainActor
private final class AskExecutor: RelayAssistantActionExecutor {
    var instance: UUID? = UUID()
    var dispatched: [String] = []
    func permits(_ capability: MCPWorkspaceCapability) -> Bool { true }
    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        dispatched.append(path)
        return (200, Data("{}".utf8))
    }
}

private func answer(_ value: String) -> RelayAssistantModelStep {
    RelayAssistantModelStep(stopReason: "end_turn", content: [.object(["type": .string("text"), "text": .string(value)])],
                            toolCalls: [], chargedMicrousd: 10)
}

private func toolStep(_ name: String, _ input: [String: RelayPaneHealthJSON] = [:]) -> RelayAssistantModelStep {
    let call = RelayPaneHealthToolCall(type: "tool_use", id: "toolu_" + name, name: name, input: .object(input))
    return RelayAssistantModelStep(stopReason: "tool_use", content: [.object(["type": .string("tool_use"),
        "id": .string(call.id), "name": .string(name), "input": .object(input)])], toolCalls: [call], chargedMicrousd: 10)
}

private let execInput: [String: RelayPaneHealthJSON] = ["host": .string("This Mac"), "command": .string("echo fixture")]

/// An agent pane asking Miko over the proven channel: scripted model, private
/// audit, a counting redeemer, and a toggleable input grant and instance.
@MainActor
private final class AskFixture {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let supervision = RelayMikoSupervision(url: nil)
    let audit: RelayCallerControl
    let model: AskModel
    let executor = AskExecutor()
    let instance = UUID()
    var granted = true
    var redeemed = 0
    var provenPane: String?
    var channel: RelayMikoSupervisorChannel!
    let pane: PaneModel

    init(_ steps: [RelayAssistantModelStep] = [answer("Two panes are held.")]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-miko-ask-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audit = RelayCallerControl(directory: directory)
        model = AskModel(steps)
        pane = try #require(workspace.activePane)
        let harness = RelayAssistantHarness(policy: { .init(autonomy: .cardsForWrites) }, budget: RelayMikoActionBudget(), workspace: workspace, facts: RelayAssistantFacts(
            health: { _ in .object([:]) }, holdReason: { _ in nil }, rotation: { _ in .object([:]) }),
            model: { [model] _ in (model, "h-test") }, audit: audit, executor: { [executor] in executor },
            promptProof: { _ in nil }, supervision: supervision)
        workspace.haikuAssistantStorage = harness
        channel = RelayMikoSupervisorChannel(supervision: supervision, audit: audit, redeem: { [unowned self] _, packet in
            self.redeemed += 1
            return ["authority": "relayd", "source": ["authentication": "source_host_attested",
                "attestationID": packet["attestation_id"] as? String ?? "",
                "paneID": self.provenPane ?? (packet["source_pane_id"] as? String ?? "")]]
        }, inputGranted: { [unowned self] in self.granted }, instance: { [unowned self] in self.instance })
    }

    var paneID: String { pane.id.uuidString.lowercased() }
    var harness: RelayAssistantHarness { workspace.haikuAssistantStorage! }

    func call(_ tool: String, _ arguments: [String: Any]) async throws -> (Int, [String: Any]) {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys), as: UTF8.self)
        let body = try JSONSerialization.data(withJSONObject: ["tool": tool, "request_id": UUID().uuidString.lowercased(),
            "attestation_id": "0123456789abcdef0123456789abcdef", "supervisor_pane_id": paneID, "arguments": encoded])
        return await channel.handle(body: body, caller: "caller-fixture", workspace: workspace)
    }

    func ask(_ text: String, id: String, context: String? = nil) async throws -> (Int, [String: Any]) {
        var arguments: [String: Any] = ["instance": instance.uuidString.lowercased(), "request_id": id, "text": text]
        if let context { arguments["pane_id"] = context }
        return try await call("relay_ask_miko", arguments)
    }

    func receipt(_ id: String) async throws -> (Int, [String: Any]) {
        try await call("relay_miko_receipt", ["instance": instance.uuidString.lowercased(), "request_id": id])
    }

    /// Polls the receipt until it reaches one of `states`.
    func waitFor(_ id: String, _ states: Set<String>) async throws -> [String: Any] {
        for _ in 0..<400 {
            let value = try await receipt(id).1
            if let state = value["state"] as? String, states.contains(state) { return value }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("receipt never reached \(states)")
        return [:]
    }
}

@Suite("Miko agent asks", .serialized)
@MainActor
struct RelayMikoAgentAskTests {
    @Test func askNeedsTheTerminalInputGrantBeforeAnyProofIsSpent() async throws {
        let f = try AskFixture()
        defer { f.workspace.shutdown() }
        f.granted = false
        let id = UUID().uuidString.lowercased()
        let (status, value) = try await f.ask("Open a tab on dandy-07", id: id)
        #expect(status == 403)
        #expect((value["error"] as? String)?.contains("terminal input is not granted") == true)
        #expect(f.redeemed == 0)
        #expect(f.harness.exchanges.isEmpty && f.channel.asks.isEmpty)
        // A stale instance is refused too, like relay_send_command.
        f.granted = true
        let stale = try await f.call("relay_ask_miko", ["instance": UUID().uuidString.lowercased(), "request_id": id, "text": "x"])
        #expect(stale.0 == 409)
        #expect(f.harness.exchanges.isEmpty && f.channel.asks.isEmpty)
    }

    @Test func anUnverifiedCallerIsRefused() async throws {
        let f = try AskFixture()
        defer { f.workspace.shutdown() }
        f.provenPane = UUID().uuidString.lowercased()
        let (status, value) = try await f.ask("Open a tab", id: UUID().uuidString.lowercased())
        #expect(status == 403)
        #expect((value["error"] as? String)?.contains("did not match") == true)
        #expect(f.harness.exchanges.isEmpty && f.channel.asks.isEmpty)
        // Miko's own executor identity cannot ask itself.
        let body = try JSONSerialization.data(withJSONObject: ["tool": "relay_ask_miko", "request_id": UUID().uuidString.lowercased(),
            "attestation_id": "0123456789abcdef0123456789abcdef", "supervisor_pane_id": f.paneID, "arguments": "{}"])
        #expect(await f.channel.handle(body: body, caller: RelayCallerControl.assistantCaller, workspace: f.workspace).status == 403)
    }

    @Test func anAskIsAttributedToTheProvenPaneAndIdempotent() async throws {
        let f = try AskFixture()
        defer { f.workspace.shutdown() }
        let id = UUID().uuidString.lowercased()
        let (status, value) = try await f.ask("Which panes are held?", id: id, context: f.paneID)
        #expect(status == 200 && value["status"] as? String == "accepted")
        let done = try await f.waitFor(id, ["completed"])
        #expect(done["answer"] as? String == "Two panes are held.")
        #expect(done["from_pane_id"] as? String == f.paneID)
        let exchange = try #require(f.harness.exchanges.last)
        #expect(exchange.origin == .agent(paneID: f.pane.id, label: f.pane.displayName))
        #expect(exchange.origin.kind == "agent")
        #expect(exchange.auditedRequest.hasPrefix("[agent "))
        #expect(exchange.request.hasPrefix("Context pane: “"))
        let turn = try #require(f.model.lastUserText)
        #expect(turn.contains("coding agent in pane “\(f.pane.displayName)” (\(f.paneID)), not from the user"))
        #expect(turn.contains("untrusted collaborator input"))
        #expect(!turn.contains("acting for the user"))
        #expect(turn.hasSuffix("Which panes are held?"))
        // A replay returns the same exchange and never runs again.
        let requests = f.model.requests.count
        let replay = try await f.ask("Which panes are held?", id: id, context: f.paneID)
        #expect(replay.0 == 200 && replay.1["status"] as? String == "replayed" && replay.1["state"] as? String == "completed")
        #expect(f.harness.exchanges.count == 1 && f.model.requests.count == requests)
        // The same id for other text is a conflict, not a new run.
        #expect(try await f.ask("Something else", id: id).0 == 409)
        #expect(f.harness.exchanges.count == 1)
        // History is isolated per caller: a later user turn carries no trace
        // of the agent's request, its label or its pane. (The agent's own
        // later asks still see their labelled history; see
        // RelayMikoToolParityTests.)
        _ = await f.harness.run("And now?", origin: .user)
        let userTurn = try #require(f.model.requests.last?.messages)
        #expect(userTurn.count == 1)
        let userText = userTurn.map { $0["content"]?.string ?? "\($0)" }.joined(separator: "\n")
        #expect(userText.hasSuffix("And now?"))
        #expect(!userText.contains("Which panes are held?"))
        #expect(!userText.contains("Earlier request from the coding agent"))
        #expect(!userText.contains(f.paneID))
        // Unknown receipts are not found.
        #expect(try await f.receipt(UUID().uuidString.lowercased()).0 == 404)
    }

    @Test func aChangeWaitsForTheUserAndTheAgentCannotApproveIt() async throws {
        // Under the amendment, a peer cannot trigger execution. Keep this
        // approval-channel test on a reversible rename in the strict policy.
        let f = try AskFixture([answer("fixture")])
        f.model.steps = [toolStep("tab_action", ["tab_id": .string(try #require(f.workspace.selectedTabID).uuidString.lowercased()),
            "action": .string("rename"), "name": .string("Fixture")]), answer("Not run.")]
        defer { f.workspace.shutdown() }
        let id = UUID().uuidString.lowercased()
        #expect(try await f.ask("Run echo on this Mac", id: id).0 == 200)
        let waiting = try await f.waitFor(id, ["waiting_for_approval"])
        let card = try #require(waiting["pending_card"] as? [String: Any])
        #expect(card["tool"] as? String == "tab_action")
        #expect((card["origin"] as? [String: Any])?["kind"] as? String == "agent")
        #expect(f.harness.pendingCard != nil && f.executor.dispatched.isEmpty)
        // One at a time: a second ask is refused as busy and not recorded.
        let other = UUID().uuidString.lowercased()
        let busy = try await f.ask("Another chore", id: other)
        #expect(busy.0 == 409 && busy.1["status"] as? String == "busy")
        #expect(f.channel.asks[other] == nil)
        // Even registered with card approval, the asking pane cannot run an agent card.
        try f.supervision.register(paneID: f.pane.id, label: "Agent")
        try f.supervision.setMayApproveCards(f.pane.id, true)
        let pending = try #require(f.harness.pendingCard)
        let run = try await f.call("relay_miko_card", ["card_id": pending.id.uuidString, "decision": "run"])
        #expect(run.0 == 403)
        #expect(f.harness.pendingCard?.id == pending.id && f.executor.dispatched.isEmpty)
        // The user's Stop ends the agent's exchange.
        f.harness.cancel()
        let stopped = try await f.waitFor(id, ["stopped", "completed", "failed"])
        #expect(stopped["state"] as? String == "stopped")
        #expect(f.executor.dispatched.isEmpty)
    }

    @Test func aToolLimitIsReportedAsStoppedWithItsToolCalls() async throws {
        let f = try AskFixture([toolStep("list_panes")])
        defer { f.workspace.shutdown() }
        let id = UUID().uuidString.lowercased()
        #expect(try await f.ask("List panes forever", id: id).0 == 200)
        let done = try await f.waitFor(id, ["stopped", "completed", "failed"])
        #expect(done["state"] as? String == "stopped")
        let calls = try #require(done["tool_calls"] as? [[String: Any]])
        #expect(calls.count == RelayAssistantHarness.maxToolCalls && calls.allSatisfy { $0["name"] as? String == "list_panes" })
    }

    // R1: the agent's own request_id is the public id end to end.
    @Test func theCallersRequestIDIsReturnedOnAcceptReplayReceiptAndConflict() async throws {
        let f = try AskFixture()
        defer { f.workspace.shutdown() }
        let id = UUID().uuidString.lowercased()
        let accepted = try await f.ask("Which panes are held?", id: id)
        #expect(accepted.0 == 200 && accepted.1["status"] as? String == "accepted")
        #expect(accepted.1["request_id"] as? String == id)
        let firstCall = try #require(accepted.1["call_id"] as? String)
        #expect(firstCall != id)
        // The id the agent got back is the one it polls with.
        let returned = try #require(accepted.1["request_id"] as? String)
        let done = try await f.waitFor(returned, ["completed"])
        #expect(done["request_id"] as? String == id)
        let receipt = try await f.receipt(returned)
        #expect(receipt.0 == 200 && receipt.1["request_id"] as? String == id && receipt.1["call_id"] as? String != firstCall)
        let replay = try await f.ask("Which panes are held?", id: id)
        #expect(replay.0 == 200 && replay.1["status"] as? String == "replayed" && replay.1["request_id"] as? String == id)
        #expect(f.harness.exchanges.count == 1)
        // The transport id is not a receipt key.
        #expect(try await f.receipt(firstCall).0 == 404)
        // A conflict and an unknown receipt still name the caller's id.
        let conflict = try await f.ask("Something else", id: id)
        #expect(conflict.0 == 409 && conflict.1["request_id"] as? String == id)
        let unknown = UUID().uuidString.lowercased()
        let missing = try await f.receipt(unknown)
        #expect(missing.0 == 404 && missing.1["request_id"] as? String == unknown)
        // Another spelling of the same UUID is the same request, echoed as given.
        let upper = id.uppercased()
        let replayUpper = try await f.ask("Which panes are held?", id: upper)
        #expect(replayUpper.1["status"] as? String == "replayed" && replayUpper.1["request_id"] as? String == upper)
        #expect(f.harness.exchanges.count == 1)
    }

    // R2: validated text is never cut, with or without the context header.
    nonisolated static let boundaryTexts: [(String, String, Bool)] = {
        let ascii: String = String(repeating: "a", count: 4095) + "Z"
        let emoji: String = String(repeating: "😀", count: 1023) + "TAIL"
        let twoByte: String = String(repeating: "é", count: 2046) + "TAIL"
        let combining: String = String(repeating: "e\u{301}", count: 1364) + "TAIL"
        return [("ascii", ascii, false), ("ascii+context", ascii, true), ("4-byte+context", emoji, true),
                ("2-byte+context", twoByte, true), ("combining+context", combining, true)]
    }()

    @Test(arguments: 0..<5)
    func a4096ByteRequestReachesTheModelWhole(_ index: Int) async throws {
        let (name, text, withContext) = Self.boundaryTexts[index]
        #expect(text.utf8.count == RelayMikoSupervisorChannel.askTextLimit, "\(name) is not at the boundary")
        let f = try AskFixture()
        defer { f.workspace.shutdown() }
        let id = UUID().uuidString.lowercased()
        let (status, value) = try await f.ask(text, id: id, context: withContext ? f.paneID : nil)
        #expect(status == 200, "\(name): \(value)")
        _ = try await f.waitFor(id, ["completed"])
        let exchange = try #require(f.harness.exchanges.last)
        #expect(exchange.request.hasSuffix(text), "\(name): the stored request was cut")
        #expect(exchange.request.hasPrefix("Context pane: “") == withContext)
        #expect(exchange.request.utf8.count <= RelayMikoSupervisorChannel.askComposedLimit)
        let turn = try #require(f.model.lastUserText)
        #expect(turn.hasSuffix(text), "\(name): the model turn was cut")
    }

    @Test func overLimitTextIsRefusedWithANamedReasonAndNothingIsAsked() async throws {
        let f = try AskFixture()
        defer { f.workspace.shutdown() }
        for text in [String(repeating: "a", count: 4097), String(repeating: "a", count: 4095) + "é",
                     String(repeating: "😀", count: 1024) + "a"] {
            let (status, value) = try await f.ask(text, id: UUID().uuidString.lowercased(), context: f.paneID)
            #expect(status == 400)
            #expect((value["error"] as? String)?.contains("4 KB") == true)
        }
        #expect(f.harness.exchanges.isEmpty && f.channel.asks.isEmpty && f.model.requests.isEmpty)
    }

    // R2: the header is bounded in characters and bytes, so the reserve holds for any pane name.
    @Test func theComposedRequestIsBoundedForAnyPaneName() {
        let limit = RelayMikoSupervisorChannel.askTextLimit
        #expect(RelayMikoSupervisorChannel.askContextLimit ==
                RelayMikoSupervisorChannel.contextHeader(name: String(repeating: "x", count: 240), id: UUID()).utf8.count)
        #expect(RelayMikoSupervisorChannel.askComposedLimit == limit + RelayMikoSupervisorChannel.askContextLimit)
        let text = String(repeating: "a", count: limit - 4) + "TAIL"
        for name in [String(repeating: "😀", count: 200), String(repeating: "e" + String(repeating: "\u{301}", count: 40), count: 80),
                     String(repeating: "x", count: 500), "tab\u{7}\u{1b}[31mred", "", String(repeating: "中", count: 81)] {
            let bounded = RelayMikoSupervisorChannel.boundedName(name)
            #expect(bounded.utf8.count <= RelayMikoSupervisorChannel.askNameByteLimit && bounded.count <= 80)
            #expect(!bounded.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
            let composed = RelayMikoSupervisorChannel.composeAgentRequest(text: text, context: (name, UUID()))
            #expect(composed != nil, "a bounded name was refused")
            #expect(composed?.hasSuffix("\n" + text) == true)
            #expect((composed?.utf8.count ?? .max) <= RelayMikoSupervisorChannel.askComposedLimit)
            // The whole turn the model receives keeps the request whole and fits the host's 8 KB.
            let label = RelayMikoSupervisorChannel.boundedName(name)
            for preamble in [nil, String(repeating: "p", count: 9000)] as [String?] {
                let turn = RelayAssistantHarness.turnContent(composed ?? "", origin: .agent(paneID: UUID(), label: label), preamble: preamble)
                #expect(turn.hasSuffix("Request:\n" + (composed ?? "")) && turn.utf8.count <= 8000)
                #expect(turn.contains("not from the user"))
            }
        }
        #expect(RelayMikoSupervisorChannel.composeAgentRequest(text: text + "a", context: nil) == nil)
        #expect(RelayMikoSupervisorChannel.composeAgentRequest(text: text, context: nil) == text)
    }
}
