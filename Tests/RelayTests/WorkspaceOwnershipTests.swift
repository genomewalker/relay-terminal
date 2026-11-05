import Foundation
import Testing
@testable import Relay

// Built from work/workspace-migration-live-20261017.json: tab, title, legacy
// session, navigator group and whether that group is a project group.
private let liveTabs: [(String, String, String, String, Bool)] = [
    ("7aa56a00", "PanBarley", "dandy-07", "PanBarley", true),
    ("a8922a82", "Codex bridge", "dandy-07", "Codex bridge", true),
    ("51909c03", "Rice", "dandy-07", "Rice", true),
    ("ac510024", "cc-soul", "dandy-07", "Relay & Chitta", true),
    ("1c2c311b", "Geodesic & ancient-metasim", "dandy-07", "Geodesic & simulation", true),
    ("941fd236", "Convergence", "dandy-07", "Convergence", true),
    ("e0cc4d95", "Sapropel live Claude", "Sapropel live Claude", "Sapropels", true),
    ("88eb3cf4", "Sapropel rotation test", "dandy-07", "General", true),
    ("331eea46", "Chitta-Relay", "Work", "Relay & Chitta", true),
    ("05791792", "Sapropels", "Work · dandy-07", "Sapropels", true),
    ("8616d845", "Seula", "Work · dandy-07", "SEULA", true),
    ("30a62084", "Kapk-review", "Work · dandy-07", "Kapk review", true),
    ("bf8a5a2b", "fqdup", "Work · dandy-07", "fqdup", true),
    ("cd59ed8d", "GTDB r232", "Work · dandy-07", "GTDB", true),
    ("e30c970c", "SSH tunnel history", "Work", "General", true),
    ("179b28a1", "Termium browser", "Work", "General", true),
    ("31b646ff", "Codex cache analysis", "Work", "General", true),
    ("35cd47d4", "R console & editor", "Work", "General", true),
    ("518cf72a", "Kapk-Briggs manifest", "Work", "General", true),
    ("1aa9f60c", "Dandy-07 shell", "dandy-07", "General", true),
    ("fb16df7f", "dart", "Work · dandy-07", "DART", false),
    ("986d6b72", "Local shell 9", "dandy-07", "dandy-07", false),
    ("41d22cfa", "Local shell 7", "Work · dandy-07", "DART", false),
    ("2a963d75", "Preview QA AL", "Work", "Work", false),
    ("606b8280", "Preview QA Dandy AL", "Work · dandy-07", "DART", false),
]

/// The doc's re-sort (decision 5): General and the session groups re-filed.
private let liveOverrides: [String: String] = [
    "Codex cache analysis": "Relay & Chitta", "SSH tunnel history": "Relay & Chitta",
    "Termium browser": "Relay & Chitta", "R console & editor": "Relay & Chitta",
    "Preview QA AL": "Relay QA", "Preview QA Dandy AL": "Relay QA", "Local shell 7": "Relay QA",
    "Sapropel rotation test": "Relay QA", "Kapk-Briggs manifest": "Kapk review",
    "Dandy-07 shell": "Inbox", "Local shell 9": "Inbox",
]

/// The doc's live preview table, workspace → tab titles.
private let livePreviewTable: [String: Set<String>] = [
    "Relay & Chitta": ["Chitta-Relay", "cc-soul", "Codex cache analysis", "SSH tunnel history", "Termium browser", "R console & editor"],
    "Relay QA": ["Preview QA AL", "Preview QA Dandy AL", "Local shell 7", "Sapropel rotation test"],
    "Kapk review": ["Kapk-review", "Kapk-Briggs manifest"],
    "DART": ["dart"],
    "Sapropels": ["Sapropels", "Sapropel live Claude"],
    "fqdup": ["fqdup"], "GTDB": ["GTDB r232"], "SEULA": ["Seula"], "Convergence": ["Convergence"],
    "Geodesic & simulation": ["Geodesic & ancient-metasim"], "PanBarley": ["PanBarley"], "Rice": ["Rice"],
    "Codex bridge": ["Codex bridge"], "Ancient DNA training": [], "Inbox": ["Dandy-07 shell", "Local shell 9"],
]

/// Pane IDs per tab, from the same inventory.
private let livePanes: [String: [String]] = [
    "7aa56a00": ["afe558a7", "5ea464c3", "94642f2a", "e66b4c7c"],
    "a8922a82": ["0c63a130", "edcdec87", "4abe0d26", "1fb0f4e6", "3ebf3abc"],
    "51909c03": ["4b3c6f80", "98646a7f", "a46fdf19"], "ac510024": ["27278f2c", "b224682e", "2c3ce303"],
    "1c2c311b": ["8a1bc2c6", "99137542", "3a4a30bb"], "941fd236": ["5137b989", "b506445f"],
    "e0cc4d95": ["775d4f1f", "c6a2d208", "ee76f546"], "88eb3cf4": ["2a2cbd99", "54e5e6be"],
    "331eea46": ["0e426bf7", "9ef1b226", "129286a2", "cbf0ccc8"], "05791792": ["dd0711f3", "a9cf29a3"],
    "8616d845": ["5a30d83a", "689d54e9", "4670bd8f"], "30a62084": ["7d85fd72", "b93f5a99"],
    "bf8a5a2b": ["1652a003", "800c06ef"], "cd59ed8d": ["c75e2d0f", "2639be6a"], "e30c970c": ["0124f4f3"],
    "179b28a1": ["dc9b74f8", "b2c9e1c2"], "31b646ff": ["487f0ef8"], "35cd47d4": ["defed4a5", "31a9f51d"],
    "518cf72a": ["2c286901"], "1aa9f60c": ["b294ecb6"], "fb16df7f": ["ede7db44", "78f9b828"],
    "986d6b72": ["98aae9de"], "41d22cfa": ["6853cd48"], "2a963d75": ["cfe5e35b"], "606b8280": ["c5a4ee34"],
]

/// The approved pane moves (user, 2026-10-17): pane → destination tab.
private let livePaneMoves: [(pane: String, from: String, to: String)] = [
    ("94642f2a-2858-4cea-80d2-3e06a6e9d43e", "7aa56a00", "941fd236"),
    ("e66b4c7c-60d9-41f4-8cff-5ba571ab2d77", "7aa56a00", "941fd236"),
    ("1fb0f4e6-4496-4c8d-94b4-a0f0e6e8afda", "a8922a82", "bf8a5a2b"),
]

private func paneID(_ short: String) -> UUID {
    UUID(uuidString: livePaneMoves.first { $0.pane.hasPrefix(short) }?.pane ?? short + "-0000-4000-8000-000000000001")!
}

private func fixtureID(_ text: String) -> UUID {
    WorkspaceMigration.workspaceID(named: "fixture:" + text)
}

/// Full tab IDs named by the decided plan file; the others are synthetic.
private let liveFullTabIDs = [
    "31b646ff-01ea-4c9c-8302-20c794cdaa1a", "e30c970c-637e-4446-b5ad-3c9a8cbd2606", "179b28a1-cdea-46c5-98f2-cd58fee8af78",
    "35cd47d4-d9bb-45eb-ae0e-bfff25247e15", "2a963d75-4bcd-4db1-8661-622e751d93cf", "606b8280-6f8c-47b8-ad2e-54656d128bf3",
    "41d22cfa-1b54-40c9-b4fe-3b0de8b22c9f", "88eb3cf4-9702-45bf-9e75-1a47f2837cb9", "518cf72a-8eb4-413d-8294-7a9b7b5e9588",
    "fb16df7f-f9c1-4e4c-a24b-cf3e5c769984", "1aa9f60c-270d-4a75-9657-b7f5a6f701c8", "986d6b72-0ee4-4947-b41a-98386af7453a",
    "b1de1729-eb03-453e-aa53-af134df3634e", "e0c5f896-08dc-4c6f-b96a-5b4527801d4b", "f4656b14-b22f-4629-b46b-5ab329a1228e",
    "35ab0565-534e-4347-bdde-4767ef11f669", "941fd236-33f6-4c41-aaac-063fadbc4bab", "bf8a5a2b-6fc1-4fa3-b198-3843fa2485e2",
]

private func tabID(_ short: String) -> UUID {
    UUID(uuidString: liveFullTabIDs.first { $0.hasPrefix(short) } ?? short + "-0000-4000-8000-000000000000")!
}

/// The FARO Labs addendum: a project group with a nested task group; four
/// tabs still sit in the dandy-07 session group.
private let faroTabs: [(String, String, String, String?)] = [
    ("6698f63e", "00 · FARO Control", "dandy-07", "00 · FARO Control"),
    ("a9b5e6fd", "01 · Data & Foldseek", "dandy-07", "FARO Labs"),
    ("b1de1729", "02 · Agro · OSR", "dandy-07", nil),
    ("e0c5f896", "03 · Biosolutions · Protease", "dandy-07", nil),
    ("f4656b14", "04 · Backend & Nextflow", "dandy-07", nil),
    ("35ab0565", "05 · Frontend & QA", "dandy-07", nil),
]

private struct LiveFixture {
    let tabs: [WorkspaceTabReference]
    let organization: WorkspaceOrganizationSnapshot
    let snapshot: WorkspaceSnapshot
    let overrides: [UUID: String]
    let titles: [UUID: String]
}

private func liveFixture(withFARO: Bool = false) -> LiveFixture {
    let faro = withFARO ? faroTabs : []
    let tabs = liveTabs.map { WorkspaceTabReference(id: tabID($0.0), sessionID: fixtureID("session:" + $0.2), title: $0.1, sessionName: $0.2) }
        + faro.map { WorkspaceTabReference(id: tabID($0.0), sessionID: fixtureID("session:" + $0.2), title: $0.1, sessionName: $0.2) }
    var groups: [WorkspaceGroup] = [], placements: [WorkspaceTabPlacement] = []
    var projectNames = liveTabs.filter(\.4).map(\.3).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    projectNames.append("Ancient DNA training")
    for (index, name) in projectNames.enumerated() {
        groups.append(WorkspaceGroup(id: fixtureID("group:" + name), parentID: nil, order: Double(index), name: name, kind: .project, collapsed: false))
    }
    // Session groups are records keyed by their session; their tabs are unplaced.
    for (session, name) in [("Work · dandy-07", "DART"), ("dandy-07", "dandy-07"), ("Work", "Work")] {
        groups.append(WorkspaceGroup(id: fixtureID("session:" + session), parentID: nil, order: Double(groups.count), name: name, kind: .session, collapsed: false))
    }
    for (index, row) in liveTabs.enumerated() where row.4 {
        placements.append(WorkspaceTabPlacement(id: tabID(row.0), groupID: fixtureID("group:" + row.3), order: Double(index)))
    }
    if withFARO {
        groups.append(WorkspaceGroup(id: UUID(uuidString: "F2B2F92A-0000-4000-8000-000000000000")!, parentID: nil,
                                     order: Double(groups.count), name: "FARO Labs", kind: .project, collapsed: false))
        groups.append(WorkspaceGroup(id: UUID(uuidString: "A92062F0-0000-4000-8000-000000000000")!,
                                     parentID: UUID(uuidString: "F2B2F92A-0000-4000-8000-000000000000")!,
                                     order: 0, name: "00 · FARO Control", kind: .task, collapsed: false))
        for (index, row) in faro.enumerated() {
            guard let group = row.3 else { continue }
            let id = group == "FARO Labs" ? "F2B2F92A-0000-4000-8000-000000000000" : "A92062F0-0000-4000-8000-000000000000"
            placements.append(WorkspaceTabPlacement(id: tabID(row.0), groupID: UUID(uuidString: id)!, order: Double(index)))
        }
    }
    let sessionNames = Dictionary(tabs.map { ($0.sessionID, $0.sessionName) }, uniquingKeysWith: { first, _ in first })
    let tabPanes = liveTabs.map { ($0.0, livePanes[$0.0]!) } + faro.map { ($0.0, [String($0.0.reversed())]) }
    let paneIDs = Dictionary(uniqueKeysWithValues: tabPanes.map { (tabID($0.0), $0.1.map(paneID)) })
    let selected = tabID("331eea46")
    let snapshot = WorkspaceSnapshot(tabs: tabs.map { tab in
            let ids = paneIDs[tab.id]!
            let layout = ids.dropFirst().reduce(PaneLayout.pane(ids[0])) { layout, id in
                layout.splitting(layout.paneIDs.last!, axis: .horizontal, with: id) }
            return TabSnapshot(id: tab.id, sessionID: tab.sessionID, name: tab.title, layout: layout, floatingPanes: [], splitRatios: [:])
        }, panes: tabPanes.flatMap { $0.1.map(paneID) }.map { id in
            PaneSnapshot(id: id, profile: .local, contentKind: .terminal, remoteParentSessionID: nil, editorRequest: nil, customName: nil)
        }, sessionNames: sessionNames, selectedTabID: selected, activePaneID: paneIDs[selected]![0])
    let byTitle = Dictionary(uniqueKeysWithValues: tabs.map { ($0.title, $0.id) })
    return LiveFixture(tabs: tabs,
        organization: WorkspaceOrganizationSnapshot(schemaVersion: WorkspaceOrganizationSnapshot.currentSchemaVersion,
            groups: groups, placements: placements, savedViews: []),
        snapshot: snapshot,
        overrides: Dictionary(uniqueKeysWithValues: liveOverrides.map { (byTitle[$0.key]!, $0.value) }),
        titles: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) }))
}

private func temporaryStore(_ label: String) -> (RelaySharedWorkspaceStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(label)-\(UUID())")
    return (RelaySharedWorkspaceStore(directory: directory), directory)
}

private func ownerTitles(_ ownership: WorkspaceOwnershipSnapshot, _ fixture: LiveFixture) -> [String: Set<String>] {
    Dictionary(uniqueKeysWithValues: ownership.workspaces.map { workspace in
        (workspace.name, Set(ownership.tabIDs(in: workspace.id).compactMap { fixture.titles[$0] }))
    })
}

@MainActor
@Test("Every tab has exactly one workspace and the Inbox is stable")
func workspaceOwnershipInvariants() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: ConnectionProfile(name: "Dandy", host: "dandy-07"))
    let ownership = workspace.ownership
    try WorkspaceOwnershipSnapshot.validate(ownership)
    #expect(ownership.workspace(WorkspaceOwnershipSnapshot.inboxID)?.isInbox == true)
    #expect(Set(ownership.owners.map(\.id)) == Set(workspace.tabs.map(\.id)) && ownership.owners.count == workspace.tabs.count)
    // The first tab's session became a workspace; a new tab joins the visible one.
    let first = workspace.tabs[0]
    #expect(ownership.owner(of: first.id) == first.sessionID)
    #expect(ownership.owner(of: workspace.tabs[1].id) == first.sessionID)
    var duplicate = ownership
    duplicate.owners.append(duplicate.owners[0])
    var noInbox = ownership
    noInbox.workspaces.removeAll(where: \.isInbox)
    var dangling = ownership
    dangling.owners[0].workspaceID = UUID()
    var newer = ownership
    newer.schemaVersion = 4
    for invalid in [duplicate, noInbox, dangling, newer] {
        #expect(throws: RelaySharedWorkspaceError.invalidSnapshot) { try WorkspaceOwnershipSnapshot.validate(invalid) }
    }
    // Closed tabs lose their owner. (Not closeTab here: it records a shared
    // closed-pane entry that other tests in this process observe.)
    var pruned = ownership
    pruned.reconcile(tabs: [WorkspaceTabReference(id: first.id, sessionID: first.sessionID, title: "", sessionName: "")])
    #expect(pruned.owners.map(\.id) == [first.id])
    // Pane membership stays disjoint through the existing validator.
    let tab = workspace.tabs[0]
    try RelaySharedWorkspaceStore.validate(WorkspaceSnapshot(tabs: [TabSnapshot(id: tab.id, sessionID: tab.sessionID,
        name: tab.name, layout: tab.layout, floatingPanes: [], splitRatios: [:])],
        panes: tab.allPaneIDs.map { PaneSnapshot(pane: workspace.panes[$0]!) }, sessionNames: nil, selectedTabID: tab.id, activePaneID: nil))
}

@MainActor
@Test("A tab move between workspaces is atomic and keeps the legacy sessions projection")
func workspaceTabMoveIsAtomic() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .local)
    let tab = workspace.tabs[1]
    let sessions = try JSONEncoder().encode(workspace.sidePanelState().sessions.map { [$0.id] + $0.tabs.map(\.id) })
    let before = workspace.ownership, selected = workspace.selectedTabID, panes = tab.allPaneIDs
    #expect(workspace.canMoveTab(tab.id, toWorkspace: UUID()) == .unknownWorkspace)
    #expect(throws: WorkspaceMoveRefusal.unknownWorkspace) { try workspace.moveTab(tab.id, toWorkspace: UUID()) }
    #expect(throws: WorkspaceMoveRefusal.unknownTab) { try workspace.moveTab(UUID(), toWorkspace: WorkspaceOwnershipSnapshot.inboxID) }
    #expect(workspace.ownership == before)
    let project = workspace.createWorkspace(named: "Project")
    try workspace.moveTab(tab.id, toWorkspace: project)
    #expect(workspace.workspaceID(forTab: tab.id) == project)
    #expect(workspace.tabs(inWorkspace: project).map(\.id) == [tab.id])
    #expect(workspace.ownership.owners.filter { $0.id == tab.id }.count == 1)
    // The moved tab was selected: the shown workspace stays put and selects its remaining tab.
    #expect(selected == tab.id && workspace.selectedTabID == workspace.tabs[0].id)
    #expect(workspace.selectedWorkspaceID == before.owner(of: tab.id))
    #expect(tab.allPaneIDs == panes && workspace.tabs[1] === tab)
    #expect(try JSONEncoder().encode(workspace.sidePanelState().sessions.map { [$0.id] + $0.tabs.map(\.id) }) == sessions)
}

@MainActor
@Test("A pane moved into a hidden tab of another workspace keeps its object, runtime, host, cwd and draft")
func workspacePaneReparentPreservesIdentity() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .local)
    let hidden = workspace.selectedTab!
    let other = workspace.createWorkspace(named: "Other")
    try workspace.moveTab(hidden.id, toWorkspace: other)
    workspace.selectTab(workspace.tabs[0].id)
    workspace.splitActive(axis: .horizontal)
    let source = workspace.selectedTab!
    let pane = workspace.activePane!
    pane.directory = "/tmp/relay-reparent"
    pane.composerState.draft = "unsent draft"
    let composer = pane.composerState, runtime = pane.runtime, profile = pane.profile
    let birth = (pane.remoteWorkspaceSessionID, pane.remoteTabID, pane.remoteParentSessionID, pane.harnessIdentity)
    let sessions = workspace.tabs.map(\.sessionID)

    let destination = WorkspacePaneDestination.split(tabID: hidden.id, beside: hidden.layout.paneIDs[0], placement: .bottom)
    #expect(workspace.canMovePane(pane.id, to: .split(tabID: hidden.id, beside: UUID(), placement: .leading)) == .unknownTarget)
    #expect(workspace.canMovePane(pane.id, to: .split(tabID: source.id, beside: nil, placement: .leading)) == .samePlace)
    #expect(workspace.canMovePane(pane.id, to: .newTab(workspaceID: UUID(), index: nil)) == .unknownWorkspace)
    #expect(workspace.canMovePane(pane.id, to: destination) == nil)
    #expect(try workspace.movePane(pane.id, to: destination) == hidden.id)

    #expect(workspace.panes[pane.id] === pane && pane.runtime === runtime && pane.composerState === composer)
    #expect(pane.id == workspace.panes[pane.id]?.id && pane.profile == profile && pane.directory == "/tmp/relay-reparent")
    #expect(composer.draft == "unsent draft")
    #expect(pane.remoteWorkspaceSessionID == birth.0 && pane.remoteTabID == birth.1 && pane.remoteParentSessionID == birth.2)
    #expect(pane.harnessIdentity == birth.3)
    #expect(hidden.allPaneIDs.contains(pane.id) && !source.allPaneIDs.contains(pane.id))
    #expect(workspace.selectedTabID == source.id && workspace.activePaneID != pane.id)
    #expect(workspace.workspaceID(forTab: hidden.id) == other && workspace.tabs.map(\.sessionID) == sessions)
    #expect(Set(workspace.tabs.flatMap(\.allPaneIDs)).count == workspace.tabs.flatMap(\.allPaneIDs).count)
    if case .split(_, let axis, .pane(let top), .pane(let bottom)) = hidden.layout {
        #expect(axis == .vertical && bottom == pane.id && top != pane.id)
    } else {
        Issue.record("The moved pane is not a new split leaf below its target")
    }
    #expect(workspace.canMovePane(source.allPaneIDs[0], to: .split(tabID: hidden.id, beside: nil, placement: .trailing)) == .lastPaneInTab)
    #expect(throws: WorkspaceMoveRefusal.lastPaneInTab) {
        try workspace.movePane(source.allPaneIDs[0], to: .split(tabID: hidden.id, beside: nil, placement: .trailing))
    }
    // A new tab in a third workspace, still hidden and still the same object.
    let third = workspace.createWorkspace(named: "Third")
    let tabID = try workspace.movePane(pane.id, to: .newTab(workspaceID: third, index: 0))
    #expect(workspace.workspaceID(forTab: tabID) == third && workspace.tabs(inWorkspace: third).map(\.id) == [tabID])
    #expect(workspace.panes[pane.id] === pane && pane.runtime === runtime && workspace.selectedTabID == source.id)
}

@MainActor
@Test("A pane given its own tab is owned by the requested workspace, not its birth session")
func workspaceNewTabOwnershipFromDestination() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.splitActive(axis: .horizontal)
    let pane = workspace.activePane!
    let birthSession = UUID(), birthTab = UUID()
    pane.assignRemoteHierarchy(workspaceSessionID: birthSession, tabID: birthTab)
    let destination = workspace.createWorkspace(named: "Destination")
    let before = workspace.ownership, tabs = workspace.tabs.map(\.id)
    #expect(throws: WorkspaceOwnershipError.unknownWorkspace) { try workspace.movePaneToNewTab(pane.id, inWorkspace: UUID()) }
    #expect(workspace.ownership == before && workspace.tabs.map(\.id) == tabs)
    let tabID = try workspace.movePaneToNewTab(pane.id, inWorkspace: destination)
    #expect(workspace.workspaceID(forTab: tabID) == destination)
    #expect(workspace.ownership.workspace(birthSession) == nil)
    #expect(workspace.tabs.first { $0.id == tabID }?.sessionID == birthSession)
    #expect(pane.remoteWorkspaceSessionID == birthSession.uuidString.lowercased() && pane.remoteTabID == birthTab.uuidString.lowercased())
}

@Test("The migration preview reproduces the doc's live table from the 2026-10-17 inventory")
func workspaceMigrationPreviewMatchesLiveTable() throws {
    let fixture = liveFixture()
    let ownership = WorkspaceOwnershipSnapshot.bootstrap(tabs: fixture.tabs)
    let preview = WorkspaceMigration.preview(tabs: fixture.tabs, organization: fixture.organization,
                                             ownership: ownership, overrides: fixture.overrides, scope: .global)
    let table = Dictionary(uniqueKeysWithValues: preview.workspaces.map { ($0.name, Set($0.tabIDs.compactMap { fixture.titles[$0] })) })
    #expect(table == livePreviewTable)
    #expect(preview.collisions.isEmpty)
    #expect(preview.rows.count == liveTabs.count)
    for (row, live) in zip(preview.rows, liveTabs) {
        #expect(row.groupPath == [live.3] && row.legacySessionName == live.2 && row.currentWorkspaceID == row.legacySessionID)
    }
    #expect(preview.workspaces.first { $0.name == "Ancient DNA training" }?.isEmptyGroup == true)
    #expect(preview.workspaces.filter(\.isNew).map(\.name).contains("Relay QA"))
    // General and the session containers are retired; DART reuses its session's ID.
    #expect(!table.keys.contains("General") && !table.keys.contains("Work") && !table.keys.contains("dandy-07"))
    #expect(Set(preview.removed.map(\.name)) == ["dandy-07", "Work", "Sapropel live Claude"])
    #expect(preview.workspaces.first { $0.name == "DART" }?.id == fixtureID("session:Work · dandy-07"))
    #expect(preview.rows.first { $0.title == "Rice" }?.workspaceID == fixtureID("group:Rice"))
    // Without overrides, ungrouped tabs fall back to their legacy session.
    let plain = WorkspaceMigration.preview(tabs: fixture.tabs, organization: fixture.organization, ownership: ownership)
    #expect(plain.rows.first { $0.title == "Preview QA AL" }?.workspaceID == fixtureID("session:Work"))
    #expect(plain.rows.first { $0.title == "Codex cache analysis" }?.workspaceName == "General")
    #expect(WorkspaceMigration.preview(tabs: fixture.tabs, organization: fixture.organization, ownership: ownership,
        overrides: fixture.overrides, keepEmptyGroups: false, scope: .global).workspaces.allSatisfy { $0.name != "Ancient DNA training" })
}

@Test("Migration names that normalize alike are reported as collisions and merged")
func workspaceMigrationReportsCollisions() {
    let session = UUID(), first = UUID(), second = UUID(), tabA = UUID(), tabB = UUID()
    let organization = WorkspaceOrganizationSnapshot(schemaVersion: 2, groups: [
        WorkspaceGroup(id: first, parentID: nil, order: 0, name: "Rice", kind: .project, collapsed: false),
        WorkspaceGroup(id: second, parentID: nil, order: 1, name: " rice", kind: .project, collapsed: false),
    ], placements: [WorkspaceTabPlacement(id: tabA, groupID: first, order: 0), WorkspaceTabPlacement(id: tabB, groupID: second, order: 0)], savedViews: [])
    let tabs = [tabA, tabB].map { WorkspaceTabReference(id: $0, sessionID: session, title: "T", sessionName: "S") }
    let preview = WorkspaceMigration.preview(tabs: tabs, organization: organization, ownership: .bootstrap(tabs: tabs))
    #expect(preview.collisions.count == 1 && preview.collisions[0].workspaceID == first)
    #expect(preview.rows.allSatisfy { $0.workspaceID == first })
}

@Test("Apply records checksums and inverse edits; Undo keeps tabs created afterwards")
func workspaceMigrationApplyUndoRoundTrip() throws {
    let fixture = liveFixture()
    let (store, directory) = temporaryStore("migration")
    defer { try? FileManager.default.removeItem(at: directory) }
    let initial = WorkspaceOwnershipSnapshot.bootstrap(tabs: fixture.tabs)
    _ = try store.commit(fixture.snapshot, baseline: nil, ownership: initial, ownershipBaseline: nil)
    _ = try store.commitOrganization(fixture.organization, baseline: nil)
    let workspaceBytes = try Data(contentsOf: directory.appendingPathComponent("workspace-v1.json"))
    let preview = try store.previewWorkspaceMigration(overrides: fixture.overrides, scope: .global)
    #expect(ownerTitles(initial, fixture)["Work"]?.contains("Preview QA AL") == true)

    let applied = try store.applyWorkspaceMigration(preview).ownership
    let record = try #require(applied.migrations.last)
    #expect(record.id == preview.id && record.sourceChecksums == preview.sourceChecksums)
    #expect(record.resultChecksum == applied.ownershipChecksum && record.forward.count == liveTabs.count)
    #expect(record.inverse.count == liveTabs.count && Set(record.replaced.map(\.name)).isSuperset(of: ["dandy-07", "Work"]))
    var applyTable = ownerTitles(applied, fixture)
    applyTable["Inbox"] = applyTable["Inbox"] ?? []
    #expect(applyTable == livePreviewTable)
    let backups = RelaySharedWorkspaceStore.migrationBackupNames(preview.id)
    #expect(try Data(contentsOf: directory.appendingPathComponent(backups.workspace)) == workspaceBytes)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(backups.organization).path))
    #expect(try store.restoreOwnership() == applied)
    #expect(throws: WorkspaceOwnershipError.staleMigration) { try store.applyWorkspaceMigration(preview) }

    // A tab created after the migration, filed in a workspace the migration created.
    let qa = try #require(applied.workspaces.first { $0.name == "Relay QA" }?.id)
    let laterTab = UUID(), laterPane = UUID()
    let later = WorkspaceSnapshot(tabs: fixture.snapshot.tabs + [TabSnapshot(id: laterTab, sessionID: laterTab, name: "Later",
            layout: .pane(laterPane), floatingPanes: [], splitRatios: [:])],
        panes: fixture.snapshot.panes + [PaneSnapshot(id: laterPane, profile: .local, contentKind: .terminal,
            remoteParentSessionID: nil, editorRequest: nil, customName: nil)],
        sessionNames: fixture.snapshot.sessionNames, selectedTabID: laterTab, activePaneID: laterPane)
    var filed = applied
    filed.owners.append(WorkspaceTabOwner(id: laterTab, workspaceID: qa, order: 9))
    // The user also re-files one migrated tab before undoing.
    let rice = tabID("51909c03")
    try filed.moveTab(rice, to: WorkspaceOwnershipSnapshot.inboxID)
    _ = try store.commit(later, baseline: fixture.snapshot, ownership: filed, ownershipBaseline: applied)

    let undone = try store.undoWorkspaceMigration(preview.id).ownership
    #expect(undone.owner(of: laterTab) == qa && undone.workspace(qa) != nil)
    #expect(undone.owner(of: rice) == WorkspaceOwnershipSnapshot.inboxID)
    for tab in fixture.tabs where tab.id != rice { #expect(undone.owner(of: tab.id) == tab.sessionID) }
    #expect(undone.workspace(fixtureID("group:PanBarley")) == nil && undone.workspace(fixtureID("session:Work"))?.name == "Work")
    #expect(undone.workspace(fixtureID("session:Work · dandy-07"))?.name == "Work · dandy-07")
    #expect(undone.migrations.last?.undoneAt != nil)
    #expect(throws: WorkspaceOwnershipError.alreadyUndone) { try store.undoWorkspaceMigration(preview.id) }
    try RelaySharedWorkspaceStore.validate(try #require(try store.restore(legacy: nil)))
}

@Test("An older writer ignores ownership, cannot drop it, and its tab edits are reconciled")
func workspaceOwnershipSurvivesOlderWriter() throws {
    let fixture = liveFixture()
    let (store, directory) = temporaryStore("fence")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try store.commit(fixture.snapshot, baseline: nil)
    let initial = WorkspaceOwnershipSnapshot.bootstrap(tabs: fixture.tabs)
    _ = try store.commit(fixture.snapshot, baseline: fixture.snapshot, ownership: initial, ownershipBaseline: nil)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("workspace-v1.pre-v3-backup.json").path))
    let ownershipURL = directory.appendingPathComponent("ownership-v3.json")
    let saved = try Data(contentsOf: ownershipURL)

    // The old schema's reader decodes the workspace file without the new fields.
    let workspaceJSON = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf:
        directory.appendingPathComponent("workspace-v1.json"))) as? [String: Any])
    #expect(Set(workspaceJSON.keys).isSubset(of: ["tabs", "panes", "sessionNames", "selectedTabID", "activePaneID",
        "recoveryWindow", "rPresentations", "sidebarVisible"]))
    var extended = workspaceJSON
    extended["workspaceOwnership"] = ["schemaVersion": 3]
    #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: extended)).tabs.count == liveTabs.count)

    // An older writer drops one tab and adds another through the old API only.
    let addedTab = UUID(), addedPane = UUID(), removed = fixture.snapshot.tabs[0]
    let older = WorkspaceSnapshot(tabs: Array(fixture.snapshot.tabs.dropFirst()) + [TabSnapshot(id: addedTab, sessionID: addedTab,
            name: "Old", layout: .pane(addedPane), floatingPanes: [], splitRatios: [:])],
        panes: fixture.snapshot.panes.filter { !removed.layout.paneIDs.contains($0.id) } + [PaneSnapshot(id: addedPane,
            profile: .local, contentKind: .terminal, remoteParentSessionID: nil, editorRequest: nil, customName: nil)],
        sessionNames: fixture.snapshot.sessionNames, selectedTabID: addedTab, activePaneID: addedPane)
    _ = try store.commit(older, baseline: fixture.snapshot)
    #expect(try Data(contentsOf: ownershipURL) == saved)
    let preview = try store.previewWorkspaceMigration()
    #expect(preview.rows.first { $0.tabID == addedTab }?.currentWorkspaceID == WorkspaceOwnershipSnapshot.inboxID)
    #expect(!preview.rows.contains { $0.tabID == removed.id })

    // A newer schema is refused rather than rewritten.
    var newer = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
    newer["schemaVersion"] = 4
    let newerBytes = try JSONSerialization.data(withJSONObject: newer)
    try newerBytes.write(to: ownershipURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownershipURL.path)
    #expect(throws: RelaySharedWorkspaceError.invalidSnapshot) { try store.restoreOwnership() }
    #expect(throws: RelaySharedWorkspaceError.invalidSnapshot) {
        try store.commit(older, baseline: older, ownership: initial, ownershipBaseline: initial)
    }
    #expect(try Data(contentsOf: ownershipURL) == newerBytes)
}

@Test("Concurrent ownership edits merge per tab: the newest entry wins and no tab or workspace is lost")
func workspaceOwnershipConflictKeepsNewestPerTab() throws {
    let fixture = liveFixture()
    let (first, directory) = temporaryStore("conflict")
    defer { try? FileManager.default.removeItem(at: directory) }
    let second = RelaySharedWorkspaceStore(directory: directory)
    let initial = WorkspaceOwnershipSnapshot.bootstrap(tabs: fixture.tabs)
    _ = try first.commit(fixture.snapshot, baseline: nil, ownership: initial, ownershipBaseline: nil)
    let shared = fixture.tabs[0].id, mineFirst = fixture.tabs[1].id, theirsOnly = fixture.tabs[2].id, mineOnly = fixture.tabs[3].id
    var mine = initial, theirs = initial
    let a = mine.createWorkspace(name: "A", id: UUID()), b = theirs.createWorkspace(name: "B", id: UUID())
    try theirs.moveTab(mineFirst, to: b)
    try mine.moveTab(shared, to: a)
    try theirs.moveTab(shared, to: b)          // later: newest for `shared`
    try mine.moveTab(mineFirst, to: a)         // later: newest for `mineFirst`
    try theirs.moveTab(theirsOnly, to: b)
    try mine.moveTab(mineOnly, to: a)          // different tabs: both writers' moves survive
    mine.owners.removeAll { $0.id == theirsOnly }   // a stale delete never loses a live tab
    _ = try first.commit(fixture.snapshot, baseline: fixture.snapshot, ownership: theirs, ownershipBaseline: initial)
    let renamed = WorkspaceSnapshot(tabs: [TabSnapshot(id: fixture.snapshot.tabs[1].id, sessionID: fixture.snapshot.tabs[1].sessionID,
            name: "Renamed", layout: fixture.snapshot.tabs[1].layout, floatingPanes: [], splitRatios: [:])]
            + fixture.snapshot.tabs.enumerated().filter { $0.offset != 1 }.map(\.element),
        panes: fixture.snapshot.panes, sessionNames: fixture.snapshot.sessionNames, selectedTabID: fixture.snapshot.selectedTabID,
        activePaneID: fixture.snapshot.activePaneID)
    let result = try second.commit(renamed, baseline: fixture.snapshot, ownership: mine, ownershipBaseline: initial)
    let merged = try #require(result.ownership)
    #expect(result.ownershipConflict)
    #expect(merged.owner(of: shared) == b && merged.owner(of: mineFirst) == a)
    #expect(merged.owner(of: theirsOnly) == b && merged.owner(of: mineOnly) == a)
    #expect(merged.workspace(a) != nil && merged.workspace(b) != nil)
    #expect(Set(merged.owners.map(\.id)) == Set(fixture.tabs.map(\.id)) && merged.owners.count == fixture.tabs.count)
    #expect(try first.restore(legacy: nil)?.tabs.contains { $0.name == "Renamed" } == true)
    #expect(try first.restoreOwnership() == merged)
    // Each edit raised that entry's revision.
    #expect(merged.owners.first { $0.id == shared }!.revision > initial.owners.first { $0.id == shared }!.revision)
}

@MainActor
@Test("New tabs are filed by the scope captured at admission, never by whatever is visible")
func workspaceNewTabAdmission() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let tab1 = workspace.selectedTab!
    let sourcePane = workspace.activePane!
    // Human ⌘T: the visible workspace.
    workspace.newTab(profile: .local)
    let tab2 = workspace.selectedTab!
    #expect(workspace.workspaceID(forTab: tab2.id) == workspace.workspaceID(forTab: tab1.id))
    let project = workspace.createWorkspace(named: "Project"), later = workspace.createWorkspace(named: "Later")
    try workspace.moveTab(tab1.id, toWorkspace: project)

    // An agent request from tab1's pane, admitted now and applied after the
    // source tab moved and another workspace became visible.
    let admission = workspace.tabAdmission(forSourcePane: sourcePane.id)
    #expect(admission == .workspace(project))
    try workspace.moveTab(tab1.id, toWorkspace: later)
    workspace.selectTab(tab2.id)
    let proposal = WorkspaceProposal(instance: UUID(), requestID: UUID(), paneID: sourcePane.id, action: .newTab)
    let created = try #require(workspace.withTabAdmission(admission) { workspace.applyWorkspaceAction(proposal, expected: sourcePane) })
    #expect(workspace.workspaceID(forTab: created.0) == project)
    // Applied without a captured scope, it uses the source pane's workspace at execution.
    let direct = try #require(workspace.applyWorkspaceAction(WorkspaceProposal(instance: UUID(), requestID: UUID(),
        paneID: sourcePane.id, action: .newTab), expected: sourcePane))
    #expect(workspace.workspaceID(forTab: direct.0) == later)

    // An agent with no source pane (MCP local tab): the Inbox, not the visible workspace.
    workspace.selectTab(tab2.id)
    workspace.newTab(profile: .local, origin: .agent(sourcePane: nil))
    #expect(workspace.workspaceID(forTab: workspace.selectedTabID!) == WorkspaceOwnershipSnapshot.inboxID)
    workspace.selectTab(tab2.id)
    workspace.newTabInActiveSession(profile: .local, origin: .agent(sourcePane: nil))
    #expect(workspace.workspaceID(forTab: workspace.selectedTabID!) == WorkspaceOwnershipSnapshot.inboxID)
    // An agent with a source pane: that pane's workspace, not the visible one.
    workspace.selectTab(tab2.id)
    workspace.newTab(profile: .local, origin: .agent(sourcePane: sourcePane.id))
    #expect(workspace.workspaceID(forTab: workspace.selectedTabID!) == later)
    // A captured scope wins over the origin's default.
    workspace.withTabAdmission(.inbox) { workspace.newTab(profile: .local) }
    #expect(workspace.workspaceID(forTab: workspace.selectedTabID!) == WorkspaceOwnershipSnapshot.inboxID)

    // Session switcher: the workspace owning the session's source tab, not the visible one.
    workspace.selectTab(tab2.id)
    workspace.newTab(inSession: tab1.sessionID)
    #expect(workspace.selectedTab?.sessionID == tab1.sessionID)
    #expect(workspace.workspaceID(forTab: workspace.selectedTabID!) == later)

    // A tab appearing with no admission (attach, older writer) never takes the visible workspace.
    var ownership = workspace.ownership
    let orphan = WorkspaceTabReference(id: UUID(), sessionID: UUID(), title: "", sessionName: "")
    ownership.reconcile(tabs: workspace.tabs.map { WorkspaceTabReference(id: $0.id, sessionID: $0.sessionID, title: "", sessionName: "") } + [orphan])
    #expect(ownership.owner(of: orphan.id) == WorkspaceOwnershipSnapshot.inboxID)
}

@MainActor
@Test("The approved live plan applies with its three pane moves and undoes exactly, keeping a later tab")
func workspaceMigrationLivePlanWithPaneMoves() throws {
    let fixture = liveFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-live-plan-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RelaySharedWorkspaceStore(directory: directory)
    _ = try store.commit(fixture.snapshot, baseline: nil)
    _ = try store.commitOrganization(fixture.organization, baseline: nil)
    let workspace = WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: directory)
    defer { workspace.shutdown() }
    #expect(workspace.tabs.map(\.id) == fixture.tabs.map(\.id))
    let moves = Dictionary(uniqueKeysWithValues: livePaneMoves.map { (UUID(uuidString: $0.pane)!, tabID($0.to)) })
    let objects = Dictionary(uniqueKeysWithValues: moves.keys.map { ($0, workspace.panes[$0]!) })
    let runtimes = objects.mapValues(\.runtime)
    let births = objects.mapValues { [$0.remoteWorkspaceSessionID, $0.remoteTabID] }
    let layouts = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0.layout) })
    let sessions = workspace.tabs.map(\.sessionID), selected = workspace.selectedTabID, active = workspace.activePaneID
    #expect(births[UUID(uuidString: livePaneMoves[2].pane)!] == [fixtureID("session:dandy-07").uuidString.lowercased(),
        tabID("a8922a82").uuidString.lowercased()])

    let preview = try workspace.previewWorkspaceMigration(overrides: fixture.overrides, paneMoves: moves, keepEmptyGroups: false, scope: .global)
    var expected = livePreviewTable
    expected["Ancient DNA training"] = nil
    #expect(Dictionary(uniqueKeysWithValues: preview.workspaces.map { ($0.name, Set($0.tabIDs.compactMap { fixture.titles[$0] })) }) == expected)
    #expect(preview.workspaces.count == 14 && preview.workspaces.last?.id == WorkspaceOwnershipSnapshot.inboxID)
    #expect(Set(preview.retiredGroups.map(\.name)) == ["General", "Ancient DNA training"])
    #expect(preview.refusals.isEmpty)
    #expect(Set(preview.paneMoves.map { [$0.paneID, $0.fromTabID, $0.toTabID] })
        == Set(livePaneMoves.map { [UUID(uuidString: $0.pane)!, tabID($0.from), tabID($0.to)] }))

    try workspace.applyWorkspaceMigration(preview)
    for (paneID, destination) in moves {
        let pane = try #require(objects[paneID])
        #expect(workspace.tabID(containingPane: paneID) == destination)
        #expect(workspace.panes[paneID] === pane && pane.runtime === runtimes[paneID])
        #expect([pane.remoteWorkspaceSessionID, pane.remoteTabID] == births[paneID])
    }
    // The fqdup move crosses legacy sessions: dandy-07 → Work · dandy-07.
    let fqdup = try #require(workspace.tabs.first { $0.id == tabID("bf8a5a2b") })
    #expect(fqdup.sessionID == fixtureID("session:Work · dandy-07") && fqdup.layout.paneIDs.last == paneID("1fb0f4e6"))
    #expect(workspace.tabs.map(\.sessionID) == sessions && workspace.selectedTabID == selected && workspace.activePaneID == active)
    var owned = ownerTitles(workspace.ownership, fixture)
    owned["Inbox"] = owned["Inbox"] ?? []
    #expect(owned == expected)
    let record = try #require(workspace.ownership.migrations.last)
    #expect(record.paneMoves.count == 3 && record.paneMoves.allSatisfy { $0.state == .done && $0.sourceLayout != nil })
    #expect(Set(record.retiredGroups.map(\.name)) == ["General", "Ancient DNA training"])
    #expect(try store.restoreOwnership()?.migrations.last?.paneMoves.allSatisfy { $0.movedSourceLayout != nil } == true)
    let saved = try #require(try store.restore(legacy: nil))
    #expect(saved.tabs.first { $0.id == tabID("941fd236") }?.layout.paneIDs.contains(paneID("94642f2a")) == true)
    // Both layers moved together: the saved organization is the fixture's
    // with exactly the recorded placement moves and created groups, and
    // no migrated tab's ownership and placement disagree.
    let savedOrganization = try #require(try store.restoreOrganization())
    var expectedPlacements = fixture.organization.placements
    for move in record.placementMoves ?? [] {
        #expect(expectedPlacements.first { $0.id == move.tabID } == move.before)
        expectedPlacements.removeAll { $0.id == move.tabID }
        expectedPlacements.append(move.after)
    }
    #expect(savedOrganization.placements.sorted { $0.id.uuidString < $1.id.uuidString }
        == expectedPlacements.sorted { $0.id.uuidString < $1.id.uuidString })
    #expect(Set(savedOrganization.groups.map(\.id)) == Set(fixture.organization.groups.map(\.id)).union(record.createdGroups ?? []))
    #expect(savedOrganization.groups.filter { !(record.createdGroups ?? []).contains($0.id) }
        .sorted { $0.id.uuidString < $1.id.uuidString } == fixture.organization.groups.sorted { $0.id.uuidString < $1.id.uuidString })
    #expect(WorkspaceMigration.disagreeing(tabs: fixture.tabs, organization: savedOrganization, ownership: workspace.ownership)
        .isDisjoint(with: Set(fixture.tabs.map(\.id))))

    // After migration the dandy-07 session has no workspace. The session
    // switcher files its new tab with the session's source tab (PanBarley),
    // not the visible Relay & Chitta; an agent tab follows its source pane.
    let visible = workspace.workspaceID(forTab: tabID("331eea46"))
    workspace.newTab(inSession: fixtureID("session:dandy-07"))
    let switched = try #require(workspace.selectedTabID)
    #expect(workspace.ownership.workspace(fixtureID("session:dandy-07")) == nil)
    #expect(workspace.workspaceID(forTab: switched) == fixtureID("group:PanBarley") && visible != fixtureID("group:PanBarley"))
    workspace.selectTab(tabID("331eea46"))
    workspace.newTab(profile: .local, origin: .agent(sourcePane: paneID("4b3c6f80")))
    #expect(workspace.workspaceID(forTab: workspace.selectedTabID!) == fixtureID("group:Rice"))
    // A tab created after the migration survives its Undo.
    workspace.selectTab(tabID("331eea46"))
    workspace.newTab(profile: .local)
    let later = try #require(workspace.selectedTabID)
    let laterOwner = workspace.workspaceID(forTab: later)
    #expect(laterOwner == visible)
    try workspace.undoWorkspaceMigration(preview.id)
    for tab in workspace.tabs where layouts[tab.id] != nil { #expect(tab.layout == layouts[tab.id]) }
    for (paneID, pane) in objects { #expect(workspace.panes[paneID] === pane && pane.runtime === runtimes[paneID]) }
    for tab in fixture.tabs { #expect(workspace.workspaceID(forTab: tab.id) == tab.sessionID) }
    #expect(workspace.tabs.contains { $0.id == later } && laterOwner != nil && workspace.workspaceID(forTab: later) == laterOwner)
    #expect(workspace.workspaceID(forTab: switched) == fixtureID("group:PanBarley"))
    #expect(workspace.ownership.migrations.last?.undoneAt != nil)
    #expect(throws: WorkspaceOwnershipError.alreadyUndone) { try workspace.undoWorkspaceMigration(preview.id) }
}

private struct SimulatedCrash: Error {}

/// A restored model over a store holding the live fixture.
@MainActor
private func liveModel(_ directory: URL, withFARO: Bool = false) throws -> (WorkspaceModel, LiveFixture, [UUID: UUID]) {
    let fixture = liveFixture(withFARO: withFARO)
    let store = RelaySharedWorkspaceStore(directory: directory)
    _ = try store.commit(fixture.snapshot, baseline: nil)
    _ = try store.commitOrganization(fixture.organization, baseline: nil)
    let moves = Dictionary(uniqueKeysWithValues: livePaneMoves.map { (UUID(uuidString: $0.pane)!, tabID($0.to)) })
    return (WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: directory), fixture, moves)
}

@MainActor
@Test("A crash between the migration's ownership and layout writes is settled on load, and Undo still reverses every move that happened")
func workspaceMigrationCrashBetweenWrites() throws {
    for step in ["ownership-pending", "workspace"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-crash-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (crashing, fixture, moves) = try liveModel(directory)
        let layouts = Dictionary(uniqueKeysWithValues: crashing.tabs.map { ($0.id, $0.layout) })
        let preview = try crashing.previewWorkspaceMigration(overrides: fixture.overrides, paneMoves: moves, keepEmptyGroups: false, scope: .global)
        crashing.sharedWorkspaceStore.migrationFault = { if $0 == step { throw SimulatedCrash() } }
        #expect(throws: SimulatedCrash.self) { try crashing.applyWorkspaceMigration(preview) }
        // The failing process is settled to exactly what was committed.
        let committed = try #require(try crashing.sharedWorkspaceStore.restore(legacy: nil))
        for (paneID, _) in moves {
            #expect(crashing.tabID(containingPane: paneID)
                == WorkspaceTabReference.references(committed).first { $0.paneIDs.contains(paneID) }?.id)
        }

        // Relaunch from what the crash left on disk.
        let relaunched = WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: directory)
        defer { relaunched.shutdown() }
        let record = try #require(relaunched.ownership.migrations.first { $0.id == preview.id })
        let landed = step == "workspace"
        #expect(record.paneMoves.count == 3 && record.paneMoves.allSatisfy { $0.state == (landed ? .done : .rolledBack) })
        for (paneID, destination) in moves {
            let source = tabID(livePaneMoves.first { $0.pane == paneID.uuidString.lowercased() }!.from)
            #expect(relaunched.tabID(containingPane: paneID) == (landed ? destination : source))
        }
        #expect(relaunched.workspaceID(forTab: tabID("2a963d75")) == relaunched.ownership.workspaces.first { $0.name == "Relay QA" }?.id)
        try relaunched.undoWorkspaceMigration(preview.id)
        for tab in relaunched.tabs { #expect(tab.layout == layouts[tab.id]) }
        for tab in fixture.tabs { #expect(relaunched.workspaceID(forTab: tab.id) == tab.sessionID) }
        #expect(try RelaySharedWorkspaceStore(directory: directory).restoreOwnership()?.migrations.first { $0.id == preview.id }?.undoneAt != nil)
    }
}

@MainActor
@Test("A crash during Undo is settled on load: moves already returned are not reversed twice, the rest still are")
func workspaceMigrationCrashDuringUndo() throws {
    for step in ["ownership-reverting", "workspace"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-undo-crash-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (first, fixture, moves) = try liveModel(directory)
        let layouts = Dictionary(uniqueKeysWithValues: first.tabs.map { ($0.id, $0.layout) })
        let preview = try first.previewWorkspaceMigration(overrides: fixture.overrides, paneMoves: moves, keepEmptyGroups: false, scope: .global)
        try first.applyWorkspaceMigration(preview)
        first.sharedWorkspaceStore.migrationFault = { if $0 == step { throw SimulatedCrash() } }
        #expect(throws: SimulatedCrash.self) { try first.undoWorkspaceMigration(preview.id) }
        let committed = try #require(try first.sharedWorkspaceStore.restore(legacy: nil))
        for (paneID, destination) in moves {
            let home = WorkspaceTabReference.references(committed).first { $0.paneIDs.contains(paneID) }?.id
            #expect(first.tabID(containingPane: paneID) == home)
            #expect((home == destination) == (step == "ownership-reverting"))
        }

        let relaunched = WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: directory)
        defer { relaunched.shutdown() }
        let record = try #require(relaunched.ownership.migrations.first { $0.id == preview.id })
        let returned = step == "workspace"
        #expect(record.undoneAt == nil && record.paneMoves.allSatisfy { $0.state == (returned ? .reverted : .done) })
        try relaunched.undoWorkspaceMigration(preview.id)
        for tab in relaunched.tabs { #expect(tab.layout == layouts[tab.id]) }
        for tab in fixture.tabs { #expect(relaunched.workspaceID(forTab: tab.id) == tab.sessionID) }
    }
}

// Root review probes (workspaces-phase1-review-20261017-a), kept as regressions.

@MainActor
@Test("A successful save adopts another writer's placement before admitting a new tab")
func workspaceAdoptsMergedPlacementOnEverySave() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-adoption-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, _) = try liveModel(directory)
    defer { model.shutdown() }
    _ = try model.previewWorkspaceMigration() // flush the renderer's baseline
    let store = RelaySharedWorkspaceStore(directory: directory)
    let tab = model.tabs[0], sourcePane = tab.allPaneIDs[0]
    let persistedWorkspace = try #require(try store.restore(legacy: nil))
    let ownershipBaseline = try #require(try store.restoreOwnership())
    var otherWriter = ownershipBaseline
    let target = otherWriter.createWorkspace(name: "Other writer's project")
    try otherWriter.moveTab(tab.id, to: target)
    _ = try store.commit(persistedWorkspace, baseline: persistedWorkspace,
                         ownership: otherWriter, ownershipBaseline: ownershipBaseline)
    _ = try model.previewWorkspaceMigration() // an ordinary successful save reads the merge
    let diskOwner = try #require(try store.restoreOwnership()?.owner(of: tab.id))
    let rendererOwner = try #require(model.workspaceID(forTab: tab.id))
    let admission = model.tabAdmission(forSourcePane: sourcePane)
    model.newTab(profile: .local, origin: .agent(sourcePane: sourcePane))
    let created = try #require(model.selectedTabID)
    _ = try model.previewWorkspaceMigration()
    let newOwner = try #require(try store.restoreOwnership()?.owner(of: created))
    #expect(diskOwner == target) // positive control: the other writer's move survived
    #expect(rendererOwner == target)
    #expect(admission == .workspace(target))
    #expect(newOwner == target)
    #expect(model.ownership.workspace(target)?.name == "Other writer's project")
}

@Test("Migration Undo preserves a later tab-order edit and still reverses unchanged owners")
func workspaceUndoPreservesLaterReorder() throws {
    let fixture = liveFixture()
    let initial = WorkspaceOwnershipSnapshot.bootstrap(tabs: fixture.tabs)
    let preview = WorkspaceMigration.preview(tabs: fixture.tabs, organization: fixture.organization,
        ownership: initial, overrides: fixture.overrides, keepEmptyGroups: false, scope: .global)
    let (applied, placed) = try WorkspaceMigration.apply(preview, to: initial, organization: fixture.organization, tabs: fixture.tabs,
                                                         current: preview.sourceChecksums)
    let target = try #require(applied.workspaces.first { $0.name == "Relay & Chitta" }?.id)
    let tab = try #require(applied.tabIDs(in: target).last)
    var edited = applied
    try edited.moveTab(tab, to: target, at: 0)
    let laterPlacement = try #require(edited.owners.first { $0.id == tab })
    let undone = try WorkspaceMigration.undo(preview.id, in: edited, organization: placed).ownership
    let result = try #require(undone.owners.first { $0.id == tab })
    #expect(laterPlacement.revision > applied.owners.first { $0.id == tab }!.revision)
    #expect(result == laterPlacement)
    // Its siblings were only renumbered by the reorder, so they are reversed.
    for sibling in applied.tabIDs(in: target) where sibling != tab {
        #expect(undone.owner(of: sibling) == initial.owner(of: sibling))
    }
}

@MainActor
@Test("A failed migration settles the current renderer before its next successful save")
func workspaceMigrationFailureSettlesContinuingRenderer() throws {
    for step in ["workspace", "ownership-pending"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-continuation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, fixture, moves) = try liveModel(directory)
        defer { model.shutdown() }
        let layouts = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.layout) })
        let preview = try model.previewWorkspaceMigration(overrides: fixture.overrides, paneMoves: moves, keepEmptyGroups: false, scope: .global)
        model.sharedWorkspaceStore.migrationFault = { if $0 == step { throw SimulatedCrash() } }
        #expect(throws: SimulatedCrash.self) { try model.applyWorkspaceMigration(preview) }
        #expect(model.workspacePersistenceIssue != nil)
        model.sharedWorkspaceStore.migrationFault = nil
        _ = try model.previewWorkspaceMigration() // keep using the same app after the error
        let disk = try #require(try model.sharedWorkspaceStore.restore(legacy: nil))
        let diskOwnership = try #require(try model.sharedWorkspaceStore.restoreOwnership())
        let diskRecord = try #require(diskOwnership.migrations.first { $0.id == preview.id })
        for move in preview.paneMoves {
            let diskHome = try #require(WorkspaceTabReference.references(disk).first { $0.paneIDs.contains(move.paneID) }?.id)
            #expect(diskHome == model.tabID(containingPane: move.paneID))
            #expect(diskHome == (step == "workspace" ? move.toTabID : move.fromTabID))
        }
        #expect(diskRecord.paneMoves.allSatisfy { $0.state == (step == "workspace" ? .done : .rolledBack) })
        #expect(model.ownership.migrations.first { $0.id == preview.id } == diskRecord)
        try model.undoWorkspaceMigration(preview.id)
        for tab in model.tabs { #expect(tab.layout == layouts[tab.id]) }
        for tab in fixture.tabs { #expect(model.workspaceID(forTab: tab.id) == tab.sessionID) }
    }
}

// Root review v2 probe (workspaces-phase1-review-20261017-b), kept as a regression.
@MainActor
@Test("Settling an interrupted apply or Undo takes the exact saved layouts, and keeps them through the next save")
func workspaceSettlementPreservesSavedLayouts() throws {
    for (operation, step) in [("apply", "ownership-pending"), ("apply", "workspace"),
                              ("undo", "ownership-reverting"), ("undo", "workspace")] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-v2-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, fixture, moves) = try liveModel(directory)
        defer { model.shutdown() }
        let preview = try model.previewWorkspaceMigration(overrides: fixture.overrides, paneMoves: moves, keepEmptyGroups: false, scope: .global)
        if operation == "undo" { try model.applyWorkspaceMigration(preview) }
        let objects = Dictionary(uniqueKeysWithValues: moves.keys.map { ($0, model.panes[$0]!) })
        let runtimes = objects.mapValues(\.runtime)
        let births = objects.mapValues { [$0.remoteWorkspaceSessionID, $0.remoteTabID] }
        model.sharedWorkspaceStore.migrationFault = { if $0 == step { throw SimulatedCrash() } }
        #expect(throws: SimulatedCrash.self) {
            if operation == "apply" { try model.applyWorkspaceMigration(preview) }
            else { try model.undoWorkspaceMigration(preview.id) }
        }
        model.sharedWorkspaceStore.migrationFault = nil
        let committed = try #require(try model.sharedWorkspaceStore.restore(legacy: nil))
        for tab in model.tabs {
            let saved = try #require(committed.tabs.first { $0.id == tab.id })
            #expect(tab.layout.paneIDs == saved.layout.paneIDs, "\(operation) \(step)")
            #expect(tab.layout == saved.layout && tab.splitRatios == (saved.splitRatios ?? [:]), "\(operation) \(step)")
            #expect(tab.floatingPanes == (saved.floatingPanes ?? []))
        }
        for (paneID, pane) in objects {
            #expect(model.panes[paneID] === pane && pane.runtime === runtimes[paneID])
            #expect([pane.remoteWorkspaceSessionID, pane.remoteTabID] == births[paneID])
        }
        #expect(model.workspacePersistenceIssue != nil)
        _ = try model.previewWorkspaceMigration() // ordinary continued use of the same renderer
        let afterNextSave = try #require(try model.sharedWorkspaceStore.restore(legacy: nil))
        for saved in committed.tabs {
            let after = try #require(afterNextSave.tabs.first { $0.id == saved.id })
            #expect(after.layout == saved.layout && (after.splitRatios ?? [:]) == (saved.splitRatios ?? [:]), "\(operation) \(step)")
        }
        for tab in model.tabs { #expect(tab.layout == afterNextSave.tabs.first { $0.id == tab.id }?.layout) }
        // The notice clears only once this window and the saved workspace agree.
        #expect(model.workspacePersistenceIssue == nil)
    }
}

// MARK: Phase 3: navigator drag and drop, and the in-app migration preview.

/// Copy of work/workspace-migration-plan-20261017.json (the user's decided plan), plus
/// "scope": "global" (QA-F01b): the plan is a full reconcile, which a plan with
/// overrides no longer is by default.
private let decidedPlanJSON = """
{
 "description": "Live workspace migration plan, user-approved decisions 2026-10-16/17 (docs/WORKSPACE-HIERARCHY-PROPOSAL.md). Default: project group -> workspace; overrides re-sort General and session groups.",
 "keepEmptyGroups": false,
 "scope": "global",
 "overrides": {
  "31b646ff-01ea-4c9c-8302-20c794cdaa1a": "Relay & Chitta",
  "e30c970c-637e-4446-b5ad-3c9a8cbd2606": "Relay & Chitta",
  "179b28a1-cdea-46c5-98f2-cd58fee8af78": "Relay & Chitta",
  "35cd47d4-d9bb-45eb-ae0e-bfff25247e15": "Relay & Chitta",
  "2a963d75-4bcd-4db1-8661-622e751d93cf": "Relay QA",
  "606b8280-6f8c-47b8-ad2e-54656d128bf3": "Relay QA",
  "41d22cfa-1b54-40c9-b4fe-3b0de8b22c9f": "Relay QA",
  "88eb3cf4-9702-45bf-9e75-1a47f2837cb9": "Relay QA",
  "518cf72a-8eb4-413d-8294-7a9b7b5e9588": "Kapk review",
  "fb16df7f-f9c1-4e4c-a24b-cf3e5c769984": "DART",
  "1aa9f60c-270d-4a75-9657-b7f5a6f701c8": "Inbox",
  "986d6b72-0ee4-4947-b41a-98386af7453a": "Inbox",
  "b1de1729-eb03-453e-aa53-af134df3634e": "FARO Labs",
  "e0c5f896-08dc-4c6f-b96a-5b4527801d4b": "FARO Labs",
  "f4656b14-b22f-4629-b46b-5ab329a1228e": "FARO Labs",
  "35ab0565-534e-4347-bdde-4767ef11f669": "FARO Labs"
 },
 "paneMoves": {
  "94642f2a-2858-4cea-80d2-3e06a6e9d43e": "941fd236-33f6-4c41-aaac-063fadbc4bab",
  "e66b4c7c-60d9-41f4-8cff-5ba571ab2d77": "941fd236-33f6-4c41-aaac-063fadbc4bab",
  "1fb0f4e6-4496-4c8d-94b4-a0f0e6e8afda": "bf8a5a2b-6fc1-4fa3-b198-3843fa2485e2"
 },
 "note": "Re-previewed in-app and approved by the user before apply."
}
"""

@MainActor
@Test("Navigator drops move a pane across workspaces and legacy sessions, keeping the same pane and never attaching a hidden one")
func navigatorPaneDropAcrossWorkspacesAndSessions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-navigator-pane-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, _) = try liveModel(directory)
    defer { model.shutdown() }
    let paneID = paneID("1fb0f4e6"), source = tabID("a8922a82"), fqdup = tabID("bf8a5a2b")
    let pane = try #require(model.panes[paneID])
    pane.directory = "/home/kbd606/repos/fqdup"
    pane.composerState.draft = "unsent fqdup draft"
    let runtime = pane.runtime, composer = pane.composerState, profile = pane.profile
    let started = runtime.hasStarted, pid = runtime.networkForegroundPID, harness = pane.harnessIdentity
    let birth = [pane.remoteWorkspaceSessionID, pane.remoteTabID, pane.remoteParentSessionID]
    let selected = model.selectedTabID, active = model.activePaneID
    let fqdupTab = try #require(model.tabs.first { $0.id == fqdup })
    let sourceTab = try #require(model.tabs.first { $0.id == source })
    // Different workspaces and different legacy sessions (dandy-07 → Work · dandy-07).
    #expect(model.workspaceID(forTab: source) != model.workspaceID(forTab: fqdup))
    #expect(sourceTab.sessionID != fqdupTab.sessionID)
    let canvas = fqdupTab.canvasSize

    #expect(model.canDrop(.paneOnTab(paneID: paneID, tabID: fqdup)) == nil)
    try model.performDrop(.paneOnTab(paneID: paneID, tabID: fqdup))

    #expect(model.tabID(containingPane: paneID) == fqdup && fqdupTab.layout.paneIDs.last == paneID)
    #expect(model.panes[paneID] === pane && pane.runtime === runtime && pane.composerState === composer)
    #expect(pane.profile == profile && pane.directory == "/home/kbd606/repos/fqdup" && composer.draft == "unsent fqdup draft")
    #expect([pane.remoteWorkspaceSessionID, pane.remoteTabID, pane.remoteParentSessionID] == birth && pane.harnessIdentity == harness)
    #expect(runtime.networkForegroundPID == pid)
    // The destination is hidden: nothing is selected, started or resized.
    #expect(model.selectedTabID == selected && model.activePaneID == active)
    #expect(runtime.hasStarted == started && fqdupTab.canvasSize == canvas)
    #expect(sourceTab.sessionID != fqdupTab.sessionID) // legacy sessions are untouched

    // Into its own new tab in another workspace, still the same object.
    let target = try #require(model.workspaceID(forTab: tabID("cd59ed8d")))
    try model.performDrop(.paneOnWorkspace(paneID: paneID, workspaceID: target))
    let newTab = try #require(model.tabID(containingPane: paneID))
    #expect(model.workspaceID(forTab: newTab) == target && model.panes[paneID] === pane && pane.runtime === runtime)
    #expect(model.selectedTabID == selected && runtime.hasStarted == started)
}

@MainActor
@Test("Navigator drops move a tab into a workspace at an index, reorder tabs and workspaces, and keep the Inbox last")
func navigatorTabAndWorkspaceDrops() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let sort = workspace.navigatorSort
    defer { workspace.setNavigatorSortMode(sort) }
    // Indexed tab ordering has an observable position in Manual mode.
    workspace.setNavigatorSortMode(.manual)
    workspace.newTab(profile: .local)
    workspace.newTab(profile: .local)
    let home = try #require(workspace.selectedWorkspaceID)
    let target = workspace.createWorkspace(named: "Target")
    let other = workspace.createWorkspace(named: "Other")
    let tabs = workspace.tabs.map(\.id)
    let panes = workspace.tabs.map(\.allPaneIDs)
    try workspace.performDrop(.tabOnWorkspace(tabID: tabs[0], workspaceID: target, index: nil))
    try workspace.performDrop(.tabOnWorkspace(tabID: tabs[1], workspaceID: target, index: 0))
    #expect(workspace.tabs(inWorkspace: target).map(\.id) == [tabs[1], tabs[0]])
    try workspace.performDrop(.tabOnWorkspace(tabID: tabs[2], workspaceID: target, index: 1))
    #expect(workspace.tabs(inWorkspace: target).map(\.id) == [tabs[1], tabs[2], tabs[0]])
    try workspace.performDrop(.tabBeforeTab(tabID: tabs[0], targetTabID: tabs[1]))
    #expect(workspace.tabs(inWorkspace: target).map(\.id) == [tabs[0], tabs[1], tabs[2]])
    #expect(workspace.tabs(inWorkspace: home).isEmpty && workspace.tabs.map(\.allPaneIDs) == panes)

    // A workspace drop in attention order switches the saved sort to Manual.
    workspace.setNavigatorSortMode(.attention)
    try workspace.performDrop(.workspaceBefore(workspaceID: other, targetID: target))
    #expect(workspace.navigatorSort == .manual)
    let order = workspace.ownership.orderedWorkspaces.map(\.id)
    #expect(order.firstIndex(of: other)! < order.firstIndex(of: target)! && order.last == WorkspaceOwnershipSnapshot.inboxID)
    #expect(workspace.canDrop(.workspaceBefore(workspaceID: WorkspaceOwnershipSnapshot.inboxID, targetID: other)) == .samePlace)

    // The rail and the workspace switcher follow the selected tab's workspace.
    workspace.selectWorkspace(target)
    #expect(workspace.selectedWorkspaceID == target && workspace.railTabs(inWorkspace: target).map(\.id) == [tabs[0], tabs[1], tabs[2]])
    workspace.selectTab(offset: 1)
    #expect(workspace.selectedTabID == tabs[1])
}

@MainActor
@Test("Invalid navigator drops are refused with their reason and change nothing")
func navigatorRefusesInvalidDrops() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .local)
    let lone = try #require(workspace.selectedTab)
    let other = workspace.tabs[0]
    let before = workspace.ownership, layouts = workspace.tabs.map(\.layout)
    let cases: [(WorkspaceNavigatorDrop, WorkspaceMoveRefusal)] = [
        (.paneOnTab(paneID: lone.allPaneIDs[0], tabID: other.id), .lastPaneInTab),
        (.paneOnTab(paneID: other.allPaneIDs[0], tabID: other.id), .samePlace),
        (.paneOnTab(paneID: UUID(), tabID: other.id), .unknownPane),
        (.paneOnWorkspace(paneID: other.allPaneIDs[0], workspaceID: UUID()), .unknownWorkspace),
        (.tabOnWorkspace(tabID: lone.id, workspaceID: UUID(), index: nil), .unknownWorkspace),
        (.tabBeforeTab(tabID: lone.id, targetTabID: lone.id), .samePlace),
        (.workspaceBefore(workspaceID: UUID(), targetID: nil), .unknownWorkspace),
    ]
    for (drop, refusal) in cases {
        #expect(workspace.canDrop(drop) == refusal)
        #expect(!(refusal.errorDescription ?? "").isEmpty)
        #expect(throws: refusal) { try workspace.performDrop(drop) }
    }
    #expect(workspace.ownership == before && workspace.tabs.map(\.layout) == layouts)
}

@MainActor
@Test("Hiding, favouriting and searching workspaces never closes a tab or stops a pane")
func navigatorHideIsNotClose() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    workspace.newTab(profile: .local)
    let tab = try #require(workspace.selectedTab)
    let pane = try #require(workspace.activePane)
    let runtime = pane.runtime, started = runtime.hasStarted
    let project = workspace.createWorkspace(named: "Project Alpha")
    try workspace.moveTab(tab.id, toWorkspace: project)
    workspace.renameWorkspace(project, to: "Alpha")
    workspace.setWorkspaceHidden(project, true)
    #expect(workspace.navigatorWorkspaces().hidden.map(\.id) == [project])
    #expect(!workspace.navigatorWorkspaces().shown.contains { $0.id == project })
    #expect(workspace.tabs.contains { $0 === tab } && workspace.panes[pane.id] === pane && pane.runtime === runtime)
    #expect(runtime.hasStarted == started && workspace.workspaceID(forTab: tab.id) == project)
    workspace.setWorkspaceHidden(project, false)
    workspace.setWorkspaceFavourite(project, true)
    #expect(workspace.navigatorWorkspaces().shown.first?.id == project)
    #expect(workspace.navigatorWorkspaces().shown.last?.id == WorkspaceOwnershipSnapshot.inboxID)
    #expect(workspace.navigatorWorkspaces(matching: "alp").shown.map(\.id) == [project])
    #expect(workspace.navigatorWorkspaces(matching: tab.name).shown.map(\.id).contains(project))
    // The hidden flag is optional, so schema 3 records written before it still decode.
    let legacy = #"{"id":"\#(UUID())","name":"Old","order":1,"favourite":false,"hostDefaults":{},"isInbox":false,"aliases":[]}"#
    #expect(try JSONDecoder().decode(WorkspaceRecord.self, from: Data(legacy.utf8)).hidden == nil)
}

@MainActor
@Test("The in-app preview of the decided plan shows every tab's new workspace and the three pane moves")
func navigatorMigrationPreviewMatchesDecidedPlan() throws {
    let plan = try WorkspaceMigrationPlan.parse(Data(decidedPlanJSON.utf8))
    #expect(plan.overrides.count == 16 && plan.paneMoves.count == 3 && !plan.keepEmptyGroups)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-navigator-plan-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, fixture, _) = try liveModel(directory, withFARO: true)
    defer { model.shutdown() }
    let preview = try model.previewWorkspaceMigration(plan: Data(decidedPlanJSON.utf8))
    #expect(model.migrationPreview == preview)
    var expected = livePreviewTable
    expected["Ancient DNA training"] = nil
    expected["FARO Labs"] = Set(faroTabs.map(\.1))
    let table = Dictionary(uniqueKeysWithValues: preview.workspaces.map { ($0.name, Set($0.tabIDs.compactMap { fixture.titles[$0] })) })
    #expect(table == expected && preview.workspaces.count == 15)
    #expect(preview.workspaces.first { $0.name == "FARO Labs" }?.id == UUID(uuidString: "F2B2F92A-0000-4000-8000-000000000000"))
    #expect(preview.workspaces.first { $0.name == "FARO Labs" }?.aliases.contains("FARO Labs / 00 · FARO Control") == true)
    #expect(preview.rows.count == fixture.tabs.count && preview.refusals.isEmpty && preview.collisions.isEmpty)
    #expect(Set(preview.retiredGroups.map(\.name)) == ["General", "Ancient DNA training"])
    #expect(Set(preview.paneMoves.map { [$0.paneID, $0.fromTabID, $0.toTabID] })
        == Set(livePaneMoves.map { [UUID(uuidString: $0.pane)!, tabID($0.from), tabID($0.to)] }))
    for (tab, name) in plan.overrides { #expect(preview.rows.first { $0.tabID == tab }?.workspaceName == name) }
    // Read-only MCP view of the same preview; nothing is applied.
    let state = model.workspaceMigrationControlState()
    #expect(state["apply"] as? String == "preview_checksum")
    #expect(((state["preview"] as? [String: Any])?["rows"] as? [Any])?.count == fixture.tabs.count)
    #expect(model.ownership.migrations.isEmpty)
    #expect(throws: WorkspaceMigrationPlanError.invalidIdentifier("not-a-tab")) {
        try WorkspaceMigrationPlan.parse(Data(#"{"overrides":{"not-a-tab":"X"}}"#.utf8))
    }
    // The user's Apply, then Undo.
    try model.applyWorkspaceMigration(preview)
    #expect(model.migrationPreview == nil && model.workspaceID(forTab: tabID("b1de1729")) == preview.workspaces.first { $0.name == "FARO Labs" }?.id)
    try model.undoWorkspaceMigration(preview.id)
    for tab in fixture.tabs { #expect(model.workspaceID(forTab: tab.id) == tab.sessionID) }
}

// 2026-10-17: at the user's request agents may apply and undo, reversing the
// 2026-10-16 user-only decision. Apply and undo are reached only from the
// user's sheet and the checksum-gated MCP routes; staging never applies.
@Test("Applying or undoing a migration is reachable only from the user's sheet and the checksum-gated MCP routes")
func navigatorMigrationApplyIsNotReachableFromMCP() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/Relay")
    let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    #expect(files.count > 20)
    var callers: Set<String> = []
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        if text.contains("applyWorkspaceMigration(") || text.contains("undoWorkspaceMigration(") {
            callers.insert(file.lastPathComponent)
        }
    }
    // Definitions (model, store), the gated agent apply, the user's sheet and the MCP routes.
    #expect(callers == ["WorkspaceModel.swift", "RelaySharedWorkspaceStore.swift", "WorkspaceNavigator.swift",
                        "WorkspaceNavigatorView.swift", "RelaySidePanel.swift"])
    let panel = try String(contentsOf: sources.appendingPathComponent("RelaySidePanel.swift"), encoding: .utf8)
    func section(_ marker: String) throws -> String {
        let tail = try #require(panel.range(of: marker).map { String(panel[$0.upperBound...]) })
        return String(tail[..<(tail.range(of: "\n            case \"")?.lowerBound ?? tail.endIndex)])
    }
    let stage = try section(#"case "/api/workspace/migration-stage":"#)
    #expect(stage.contains("stageWorkspaceMigrationPlan(") && !stage.contains("applyWorkspace") && !stage.contains("undoWorkspace"))
    let apply = try section(#"case "/api/workspace/migration-apply":"#)
    #expect(apply.contains("applyWorkspaceMigration(previewID: id, checksum: checksum"))
    #expect(panel.components(separatedBy: "applyWorkspaceMigration(").count == 2)
    let model = try String(contentsOf: sources.appendingPathComponent("WorkspaceModel.swift"), encoding: .utf8)
    let staging = try #require(model.range(of: "func stageWorkspaceMigrationPlan(").map { String(model[$0.lowerBound...]) })
    let body = String(staging[..<(staging.range(of: "\n    }\n")?.upperBound ?? staging.endIndex)])
    #expect(body.contains("inbox.store(") && !body.contains("applyWorkspaceMigration") && !body.contains("undoWorkspaceMigration"))
}

@MainActor
@Test("Staging does not apply; an agent's apply needs the open preview's exact ID and checksum, and records the caller")
func agentMigrationApplyRequiresChecksum() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-agent-apply-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = WorkspaceMigrationPlanInbox(directory: directory.appendingPathComponent("plans"))
    let (model, fixture, moves) = try liveModel(directory, withFARO: true)
    defer { model.shutdown() }
    let plan = Data(decidedPlanJSON.utf8)
    func stage(_ data: Data = plan, replace: Bool = false) throws -> (preview: WorkspaceMigrationPreview, checksum: String) {
        let preview = try model.stageWorkspaceMigrationPlan(data, name: "decided", replace: replace, inbox: inbox).preview
        return (preview, try #require(model.migrationChecksum))
    }
    let first = try stage()
    #expect(model.ownership.migrations.isEmpty && first.checksum.count == 64)
    #expect(model.workspaceMigrationControlState(inbox: inbox)["preview"].flatMap { ($0 as? [String: Any])?["checksum"] as? String } == first.checksum)
    // Missing, wrong, or another preview's ID: refused, nothing applied.
    for (id, checksum) in [(first.preview.id, ""), (first.preview.id, String(repeating: "0", count: 64)), (UUID(), first.checksum)] {
        #expect(throws: WorkspaceMigrationPlanInboxError.previewMismatch) {
            try model.applyWorkspaceMigration(previewID: id, checksum: checksum, caller: "agent")
        }
    }
    // The checksum covers the exact plan bytes: the same plan, reformatted, previews alike but checksums differently.
    let reformatted = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: plan), options: [.sortedKeys])
    let other = try stage(reformatted)
    #expect(other.preview.rows == first.preview.rows && other.checksum != first.checksum)
    #expect(throws: WorkspaceMigrationPlanInboxError.previewMismatch) {
        try model.applyWorkspaceMigration(previewID: first.preview.id, checksum: first.checksum, caller: "agent")
    }
    // A workspace change after the preview is refused by the store, and nothing is applied.
    let second = try stage()
    let layouts = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.layout) })
    model.newTab(profile: .local)
    let later = try #require(model.selectedTabID)
    #expect(throws: WorkspaceOwnershipError.staleMigration) {
        try model.applyWorkspaceMigration(previewID: second.preview.id, checksum: second.checksum, caller: "agent")
    }
    #expect(model.ownership.migrations.isEmpty)
    for tab in model.tabs where layouts[tab.id] != nil { #expect(tab.layout == layouts[tab.id]) }
    // The current preview, quoted exactly, applies and names its caller; undo round-trips.
    let current = try stage()
    let objects = Dictionary(uniqueKeysWithValues: moves.keys.map { ($0, model.panes[$0]!) })
    let migration = try model.applyWorkspaceMigration(previewID: current.preview.id, checksum: current.checksum, caller: "codex-dev")
    #expect(migration == current.preview.id && model.migrationPreview == nil && model.migrationChecksum == nil)
    for (pane, destination) in moves {
        #expect(model.tabID(containingPane: pane) == destination && model.panes[pane] === objects[pane])
    }
    let record = try #require(model.ownership.migrations.last)
    #expect(record.id == migration && record.appliedBy == "codex-dev" && record.undoneBy == nil)
    #expect(try model.sharedWorkspaceStore.restoreOwnership()?.migrations.last?.appliedBy == "codex-dev")
    let state = model.workspaceMigrationControlState(inbox: inbox)
    #expect((state["migrations"] as? [[String: Any]])?.last?["applied_by"] as? String == "codex-dev")
    try model.undoWorkspaceMigration(migration, caller: "relay-assistant")
    #expect(model.ownership.migrations.last?.undoneBy == "relay-assistant")
    #expect(try model.sharedWorkspaceStore.restoreOwnership()?.migrations.last?.undoneBy == "relay-assistant")
    for tab in fixture.tabs { #expect(model.workspaceID(forTab: tab.id) == tab.sessionID) }
    for (pane, object) in objects { #expect(model.panes[pane] === object) }
    #expect(model.tabs.contains { $0.id == later })
    #expect(throws: WorkspaceOwnershipError.alreadyUndone) { try model.undoWorkspaceMigration(migration, caller: "agent") }
}

@MainActor
@Test("An agent cannot apply a preview with name collisions")
func agentMigrationApplyRefusesCollisions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-agent-collide-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = WorkspaceMigrationPlanInbox(directory: directory.appendingPathComponent("plans"))
    // A second project group whose name differs only in case from an existing one.
    let fixture = liveFixture()
    var organization = fixture.organization
    let original = try #require(organization.groups.first { $0.kind == .project })
    let twin = WorkspaceGroup(id: UUID(), parentID: nil, order: 99, name: original.name.uppercased(), kind: .project, collapsed: false)
    organization.groups.append(twin)
    let moved = try #require(organization.placements.firstIndex { $0.groupID == original.id })
    organization.placements[moved] = WorkspaceTabPlacement(id: organization.placements[moved].id, groupID: twin.id, order: 0)
    let store = RelaySharedWorkspaceStore(directory: directory)
    _ = try store.commit(fixture.snapshot, baseline: nil)
    _ = try store.commitOrganization(organization, baseline: nil)
    let model = WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: directory)
    defer { model.shutdown() }
    let preview = try model.stageWorkspaceMigrationPlan(Data("{}".utf8), name: nil, replace: false, inbox: inbox).preview
    try #require(!preview.collisions.isEmpty)
    #expect(throws: WorkspaceMigrationPlanInboxError.previewNotClean) {
        try model.applyWorkspaceMigration(previewID: preview.id, checksum: model.migrationChecksum ?? "", caller: "agent")
    }
    #expect(model.ownership.migrations.isEmpty)
}

@MainActor
@Test("An agent's staged plan is validated, kept in the plan folder and opened for review, never applied")
func navigatorMigrationStagedPlanIsOnlyPreviewed() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-stage-plan-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = WorkspaceMigrationPlanInbox(directory: directory.appendingPathComponent("plans"))
    let (model, fixture, _) = try liveModel(directory, withFARO: true)
    defer { model.shutdown() }
    let plan = Data(decidedPlanJSON.utf8)
    // An invalid plan is refused before anything is written or opened.
    #expect(throws: WorkspaceMigrationPlanError.invalidIdentifier("not-a-tab")) {
        try model.stageWorkspaceMigrationPlan(Data(#"{"overrides":{"not-a-tab":"X"}}"#.utf8), name: "bad", replace: false, inbox: inbox)
    }
    #expect(throws: WorkspaceMigrationPlanInboxError.notAnObject) {
        try model.stageWorkspaceMigrationPlan(Data("[]".utf8), name: nil, replace: false, inbox: inbox)
    }
    #expect(model.migrationPreview == nil && inbox.list().isEmpty)

    let (url, preview) = try model.stageWorkspaceMigrationPlan(plan, name: "decided", replace: false, inbox: inbox)
    #expect(try url.lastPathComponent == "decided.json" && Data(contentsOf: url) == plan)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: inbox.directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(model.migrationPreview == preview && model.migrationPlan?.staged == true && model.migrationPlan?.name == "decided.json")
    #expect(model.isMigrationPresented && model.sidebarVisible)
    #expect(preview.rows.count == fixture.tabs.count && preview.paneMoves.count == 3)
    // Nothing was applied, in memory or on disk.
    #expect(model.ownership.migrations.isEmpty)
    #expect(try model.sharedWorkspaceStore.restoreOwnership()?.migrations.isEmpty ?? true)
    for tab in fixture.tabs { #expect(model.workspaceID(forTab: tab.id) == tab.sessionID) }

    // The same plan may be staged again; a different one only with replace.
    let again = try model.stageWorkspaceMigrationPlan(plan, name: "decided", replace: false, inbox: inbox).preview
    let other = Data(#"{"description":"other","keepEmptyGroups":true}"#.utf8)
    #expect(throws: WorkspaceMigrationPlanInboxError.previewOpen) {
        try model.stageWorkspaceMigrationPlan(other, name: "other", replace: false, inbox: inbox)
    }
    #expect(model.migrationPreview == again && inbox.list().map(\.name) == ["decided.json"])
    let replaced = try model.stageWorkspaceMigrationPlan(other, name: nil, replace: true, inbox: inbox)
    #expect(model.migrationPreview == replaced.preview && replaced.url.lastPathComponent.hasPrefix("workspace-migration-plan-"))
    #expect(model.ownership.migrations.isEmpty)

    let state = model.workspaceMigrationControlState(inbox: inbox)
    let listed = try #require(state["plans"] as? [[String: Any]])
    #expect(Set(listed.compactMap { $0["name"] as? String }) == ["decided.json", replaced.url.lastPathComponent])
    #expect(listed.allSatisfy { Set($0.keys) == ["name", "size", "modified"] })
    #expect((state["preview"] as? [String: Any])?["staged"] as? Bool == true)
    model.dismissMigrationPreview()
    #expect(model.migrationPlan == nil)
}

@Test("The plan folder lists plans newest first and refuses links, folders, oversize files and unsafe names")
func migrationPlanInboxListsAndRefuses() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-plan-inbox-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = WorkspaceMigrationPlanInbox(directory: root.appendingPathComponent("plans"))
    #expect(inbox.list().isEmpty)
    let older = try inbox.store(Data(#"{"description":"older"}"#.utf8), name: "older")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: older.path)
    try inbox.store(Data(#"{"description":"newer"}"#.utf8), name: "newer.json")
    #expect(inbox.list().map(\.name) == ["newer.json", "older.json"])
    #expect(inbox.list().map(\.description) == ["newer", "older"])

    let outside = root.appendingPathComponent("My plan (draft).json")
    try Data(#"{"description":"chosen"}"#.utf8).write(to: outside)
    let copied = try inbox.importPlan(WorkspaceMigrationPlanInbox.read(outside), from: outside)
    #expect(copied.lastPathComponent == "My-plan--draft-.json" && inbox.list().contains { $0.name == copied.lastPathComponent })
    #expect(try inbox.importPlan(Data(), from: copied) == copied)

    let link = inbox.directory.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: WorkspaceMigrationPlanInboxError.notRegularFile) { try WorkspaceMigrationPlanInbox.read(link) }
    #expect(throws: WorkspaceMigrationPlanInboxError.notRegularFile) { try inbox.store(Data("{}".utf8), name: "link") }
    let folder = inbox.directory.appendingPathComponent("folder.json")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(throws: WorkspaceMigrationPlanInboxError.notRegularFile) { try WorkspaceMigrationPlanInbox.read(folder) }
    let large = root.appendingPathComponent("large.json")
    try Data(count: WorkspaceMigrationPlanInbox.maximumBytes + 1).write(to: large)
    #expect(throws: WorkspaceMigrationPlanInboxError.tooLarge) { try WorkspaceMigrationPlanInbox.read(large) }
    #expect(throws: WorkspaceMigrationPlanInboxError.tooLarge) { try inbox.store(Data(count: WorkspaceMigrationPlanInbox.maximumBytes + 1), name: "x") }
    for name in ["../escape", ".hidden", "a/b", ""] {
        #expect(throws: WorkspaceMigrationPlanInboxError.invalidName) { try inbox.store(Data("{}".utf8), name: name) }
    }
    #expect(Set(inbox.list().map(\.name)) == ["newer.json", "older.json", copied.lastPathComponent])
}

// Root apply review (migration-apply-review-20261017-a), kept as regressions.

@MainActor
@Test("The plan folder is refused when it, or a folder above it, is a link or is not 0700; nothing is written through it")
func migrationPlanInboxRefusesLinkedFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-plan-folder-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data(#"{"description":"outside"}"#.utf8).write(to: elsewhere.appendingPathComponent("outside.json"))
    let linked = root.appendingPathComponent("plans")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
    let parent = root.appendingPathComponent("parent")
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: root)
    let model = WorkspaceModel(restoreSavedWorkspace: false, workspaceDirectory: root.appendingPathComponent("workspace"))
    defer { model.shutdown() }
    let tab = try #require(model.selectedTabID)
    let plan = Data(#"{"overrides":{"\#(tab.uuidString)":"Linked"}}"#.utf8)
    for inbox in [WorkspaceMigrationPlanInbox(directory: linked), WorkspaceMigrationPlanInbox(directory: parent.appendingPathComponent("elsewhere"))] {
        #expect(throws: WorkspaceMigrationPlanInboxError.unsafeFolder) { try inbox.store(Data("{}".utf8), name: "staged") }
        #expect(throws: WorkspaceMigrationPlanInboxError.unsafeFolder) { try inbox.read("outside.json") }
        #expect(throws: WorkspaceMigrationPlanInboxError.unsafeFolder) {
            try model.stageWorkspaceMigrationPlan(plan, name: "staged", replace: false, inbox: inbox)
        }
        #expect(inbox.list().isEmpty && model.migrationPreview == nil && !model.isMigrationPresented)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path) == ["outside.json"])
    // A real folder with a wider mode is refused, not repaired.
    let direct = WorkspaceMigrationPlanInbox(directory: elsewhere)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: elsewhere.path)
    #expect(throws: WorkspaceMigrationPlanInboxError.unsafeFolder) { try direct.store(Data("{}".utf8), name: "staged") }
    #expect(direct.list().isEmpty)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: elsewhere.path)
    #expect(try direct.store(Data("{}".utf8), name: "staged").lastPathComponent == "staged.json")
    #expect(Set(direct.list().map(\.name)) == ["outside.json", "staged.json"])
    #expect(try direct.read("outside.json") == Data(#"{"description":"outside"}"#.utf8))
}

@Test("A plan file swapped for a link after its metadata was read is refused, not followed; a FIFO is refused without blocking")
func migrationPlanReadRefusesSwappedFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-plan-swap-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let secret = root.appendingPathComponent("secret.txt")
    try Data("outside the plan folder, never to be read".utf8).write(to: secret)
    func swap(_ url: URL) throws {
        // What NSOpenPanel hands over: a URL whose metadata is already cached as a regular file.
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        #expect(values.isRegularFile == true && values.isSymbolicLink == false)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: secret)
    }
    let chosen = root.appendingPathComponent("chosen.json")
    try Data(#"{"description":"chosen"}"#.utf8).write(to: chosen)
    #expect(try WorkspaceMigrationPlanInbox.read(chosen) == Data(#"{"description":"chosen"}"#.utf8))
    try swap(chosen)
    #expect(throws: WorkspaceMigrationPlanInboxError.notRegularFile) { try WorkspaceMigrationPlanInbox.read(chosen) }
    let inbox = WorkspaceMigrationPlanInbox(directory: root.appendingPathComponent("plans"))
    let stored = try inbox.store(Data("{}".utf8), name: "plan")
    try swap(stored)
    #expect(throws: WorkspaceMigrationPlanInboxError.notRegularFile) { try inbox.read("plan.json") }
    #expect(throws: WorkspaceMigrationPlanInboxError.notRegularFile) { try WorkspaceMigrationPlanInbox.read(stored) }
    #expect(inbox.list().isEmpty)
    let fifo = root.appendingPathComponent("pipe.json")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: WorkspaceMigrationPlanInboxError.notRegularFile) { try WorkspaceMigrationPlanInbox.read(fifo) }
}

// Root phase 3 review probes (workspaces-phase3-review-20261017-a), kept as regressions.

@MainActor
@Test("Selecting an empty workspace shows it and scopes the next human New Tab there")
func navigatorSelectsEmptyWorkspace() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-p3-empty-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, _) = try liveModel(directory)
    defer { model.shutdown() }
    let originalTab = try #require(model.selectedTabID)
    let target = model.createWorkspace(named: "New empty research project")
    #expect(model.tabs(inWorkspace: target).isEmpty)
    model.selectWorkspace(target) // the navigator workspace row
    #expect(model.selectedWorkspaceID == target && model.visibleTab == nil)
    model.newTabInActiveSession(profile: .local) // the rail + and Cmd-T
    let created = try #require(model.selectedTabID)
    #expect(created != originalTab)
    #expect(model.workspaceID(forTab: created) == target && model.visibleTab?.id == created)
    try model.moveTab(created, toWorkspace: target)
    model.selectWorkspace(target)
    model.newTabInActiveSession(profile: .local)
    #expect(model.selectedTabID.flatMap { model.workspaceID(forTab: $0) } == target)
    // An agent request keeps its captured scope, whatever is shown.
    let source = tabID("cd59ed8d"), sourcePane = try #require(model.tabs.first { $0.id == source }?.allPaneIDs.first)
    let scope = try #require(model.workspaceID(forTab: source))
    model.newTabInActiveSession(profile: .local, origin: .agent(sourcePane: sourcePane))
    #expect(model.selectedTabID.flatMap { model.workspaceID(forTab: $0) } == scope && scope != target)
}

@MainActor
@Test("A drop into a hidden workspace keeps that destination out of view, for a tab and a sole-pane drop")
func navigatorHiddenDropDoesNotSwitchWorkspace() throws {
    for gesture in ["tab", "single-pane"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-p3-hidden-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _, _) = try liveModel(directory)
        defer { model.shutdown() }
        let destination = model.createWorkspace(named: "Hidden project")
        try model.moveTab(tabID("bf8a5a2b"), toWorkspace: destination)
        model.setWorkspaceHidden(destination, true)
        let source = try #require(model.tabs.first { $0.id == tabID("31b646ff") })
        #expect(source.allPaneIDs.count == 1)
        model.selectTab(source.id)
        let visibleBefore = try #require(model.selectedWorkspaceID)
        let pane = try #require(model.panes[source.allPaneIDs[0]])
        let runtime = pane.runtime, started = pane.runtime.hasStarted
        if gesture == "tab" {
            try model.performDrop(.tabOnWorkspace(tabID: source.id, workspaceID: destination, index: nil))
        } else {
            try model.performDrop(.paneOnWorkspace(paneID: pane.id, workspaceID: destination))
        }
        _ = try model.previewWorkspaceMigration() // an ordinary save, not a migration apply
        let visibleAfter = try #require(model.selectedWorkspaceID)
        #expect(model.workspaceID(forTab: source.id) == destination, "\(gesture)")
        #expect(model.panes[pane.id] === pane && pane.runtime === runtime && runtime.hasStarted == started)
        #expect(visibleAfter == visibleBefore && model.ownership.workspace(visibleAfter)?.hidden != true, "\(gesture)")
        // A remaining tab of the shown workspace is selected; the moved tab is not shown.
        #expect(model.visibleTab.map { model.workspaceID(forTab: $0.id) == visibleBefore } ?? true)
        #expect(model.visibleTab?.id != source.id)
    }
}

@MainActor
@Test("The decided plan is previewed read-only with 15 workspaces, 16 overrides and 3 moves; reads change nothing")
func navigatorPlanAndReadOnlyState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-p3-plan-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, fixture, _) = try liveModel(directory, withFARO: true)
    defer { model.shutdown() }
    #expect(model.migrationPreview == nil)
    let emptyState = model.workspaceMigrationControlState()
    #expect(emptyState["preview"] == nil && emptyState["apply"] as? String == "preview_checksum")
    let actualPlan = Data(decidedPlanJSON.utf8)
    let parsed = try WorkspaceMigrationPlan.parse(actualPlan)
    let preview = try model.previewWorkspaceMigration(plan: actualPlan)
    #expect(parsed.overrides.count == 16 && parsed.paneMoves.count == 3 && !parsed.keepEmptyGroups)
    #expect(preview.workspaces.count == 15 && preview.rows.count == fixture.tabs.count)
    #expect(preview.refusals.isEmpty && preview.collisions.isEmpty)
    let faro = try #require(preview.workspaces.first { $0.name == "FARO Labs" })
    #expect(faro.tabIDs.count == 6 && faro.aliases.contains("FARO Labs / 00 · FARO Control"))
    for (id, destination) in parsed.overrides { #expect(preview.rows.first { $0.tabID == id }?.workspaceName == destination) }
    #expect(Dictionary(uniqueKeysWithValues: preview.paneMoves.map { ($0.paneID, $0.toTabID) }) == parsed.paneMoves)
    let workspaceURL = directory.appendingPathComponent("workspace-v1.json")
    let ownershipURL = directory.appendingPathComponent("ownership-v3.json")
    let beforeWorkspace = try Data(contentsOf: workspaceURL), beforeOwnership = try Data(contentsOf: ownershipURL)
    let ownership = model.ownership
    for _ in 0..<20 {
        let state = model.workspaceMigrationControlState()
        let bytes = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        let roundTrip = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(roundTrip["apply"] as? String == "preview_checksum")
        #expect(((roundTrip["preview"] as? [String: Any])?["rows"] as? [Any])?.count == fixture.tabs.count)
    }
    #expect(model.ownership == ownership && model.ownership.migrations.isEmpty && model.migrationPreview == preview)
    #expect(try Data(contentsOf: workspaceURL) == beforeWorkspace && Data(contentsOf: ownershipURL) == beforeOwnership)
    for action in ["applyWorkspaceMigration", "undoWorkspaceMigration", "migrationApply", "migrationUndo", "apply", "undo"] {
        #expect(WorkspaceAction(rawValue: action) == nil && WorkspaceTabAction(rawValue: action) == nil)
    }
}

// Root phase 3 v2 review probes (workspaces-phase3-review-20261017-b), kept as regressions.

@MainActor
@Test("A captured agent admission survives a source rehome and an empty visible workspace")
func navigatorCapturedAdmissionWithEmptyView() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-p3-v2-admission-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, _) = try liveModel(directory)
    defer { model.shutdown() }
    let source = try #require(model.tabs.first { $0.id == tabID("31b646ff") })
    let sourcePane = try #require(source.allPaneIDs.first)
    let admittedWorkspace = try #require(model.workspaceID(forTab: source.id))
    let captured = model.tabAdmission(forSourcePane: sourcePane)
    let changed = model.createWorkspace(named: "Later source location")
    try model.moveTab(source.id, toWorkspace: changed)
    let shown = model.createWorkspace(named: "Visible empty workspace")
    model.selectWorkspace(shown)
    model.withTabAdmission(captured) {
        model.newTabInActiveSession(profile: .local, origin: .agent(sourcePane: sourcePane))
    }
    let created = try #require(model.selectedTabID)
    let result = try #require(model.workspaceID(forTab: created))
    #expect(result == admittedWorkspace && result != changed && result != shown)
    model.selectWorkspace(shown)
    model.newTabInActiveSession(profile: .local, origin: .agent(sourcePane: nil))
    #expect(model.selectedTabID.flatMap { model.workspaceID(forTab: $0) } == WorkspaceOwnershipSnapshot.inboxID)
}

@MainActor
@Test("Pane commands while an empty workspace is shown do not edit or close the previous tab")
func navigatorEmptyViewPaneCommands() throws {
    for command in ["close", "split"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-p3-v2-actions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(restoreSavedWorkspace: false, workspaceDirectory: directory)
        defer { model.shutdown() }
        model.newTab(profile: .local)
        let source = try #require(model.selectedTab)
        let pane = try #require(model.activePane)
        let originalLayout = source.layout, originalPaneCount = model.panes.count
        let empty = model.createWorkspace(named: "Empty active workspace")
        model.selectWorkspace(empty)
        #expect(model.selectedWorkspaceID == empty && model.visibleTab == nil)
        if command == "close" { model.closeActivePane() } else { model.splitActive(axis: .horizontal) }
        #expect(model.panes.count == originalPaneCount, "\(command)")
        #expect(model.tabs.contains { $0 === source } && source.layout == originalLayout, "\(command)")
        #expect(model.panes[pane.id] === pane && model.selectedWorkspaceID == empty)
    }
}

@MainActor
@Test("Selecting the remembered tab returns from an empty workspace")
func navigatorReturnToRememberedTab() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-p3-v2-return-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, _) = try liveModel(directory)
    defer { model.shutdown() }
    let rememberedTab = try #require(model.selectedTabID), originalWorkspace = try #require(model.selectedWorkspaceID)
    let empty = model.createWorkspace(named: "Empty for return test")
    model.selectWorkspace(empty)
    #expect(model.visibleTab == nil && model.selectedWorkspaceID == empty)
    model.selectTab(rememberedTab) // the navigator tab row
    #expect(model.selectedWorkspaceID == originalWorkspace && model.visibleTab?.id == rememberedTab)
    model.selectWorkspace(empty)
    model.selectWorkspace(originalWorkspace) // the workspace row also returns
    #expect(model.selectedWorkspaceID == originalWorkspace && model.visibleTab?.id == rememberedTab)
    // A click on the tab that is already selected still shows its workspace.
    model.selectTab(rememberedTab)
    #expect(model.selectedWorkspaceID == originalWorkspace)
}

@MainActor
@Test("Relaunch restores a saved empty workspace before any selected-tab side effects")
func navigatorRestoresEmptyWorkspace() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-p3-v2-restore-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, _) = try liveModel(directory)
    let originalWorkspace = try #require(model.selectedWorkspaceID)
    let empty = model.createWorkspace(named: "Persisted empty workspace")
    model.selectWorkspace(empty)
    _ = try model.previewWorkspaceMigration()
    model.shutdown()
    #expect(WorkspaceNavigationState.load().visibleWorkspace == empty)
    let restored = WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: directory)
    #expect(restored.selectedWorkspaceID == empty && restored.visibleTab == nil)
    #expect(restored.selectedTabID == nil && restored.activePaneID == nil)
    restored.newTabInActiveSession(profile: .local) // the empty view's New tab
    #expect(restored.selectedTabID.flatMap { restored.workspaceID(forTab: $0) } == empty)
    restored.selectWorkspace(originalWorkspace)
    _ = try restored.previewWorkspaceMigration()
    restored.shutdown()
    let populatedControl = WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: directory)
    defer { populatedControl.shutdown() }
    #expect(populatedControl.selectedWorkspaceID == originalWorkspace && populatedControl.visibleTab != nil)
}

@MainActor
@Test("While an empty workspace is shown, every active pane and tab command is a no-op: no mutation, no runtime stop")
func navigatorEmptyViewDisablesEveryActiveCommand() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-p3-empty-commands-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = WorkspaceModel(restoreSavedWorkspace: false, workspaceDirectory: directory)
    defer { model.shutdown() }
    model.splitActive(axis: .horizontal)
    model.splitActive(axis: .vertical)
    let source = try #require(model.selectedTab)
    let paneObjects = model.panes
    let runtimes = paneObjects.mapValues(\.runtime), started = paneObjects.mapValues(\.runtime.hasStarted)
    let layout = source.layout, floating = source.floatingPanes, ratios = source.splitRatios, stacks = source.stacks
    let empty = model.createWorkspace(named: "Empty")
    model.selectWorkspace(empty)
    let ownership = model.ownership, tabs = model.tabs.map(\.id)
    #expect(model.selectedTabID == nil && model.activePaneID == nil && model.activePane == nil && model.visibleTab == nil)
    let commands: [(String, () -> Void)] = [
        ("close pane", { model.closeActivePane() }),
        ("split right", { model.splitActive(axis: .horizontal) }),
        ("split down", { model.splitActive(axis: .vertical) }),
        ("zoom", { model.toggleActivePaneZoom() }),
        ("float or dock", { model.toggleActivePaneFloating() }),
        ("balance", { model.balanceActiveTabPanes() }),
        ("open remote editor", { model.openEditorForActive() }),
        ("new floating pane", { model.newFloatingPane() }),
        ("cascade floats", { model.arrangeFloatingPanes(cascade: true) }),
        ("tile floats", { model.arrangeFloatingPanes(cascade: false) }),
        ("restore arrangement", { model.restorePaneArrangement() }),
        ("previous pane", { model.selectAdjacentPane(offset: -1) }),
        ("next pane", { model.selectAdjacentPane(offset: 1) }),
        ("next stack member", { model.selectAdjacentStackMember(offset: 1) }),
        ("next tab", { model.selectTab(offset: 1) }),
        ("previous tab", { model.selectTab(offset: -1) }),
        ("prompt jump", { _ = model.activePane?.runtime.jumpToPrompt(by: -1) }),
        ("unstack", { if let id = model.activePaneID { try? model.unstackPane(id) } }),
    ]
    for (name, run) in commands {
        run()
        #expect(model.panes.count == paneObjects.count && model.tabs.map(\.id) == tabs, "\(name)")
        #expect(source.layout == layout && source.floatingPanes == floating && source.splitRatios == ratios && source.stacks == stacks, "\(name)")
        #expect(model.selectedTabID == nil && model.activePaneID == nil && model.zoomedPaneID == nil, "\(name)")
        #expect(model.selectedWorkspaceID == empty && model.ownership == ownership, "\(name)")
    }
    for (id, pane) in paneObjects {
        #expect(model.panes[id] === pane && pane.runtime === runtimes[id] && pane.runtime.hasStarted == started[id])
    }
}

// Root phase 3 v3 review probe (workspaces-phase3-review-20261017-c), kept as a regression.
@MainActor
@Test("The startup R tool-window restore keeps the shown workspace exactly, for an empty view and a populated one")
func navigatorRPresentationRestoreKeepsShownState() throws {
    for shown in ["empty", "populated"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-p3-r-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let consoleID = UUID(), editorID = UUID(), tabID = UUID(), sessionID = UUID()
        let otherTab = UUID(), otherPane = UUID()
        let presentation = RWorkspacePresentation(consoleID: consoleID, editorID: editorID, tabID: tabID,
            selected: false, minimized: false, placement: nil, extras: [])
        let console = PaneSnapshot(id: consoleID, profile: .local, contentKind: .terminal,
            remoteParentSessionID: nil, editorRequest: nil, customName: nil)
        let editor = PaneSnapshot(id: editorID, profile: .local, contentKind: .editor,
            remoteParentSessionID: consoleID.uuidString.lowercased(), editorRequest: nil, customName: nil)
        let other = PaneSnapshot(id: otherPane, profile: .local, contentKind: .terminal,
            remoteParentSessionID: nil, editorRequest: nil, customName: nil)
        let snapshot = WorkspaceSnapshot(tabs: [
                TabSnapshot(id: tabID, sessionID: sessionID, name: "Saved R project", layout: .pane(consoleID), floatingPanes: [], splitRatios: [:]),
                TabSnapshot(id: otherTab, sessionID: UUID(), name: "Other project", layout: .pane(otherPane), floatingPanes: [], splitRatios: [:]),
            ], panes: [console, editor, other],
            sessionNames: [sessionID: "R fixture"], selectedTabID: tabID, activePaneID: consoleID,
            rPresentations: [presentation])
        _ = try RelaySharedWorkspaceStore(directory: directory).commit(snapshot, baseline: nil)
        let model = WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: directory)
        defer { model.shutdown() }
        #expect(model.savedRPresentations == [presentation])
        let target: UUID
        if shown == "empty" {
            target = model.createWorkspace(named: "Empty view before R restoration")
            model.selectWorkspace(target)
        } else {
            target = model.createWorkspace(named: "Populated view before R restoration")
            try model.moveTab(otherTab, toWorkspace: target)
            model.selectTab(otherTab)
        }
        _ = try model.previewWorkspaceMigration()
        let before = (model.selectedTabID, model.activePaneID, model.zoomedPaneID, model.selectedWorkspaceID)
        let navigation = WorkspaceNavigationState.load()
        #expect(before.3 == target && navigation.visibleWorkspace == target)
        #expect(shown == "empty" ? before.0 == nil && before.1 == nil : before.0 == otherTab)
        relayRestoreToolWindowPresentations(model) // the window's onAppear restore
        #expect(model.captureRPresentations != nil)
        #expect(model.panes.values.allSatisfy { !$0.runtime.hasStarted })
        #expect(model.selectedTabID == before.0 && model.activePaneID == before.1 && model.zoomedPaneID == before.2, "\(shown)")
        #expect(model.selectedWorkspaceID == target && model.workspaceID(forTab: tabID) != target, "\(shown)")
        #expect(WorkspaceNavigationState.load().visibleWorkspace == target, "\(shown)")
        #expect(WorkspaceNavigationState.load().preferredTab(in: target, available: [otherTab, tabID])
            == navigation.preferredTab(in: target, available: [otherTab, tabID]))
        #expect(shown == "empty" ? model.visibleTab == nil : model.visibleTab?.id == otherTab)
    }
}

private struct ProbeFailure: Error {}

/// Reads the shared navigation record as another process would, straight from defaults.
private func sharedNavigationRecord() throws -> [String: Any] {
    let data = try #require(RelayStateProfile.defaults.data(forKey: "relay.workspace.navigation-state.v1"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// Root phase 3 v4 review probe (workspaces-phase3-review-20261017-d), kept as a regression.
@MainActor
@Test("A temporary selection publishes nothing, and another writer's navigation update made meanwhile survives")
func navigatorTemporarySelectionIsNotPublished() throws {
    let key = "relay.workspace.navigation-state.v1"
    let backup = RelayStateProfile.defaults.data(forKey: key)
    defer {
        if let backup { RelayStateProfile.defaults.set(backup, forKey: key) } else { RelayStateProfile.defaults.removeObject(forKey: key) }
    }
    for shown in ["empty", "populated"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-p3-publication-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(restoreSavedWorkspace: false, workspaceDirectory: directory)
        defer { model.shutdown() }
        model.newTab(profile: .local)
        let originalTab = try #require(model.selectedTabID)
        let owner = try #require(model.selectedWorkspaceID)
        let temporaryTab = try #require(model.tabs.first { $0.id != originalTab })
        let temporaryPane = try #require(temporaryTab.allPaneIDs.first)
        let target = model.createWorkspace(named: "Stable \(shown) view")
        if shown == "empty" {
            model.selectWorkspace(target)
        } else {
            try model.moveTab(originalTab, toWorkspace: target)
            model.selectTab(originalTab)
        }
        _ = try model.previewWorkspaceMigration()
        let selection = (model.selectedTabID, model.activePaneID, model.zoomedPaneID)
        let before = try sharedNavigationRecord()
        #expect((before["visibleWorkspace"] as? String).flatMap(UUID.init(uuidString:)) == target)
        let beforeLast = (before["lastSelectedTabs"] as? [String: String])?[owner.uuidString]
        let marker = "tab:" + temporaryTab.id.uuidString
        let workspaceURL = directory.appendingPathComponent("workspace-v1.json")
        let beforeWorkspace = try Data(contentsOf: workspaceURL)
        try model.withoutNavigationEffects {
            // The same direct assignments the R restore makes.
            model.selectedTabID = temporaryTab.id
            model.activePaneID = temporaryPane
            model.balanceActiveTabPanes()
            // Read as another process would: nothing temporary is published.
            let during = try sharedNavigationRecord()
            #expect((during["visibleWorkspace"] as? String).flatMap(UUID.init(uuidString:)) == target, "\(shown)")
            #expect((during["lastSelectedTabs"] as? [String: String])?[owner.uuidString] == beforeLast, "\(shown)")
            #expect(model.selectedWorkspaceID == target, "\(shown)")
            // Another writer records a legitimate last tab and an expansion meanwhile.
            var record = during
            var last = record["lastSelectedTabs"] as? [String: String] ?? [:]
            var expanded = record["expandedGroups"] as? [String: Bool] ?? [:]
            last[owner.uuidString] = temporaryTab.id.uuidString
            expanded[marker] = true
            record["lastSelectedTabs"] = last
            record["expandedGroups"] = expanded
            RelayStateProfile.defaults.set(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), forKey: key)
            #expect(try Data(contentsOf: workspaceURL) == beforeWorkspace)
        }
        let after = try sharedNavigationRecord()
        #expect((after["visibleWorkspace"] as? String).flatMap(UUID.init(uuidString:)) == target, "\(shown)")
        #expect((after["lastSelectedTabs"] as? [String: String])?[owner.uuidString] == temporaryTab.id.uuidString, "\(shown)")
        #expect((after["expandedGroups"] as? [String: Bool])?[marker] == true, "\(shown)")
        #expect(model.selectedTabID == selection.0 && model.activePaneID == selection.1 && model.zoomedPaneID == selection.2)
        #expect(model.selectedWorkspaceID == target)
        _ = try model.previewWorkspaceMigration() // flush the queued save with the restored state
        let stored = try #require(try model.sharedWorkspaceStore.restore(legacy: nil))
        #expect(stored.selectedTabID == selection.0 && stored.activePaneID == selection.1)
    }
}

@MainActor
@Test("Suspended navigation effects end after a throwing body, with the selection restored")
func navigatorNavigationSuspensionEndsOnThrow() throws {
    let model = WorkspaceModel(restoreSavedWorkspace: false)
    defer { model.shutdown() }
    model.newTab(profile: .local)
    let first = model.tabs[0], second = model.tabs[1]
    let other = model.createWorkspace(named: "Other")
    try model.moveTab(second.id, toWorkspace: other)
    model.selectTab(first.id)
    let shown = model.selectedWorkspaceID, selection = (model.selectedTabID, model.activePaneID)
    #expect(throws: ProbeFailure.self) {
        try model.withoutNavigationEffects {
            model.selectedTabID = second.id
            throw ProbeFailure()
        }
    }
    #expect(model.selectedTabID == selection.0 && model.activePaneID == selection.1 && model.selectedWorkspaceID == shown)
    // Effects are live again: an ordinary selection shows and publishes its workspace.
    model.selectTab(second.id)
    #expect(model.selectedWorkspaceID == other)
    #expect((try sharedNavigationRecord()["visibleWorkspace"] as? String).flatMap(UUID.init(uuidString:)) == other)
}

/// QA-F01b: a request with pane moves only and no scope is partial. The
/// panes land in their destination tabs; every tab keeps its owner record
/// and sidebar placement, and no workspace or group is removed or retired.
@MainActor
@Test("A pane-moves-only plan without a scope is partial: panes move, every tab keeps its owner and placement")
func workspaceMigrationPaneMovesOnlyIsPartial() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-partial-moves-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (workspace, _, moves) = try liveModel(directory)
    defer { workspace.shutdown() }
    let owners = workspace.ownership.owners, records = workspace.ownership.workspaces
    func sorted(_ o: WorkspaceOrganizationSnapshot) -> ([WorkspaceTabPlacement], [WorkspaceGroup]) {
        (o.placements.sorted { $0.id.uuidString < $1.id.uuidString }, o.groups.sorted { $0.id.uuidString < $1.id.uuidString })
    }
    let before = sorted(workspace.organization.snapshot)
    let preview = try workspace.previewWorkspaceMigration(paneMoves: moves)
    #expect(preview.scope == .partial)
    #expect(preview.workspaces.flatMap(\.tabIDs).isEmpty && preview.removed.isEmpty && preview.retiredGroups.isEmpty)
    #expect(preview.refusals.isEmpty && preview.paneMoves.count == moves.count)
    try workspace.applyWorkspaceMigration(preview)
    for (paneID, destination) in moves { #expect(workspace.tabID(containingPane: paneID) == destination) }
    #expect(workspace.ownership.owners == owners)
    #expect(workspace.ownership.workspaces == records)
    let after = sorted(workspace.organization.snapshot)
    #expect(after.0 == before.0 && after.1 == before.1)
    let saved = sorted(try #require(try RelaySharedWorkspaceStore(directory: directory).restoreOrganization()))
    #expect(saved.0 == before.0 && saved.1 == before.1, "the saved sidebar is unchanged too")
    let record = try #require(workspace.ownership.migrations.last)
    #expect(record.id == preview.id && record.paneMoves.count == moves.count && record.paneMoves.allSatisfy { $0.state == .done })
}
