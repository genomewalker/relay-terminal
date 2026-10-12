import Foundation
import Testing
@testable import Relay

@Test("Assistant shell input requires an exact kernel-bound shell owner")
func assistantShellOwnerAdmission() {
    let pane = UUID(), host = UUID()
    func owner(_ provider: String, sourceHost: UUID? = nil) -> RelayPromptOwnerIdentity {
        .init(hostID: sourceHost ?? host, binding: .init(version: 1, paneId: pane.uuidString.lowercased(),
            nodeBootId: "fixture-boot", workerPid: 42, workerStart: 1, shellPid: 43, shellStart: 2,
            provider: provider, processId: provider == "shell" ? 43 : 44, processStart: provider == "shell" ? 2 : 3,
            sessionId: provider == "shell" ? nil : "original-session",
            transcriptIdentity: provider == "shell" ? nil : "1:2"))
    }
    #expect(RelayAssistantShellAdmission.allows(owner("shell"), paneID: pane, hostID: host))
    #expect(!RelayAssistantShellAdmission.allows(owner("codex"), paneID: pane, hostID: host))
    #expect(!RelayAssistantShellAdmission.allows(owner("claude"), paneID: pane, hostID: host))
    #expect(!RelayAssistantShellAdmission.allows(owner("shell", sourceHost: UUID()), paneID: pane, hostID: host))
    #expect(!RelayAssistantShellAdmission.allows(owner("shell"), paneID: UUID(), hostID: host))
    #expect(!RelayAssistantShellAdmission.allows(nil, paneID: pane, hostID: host))
}

@Test("Assistant closes a captured chat automatically while retaining its pane")
@MainActor
func assistantClosesChatWithoutIntervention() async throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let pane = try #require(workspace.activePane)
    workspace.agentInspector = .init(paneID: pane.id, subagentID: "fixture-agent")
    let assistant = RelayAssistantController(workspace: workspace, permits: { _ in false })
    let turn = try assistant.beginTurn()
    defer { assistant.cancel() }
    let command = RelayAssistantCommand(action: .closeChat, targetID: pane.id.uuidString)
    let first = try await assistant.execute(command, turn: turn)
    #expect(workspace.agentInspector == nil && workspace.panes[pane.id] === pane)
    #expect(try await assistant.execute(command, turn: turn) == first)
    #expect(assistant.receipts.count == 1 && assistant.receipts[0].status == "applied")
}

@Test("Assistant rejects stale targets and disabled permissions without changing the workspace")
@MainActor
func assistantRejectsChangedTargetsAndPermissions() async throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let pane = try #require(workspace.activePane)
    workspace.agentInspector = .init(paneID: pane.id, subagentID: "before")
    let assistant = RelayAssistantController(workspace: workspace, permits: { _ in false })
    let turn = try assistant.beginTurn()
    defer { assistant.cancel() }
    workspace.agentInspector = .init(paneID: pane.id, subagentID: "after")
    await #expect(throws: (any Error).self) { try await assistant.execute(.init(action: .closeChat, targetID: pane.id.uuidString), turn: turn) }
    await #expect(throws: (any Error).self) { try await assistant.execute(.init(action: .closePane, targetID: pane.id.uuidString), turn: turn) }
    #expect(workspace.panes[pane.id] === pane && workspace.agentInspector?.subagentID == "after")
    assistant.cancel()
    await #expect(throws: (any Error).self) { try await assistant.execute(.init(action: .inspectWorkspace), turn: turn) }
}

@Test("Assistant reads live workspace changes and submits allowed shell input only once")
@MainActor
func assistantUsesLiveContextAndDeduplicatesInput() async throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let pane = try #require(workspace.activePane)
    var sends = 0
    let assistant = RelayAssistantController(workspace: workspace, permits: { _ in true }, sendShell: { target, _ in
        #expect(target === pane)
        sends += 1
        target.userEnteredInput()
        return true
    })
    let turn = try assistant.beginTurn()
    defer { assistant.cancel() }
    let before = try await assistant.execute(.init(action: .inspectWorkspace), turn: turn)
    pane.customName = "Live updated name"
    let after = try await assistant.execute(.init(action: .inspectWorkspace), turn: turn)
    #expect(before != after && after.contains("Live updated name"))
    let command = RelayAssistantCommand(action: .runCommand, targetID: pane.id.uuidString, text: "printf test")
    let sent = try await assistant.execute(command, turn: turn)
    #expect(sent.contains("submitted_outcome_unknown"))
    #expect(try await assistant.execute(command, turn: turn) == sent)
    #expect(sends == 1)
}

@Test("Real Apple model calls the Relay tool to close an isolated chat",
      .enabled(if: ProcessInfo.processInfo.environment["RELAY_ASSISTANT_MODEL_TEST"] == "1"))
@MainActor
func assistantActualAppleToolCall() async throws {
    try #require(RelayStateProfile.isIsolated, "Real model acceptance must use a private Relay state profile")
    let wasEnabled = RelayPreferences.shared.intelligenceEnabled
    RelayPreferences.shared.intelligenceEnabled = true
    defer { RelayPreferences.shared.intelligenceEnabled = wasEnabled }
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let pane = try #require(workspace.activePane)
    workspace.agentInspector = .init(paneID: pane.id, subagentID: "isolated-fixture")
    let assistant = RelayAssistantController(workspace: workspace, permits: { _ in false })
    _ = try await assistant.respond(to: "Close the inspector chat with ID \(pane.id.uuidString.lowercased()) using closeChat. Keep its terminal pane. Do this now without asking me to click anything.")
    try #require(workspace.agentInspector == nil)
    try #require(workspace.panes[pane.id] === pane)
    try #require(assistant.receipts.contains { $0.action == "closeChat" && $0.status == "applied" })
    print("RELAY_ASSISTANT_APPLE_ACCEPTANCE: actual model tool call closed the captured chat automatically; pane retained")
}
