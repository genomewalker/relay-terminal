import AppKit
import Testing
@testable import Relay

@Test @MainActor func mcpWorkspaceGrantDefaultsOnAndHonoursOptOut() throws {
    var alert: NSAlert?
    var complete: ((NSApplication.ModalResponse) -> Void)?
    var presentations = 0
    let grant = MCPWorkspaceGrant { proposal, callback in
        alert = proposal
        complete = callback
        presentations += 1
        return true
    }
    #expect(!grant.permits(.navigate))
    try grant.request()
    try grant.request()
    #expect(presentations == 1)
    #expect(grant.status == "awaiting_approval")
    let buttons = (alert?.accessoryView as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton } ?? []
    #expect(buttons.count == MCPWorkspaceCapability.allCases.count)
    #expect(buttons.allSatisfy { $0.state == .on })
    buttons[3].state = .off // terminal input opted out
    complete?(.alertSecondButtonReturn)
    #expect(grant.status == "granted")
    #expect(grant.permits(.navigate))
    #expect(grant.permits(.create))
    #expect(grant.permits(.layout))
    #expect(!grant.permits(.input))
    try grant.request()
    #expect(presentations == 1)
}

@Test @MainActor func mcpWorkspaceGrantDenialAndUnavailablePresenter() throws {
    let unavailable = MCPWorkspaceGrant { _, _ in false }
    #expect(throws: (any Error).self) { try unavailable.request() }
    #expect(unavailable.status == "not_requested")
    var complete: ((NSApplication.ModalResponse) -> Void)?
    let grant = MCPWorkspaceGrant { _, callback in complete = callback; return true }
    try grant.request()
    complete?(.alertFirstButtonReturn)
    #expect(grant.status == "denied")
    #expect(MCPWorkspaceCapability.allCases.allSatisfy { !grant.permits($0) })
    try grant.request()
    #expect(grant.status == "awaiting_approval")
}

@Test @MainActor func workspaceActionsPreserveNeighboursAndTargetIdentity() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("workspace-mcp-test.invalid"))
    let pane = workspace.activePane!
    let instance = UUID()
    func proposal(_ action: WorkspaceAction) -> WorkspaceProposal {
        .init(instance: instance, requestID: UUID(), paneID: pane.id, action: action)
    }
    let split = workspace.applyWorkspaceAction(proposal(.splitRight), expected: pane)
    #expect(split?.1 != pane.id)
    #expect(workspace.selectedTab?.allPaneIDs.count == 2)
    let neighbour = workspace.activePane!
    #expect(workspace.applyWorkspaceAction(proposal(.select), expected: neighbour) == nil)
    #expect(throws: (any Error).self) { try workspace.workspaceActionDetail(proposal(.dock)) }
    _ = workspace.applyWorkspaceAction(proposal(.zoom), expected: pane)
    #expect(workspace.zoomedPaneID == pane.id)
    let unzoom = WorkspaceProposal(instance: instance, requestID: UUID(), paneID: neighbour.id, action: .unzoom)
    _ = workspace.applyWorkspaceAction(unzoom, expected: neighbour)
    #expect(workspace.zoomedPaneID == nil)
    _ = workspace.applyWorkspaceAction(proposal(.float), expected: pane)
    let closeNeighbour = WorkspaceProposal(instance: instance, requestID: UUID(), paneID: neighbour.id, action: .close)
    #expect(throws: (any Error).self) { try workspace.workspaceActionDetail(closeNeighbour) }
    #expect(workspace.applyWorkspaceAction(closeNeighbour, expected: neighbour) == nil)
    _ = workspace.applyWorkspaceAction(proposal(.close), expected: pane)
    #expect(workspace.panes[pane.id] == nil)
    #expect(workspace.panes[neighbour.id] === neighbour)
    #expect(workspace.applyWorkspaceAction(proposal(.close), expected: pane) == nil)
    workspace.openEditorForActive()
    let editor = workspace.activePane!
    let closeEditor = WorkspaceProposal(instance: instance, requestID: UUID(), paneID: editor.id, action: .close)
    #expect(throws: (any Error).self) { try workspace.workspaceActionDetail(closeEditor) }
}

@Test @MainActor func workspaceApprovalBindsTargetAndReplaysOnce() throws {
    var answer: ((NSApplication.ModalResponse) -> Void)?
    var applied = 0
    let broker = WorkspaceControl { _, callback in answer = callback; return true }
    let instance = UUID(), pane = UUID(), tab = UUID(), id = UUID()
    let proposal = WorkspaceProposal(instance: instance, requestID: id, paneID: pane, action: .close)
    #expect(try broker.propose(proposal, instance: instance, detail: "Stop legacy shell") {
        applied += 1; return (tab, pane)
    }.status == "awaiting_approval")
    #expect(applied == 0)
    #expect(throws: (any Error).self) {
        try broker.propose(.init(instance: instance, requestID: id, paneID: UUID(), action: .close), instance: instance, detail: "") { nil }
    }
    answer?(.alertSecondButtonReturn)
    answer?(.alertSecondButtonReturn)
    #expect(applied == 1)
    #expect(try broker.propose(proposal, instance: instance, detail: "") { nil }.status == "applied")
    #expect(broker.receipt(id)?.paneID == pane)
    #expect(throws: (any Error).self) { try broker.propose(proposal, instance: UUID(), detail: "") { nil } }
}

@Test @MainActor func workspaceApprovalCancellationAndStaleTarget() throws {
    let instance = UUID()
    for accept in [false, true] {
        let broker = WorkspaceControl { _, callback in
            callback(accept ? .alertSecondButtonReturn : .alertFirstButtonReturn); return true
        }
        let proposal = WorkspaceProposal(instance: instance, requestID: UUID(), paneID: UUID(), action: .select)
        #expect(try broker.propose(proposal, instance: instance, detail: "") {
            if !accept { Issue.record("Cancelled operation executed") }
            return nil // Target disappeared before approval.
        }.status == (accept ? "failed" : "cancelled"))
    }
}

@Test @MainActor func workspaceNewTabRejectsLatePreviousPaneSelection() async throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("late-selection-test.invalid"))
    let previous = try #require(workspace.activePane)
    let oldTab = try #require(workspace.selectedTab)
    let proposal = WorkspaceProposal(instance: UUID(), requestID: UUID(), paneID: previous.id, action: .newTab)
    let created = try #require(workspace.applyWorkspaceAction(proposal, expected: previous))
    let current = try #require(workspace.activePane)
    #expect(created.1 == current.id && created.0 != oldTab.id)
    previous.runtime.onPaneSelection?(.programmatic)
    await Task.yield()
    #expect(workspace.selectedTabID == created.0 && workspace.activePaneID == current.id)
    #expect(workspace.selectedTab?.allPaneIDs.contains(current.id) == true)
    workspace.selectPane(previous.id, origin: .user)
    #expect(workspace.activePaneID == current.id)
    workspace.revealPane(previous.id, origin: .user)
    #expect(workspace.selectedTabID == oldTab.id && workspace.activePaneID == previous.id)
}
