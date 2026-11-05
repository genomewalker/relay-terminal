import Foundation
import Testing
@testable import Relay

@MainActor
private final class SupervisedModel: RelayAssistantModel {
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
private final class SupervisedExecutor: RelayAssistantActionExecutor {
    var instance: UUID? = UUID()
    var dispatched = 0
    func permits(_ capability: MCPWorkspaceCapability) -> Bool { true }
    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data) { dispatched += 1; return (200, Data("{}".utf8)) }
}

private func text(_ value: String) -> RelayAssistantModelStep {
    RelayAssistantModelStep(stopReason: "end_turn", content: [.object(["type": .string("text"), "text": .string(value)])],
                            toolCalls: [], chargedMicrousd: 10)
}

private func call(_ name: String) -> RelayAssistantModelStep {
    let call = RelayPaneHealthToolCall(type: "tool_use", id: "toolu_" + name, name: name, input: .object([:]))
    return RelayAssistantModelStep(stopReason: "tool_use", content: [.object(["type": .string("tool_use"),
        "id": .string(call.id), "name": .string(name), "input": .object([:])])], toolCalls: [call], chargedMicrousd: 10)
}

/// A supervisor fixture: a workspace whose active pane can be registered, a
/// harness with a scripted model, a private audit and a counting redeemer.
@MainActor
private final class Fixture {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let supervision = RelayMikoSupervision(url: nil)
    let audit: RelayCallerControl
    let model: SupervisedModel
    let executor = SupervisedExecutor()
    var redeemed = 0
    /// What the supervisor pane's relayd says the proof proved.
    var provenPane: String?
    var beforeProof: (() -> Void)?
    var channel: RelayMikoSupervisorChannel!
    let pane: PaneModel

    init(_ steps: [RelayAssistantModelStep] = [text("Two panes are held.")]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-miko-supervisor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audit = RelayCallerControl(directory: directory)
        model = SupervisedModel(steps)
        pane = try #require(workspace.activePane)
        let harness = RelayAssistantHarness(policy: { .init(autonomy: .cardsForWrites) }, budget: RelayMikoActionBudget(), workspace: workspace, facts: RelayAssistantFacts(
            health: { _ in .object([:]) }, holdReason: { _ in nil }, rotation: { _ in .object([:]) }),
            model: { [model] _ in (model, "h-test") }, audit: audit, executor: { [executor] in executor },
            promptProof: { _ in nil }, supervision: supervision)
        workspace.haikuAssistantStorage = harness
        channel = RelayMikoSupervisorChannel(supervision: supervision, audit: audit, redeem: { [unowned self] _, packet in
            self.redeemed += 1
            self.beforeProof?()
            return ["authority": "relayd", "source": ["authentication": "source_host_attested",
                "attestationID": packet["attestation_id"] as? String ?? "",
                "paneID": self.provenPane ?? (packet["source_pane_id"] as? String ?? "")]]
        })
    }

    var paneID: String { pane.id.uuidString.lowercased() }
    var harness: RelayAssistantHarness { workspace.haikuAssistantStorage! }

    func register() throws { try supervision.register(paneID: pane.id, label: "Supervisor fixture") }

    func call(_ tool: String, _ arguments: [String: Any] = [:], from source: String? = nil,
              caller: String = "caller-fixture") async throws -> (Int, [String: Any]) {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys), as: UTF8.self)
        let body = try JSONSerialization.data(withJSONObject: ["tool": tool, "request_id": UUID().uuidString.lowercased(),
            "attestation_id": "0123456789abcdef0123456789abcdef", "supervisor_pane_id": source ?? paneID, "arguments": encoded])
        let (status, value) = await channel.handle(body: body, caller: caller, workspace: workspace)
        return (status, value)
    }

    func supervisorRecords() -> [RelayCallerControl.Audit] { audit.audit().filter { $0.caller == RelayCallerControl.supervisorCaller } }
}


@Suite("Reviewer Miko corrections at dispatch", .serialized)
@MainActor
struct ReviewerMikoDispatchTests {
    @Test func disablingPendingToolMustPreventDispatch() async throws {
        let f = try Fixture()
        try f.register()
        try f.supervision.setMayApproveCards(f.pane.id, true)
        var exchange = RelayAssistantExchange(request: "fixture", origin: .user)
        let input: RelayPaneHealthJSON = .object(["host": .string("This Mac"), "command": .string("echo fixture")])
        let call = RelayPaneHealthToolCall(type: "tool_use", id: "reviewer", name: "exec_command", input: input)
        let waitStarted = ContinuousClock().now
        let task = Task { @MainActor in await f.harness.execute(call, exchange: &exchange) }
        for _ in 0..<200 { if f.harness.pendingCard != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let card = try #require(f.harness.pendingCard)
        #expect(card.blockedReason == nil)
        let corrected = try await f.call("relay_miko_set_capabilities", ["disabled_tools": ["exec_command"], "reason": "Stop pending execution"])
        #expect(corrected.0 == 200)
        #expect(f.supervision.isDisabled("exec_command"))
        let approved = try await f.call("relay_miko_card", ["card_id": card.id.uuidString, "decision": "run"])
        #expect(approved.0 == 403)
        f.harness.runCard()
        #expect(f.harness.pendingCard?.id == card.id)
        let result = await task.value
        #expect(waitStarted.duration(to: ContinuousClock().now) >= .seconds(300), "The original 300-second disabled-card expiry interval must run")
        #expect(result.1)
        #expect(f.harness.pendingCard == nil)
        print("REVIEWER corrected=\(corrected.0) approved=\(approved.0) disabled=\(f.supervision.isDisabled("exec_command")) dispatched=\(f.executor.dispatched) result=\(result.0)")
        #expect(f.executor.dispatched == 0)
    }
    @Test func disablingPendingToolCanAlsoCancelImmediately() async throws {
        let f = try Fixture()
        try f.register()
        try f.supervision.setMayApproveCards(f.pane.id, true)
        var exchange = RelayAssistantExchange(request: "fixture", origin: .user)
        let input: RelayPaneHealthJSON = .object(["host": .string("This Mac"), "command": .string("echo fixture")])
        let call = RelayPaneHealthToolCall(type: "tool_use", id: "reviewer", name: "exec_command", input: input)
        let task = Task { @MainActor in await f.harness.execute(call, exchange: &exchange) }
        for _ in 0..<200 { if f.harness.pendingCard != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let card = try #require(f.harness.pendingCard)
        #expect(card.blockedReason == nil)
        let corrected = try await f.call("relay_miko_set_capabilities", ["disabled_tools": ["exec_command"], "reason": "Stop pending execution"])
        #expect(corrected.0 == 200)
        #expect(f.supervision.isDisabled("exec_command"))
        let approved = try await f.call("relay_miko_card", ["card_id": card.id.uuidString, "decision": "run"])
        #expect(approved.0 == 403)
        f.harness.runCard()
        #expect(f.harness.pendingCard?.id == card.id)
        f.harness.cancelCard()
        let result = await task.value
        print("REVIEWER corrected=\(corrected.0) approved=\(approved.0) disabled=\(f.supervision.isDisabled("exec_command")) dispatched=\(f.executor.dispatched) result=\(result.0)")
        #expect(f.executor.dispatched == 0)
    }
}
