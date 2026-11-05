import Foundation
import Testing
@testable import Relay

/// QA-F01b: a migration that names some tabs is partial. Every tab it does
/// not name is left exactly as it is, in ownership and in the sidebar; no
/// workspace is removed, renamed or reordered. The no-overrides default and
/// an explicit "global" scope keep the full reconcile.
@MainActor @Suite(.serialized) struct RelayMigrationPartialScopeTests {
    struct Fixture {
        let tabs: [WorkspaceTabReference]
        let ownership: WorkspaceOwnershipSnapshot
        let organization: WorkspaceOrganizationSnapshot
        let named: WorkspaceTabReference
        let placedElsewhere: WorkspaceTabReference
        let target: UUID
        let emptyWorkspace: UUID
        let otherEmpty: UUID
    }

    /// Root's repro plus a placed tab whose sidebar group differs from its
    /// owner (the kaiku shape) and an untouched empty workspace.
    static func fixture() -> Fixture {
        let work = UUID(), dandy = UUID(), project = UUID()
        func tab(_ session: UUID, _ name: String) -> WorkspaceTabReference {
            WorkspaceTabReference(id: UUID(), sessionID: session, title: "tab", sessionName: name, paneIDs: [UUID()])
        }
        let relayA = tab(work, "Work"), relayB = tab(work, "Work")
        let panBarley = tab(dandy, "dandy-07")
        let stillHome = tab(work, "Work")
        let placedElsewhere = tab(work, "Work")    // owned by Relay & Chitta, shown in the "Kaiku" project group
        let named = tab(dandy, "dandy-07")         // the one tab the request names
        let tabs = [relayA, relayB, panBarley, stillHome, placedElsewhere, named]
        var ownership = WorkspaceOwnershipSnapshot.bootstrap(tabs: tabs)
        let relayWS = ownership.createWorkspace(name: "Relay & Chitta")
        let panWS = ownership.createWorkspace(name: "PanBarley")
        let qaWS = ownership.createWorkspace(name: "Relay live QA")
        let emptyWS = ownership.createWorkspace(name: "Untouched empty")
        for (t, owner) in [(relayA, relayWS), (relayB, relayWS), (panBarley, panWS), (placedElsewhere, relayWS)] {
            let index = ownership.owners.firstIndex { $0.id == t.id }!
            ownership.owners[index].place(in: owner, order: Double(index))
        }
        let organization = WorkspaceOrganizationSnapshot(schemaVersion: 2, groups: [
            WorkspaceGroup(id: work, parentID: nil, order: 0, name: "Work", kind: .session, collapsed: false),
            WorkspaceGroup(id: project, parentID: nil, order: 1, name: "Kaiku", kind: .project, collapsed: false),
        ], placements: [WorkspaceTabPlacement(id: placedElsewhere.id, groupID: project, order: 0)], savedViews: [])
        return Fixture(tabs: tabs, ownership: ownership, organization: organization, named: named,
                       placedElsewhere: placedElsewhere, target: relayWS, emptyWorkspace: emptyWS, otherEmpty: qaWS)
    }

    @Test func aRequestNamingOneTabWithoutAScopeLeavesEveryOtherTabExactlyAsItIs() throws {
        let f = Self.fixture()
        let before = f.ownership
        #expect(WorkspaceMigration.disagreeing(tabs: f.tabs, organization: f.organization, ownership: f.ownership)
            .contains(f.placedElsewhere.id), "positive control: the placed tab's layers disagree today")

        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: f.organization, ownership: f.ownership,
                                                 overrides: [f.named.id: "Relay & Chitta"])
        #expect(preview.scope == .partial)
        for row in preview.rows where row.tabID != f.named.id {
            #expect(row.source == .currentOwner && row.workspaceID == before.owner(of: row.tabID))
        }
        #expect(preview.workspaces.flatMap(\.tabIDs) == [f.named.id], "only the named tab is migrated")
        #expect(preview.removed.isEmpty && preview.retiredGroups.isEmpty)

        let applied = try WorkspaceMigration.apply(preview, to: f.ownership, organization: f.organization, tabs: f.tabs,
                                                   current: preview.sourceChecksums)
        // Unnamed tabs: owner, owner order and sidebar placement unchanged.
        for t in f.tabs where t.id != f.named.id {
            #expect(applied.ownership.owners.first { $0.id == t.id } == before.owners.first { $0.id == t.id })
            #expect(applied.organization.placements.first { $0.id == t.id } == f.organization.placements.first { $0.id == t.id })
        }
        #expect(WorkspaceMigration.disagreeing(tabs: f.tabs, organization: applied.organization, ownership: applied.ownership)
            .contains(f.placedElsewhere.id), "the unnamed placed tab is not re-placed")
        // Workspaces: none removed, renamed or reordered; the empty one stays.
        for record in before.workspaces {
            let after = try #require(applied.ownership.workspace(record.id), "workspace \(record.name) kept")
            #expect(after.name == record.name && after.order == record.order)
        }
        #expect(applied.ownership.workspace(f.emptyWorkspace) != nil && applied.ownership.workspace(f.otherEmpty) != nil)
        #expect(applied.ownership.orderedWorkspaces.map(\.id) == before.orderedWorkspaces.map(\.id))
        // The named tab moves, after the target's existing tabs, and both its layers agree.
        #expect(applied.ownership.owner(of: f.named.id) == f.target)
        #expect(!WorkspaceMigration.disagreeing(tabs: f.tabs, organization: applied.organization, ownership: applied.ownership)
            .contains(f.named.id))
        let existing = before.owners.filter { $0.workspaceID == f.target }.map(\.order).max() ?? -1
        #expect(existing >= 0, "positive control: the target already has tabs")
        #expect((applied.ownership.owners.first { $0.id == f.named.id }?.order ?? -1) > existing)
    }

    @Test func theSameRequestWithAnExplicitGlobalScopeStillReconciles() {
        let f = Self.fixture()
        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: f.organization, ownership: f.ownership,
                                                 overrides: [f.named.id: "Relay & Chitta"], scope: .global)
        #expect(preview.scope == .global)
        #expect(Set(preview.workspaces.flatMap(\.tabIDs)) == Set(f.tabs.map(\.id)), "global covers every tab")
        #expect(preview.removed.map(\.id).contains(f.emptyWorkspace), "global still removes empty workspaces")
    }

    @Test func noOverridesAndNoScopeIsTheGlobalDefault() {
        let f = Self.fixture()
        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: f.organization, ownership: f.ownership)
        #expect(preview.scope == .global)
        #expect(Set(preview.workspaces.flatMap(\.tabIDs)) == Set(f.tabs.map(\.id)))
    }

    @Test func anExplicitPartialScopeWithNoEntriesIsANoOp() throws {
        let f = Self.fixture()
        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: f.organization, ownership: f.ownership,
                                                 scope: .partial)
        #expect(preview.scope == .partial, "never promoted to global")
        #expect(preview.workspaces.flatMap(\.tabIDs).isEmpty && preview.removed.isEmpty && preview.retiredGroups.isEmpty)
        let applied = try WorkspaceMigration.apply(preview, to: f.ownership, organization: f.organization, tabs: f.tabs,
                                                   current: preview.sourceChecksums)
        #expect(applied.ownership.owners == f.ownership.owners)
        #expect(applied.ownership.workspaces == f.ownership.workspaces)
        #expect(applied.organization == f.organization)
    }

    /// Root's r1 review (a9b48a73): a blank or whitespace-only override
    /// without a scope must not promote the request to global. It is
    /// partial and, naming no workspace, moves nothing.
    @Test(arguments: ["", "   ", " \t\n"])
    func aBlankOverrideWithoutAScopeIsPartialAndChangesNothing(_ blank: String) throws {
        let f = Self.fixture()
        let preview = WorkspaceMigration.preview(tabs: f.tabs, organization: f.organization, ownership: f.ownership,
                                                 overrides: [f.named.id: blank])
        #expect(preview.scope == .partial, "never promoted to global")
        #expect(preview.workspaces.flatMap(\.tabIDs).isEmpty && preview.removed.isEmpty && preview.retiredGroups.isEmpty)
        #expect(preview.rows.allSatisfy { $0.source == .currentOwner })
        let applied = try WorkspaceMigration.apply(preview, to: f.ownership, organization: f.organization, tabs: f.tabs,
                                                   current: preview.sourceChecksums)
        #expect(applied.ownership.owners == f.ownership.owners)
        #expect(applied.ownership.workspaces == f.ownership.workspaces)
        #expect(applied.organization == f.organization)
    }

    @Test func aBlankOverrideInAPlanWithoutAScopeOpensAPartialPreview() throws {
        let w = WorkspaceModel(restoreSavedWorkspace: false)
        defer { w.shutdown() }
        let id = try #require(w.selectedTab?.id).uuidString.lowercased()
        for blank in ["", "   "] {
            let preview = try w.previewWorkspaceMigration(plan: Data("{\"overrides\":{\"\(id)\":\"\(blank)\"}}".utf8))
            #expect(preview.scope == .partial && preview.workspaces.flatMap(\.tabIDs).isEmpty && preview.removed.isEmpty)
        }
        // Explicit global and a truly empty override map stay global.
        #expect(try w.previewWorkspaceMigration(plan: Data("{\"overrides\":{\"\(id)\":\"   \"},\"scope\":\"global\"}".utf8)).scope == .global)
        #expect(try w.previewWorkspaceMigration(plan: Data("{\"overrides\":{}}".utf8)).scope == .global)
    }

    @Test func planScopeIsParsedValidatedAndKept() throws {
        let tab = UUID().uuidString.lowercased()
        func plan(_ scope: String?) -> Data {
            Data(("{\"overrides\":{\"\(tab)\":\"X\"}" + (scope.map { ",\"scope\":\"\($0)\"" } ?? "") + "}").utf8)
        }
        #expect(try WorkspaceMigrationPlan.parse(plan(nil)).scope == nil)
        #expect(try WorkspaceMigrationPlan.parse(plan("partial")).scope == .partial)
        #expect(try WorkspaceMigrationPlan.parse(plan("global")).scope == .global)
        for bad in ["everything", "Global", ""] {
            #expect(throws: WorkspaceMigrationPlanError.invalidScope(bad)) { try WorkspaceMigrationPlan.parse(plan(bad)) }
        }
        // The decoded plan keeps its scope through encode and decode (staging stores the plan).
        let decoded = try JSONDecoder().decode(WorkspaceMigrationPlan.self, from: plan("global"))
        let again = try JSONDecoder().decode(WorkspaceMigrationPlan.self, from: try JSONEncoder().encode(decoded))
        #expect(again.scope == "global" && again == decoded)
    }

    @Test func thePlanPathCarriesScopeIntoTheOpenPreview() throws {
        let w = WorkspaceModel(restoreSavedWorkspace: false)
        defer { w.shutdown() }
        let id = try #require(w.selectedTab?.id).uuidString.lowercased()
        let named = Data("{\"overrides\":{\"\(id)\":\"Somewhere\"}}".utf8)
        #expect(try w.previewWorkspaceMigration(plan: named).scope == .partial)
        #expect(w.migrationPreview?.scope == .partial)
        // The MCP preview state (relay_workspace_migration_preview) reports it.
        #expect((w.workspaceMigrationControlState()["preview"] as? [String: Any])?["scope"] as? String == "partial")
        let global = Data("{\"overrides\":{\"\(id)\":\"Somewhere\"},\"scope\":\"global\"}".utf8)
        #expect(try w.previewWorkspaceMigration(plan: global).scope == .global)
        #expect(w.migrationPreview?.scope == .global)
        #expect(throws: WorkspaceMigrationPlanError.invalidScope("all")) {
            try w.previewWorkspaceMigration(plan: Data("{\"scope\":\"all\"}".utf8))
        }
        #expect(w.migrationPreview?.scope == .global, "a rejected plan leaves the open preview as it was")
    }
}
