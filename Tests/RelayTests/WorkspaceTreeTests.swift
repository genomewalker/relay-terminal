import Foundation
import AppKit
import Testing
@testable import Relay

/// Builds a tab with `count` tiled local panes and returns their IDs in order.
@MainActor
private func tiledWorkspace(_ count: Int) -> (WorkspaceModel, [UUID]) {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    var ids = [workspace.activePaneID!]
    for _ in 1..<count {
        workspace.splitActive(axis: .horizontal)
        ids.append(workspace.activePaneID!)
    }
    return (workspace, ids)
}

@MainActor
@Test("Dropping a stacked pane into a task retains its runtime, draft and remote birth hierarchy")
func paneWorkspaceDropPreservesIdentity() throws {
    let (workspace, ids) = tiledWorkspace(3)
    defer { workspace.shutdown() }
    let source = workspace.selectedTab!
    let pane = workspace.panes[ids[1]]!
    let composer = pane.composerState
    composer.draft = "keep this unsent draft"
    let runtime = pane.runtime
    let birth = (pane.remoteWorkspaceSessionID, pane.remoteTabID, pane.remoteParentSessionID)
    try workspace.stackPane(pane.id, onto: ids[0])
    let project = workspace.organization.createGroup(name: "Mixed project", kind: .project, parentID: nil)
    let task = workspace.organization.createGroup(name: "Review", kind: .task, parentID: project)

    try workspace.organization.movePane(pane.id, toGroup: task)

    let destination = workspace.tabs.first { $0.allPaneIDs.contains(pane.id) }!
    #expect(destination !== source && destination.sessionID == source.sessionID)
    #expect(workspace.organization.group(containingTab: destination.id)?.id == task)
    #expect(!source.allPaneIDs.contains(pane.id) && source.allPaneIDs.count == 2)
    #expect(workspace.panes[pane.id] === pane && pane.runtime === runtime)
    #expect(pane.composerState === composer && composer.draft == "keep this unsent draft")
    #expect(pane.remoteWorkspaceSessionID == birth.0 && pane.remoteTabID == birth.1 && pane.remoteParentSessionID == birth.2)
    #expect(Set(workspace.tabs.flatMap(\.allPaneIDs)) == Set(ids))
}

@MainActor
@Test("Moved panes keep their birth hierarchy through disk snapshots and close/reopen")
func movedPaneBirthSurvivesPersistence() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    let pane = workspace.panes[ids[1]]!
    let birthSession = UUID(), birthTab = UUID()
    pane.assignRemoteHierarchy(workspaceSessionID: birthSession, tabID: birthTab)
    let project = workspace.organization.createGroup(name: "Project", kind: .project, parentID: nil)
    try workspace.organization.movePane(pane.id, toGroup: project)
    let destination = workspace.selectedTab!
    #expect(destination.sessionID == birthSession && destination.id != birthTab)
    let record = PaneSnapshot(pane: pane)
    let snapshot = WorkspaceSnapshot(tabs: [TabSnapshot(id: destination.id, sessionID: destination.sessionID,
        name: destination.name, layout: destination.layout, floatingPanes: [], splitRatios: [:])], panes: [record],
        sessionNames: nil, selectedTabID: destination.id, activePaneID: pane.id)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-birth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RelaySharedWorkspaceStore(directory: directory)
    _ = try store.commit(snapshot, baseline: nil)
    let savedValue = try store.restore(legacy: nil)
    let saved = try #require(savedValue)
    let restored = PaneModel(id: pane.id, profile: pane.profile, requiresExistingWorker: true)
    saved.panes[0].restoreBirthHierarchy(on: restored, fallbackWorkspaceSessionID: destination.sessionID,
        fallbackTabID: destination.id)
    #expect(restored.remoteWorkspaceSessionID == birthSession.uuidString.lowercased())
    #expect(restored.remoteTabID == birthTab.uuidString.lowercased())
    workspace.closeActivePane()
    workspace.reopenLastClosedPane()
    let reopened = try #require(workspace.panes[pane.id])
    #expect(reopened.remoteWorkspaceSessionID == birthSession.uuidString.lowercased())
    #expect(reopened.remoteTabID == birthTab.uuidString.lowercased())
}

@MainActor
@Test("Host birth overrides snapshot birth once and legacy snapshots use the presentation fallback")
func restoredBirthUsesAuthorityAndLegacyFallback() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let saved = PaneSnapshot(pane: workspace.activePane!)
    let hostSession = UUID(), hostTab = UUID()
    let restored = PaneModel(profile: .local)
    saved.restoreBirthHierarchy(on: restored, hostWorkspaceSessionID: hostSession.uuidString.lowercased(), hostTabID: hostTab.uuidString.lowercased())
    saved.restoreBirthHierarchy(on: restored, fallbackWorkspaceSessionID: UUID(), fallbackTabID: UUID())
    #expect(restored.remoteWorkspaceSessionID == hostSession.uuidString.lowercased())
    #expect(restored.remoteTabID == hostTab.uuidString.lowercased())
    let savedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
    var object = try #require(savedJSON as? [String: Any])
    object.removeValue(forKey: "remoteWorkspaceSessionID"); object.removeValue(forKey: "remoteTabID")
    let legacy = try JSONDecoder().decode(PaneSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.hasValidBirthHierarchy)
    let legacyPane = PaneModel(profile: .local)
    legacy.restoreBirthHierarchy(on: legacyPane, fallbackWorkspaceSessionID: hostSession, fallbackTabID: hostTab)
    #expect(legacyPane.remoteWorkspaceSessionID == hostSession.uuidString.lowercased())
    #expect(legacyPane.remoteTabID == hostTab.uuidString.lowercased())
}

@MainActor
@Test("Snapshot validation rejects partial, malformed and noncanonical birth identities")
func birthHierarchyValidationFailsClosed() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!, pane = workspace.activePane!
    let snapshot = WorkspaceSnapshot(tabs: [TabSnapshot(id: tab.id, sessionID: tab.sessionID, name: tab.name,
        layout: tab.layout, floatingPanes: [], splitRatios: [:])], panes: [PaneSnapshot(pane: pane)],
        sessionNames: nil, selectedTabID: tab.id, activePaneID: pane.id)
    let snapshotJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
    let original = try #require(snapshotJSON as? [String: Any])
    for value in [nil, "invalid", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"] as [String?] {
        var object = original
        var panes = try #require(object["panes"] as? [[String: Any]])
        panes[0]["remoteTabID"] = value
        object["panes"] = panes
        let malformed = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: RelaySharedWorkspaceError.invalidSnapshot) { try RelaySharedWorkspaceStore.validate(malformed) }
    }
}

@MainActor
@Test("A single-pane workspace drop reuses the tab and invalid destinations change nothing")
func singlePaneWorkspaceDropIsAtomic() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    let paneID = workspace.activePaneID!
    let baseline = workspace.organization.snapshot
    #expect(throws: WorkspaceOrganizationError.unknownGroup) {
        try workspace.organization.movePane(paneID, toGroup: UUID())
    }
    #expect(workspace.tabs.count == 1 && workspace.tabs[0] === tab)
    #expect(workspace.organization.snapshot == baseline)
    let project = workspace.organization.createGroup(name: "Project", kind: .project, parentID: nil)
    try workspace.organization.movePane(paneID, toGroup: project)
    #expect(workspace.tabs.count == 1 && workspace.tabs[0] === tab)
    #expect(workspace.organization.group(containingTab: tab.id)?.id == project)
}

@MainActor
@Test("One project holds local and remote tabs and sorting preserves their identities")
func mixedProjectSortingPreservesHosts() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let local = workspace.selectedTab!
    local.name = "Review 10"
    let localPane = workspace.activePane!
    workspace.newTab(profile: ConnectionProfile(name: "Dandy", host: "dandy-07"))
    let remote = workspace.selectedTab!
    remote.name = "Review 2"
    let remotePane = workspace.activePane!
    let sessions = [local.sessionID, remote.sessionID]
    let profiles = [localPane.profile, remotePane.profile]
    let group = workspace.organization.createGroup(name: "Project", kind: .project, parentID: nil)
    workspace.organization.placeTab(local.id, inGroup: group, at: 0)
    workspace.organization.placeTab(remote.id, inGroup: group, at: 1)
    workspace.organization.sortChildren(of: group, by: .name)
    let names = workspace.organization.children(of: group).compactMap { node -> UUID? in
        if case .tab(let id) = node { return id }; return nil
    }
    #expect(names == [remote.id, local.id])
    #expect(workspace.organization.paneIDs(in: .group(group)).count == 2)
    #expect([local.sessionID, remote.sessionID] == sessions)
    #expect([localPane.profile, remotePane.profile] == profiles)
    #expect(workspace.panes[localPane.id] === localPane && workspace.panes[remotePane.id] === remotePane)
}

@MainActor
@Test("Pane pins remain on the same pane after stacking and are removed when it closes")
func panePinsFollowIdentity() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    workspace.togglePanePin(ids[1])
    #expect(workspace.isPanePinned(ids[1]))
    try workspace.stackPane(ids[1], onto: ids[0])
    workspace.selectPane(ids[0], origin: .user)
    #expect(workspace.isPanePinned(ids[1]) && !workspace.isPanePinned(ids[0]))
    workspace.selectPane(ids[1], origin: .user)
    workspace.closeActivePane()
    #expect(!workspace.isPanePinned(ids[1]))
    let defaults = UserDefaults(suiteName: "relay.pane-pins-test.\(UUID().uuidString)")!
    WorkspacePinStore.save([ids[0]], kind: .pane, defaults: defaults)
    #expect(WorkspacePinStore.load(.pane, defaults: defaults) == [ids[0]])
    #expect(WorkspacePinStore.load(.tab, defaults: defaults).isEmpty)
}

@MainActor
@Test("Workspace drags carry an explicit UUID data representation and pane text compatibility")
func workspaceDragRepresentations() async throws {
    let id = UUID()
    for type in [WorkspaceDragPayload.tab, WorkspaceDragPayload.group, WorkspaceDragPayload.pane] {
        let provider = WorkspaceDragPayload.provider(id, type: type)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.coderReadCorrupt)) }
            }
        }
        #expect(UUID(uuidString: String(decoding: data, as: UTF8.self)) == id)
    }
    let paneProvider = WorkspaceDragPayload.paneProvider(id)
    #expect(paneProvider.hasItemConformingToTypeIdentifier(WorkspaceDragPayload.pane.identifier))
    #expect(paneProvider.canLoadObject(ofClass: NSString.self))
    PaneDragCoordinator.shared.paneID = nil
}

@MainActor
@Test("Stacking keeps every pane object, its remote birth tab and its draft")
func stackingPreservesPaneIdentity() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    let objects = ids.map { workspace.panes[$0]! }
    let birthTabs = objects.map(\.remoteTabID)
    objects[0].composerState.draft = "unsent"
    let composer = objects[0].composerState

    try workspace.stackPane(ids[1], onto: ids[0])

    #expect(tab.layout == .pane(ids[1]))
    #expect(tab.stacks.count == 1 && tab.stacks[0].members == [ids[0], ids[1]] && tab.stacks[0].selected == ids[1])
    #expect(Set(tab.allPaneIDs) == Set(ids))
    for (index, id) in ids.enumerated() {
        #expect(workspace.panes[id] === objects[index])
        #expect(workspace.panes[id]?.remoteTabID == birthTabs[index])
    }
    #expect(objects[0].composerState === composer && composer.draft == "unsent")
}

@MainActor
@Test("Selecting a hidden stack member shows it in the stack's slot")
func selectingHiddenStackMemberShowsIt() throws {
    let (workspace, ids) = tiledWorkspace(3)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    try workspace.stackPane(ids[1], onto: ids[0])
    workspace.selectPane(ids[0], origin: .user)
    #expect(tab.layout.paneIDs == [ids[0], ids[2]])
    #expect(tab.stacks[0].selected == ids[0])
    #expect(workspace.activePaneID == ids[0])
    workspace.selectAdjacentStackMember(offset: 1)
    #expect(tab.layout.paneIDs == [ids[1], ids[2]])
}

@MainActor
@Test("Closing a shown stack member hands its slot to the next member")
func closingShownStackMemberKeepsSlot() throws {
    let (workspace, ids) = tiledWorkspace(3)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    try workspace.stackPane(ids[1], onto: ids[0])
    workspace.selectPane(ids[1], origin: .user)
    workspace.closeActivePane()
    #expect(workspace.panes[ids[1]] == nil)
    #expect(tab.layout.paneIDs == [ids[0], ids[2]])
    #expect(tab.stacks.isEmpty)
    #expect(workspace.tabs.contains { $0 === tab })
}

@MainActor
@Test("Closing the only shown pane of a stack keeps the tab and its other member")
func closingStackInSinglePaneTabKeepsTab() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    try workspace.stackPane(ids[1], onto: ids[0])
    workspace.selectPane(ids[1], origin: .user)
    workspace.closeActivePane()
    #expect(workspace.tabs.contains { $0 === tab })
    #expect(tab.layout == .pane(ids[0]) && workspace.panes[ids[0]] != nil)
}

@MainActor
@Test("Unstacking tiles the pane beside its former stack")
func unstackingTilesPane() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    try workspace.stackPane(ids[1], onto: ids[0])
    try workspace.unstackPane(ids[1], placement: .trailing)
    #expect(tab.stacks.isEmpty)
    #expect(tab.layout.paneIDs == [ids[0], ids[1]])
    #expect(throws: WorkspaceLayoutError.notStacked) { try workspace.unstackPane(ids[1]) }
}

@MainActor
@Test("Layout operations refuse instead of partially applying")
func layoutOperationsRefuseCleanly() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    #expect(throws: WorkspaceLayoutError.samePane) { try workspace.stackPane(ids[0], onto: ids[0]) }
    #expect(throws: WorkspaceLayoutError.unknownPane) { try workspace.stackPane(UUID(), onto: ids[0]) }
    let before = tab.layout
    workspace.floatTiledPane(ids[1])
    #expect(throws: WorkspaceLayoutError.floatingPane) { try workspace.stackPane(ids[1], onto: ids[0]) }
    #expect(tab.stacks.isEmpty)
    workspace.dockFloatingPane(ids[1])
    #expect(Set(tab.layout.paneIDs) == Set(before.paneIDs))
}

@MainActor
@Test("Floating the shown stack member promotes the next member")
func floatingShownStackMemberPromotesNext() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    try workspace.stackPane(ids[1], onto: ids[0])
    workspace.floatTiledPane(ids[1])
    #expect(tab.layout == .pane(ids[0]))
    #expect(tab.floatingPanes.map(\.paneID) == [ids[1]])
    #expect(tab.stacks.isEmpty)
}

@MainActor
@Test("The legacy projection tiles every stacked pane and round-trips exactly")
func legacyProjectionRoundTrips() throws {
    let (workspace, ids) = tiledWorkspace(3)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    try workspace.stackPane(ids[1], onto: ids[0])
    let legacy = tab.legacyLayoutProjection
    #expect(Set(legacy.paneIDs) == Set(ids))
    #expect(legacy == tab.legacyLayoutProjection)

    let restored = TabModel(name: "restored", firstPane: ids[0])
    restored.restoreLayout(legacy: legacy, visible: tab.layout, stacks: tab.stacks)
    #expect(restored.layout == tab.layout && restored.stacks == tab.stacks)

    // An older writer moved panes but kept the same pane set: legacy wins.
    let rearranged = legacy.swapping(ids[0], ids[2])
    #expect(Set(rearranged.paneIDs) == Set(legacy.paneIDs))
    restored.restoreLayout(legacy: rearranged, visible: tab.layout, stacks: tab.stacks)
    #expect(restored.layout == rearranged && restored.stacks.isEmpty)
    #expect(Set(restored.allPaneIDs) == Set(ids))
}

@MainActor
@Test("A direct layout assignment never drops hidden stack members")
func reconcileNeverDropsPanes() throws {
    let (workspace, ids) = tiledWorkspace(3)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    try workspace.stackPane(ids[1], onto: ids[0])
    tab.layout = tab.layout.removing(ids[1])!   // as an unaware caller might
    tab.reconcileStacks()
    #expect(tab.stacks.isEmpty)
    #expect(Set(tab.allPaneIDs) == Set(ids))
}

@MainActor
@Test("Cross-tab moves stay within a session and keep the remote birth tab")
func crossTabMoveRules() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    let source = workspace.selectedTab!
    workspace.newTab(inSession: source.sessionID)
    let target = workspace.selectedTab!
    let birth = workspace.panes[ids[1]]!.remoteTabID
    try workspace.movePane(ids[1], toTab: target.id, beside: nil, placement: .trailing)
    #expect(target.allPaneIDs.contains(ids[1]) && !source.allPaneIDs.contains(ids[1]))
    #expect(workspace.panes[ids[1]]?.remoteTabID == birth)
    #expect(throws: WorkspaceLayoutError.lastPaneInTab) {
        try workspace.movePane(ids[0], toTab: target.id, beside: nil, placement: .trailing)
    }
    workspace.newTab(profile: .local)
    let otherSession = workspace.selectedTab!
    #expect(throws: WorkspaceLayoutError.differentSession) {
        try workspace.movePane(ids[1], toTab: otherSession.id, beside: nil, placement: .trailing)
    }
}

@MainActor
@Test("Groups organize tabs without touching sessions, and deletion ungroups")
func groupsOrganizeTabs() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let organization = workspace.organization
    let tab = workspace.selectedTab!
    let session = tab.sessionID
    // An unplaced tab shows in its (implicit) session group.
    #expect(organization.group(containingTab: tab.id)?.id == session)

    let project = organization.createGroup(name: "Rice", kind: .project, parentID: nil)
    let task = organization.createGroup(name: "Stock", kind: .task, parentID: project)
    organization.placeTab(tab.id, inGroup: task, at: 0)
    #expect(organization.group(containingTab: tab.id)?.id == task)
    #expect(organization.breadcrumb(for: .tab(tab.id)) == [.all, .group(project), .group(task), .tab(tab.id)])
    #expect(tab.sessionID == session)
    #expect(throws: WorkspaceOrganizationError.cycle) { try organization.moveGroup(project, toParent: task, at: 0) }

    organization.deleteGroup(task)
    #expect(organization.group(containingTab: tab.id)?.id == project)
    organization.deleteGroup(project)
    #expect(organization.group(containingTab: tab.id) == nil)
    #expect(organization.outline().contains { if case .ungrouped = $0 { true } else { false } })
}

@MainActor
@Test("Navigation history goes back, forward and up, and selection escapes the overview")
func navigationHistory() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    let organization = workspace.organization
    let tab = workspace.selectedTab!
    let group = organization.createGroup(name: "Project", kind: .project, parentID: nil)
    organization.placeTab(tab.id, inGroup: group, at: 0)

    organization.navigate(to: .all)
    organization.navigate(to: .group(group))
    #expect(organization.current == .group(group))
    // Selecting the already-selected tab still leaves the overview.
    workspace.selectTab(tab.id)
    #expect(organization.current == .tab(tab.id))
    organization.goBack()
    #expect(organization.current == .group(group))
    organization.goForward()
    #expect(organization.current == .tab(tab.id))
    // Pane changes within one tab replace the entry rather than piling up.
    workspace.selectPane(ids[0], origin: .user)
    workspace.selectPane(ids[1], origin: .user)
    #expect(organization.current == .pane(ids[1]))
    organization.goBack()
    #expect(organization.current == .group(group))
    organization.navigate(to: .pane(ids[0]))
    organization.goUp()
    #expect(organization.current == .tab(tab.id))
    organization.goUp()
    #expect(organization.current == .group(group))
}

@MainActor
@Test("Saved views restore presentation only")
func savedViewsArePresentationOnly() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    let organization = workspace.organization
    try workspace.stackPane(ids[1], onto: ids[0])
    organization.navigate(to: .tab(tab.id))
    let view = organization.saveView(name: "Stack shows second")
    workspace.selectStackMember(ids[0])
    organization.navigate(to: .all)
    let objects = ids.map { workspace.panes[$0]! }
    organization.applyView(view)
    #expect(tab.stacks[0].selected == ids[1])
    #expect(organization.current == .tab(tab.id))
    #expect(ids.enumerated().allSatisfy { workspace.panes[$1] === objects[$0] })
}

@Test("Organization merges per entity and migration is deterministic")
func organizationMerge() throws {
    let a = UUID(), b = UUID()
    let base = WorkspaceOrganizationController.migrated(sessionIDs: [a], name: { _ in "Session" })
    let again = WorkspaceOrganizationController.migrated(sessionIDs: [a], name: { _ in "Session" })
    #expect(base == again)
    var local = base
    local.groups.append(WorkspaceGroup(id: b, parentID: nil, order: 1, name: "Local", kind: .project, collapsed: false))
    var current = base
    current.groups[0].collapsed = true
    let merged = try RelaySharedWorkspaceStore.mergeOrganization(local: local, baseline: base, current: current)
    #expect(merged.groups.count == 2)
    #expect(merged.groups.first { $0.id == a }?.collapsed == true)
    var renamedHere = base, renamedThere = base
    renamedHere.groups[0].name = "Here"
    renamedThere.groups[0].name = "There"
    #expect(throws: RelaySharedWorkspaceError.self) {
        try RelaySharedWorkspaceStore.mergeOrganization(local: renamedHere, baseline: base, current: renamedThere)
    }
    var invalid = base
    invalid.schemaVersion = 3
    #expect(throws: RelaySharedWorkspaceError.self) { try RelaySharedWorkspaceStore.validateOrganization(invalid) }
}

@Test("Stacks are validated against the legacy layout, and v2 writes back up v1 once")
func storeStacksAndBackup() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-trellis-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RelaySharedWorkspaceStore(directory: directory)
    let tab = UUID(), a = UUID(), b = UUID()
    let panes = [a, b].map { PaneSnapshot(id: $0, profile: .local, contentKind: .terminal,
        remoteParentSessionID: nil, editorRequest: nil, customName: nil) }
    let plain = WorkspaceSnapshot(tabs: [TabSnapshot(id: tab, sessionID: tab, name: "T",
        layout: .split(id: UUID(), axis: .horizontal, first: .pane(a), second: .pane(b)), floatingPanes: [], splitRatios: [:])],
        panes: panes, sessionNames: [:], selectedTabID: tab, activePaneID: a)
    _ = try store.commit(plain, baseline: nil)

    let stack = PaneStack(id: UUID(), members: [a, b], selected: a)
    var stacked = TabSnapshot(id: tab, sessionID: tab, name: "T",
        layout: PaneLayout.pane(a).legacyProjection(stacks: [stack]), floatingPanes: [], splitRatios: [:])
    stacked.visibleLayout = .pane(a)
    stacked.stacks = [stack]
    let v2 = WorkspaceSnapshot(tabs: [stacked], panes: panes, sessionNames: [:], selectedTabID: tab, activePaneID: a)
    _ = try store.commit(v2, baseline: plain)
    let backup = directory.appendingPathComponent("workspace-v1.pre-v2-backup.json")
    let saved = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: backup))
    #expect(saved.tabs[0].stacks == nil && Set(saved.tabs[0].layout.paneIDs) == [a, b])
    // The backup is written once, never overwritten by later saves.
    let first = try Data(contentsOf: backup)
    _ = try store.commit(v2, baseline: v2)
    #expect(try Data(contentsOf: backup) == first)

    // A stack naming a pane the legacy layout does not place is invalid.
    var bad = stacked
    bad.stacks = [PaneStack(id: UUID(), members: [a, UUID()], selected: a)]
    #expect(throws: RelaySharedWorkspaceError.self) {
        try RelaySharedWorkspaceStore.validate(WorkspaceSnapshot(tabs: [bad], panes: panes, sessionNames: [:],
            selectedTabID: tab, activePaneID: a))
    }
}

@MainActor
@Test("Stack switches and overview visits keep the same composer and its send state")
func composerSurvivesStackAndNavigation() throws {
    let (workspace, ids) = tiledWorkspace(2)
    defer { workspace.shutdown() }
    let tab = workspace.selectedTab!
    let pane = workspace.panes[ids[0]]!
    let composer = pane.composerState
    composer.draft = "staged text"
    composer.attachmentQueue.restore([])
    composer.submitting = true
    composer.submitted = true
    composer.nativeDeliveryHeld = true
    composer.stopRequested = true
    composer.submissionStatus = "Outcome unknown; do not resend"

    try workspace.stackPane(ids[1], onto: ids[0])   // ids[0] becomes hidden
    workspace.organization.navigate(to: .all)
    workspace.organization.navigate(to: .tab(tab.id))
    workspace.selectStackMember(ids[0])
    try workspace.unstackPane(ids[1])

    #expect(workspace.panes[ids[0]] === pane)
    #expect(pane.composerState === composer)
    #expect(pane.composerState.attachmentQueue === composer.attachmentQueue)
    #expect(composer.draft == "staged text")
    #expect(composer.submitting && composer.submitted && composer.nativeDeliveryHeld && composer.stopRequested)
    #expect(composer.submissionStatus == "Outcome unknown; do not resend")
}
