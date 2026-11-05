import Foundation
import Testing
@testable import Relay

/// QA-F01: relay_workspace_organization reports ownership as its canonical
/// structure; the legacy group projection is kept under labelled keys.
@MainActor @Suite(.serialized) struct WorkspaceOrganizationCanonicalTests {
    private func text(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    @Test func emptyWorkspaceNewTabIsFiledByOwnershipNotItsBirthSession() throws {
        let w = WorkspaceModel(restoreSavedWorkspace: false)
        defer { w.shutdown() }
        let first = try #require(w.selectedTab)
        w.newTab(profile: .sshConfigHost("qa-f01-a.invalid"))
        let placed = try #require(w.selectedTab)
        let a = try #require(w.workspaceID(forTab: first.id))
        #expect(w.workspaceID(forTab: placed.id) == a)
        let group = w.organization.createGroup(name: "Placed group", kind: .project, parentID: nil)
        w.organization.placeTab(placed.id, inGroup: group, at: 0)
        let b = w.createWorkspace(named: "QA empty")

        // Every existing tab's canonical and legacy trails, owners and order.
        func trails() -> [UUID: String] {
            Dictionary(uniqueKeysWithValues: w.tabs.map { tab in
                (tab.id, text(w.ownershipBreadcrumbs(for: .tab(tab.id)))
                    + "|" + text(w.organization.breadcrumb(for: .tab(tab.id)).map(w.organizationTargetJSON)))
            })
        }
        let before = trails()
        let ownersBefore = Dictionary(uniqueKeysWithValues: w.tabs.map { ($0.id, w.workspaceID(forTab: $0.id)) })
        let orderBefore = w.ownership.tabIDs(in: a)

        // Show the empty workspace B (the remembered tab is in A), then New tab.
        w.selectWorkspace(b)
        #expect(w.selectedWorkspaceID == b)
        #expect(w.visibleTab == nil, "B is shown empty")
        w.newTabInActiveSession(origin: .human)
        let made = try #require(w.selectedTab)
        try #require(before[made.id] == nil, "a new tab was made")
        let paneID = try #require(made.allPaneIDs.first)
        #expect(w.workspaceID(forTab: made.id) == b)
        #expect(w.selectedWorkspaceID == b)
        // The divergence QA-F01 is about: its legacy session is A's.
        #expect(made.sessionID != b)

        w.organization.navigate(to: .tab(made.id))
        #expect(w.selectedWorkspaceID == b)
        var state = try w.workspaceOrganizationControlState()
        #expect(state["schema_version"] as? Int == 3)
        #expect(state["canonical_structure"] as? String == "workspaces")
        #expect(state["outline"] == nil, "the ambiguous key is gone")
        #expect(state["legacy_group_outline"] is [[String: Any]])
        var navigation = try #require(state["navigation"] as? [String: Any])
        let crumbs = try #require(navigation["breadcrumbs"] as? [[String: Any]])
        #expect(crumbs.map { $0["kind"] as? String } == ["all", "workspace", "tab"])
        #expect(crumbs[1]["id"] as? String == b.uuidString.lowercased())
        #expect(crumbs[1]["title"] as? String == "QA empty")
        #expect(crumbs[2]["id"] as? String == made.id.uuidString.lowercased())
        let legacy = try #require(navigation["group_breadcrumbs"] as? [[String: Any]])
        #expect(legacy.contains { $0["id"] as? String == made.sessionID.uuidString.lowercased() },
            "the legacy trail is still reported, labelled as such")
        let paneCrumbs = w.ownershipBreadcrumbs(for: .pane(paneID))
        #expect(paneCrumbs.map { $0["kind"] as? String } == ["all", "workspace", "tab", "pane"])
        #expect(paneCrumbs[1]["id"] as? String == b.uuidString.lowercased())

        // Canonical structure: the new tab is listed under B and nowhere else.
        let workspaces = try #require(state["workspaces"] as? [[String: Any]])
        let holders = workspaces.filter { ($0["tab_ids"] as? [String])?.contains(made.id.uuidString.lowercased()) == true }
        #expect(holders.count == 1)
        #expect(holders.first?["id"] as? String == b.uuidString.lowercased())
        let layouts = try #require(state["tabs"] as? [[String: Any]])
        #expect(layouts.first { $0["id"] as? String == made.id.uuidString.lowercased() }?["workspace_id"] as? String
            == b.uuidString.lowercased())

        // Unrelated tabs: same trails, owners and order.
        let after = trails()
        for (id, trail) in before { #expect(after[id] == trail, "tab \(id) unchanged") }
        for (id, owner) in ownersBefore { #expect(w.workspaceID(forTab: id) == owner) }
        #expect(w.ownership.tabIDs(in: a) == orderBefore)

        // A placed tab keeps its group path under group_breadcrumbs.
        w.organization.navigate(to: .tab(placed.id))
        state = try w.workspaceOrganizationControlState()
        navigation = try #require(state["navigation"] as? [String: Any])
        let placedLegacy = try #require(navigation["group_breadcrumbs"] as? [[String: Any]])
        #expect(placedLegacy.contains { $0["id"] as? String == group.uuidString.lowercased() })
        let placedCrumbs = try #require(navigation["breadcrumbs"] as? [[String: Any]])
        #expect(placedCrumbs.dropFirst().first?["id"] as? String == a.uuidString.lowercased())
    }

    /// Root's planner repro, as a mixed fixture: several workspaces, and
    /// unplaced tabs whose birth session differs from their canonical owner.
    /// A preview that names one tab (a same-owner override) must move no
    /// other tab, in the preview and after apply. QA-F01b: pinned to
    /// `scope: .global`, the QA-F01 rule under the full reconcile; the same
    /// request without a scope is partial (RelayMigrationPartialScopeTests).
    @Test func previewNamingOneTabMovesNoUnnamedTab() throws {
        let work = UUID(), sapropel = UUID(), dandy = UUID(), other = UUID()
        func tab(_ session: UUID, _ name: String) -> WorkspaceTabReference {
            WorkspaceTabReference(id: UUID(), sessionID: session, title: "tab", sessionName: name, paneIDs: [UUID()])
        }
        let relayA = tab(work, "Work"), relayB = tab(work, "Work")       // owned by Relay & Chitta
        let panBarley = tab(dandy, "dandy-07")                            // owned by PanBarley
        let qaRemote = tab(sapropel, "Sapropel live Claude")              // owned by QA (empty-workspace New tab)
        let qaLocal = tab(other, "Other")                                 // owned by QA; the one named tab
        let stillHome = tab(work, "Work")                                 // owned by its own session workspace
        let tabs = [relayA, relayB, panBarley, qaRemote, qaLocal, stillHome]
        var ownership = WorkspaceOwnershipSnapshot.bootstrap(tabs: tabs)
        let relayWS = ownership.createWorkspace(name: "Relay & Chitta")
        let panWS = ownership.createWorkspace(name: "PanBarley")
        let qaWS = ownership.createWorkspace(name: "Relay live QA")
        for (t, owner) in [(relayA, relayWS), (relayB, relayWS), (panBarley, panWS), (qaRemote, qaWS), (qaLocal, qaWS)] {
            let index = try #require(ownership.owners.firstIndex { $0.id == t.id })
            ownership.owners[index].place(in: owner, order: Double(index))
        }
        #expect(ownership.owner(of: stillHome.id) == work)
        let organization = WorkspaceOrganizationSnapshot(schemaVersion: 2, groups: [
            WorkspaceGroup(id: work, parentID: nil, order: 0, name: "Work", kind: .session, collapsed: false),
            WorkspaceGroup(id: sapropel, parentID: nil, order: 1, name: "Sapropel live Claude", kind: .session, collapsed: false),
        ], placements: [], savedViews: [])
        let ownersBefore = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, ownership.owner(of: $0.id)) })

        let preview = WorkspaceMigration.preview(tabs: tabs, organization: organization, ownership: ownership,
                                                 overrides: [qaLocal.id: "Relay live QA"], scope: .global)
        for row in preview.rows where row.tabID != qaLocal.id {
            #expect(row.workspaceID == ownersBefore[row.tabID]!, "unnamed tab \(row.tabID) keeps its owner in the preview")
        }
        #expect(preview.rows.first { $0.tabID == qaLocal.id }?.workspaceID == qaWS)
        let kept: Set<UUID> = Set(preview.rows.filter { $0.source == .currentOwner }.map(\.tabID))
        let decided: Set<UUID> = [relayA.id, relayB.id, panBarley.id, qaRemote.id]
        #expect(kept == decided)

        let applied = try WorkspaceMigration.apply(preview, to: ownership, organization: organization, tabs: tabs,
                                                   current: preview.sourceChecksums)
        for t in tabs { #expect(applied.ownership.owner(of: t.id) == ownersBefore[t.id]!, "tab \(t.id) keeps its owner after apply") }
        #expect(WorkspaceMigration.disagreeing(tabs: tabs, organization: applied.organization, ownership: applied.ownership).isEmpty,
            "after apply the sidebar agrees with every owner")
    }
}
