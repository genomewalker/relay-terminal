import Foundation
import Testing
@testable import Relay

@MainActor
@Test func sidebarSearchFindsPanesByIDInAnyCaseAndPart() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("sidebar-test.invalid"))
    let pane = workspace.activePane!
    let id = pane.id.uuidString
    for query in [id.lowercased(), id.uppercased(), String(id.lowercased().prefix(8)), "  \(id.prefix(13))  "] {
        let hits = workspace.sidebarSearch(query)
        #expect(hits.first?.pane?.id == pane.id, "query \(query)")
    }
    #expect(workspace.sidebarSearch("   ").isEmpty)
}

@MainActor
@Test func sidebarSearchListsIDMatchesFirst() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .sshConfigHost("sidebar-test.invalid"))
    workspace.newTab(profile: .sshConfigHost("sidebar-test.invalid"))
    let target = workspace.activePane!
    let fragment = String(target.id.uuidString.prefix(8))
    // Another tab named after the fragment matches first in workspace order.
    let decoy = workspace.tabs.first { $0.id != workspace.tabID(containingPane: target.id) }!
    decoy.name = "notes \(fragment)"
    let hits = workspace.sidebarSearch(fragment)
    #expect(hits.first?.pane?.id == target.id)
    #expect(hits.contains { $0.tab.id == decoy.id && $0.pane == nil })
    // The decoy fills the result limit before the target's tab is reached;
    // the ID match is still found and listed first.
    let decoyFirst = workspace.tabs.firstIndex { $0.id == decoy.id }! <
        workspace.tabs.firstIndex { $0.id == workspace.tabID(containingPane: target.id) }!
    #expect(decoyFirst)
    let limited = workspace.sidebarSearch(fragment, limit: 1)
    #expect(limited.first?.pane?.id == target.id)
    #expect(limited.contains { $0.tab.id == decoy.id })
}

@Test func navigationExpandsAndCollapsesEveryListedGroup() {
    var state = WorkspaceNavigationState()
    let ids = [UUID(), UUID(), UUID()]
    state.toggle(.session, id: ids[1])
    state.setExpanded(.session, ids: ids, expanded: true)
    #expect(ids.allSatisfy { state.isExpanded(.session, id: $0) })
    #expect(!state.isExpanded(.tab, id: ids[0]))
    state.setExpanded(.session, ids: ids, expanded: false)
    #expect(!ids.contains { state.isExpanded(.session, id: $0) })
}

@MainActor
@Test func collapseAndExpandAllReachEverySessionAndTab() {
    // Pure state: a live WorkspaceModel would share saved workspace and
    // navigation defaults with the relaunch tests running beside this one.
    var state = WorkspaceNavigationState()
    let session = UUID(), other = UUID()
    let tabs = [(id: UUID(), sessionID: session), (id: UUID(), sessionID: session), (id: UUID(), sessionID: other)]
    state.setAllExpanded(tabs: tabs, expanded: true)
    for tab in tabs {
        #expect(state.isExpanded(.tab, id: tab.id))
        #expect(state.isExpanded(.session, id: tab.sessionID))
    }
    state.setAllExpanded(tabs: tabs, expanded: false)
    for tab in tabs {
        #expect(!state.isExpanded(.tab, id: tab.id))
        #expect(!state.isExpanded(.session, id: tab.sessionID))
    }
}

@Test func mostUsedOrderWeighsRecentUseAndKeepsPinsFirst() {
    var state = WorkspaceNavigationState()
    let now = Date()
    let old = UUID(), recent = UUID(), unused = UUID(), pinned = UUID()
    let arranged = [unused, old, recent, pinned]
    // Five uses nine days ago decay to 5/8; two uses today stay at 2.
    for _ in 0..<5 { state.noteUse(.tab, id: old, now: now.addingTimeInterval(-9 * 86_400)) }
    state.noteUse(.tab, id: recent, now: now.addingTimeInterval(-60))
    state.noteUse(.tab, id: recent, now: now)
    #expect(abs(state.usageScore(.tab, id: old, now: now) - 0.625) < 0.001)
    #expect(state.usageScore(.session, id: recent, now: now) == 0)

    let isPinned = { (id: UUID) in id == pinned }
    #expect(state.ordered(.tab, ids: arranged, pinned: isPinned, now: now) == [pinned, unused, old, recent])
    state.sortMode = .mostUsed
    #expect(state.ordered(.tab, ids: arranged, pinned: isPinned, now: now) == [pinned, recent, old, unused])
    // Equal use keeps the arrangement.
    let a = UUID(), b = UUID()
    #expect(state.ordered(.tab, ids: [a, b], pinned: { _ in false }, now: now) == [a, b])
}

@Test func usageStaysBounded() {
    var state = WorkspaceNavigationState()
    let now = Date()
    let favourite = UUID()
    for _ in 0..<3 { state.noteUse(.session, id: favourite, now: now) }
    for _ in 0..<(WorkspaceNavigationState.usageLimit + 20) { state.noteUse(.tab, id: UUID(), now: now) }
    #expect(state.usageScore(.session, id: favourite, now: now) == 3)
    let data = try! JSONEncoder().encode(state)
    let usage = (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["usage"] as! [String: Any]
    #expect(usage.count == WorkspaceNavigationState.usageLimit)
}

@Test func navigationStateFromEarlierBuildsStillDecodes() throws {
    let tab = UUID(), session = UUID()
    let saved = #"{"expandedGroups":{"tab:\#(tab.uuidString)":true},"lastSelectedTabs":{"\#(session.uuidString)":"\#(tab.uuidString)"}}"#
    let state = try JSONDecoder().decode(WorkspaceNavigationState.self, from: Data(saved.utf8))
    #expect(state.sortMode == .manual)
    #expect(state.usageScore(.tab, id: tab) == 0)
    #expect(state.preferredTab(in: session, available: [UUID(), tab]) == tab)
}

@Test func navigationStateKeepsSortModeAndUsageAcrossSaves() throws {
    var state = WorkspaceNavigationState()
    let id = UUID(), now = Date()
    state.sortMode = .mostUsed
    state.noteUse(.session, id: id, now: now)
    let decoded = try JSONDecoder().decode(WorkspaceNavigationState.self, from: JSONEncoder().encode(state))
    #expect(decoded.sortMode == .mostUsed)
    #expect(decoded.usageScore(.session, id: id, now: now) == 1)
}
