import Foundation
import Testing
@testable import Relay

@Test @MainActor func workspaceHistoryActionDoesNotRevealItsAnchorFirst() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let anchor = try #require(workspace.activePane)
    workspace.newTab(profile: .sshConfigHost("workspace-navigation-test.invalid"))
    let destination = try #require(workspace.selectedTab)
    let group = workspace.organization.createGroup(name: "Review", kind: .task, parentID: nil)
    workspace.organization.navigate(to: .group(group))
    workspace.organization.navigate(to: .tab(destination.id))
    workspace.organization.navigate(to: .all)
    let owners = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0.sessionID) })
    let paneIDs = Set(workspace.panes.keys)
    let proposal = WorkspaceProposal(instance: UUID(), requestID: UUID(), paneID: anchor.id, action: .back)

    let result = workspace.applyWorkspaceAction(proposal, expected: anchor)

    #expect(result != nil)
    #expect(result?.0 == destination.id)
    #expect(result?.1 == workspace.activePaneID)
    #expect(workspace.organization.current == .tab(destination.id))
    #expect(workspace.selectedTabID == destination.id)
    #expect(Set(workspace.panes.keys) == paneIDs)
    #expect(Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0.sessionID) }) == owners)
    #expect(workspace.panes[anchor.id] === anchor)
}

@Test @MainActor func workspaceCentreDropDocksFloatingPaneWithoutStacking() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let first = try #require(workspace.activePane)
    workspace.splitActive(axis: .horizontal)
    let second = try #require(workspace.activePane)
    workspace.splitActive(axis: .vertical)
    let tab = try #require(workspace.selectedTab)
    let originalIDs = Set(tab.allPaneIDs)
    workspace.floatTiledPane(first.id)
    #expect(tab.floatingPanes.contains { $0.paneID == first.id })

    try workspace.applyWorkspacePaneDrop(first.id, toTab: tab.id, onto: second.id, placement: .center)

    #expect(tab.stacks.isEmpty)
    #expect(!tab.floatingPanes.contains { $0.paneID == first.id })
    #expect(tab.layout.paneIDs.contains(first.id))
    #expect(Set(tab.allPaneIDs) == originalIDs)
    #expect(workspace.panes[first.id] === first)
    let layout = tab.layout
    try workspace.applyWorkspacePaneDrop(first.id, toTab: tab.id, onto: first.id, placement: .center)
    #expect(tab.layout == layout)
}

@Test @MainActor func workspaceOrganizationDiscoveryIncludesHiddenStackMembers() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let first = try #require(workspace.activePane)
    workspace.splitActive(axis: .horizontal)
    let second = try #require(workspace.activePane)
    let tab = try #require(workspace.selectedTab)
    let session = tab.sessionID
    try workspace.stackPane(second.id, onto: first.id)
    workspace.organization.navigate(to: .all)

    let state = try workspace.workspaceOrganizationControlState()
    let navigation = try #require(state["navigation"] as? [String: Any])
    let tabs = try #require(state["tabs"] as? [[String: Any]])
    let exported = try #require(tabs.first { $0["id"] as? String == tab.id.uuidString.lowercased() })
    let members = try #require(exported["pane_ids"] as? [String])
    #expect(navigation["kind"] as? String == "all")
    #expect(exported["session_id"] as? String == session.uuidString.lowercased())
    #expect(Set(members) == Set([first.id, second.id].map { $0.uuidString.lowercased() }))
    #expect((exported["stacks"] as? [[String: Any]])?.count == 1)
    #expect(workspace.panes[first.id] === first)
    #expect(workspace.panes[second.id] === second)
}
