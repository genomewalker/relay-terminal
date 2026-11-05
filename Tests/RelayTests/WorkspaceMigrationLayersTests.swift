import Foundation
import Testing
@testable import Relay

/// Workspace migrations move both records of a tab's place together:
/// ownership (WorkspaceOwnership) and organization placement (the sidebar).
/// The fixture mirrors the live kaiku case: tab K is owned by workspace
/// "Kaiku" while its placement still shows it in Relay & Chitta.
@Suite("Workspace migration: ownership and placement together")
struct WorkspaceMigrationLayersTests {
    static let s1 = UUID(uuidString: "5E550001-0000-4000-8000-000000000001")!   // session "Work"
    static let s2 = UUID(uuidString: "5E550002-0000-4000-8000-000000000002")!   // session "DART"
    static let project = UUID(uuidString: "6A000000-0000-4000-8000-00000000000A")! // "Relay & Chitta"
    static let kaikuWorkspace = UUID(uuidString: "29AF7D40-0000-4000-8000-000000000000")!
    static let t1 = UUID(uuidString: "7AB00001-0000-4000-8000-000000000000")!
    static let t2 = UUID(uuidString: "7AB00002-0000-4000-8000-000000000000")!
    static let t3 = UUID(uuidString: "7AB00003-0000-4000-8000-000000000000")!
    static let kaiku = UUID(uuidString: "AC510024-0000-4000-8000-000000000000")!

    struct Fixture {
        let tabs: [WorkspaceTabReference]
        let organization: WorkspaceOrganizationSnapshot
        let ownership: WorkspaceOwnershipSnapshot
        let snapshot: WorkspaceSnapshot
    }

    static func fixture() -> Fixture {
        let tabs = [
            WorkspaceTabReference(id: t1, sessionID: s1, title: "Relay core", sessionName: "Work"),
            WorkspaceTabReference(id: t2, sessionID: s1, title: "Shell", sessionName: "Work"),
            WorkspaceTabReference(id: t3, sessionID: s2, title: "DART run", sessionName: "DART"),
            WorkspaceTabReference(id: kaiku, sessionID: s2, title: "Kaiku", sessionName: "DART"),
        ]
        let organization = WorkspaceOrganizationSnapshot(schemaVersion: WorkspaceOrganizationSnapshot.currentSchemaVersion,
            groups: [WorkspaceGroup(id: project, parentID: nil, order: 0, name: "Relay & Chitta", kind: .project, collapsed: false),
                     WorkspaceGroup(id: s1, parentID: nil, order: 1, name: "Work", kind: .session, collapsed: false),
                     WorkspaceGroup(id: s2, parentID: nil, order: 2, name: "DART", kind: .session, collapsed: false)],
            placements: [WorkspaceTabPlacement(id: t1, groupID: project, order: 0),
                         WorkspaceTabPlacement(id: kaiku, groupID: project, order: 1)],
            savedViews: [])
        var ownership = WorkspaceOwnershipSnapshot.empty
        for (id, name, order) in [(project, "Relay & Chitta", 0.0), (s1, "Work", 1), (s2, "DART", 2), (kaikuWorkspace, "Kaiku", 3)] {
            ownership.workspaces.append(WorkspaceRecord(id: id, name: name, order: order, favourite: false,
                                                        hostDefaults: [:], isInbox: false, aliases: []))
        }
        for (index, (tab, owner)) in [(t1, project), (t2, s1), (t3, s2), (kaiku, kaikuWorkspace)].enumerated() {
            ownership.owners.append(WorkspaceTabOwner(id: tab, workspaceID: owner, order: Double(index), updatedAt: Date(timeIntervalSince1970: 0)))
        }
        let panes = tabs.map { _ in UUID() }
        let snapshot = WorkspaceSnapshot(
            tabs: zip(tabs, panes).map { tab, pane in
                TabSnapshot(id: tab.id, sessionID: tab.sessionID, name: tab.title, layout: .pane(pane), floatingPanes: [], splitRatios: [:])
            },
            panes: panes.map { PaneSnapshot(id: $0, profile: .local, contentKind: .terminal, remoteParentSessionID: nil, editorRequest: nil, customName: nil) },
            sessionNames: [s1: "Work", s2: "DART"], selectedTabID: t1, activePaneID: panes[0])
        let references = tabs.enumerated().map { index, tab in
            WorkspaceTabReference(id: tab.id, sessionID: tab.sessionID, title: tab.title, sessionName: tab.sessionName, paneIDs: [panes[index]])
        }
        return Fixture(tabs: references, organization: organization, ownership: ownership, snapshot: snapshot)
    }

    /// Kaiku stays in Kaiku; Shell goes to the Inbox.
    static let overrides: [UUID: String] = [kaiku: "Kaiku", t2: "Inbox"]

    static func placement(_ tab: UUID, _ organization: WorkspaceOrganizationSnapshot) -> WorkspaceTabPlacement? {
        organization.placements.first { $0.id == tab }
    }

    static func sorted(_ organization: WorkspaceOrganizationSnapshot) -> WorkspaceOrganizationSnapshot {
        var copy = organization
        copy.groups.sort { $0.id.uuidString < $1.id.uuidString }
        copy.placements.sort { $0.id.uuidString < $1.id.uuidString }
        return copy
    }

    @Test func previewFlagsEveryTabWhoseLayersDisagree() {
        let f = Self.fixture()
        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: f.organization, ownership: f.ownership)
        #expect(preview.disagreements == [Self.kaiku])
        #expect(preview.rows.first { $0.tabID == Self.kaiku }?.layersDisagree == true)
        #expect(preview.rows.filter { $0.tabID != Self.kaiku }.allSatisfy { !$0.layersDisagree })
        // The checksums still cover both layers.
        var moved = f.organization
        moved.placements[1].groupID = Self.s2
        #expect(WorkspaceMigration.checksums(tabs: f.tabs, organization: moved, ownership: f.ownership)
            != preview.sourceChecksums)
    }

    /// A tab moved across sessions sits in the other session's group; it
    /// agrees with an owner of that group's workspace, not its birth session.
    @Test func aTabShownInAnotherSessionsGroupAgreesWithThatWorkspace() {
        let f = Self.fixture()
        var organization = f.organization, ownership = f.ownership
        organization.placements.append(WorkspaceTabPlacement(id: Self.t3, groupID: Self.s1, order: 5))
        ownership.owners[2].workspaceID = Self.s1
        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: organization, ownership: ownership)
        #expect(preview.rows.first { $0.tabID == Self.t3 }?.workspaceID == Self.s1)
        #expect(preview.disagreements == [Self.kaiku])
        ownership.owners[2].workspaceID = Self.s2
        #expect(Set(WorkspaceMigration.preview(tabs: f.tabs, organization: organization, ownership: ownership).disagreements)
            == [Self.kaiku, Self.t3])
    }

    @Test func applyMovesBothLayersToTheTarget() throws {
        let f = Self.fixture()
        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: f.organization, ownership: f.ownership,
                                                 overrides: Self.overrides)
        let result = try WorkspaceMigration.apply(preview, to: f.ownership, organization: f.organization, tabs: f.tabs,
                                                  current: preview.sourceChecksums)
        // Ownership: every tab where the preview sends it.
        for item in preview.workspaces { for tab in item.tabIDs { #expect(result.ownership.owner(of: tab) == item.id) } }
        #expect(result.ownership.owner(of: Self.kaiku) == Self.kaikuWorkspace)
        #expect(result.ownership.owner(of: Self.t2) == WorkspaceOwnershipSnapshot.inboxID)
        // Placement: Kaiku is shown in a group of its own workspace; Shell is Ungrouped (the Inbox).
        #expect(Self.placement(Self.kaiku, result.organization)?.groupID == Self.kaikuWorkspace)
        let group = try #require(result.organization.groups.first { $0.id == Self.kaikuWorkspace })
        #expect(group.name == "Kaiku" && group.kind == .project && group.parentID == nil)
        #expect(Self.placement(Self.t2, result.organization).map { $0.groupID == nil } == true)
        // Tabs that already agreed keep their placement exactly.
        #expect(Self.placement(Self.t1, result.organization) == Self.placement(Self.t1, f.organization))
        #expect(Self.placement(Self.t3, result.organization) == nil)
        // Afterwards the layers agree everywhere.
        #expect(WorkspaceMigration.disagreeing(tabs: f.tabs, organization: result.organization, ownership: result.ownership).isEmpty)
        let record = try #require(result.ownership.migrations.last)
        #expect(Set(record.placementMoves?.map(\.tabID) ?? []) == [Self.kaiku, Self.t2])
        #expect(record.createdGroups == [Self.kaikuWorkspace])
    }

    @Test func defaultApplyReconcilesKaikuToItsSidebarGroup() throws {
        let f = Self.fixture()
        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: f.organization, ownership: f.ownership)
        let result = try WorkspaceMigration.apply(preview, to: f.ownership, organization: f.organization, tabs: f.tabs,
                                                  current: preview.sourceChecksums)
        #expect(result.ownership.owner(of: Self.kaiku) == Self.project)
        #expect(Self.placement(Self.kaiku, result.organization)?.groupID == Self.project)
        #expect(WorkspaceMigration.disagreeing(tabs: f.tabs, organization: result.organization, ownership: result.ownership).isEmpty)
    }

    @Test func undoRestoresBothLayers() throws {
        let f = Self.fixture()
        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: f.organization, ownership: f.ownership,
                                                 overrides: Self.overrides)
        let applied = try WorkspaceMigration.apply(preview, to: f.ownership, organization: f.organization, tabs: f.tabs,
                                                   current: preview.sourceChecksums)
        let undone = try WorkspaceMigration.undo(preview.id, in: applied.ownership, organization: applied.organization)
        for tab in f.tabs { #expect(undone.ownership.owner(of: tab.id) == f.ownership.owner(of: tab.id)) }
        #expect(Self.sorted(undone.organization) == Self.sorted(f.organization))
        #expect(undone.ownership.migrations.last?.undoneAt != nil)
    }

    @Test func undoKeepsATabChangedSinceInEitherLayer() throws {
        let f = Self.fixture()
        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: f.organization, ownership: f.ownership,
                                                 overrides: Self.overrides)
        let applied = try WorkspaceMigration.apply(preview, to: f.ownership, organization: f.organization, tabs: f.tabs,
                                                   current: preview.sourceChecksums)
        // The user drags Shell (migrated Work → Inbox) into the DART group afterwards.
        var edited = applied.organization
        let index = try #require(edited.placements.firstIndex { $0.id == Self.t2 })
        edited.placements[index].groupID = Self.s2
        #expect(applied.ownership.owner(of: Self.t2) != f.ownership.owner(of: Self.t2)) // positive control
        let undone = try WorkspaceMigration.undo(preview.id, in: applied.ownership, organization: edited)
        // Shell keeps both layers: its new placement and its migrated owner.
        #expect(Self.placement(Self.t2, undone.organization)?.groupID == Self.s2)
        #expect(undone.ownership.owner(of: Self.t2) == WorkspaceOwnershipSnapshot.inboxID)
        // Kaiku was untouched since, so both of its layers are restored.
        #expect(Self.placement(Self.kaiku, undone.organization) == Self.placement(Self.kaiku, f.organization))
        #expect(undone.ownership.owner(of: Self.kaiku) == f.ownership.owner(of: Self.kaiku))
        #expect(!undone.organization.groups.contains { $0.id == Self.kaikuWorkspace })
    }

    // MARK: Store: both files or neither

    static func store(_ f: Fixture) throws -> (RelaySharedWorkspaceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-layers-\(UUID())")
        let store = RelaySharedWorkspaceStore(directory: directory)
        _ = try store.commit(f.snapshot, baseline: nil, ownership: f.ownership, ownershipBaseline: nil)
        _ = try store.commitOrganization(f.organization, baseline: nil)
        return (store, directory)
    }

    struct Crash: Error {}

    static func files(_ directory: URL) throws -> [Data] {
        try ["ownership-v3.json", "organization-v2.json"].map {
            try Data(contentsOf: directory.appendingPathComponent($0))
        }
    }

    @Test func storeApplyAndUndoWriteBothLayers() throws {
        let f = Self.fixture()
        let (store, directory) = try Self.store(f)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try store.previewWorkspaceMigration(overrides: Self.overrides)
        #expect(preview.disagreements == [Self.kaiku])
        let applied = try store.applyWorkspaceMigration(preview)
        let savedOrganization = try #require(try store.restoreOrganization())
        #expect(savedOrganization == applied.organization)
        #expect(Self.placement(Self.kaiku, savedOrganization)?.groupID == Self.kaikuWorkspace)
        #expect(try store.restoreOwnership()?.owner(of: Self.kaiku) == Self.kaikuWorkspace)
        _ = try store.undoWorkspaceMigration(preview.id)
        #expect(Self.sorted(try #require(try store.restoreOrganization())) == Self.sorted(f.organization))
        #expect(try store.restoreOwnership()?.owner(of: Self.t2) == Self.s1)
    }

    @Test(arguments: [false, true])
    func aFailedLayerWriteChangesNeitherLayer(undo: Bool) throws {
        let f = Self.fixture()
        let (store, directory) = try Self.store(f)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try store.previewWorkspaceMigration(overrides: Self.overrides)
        if undo { _ = try store.applyWorkspaceMigration(preview) }
        let before = try Self.files(directory)
        store.migrationFault = { if $0 == (undo ? "organization-undo" : "organization") { throw Crash() } }
        #expect(throws: Crash.self) {
            if undo { _ = try store.undoWorkspaceMigration(preview.id) } else { _ = try store.applyWorkspaceMigration(preview) }
        }
        #expect(try Self.files(directory) == before)
        store.migrationFault = nil
        // The same step then succeeds.
        if undo { _ = try store.undoWorkspaceMigration(preview.id) } else { _ = try store.applyWorkspaceMigration(preview) }
    }

    @Test(arguments: [false, true])
    func aCrashBetweenTheLayerWritesIsSettledOnLoad(undo: Bool) throws {
        let f = Self.fixture()
        let (store, directory) = try Self.store(f)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try store.previewWorkspaceMigration(overrides: Self.overrides)
        if undo { _ = try store.applyWorkspaceMigration(preview) }
        let before = try Self.files(directory)
        store.layerFaultIsCrash = true
        store.migrationFault = { if $0 == (undo ? "organization-undo" : "organization") { throw Crash() } }
        #expect(throws: Crash.self) {
            if undo { _ = try store.undoWorkspaceMigration(preview.id) } else { _ = try store.applyWorkspaceMigration(preview) }
        }
        // Positive control: the crash left the organization written alone.
        #expect(try Self.files(directory)[1] != before[1] && Self.files(directory)[0] == before[0])
        let relaunched = RelaySharedWorkspaceStore(directory: directory)
        _ = try relaunched.restoreOrganization()
        #expect(try Self.files(directory) == before)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("migration-layers-pending.json").path))
    }

    @MainActor @Test func modelAdoptsThePlacementsAndKeepsThemThroughTheNextSave() throws {
        let f = Self.fixture()
        let (_, directory) = try Self.store(f)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceModel(restoreSavedWorkspace: true, workspaceDirectory: directory)
        defer { model.shutdown() }
        let preview = try model.previewWorkspaceMigration(overrides: Self.overrides)
        try model.applyWorkspaceMigration(preview)
        #expect(model.organization.group(containingTab: Self.kaiku)?.id == Self.kaikuWorkspace)
        #expect(model.workspaceID(forTab: Self.kaiku) == Self.kaikuWorkspace)
        _ = try model.previewWorkspaceMigration() // an ordinary save of the same renderer
        let saved = try #require(try RelaySharedWorkspaceStore(directory: directory).restoreOrganization())
        #expect(Self.placement(Self.kaiku, saved)?.groupID == Self.kaikuWorkspace)
        try model.undoWorkspaceMigration(preview.id)
        #expect(model.organization.group(containingTab: Self.kaiku)?.id == Self.project)
        #expect(model.workspaceID(forTab: Self.kaiku) == Self.kaikuWorkspace)  // restored owner
    }
}
