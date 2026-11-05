import AppKit
import Foundation
import Testing
@testable import Relay

/// relay_tab_action move across sessions/workspaces and the anchored
/// relay_new_local_tab, driven through the real direct MCP handler.
@MainActor @Suite("MCP tab move and anchored new tab")
struct MCPTabMoveTests {
    struct Fixture {
        let workspace: WorkspaceModel
        let a1: TabModel, b1: TabModel, b2: TabModel
        let w1: UUID, w2: UUID
    }

    /// Two legacy sessions in two workspaces: A1 (S1, W1); B1, B2 (S2, W2).
    static func fixture() throws -> Fixture {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.newTab(profile: .sshConfigHost("mcp-tab-move-a.invalid"))
        let a1 = try #require(workspace.selectedTab)
        workspace.newTab(profile: .sshConfigHost("mcp-tab-move-b.invalid"))
        let b1 = try #require(workspace.selectedTab)
        workspace.newTab(inSession: b1.sessionID, profile: nil)
        let b2 = try #require(workspace.selectedTab)
        #expect(b2.sessionID == b1.sessionID && a1.sessionID != b1.sessionID)
        let w1 = workspace.createWorkspace(named: "MCP W1"), w2 = workspace.createWorkspace(named: "MCP W2")
        try workspace.moveTab(a1.id, toWorkspace: w1)
        try workspace.moveTab(b1.id, toWorkspace: w2)
        try workspace.moveTab(b2.id, toWorkspace: w2)
        workspace.setNavigatorSortMode(.manual)
        return Fixture(workspace: workspace, a1: a1, b1: b1, b2: b2, w1: w1, w2: w2)
    }

    /// Everything a move or an anchored create must never change.
    struct Identity: Equatable {
        let panes: [UUID: ObjectIdentifier]
        let runtimes: [UUID: ObjectIdentifier]
        let tabPanes: [UUID: [UUID]]
        let sessions: [UUID: UUID]
        let remote: [UUID: String?]
        let pinned: Set<UUID>

        @MainActor init(_ workspace: WorkspaceModel) {
            panes = workspace.panes.mapValues { ObjectIdentifier($0) }
            runtimes = workspace.panes.mapValues { ObjectIdentifier($0.runtime) }
            tabPanes = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0.allPaneIDs) })
            sessions = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0.sessionID) })
            remote = workspace.panes.mapValues { $0.remoteWorkspaceSessionID }
            pinned = Set(workspace.tabs.map(\.id).filter(workspace.isTabPinned))
        }
    }

    /// Workspace structure an action may change, for "nothing changed" checks.
    struct Layout: Equatable {
        let tabs: [UUID]
        let owners: [WorkspaceTabOwner]
        let placements: [WorkspaceTabPlacement]
        let panes: Set<UUID>
        @MainActor init(_ workspace: WorkspaceModel) {
            tabs = workspace.tabs.map(\.id)
            owners = workspace.ownership.owners.sorted { $0.id.uuidString < $1.id.uuidString }
            placements = workspace.organization.placements.sorted { $0.id.uuidString < $1.id.uuidString }
            panes = Set(workspace.panes.keys)
        }
    }

    static func body(_ object: [String: String]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    static func move(_ instance: UUID, _ request: UUID, _ tab: UUID, _ target: UUID, _ placement: String) -> Data {
        body(["instance": instance.uuidString, "requestID": request.uuidString, "tabID": tab.uuidString,
              "action": "move", "targetTabID": target.uuidString, "placement": placement])
    }

    static func json(_ response: RelaySidePanelHTTPResponse) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: response.body) as? [String: String]) ?? [:]
    }

    static let all: (MCPWorkspaceCapability) -> Bool = { _ in true }

    @Test(arguments: ["after", "before"])
    func crossSessionMoveSitsBesideTargetAndKeepsEveryPane(placement: String) throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let handler = MCPDirectTabRequests(), instance = UUID()
        let before = Identity(f.workspace)
        let response = handler.tabAction(Self.move(instance, UUID(), f.a1.id, f.b1.id, placement), instance: instance,
                                         permits: Self.all, workspace: f.workspace)
        #expect(response.status == 200)
        #expect(Self.json(response)["workspaceID"] == f.w2.uuidString.lowercased())
        let side: TabMovePlacement = placement == "after" ? .after : .before
        #expect(f.workspace.workspaceTabIsBeside(f.a1.id, f.b1.id, placement: side))
        let expected = side == .after ? [f.b1.id, f.a1.id, f.b2.id] : [f.a1.id, f.b1.id, f.b2.id]
        #expect(f.workspace.ownership.tabIDs(in: f.w2) == expected)
        #expect(f.workspace.ownership.tabIDs(in: f.w1).isEmpty)
        // Shown in B1's session group, beside B1.
        #expect(f.workspace.organization.group(containingTab: f.a1.id)?.id == f.b1.sessionID)
        #expect(f.workspace.organizationSiblings(ofTab: f.b1.id).tabIDs == expected)
        // Birth identity, panes, runtimes, remote hierarchy, pins: unchanged.
        #expect(Identity(f.workspace) == before)
        #expect(f.workspace.tabs.first { $0.id == f.a1.id }?.sessionID == f.a1.sessionID)
    }

    @Test func moveWithinOneWorkspaceReorders() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        try f.workspace.moveWorkspaceTab(f.b2.id, beside: f.b1.id, placement: .before)
        #expect(f.workspace.ownership.tabIDs(in: f.w2) == [f.b2.id, f.b1.id])
        #expect(f.workspace.organizationSiblings(ofTab: f.b1.id).tabIDs == [f.b2.id, f.b1.id])
        try f.workspace.moveWorkspaceTab(f.b2.id, beside: f.b1.id, placement: .after)
        #expect(f.workspace.ownership.tabIDs(in: f.w2) == [f.b1.id, f.b2.id])
    }

    @Test func refusedMovesChangeNothing() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let handler = MCPDirectTabRequests(), instance = UUID()
        let layout = Layout(f.workspace)
        func attempt(_ tab: UUID, _ target: UUID) -> Int {
            handler.tabAction(Self.move(instance, UUID(), tab, target, "after"), instance: instance,
                              permits: Self.all, workspace: f.workspace).status
        }
        #expect(attempt(f.a1.id, f.a1.id) == 409)       // same tab
        #expect(throws: WorkspaceMoveRefusal.samePlace) {
            try f.workspace.workspaceTabMoveDestination(f.b1.id, beside: f.b1.id, placement: .after)
        }
        #expect(attempt(UUID(), f.b1.id) == 409)         // stale source
        #expect(attempt(f.a1.id, UUID()) == 409)         // stale target
        // A tab whose close awaits confirmation, as source or as target.
        _ = f.workspace.whileAwaitingCloseConfirmation([f.b1.id]) {
            #expect(attempt(f.a1.id, f.b1.id) == 409)
            #expect(attempt(f.b1.id, f.b2.id) == 409)
            #expect(throws: WorkspaceMoveRefusal.tabClosing) {
                try f.workspace.moveWorkspaceTab(f.a1.id, beside: f.b1.id, placement: .after)
            }
            return false
        }
        #expect(Layout(f.workspace) == layout)
        #expect(f.workspace.tabsAwaitingCloseConfirmation.isEmpty)
        // After the confirmation is cancelled, the same move is admitted.
        #expect(attempt(f.a1.id, f.b1.id) == 200)
    }

    /// Two actors: an approval-path move is admitted, then the target (or
    /// source) closes before the user approves. Approval must not apply it.
    @Test(arguments: [false, true])
    func concurrentCloseBeforeApprovalFailsWithoutMoving(closeSource: Bool) throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        var approve: ((NSApplication.ModalResponse) -> Void)?
        let broker = WorkspaceControl { _, callback in approve = callback; return true }
        let instance = UUID(), id = UUID()
        let proposal = WorkspaceTabProposal(instance: instance, requestID: id, tabID: f.a1.id, action: .move,
                                            name: nil, targetTabID: f.b1.id, placement: .after)
        let detail = try f.workspace.workspaceTabActionDetail(proposal)
        var applied = 0
        let receipt = try broker.propose(proposal, instance: instance, detail: detail) { [weak workspace = f.workspace] in
            guard let workspace, let tab = workspace.applyWorkspaceTabAction(proposal) else { return nil }
            applied += 1
            return (tab, workspace.selectedTabID ?? tab)
        }
        #expect(receipt.status == "awaiting_approval")
        f.workspace.closeTab(closeSource ? f.a1.id : f.b1.id)
        let layout = Layout(f.workspace)
        approve?(.alertSecondButtonReturn)
        #expect(applied == 0)
        #expect(broker.receipt(id)?.status == "failed")
        #expect(Layout(f.workspace) == layout)
    }

    @Test func requestIDsAreIdempotentAndBound() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let handler = MCPDirectTabRequests(), instance = UUID(), id = UUID()
        let first = handler.tabAction(Self.move(instance, id, f.a1.id, f.b1.id, "after"), instance: instance,
                                      permits: Self.all, workspace: f.workspace)
        #expect(first.status == 200)
        let again = handler.tabAction(Self.move(instance, id, f.a1.id, f.b1.id, "after"), instance: instance,
                                      permits: Self.all, workspace: f.workspace)
        #expect(again.status == 200 && again.body == first.body)
        #expect(handler.tabAction(Self.move(instance, id, f.a1.id, f.b2.id, "after"), instance: instance,
                                  permits: Self.all, workspace: f.workspace).status == 409)
        #expect(handler.tabAction(Self.move(UUID(), UUID(), f.a1.id, f.b2.id, "after"), instance: instance,
                                  permits: Self.all, workspace: f.workspace).status == 400)
    }

    // MARK: Anchored new tab

    static func newTab(_ instance: UUID, _ request: UUID, pane: UUID? = nil, tab: UUID? = nil) -> Data {
        var object = ["instance": instance.uuidString, "requestID": request.uuidString]
        if let pane { object["anchorPaneID"] = pane.uuidString }
        if let tab { object["anchorTabID"] = tab.uuidString }
        return body(object)
    }

    @Test(arguments: [false, true])
    func anchoredNewTabOpensRightAfterTheAnchorInItsSession(byTab: Bool) throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        f.workspace.selectTab(f.a1.id) // The active session is not the anchor's.
        let handler = MCPDirectTabRequests(), instance = UUID()
        let before = Identity(f.workspace)
        let anchorPane = try #require(f.b1.allPaneIDs.first)
        let response = handler.newLocalTab(byTab ? Self.newTab(instance, UUID(), tab: f.b1.id)
                                                 : Self.newTab(instance, UUID(), pane: anchorPane),
                                           instance: instance, permits: Self.all, workspace: f.workspace)
        #expect(response.status == 200)
        let result = Self.json(response)
        let created = try #require(result["tabID"].flatMap(UUID.init(uuidString:)))
        let tab = try #require(f.workspace.tabs.first { $0.id == created })
        #expect(tab.sessionID == f.b1.sessionID)
        #expect(result["workspaceID"] == f.w2.uuidString.lowercased())
        #expect(f.workspace.ownership.tabIDs(in: f.w2) == [f.b1.id, created, f.b2.id])
        #expect(f.workspace.organizationSiblings(ofTab: f.b1.id).tabIDs == [f.b1.id, created, f.b2.id])
        Self.expectPlacedRightAfter(created, f.b1.id, then: f.b2.id, group: f.b1.sessionID, in: f.workspace)
        #expect(result["paneID"] == tab.allPaneIDs.first?.uuidString.lowercased())
        // Every pre-existing pane and tab is untouched.
        let after = Identity(f.workspace)
        #expect(before.panes.allSatisfy { after.panes[$0.key] == $0.value })
        #expect(before.tabPanes.allSatisfy { after.tabPanes[$0.key] == $0.value })
        #expect(before.sessions.allSatisfy { after.sessions[$0.key] == $0.value })
    }

    /// The organization record itself, not only the derived sibling list:
    /// `tab` has a placement in the anchor's group at the anchor's next index.
    static func expectPlacedRightAfter(_ tab: UUID, _ anchor: UUID, then next: UUID, group: UUID,
                                       in workspace: WorkspaceModel) {
        let placement = { (id: UUID) in workspace.organization.placements.first { $0.id == id } }
        #expect(placement(tab)?.groupID == group)
        #expect(placement(anchor)?.groupID == group)
        #expect(workspace.organization.group(containingTab: tab)?.id == group)
        if let mine = placement(tab)?.order, let theirs = placement(anchor)?.order, let after = placement(next)?.order {
            #expect(mine == theirs + 1 && after == mine + 1)
        } else {
            Issue.record("Missing organization placement for the new tab, its anchor or the next tab")
        }
    }

    /// The anchor's group already has explicit placements (the sidebar was
    /// reordered by hand, or the tabs were filed into a project). An unplaced
    /// new tab would sort after every placed tab, so only an explicit
    /// placement puts it right after the anchor in the sidebar.
    @Test(arguments: [false, true])
    func anchoredNewTabJoinsTheAnchorsExplicitlyOrderedGroup(project: Bool) throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let group = project ? f.workspace.organization.createGroup(name: "MCP project", kind: .project, parentID: nil)
                            : f.b1.sessionID
        f.workspace.organization.placeTab(f.b1.id, inGroup: group, at: 0)
        f.workspace.organization.placeTab(f.b2.id, inGroup: group, at: 1)
        #expect(f.workspace.organizationSiblings(ofTab: f.b1.id).tabIDs == [f.b1.id, f.b2.id])
        f.workspace.selectTab(f.a1.id)
        let handler = MCPDirectTabRequests(), instance = UUID()
        let response = handler.newLocalTab(Self.newTab(instance, UUID(), tab: f.b1.id), instance: instance,
                                           permits: Self.all, workspace: f.workspace)
        #expect(response.status == 200)
        let created = try #require(Self.json(response)["tabID"].flatMap(UUID.init(uuidString:)))
        #expect(f.workspace.tabs.first { $0.id == created }?.sessionID == f.b1.sessionID)
        #expect(f.workspace.ownership.tabIDs(in: f.w2) == [f.b1.id, created, f.b2.id])
        #expect(f.workspace.organizationSiblings(ofTab: f.b1.id).tabIDs == [f.b1.id, created, f.b2.id])
        Self.expectPlacedRightAfter(created, f.b1.id, then: f.b2.id, group: group, in: f.workspace)
    }

    @Test func anchoredNewTabRefusalsCreateNothing() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        let handler = MCPDirectTabRequests(), instance = UUID()
        let layout = Layout(f.workspace)
        let pane = try #require(f.b1.allPaneIDs.first)
        func status(_ data: Data) -> Int {
            handler.newLocalTab(data, instance: instance, permits: Self.all, workspace: f.workspace).status
        }
        #expect(status(Self.newTab(instance, UUID(), pane: pane, tab: f.b1.id)) == 400) // two anchors
        #expect(status(Self.newTab(instance, UUID(), pane: UUID())) == 409)              // stale pane
        #expect(status(Self.newTab(instance, UUID(), tab: UUID())) == 409)               // stale tab
        _ = f.workspace.whileAwaitingCloseConfirmation([f.b1.id]) {
            #expect(status(Self.newTab(instance, UUID(), tab: f.b1.id)) == 409)
            #expect(status(Self.newTab(instance, UUID(), pane: pane)) == 409)
            return false
        }
        #expect(Layout(f.workspace) == layout)
        // Same request ID with a different anchor is a conflict, not a second tab.
        let id = UUID()
        #expect(status(Self.newTab(instance, id, tab: f.b1.id)) == 200)
        let count = f.workspace.tabs.count
        #expect(status(Self.newTab(instance, id, tab: f.b2.id)) == 409)
        #expect(status(Self.newTab(instance, id, tab: f.b1.id)) == 200)
        #expect(f.workspace.tabs.count == count)
    }

    @Test func unanchoredNewTabKeepsTodaysActiveSessionDefault() throws {
        let f = try Self.fixture()
        defer { f.workspace.shutdown() }
        f.workspace.selectTab(f.a1.id)
        let handler = MCPDirectTabRequests(), instance = UUID()
        let response = handler.newLocalTab(Self.newTab(instance, UUID()), instance: instance,
                                           permits: Self.all, workspace: f.workspace)
        #expect(response.status == 200)
        let created = try #require(Self.json(response)["tabID"].flatMap(UUID.init(uuidString:)))
        #expect(f.workspace.tabs.first { $0.id == created }?.sessionID == f.a1.sessionID)
        #expect(f.workspace.tabs.last?.id == created)
        #expect(Self.json(response)["workspaceID"] == nil)
    }

    // MARK: Exhaustive bounded authorization check

    enum GrantState: Hashable { case notRequested, awaiting, denied, granted(Set<MCPWorkspaceCapability>) }

    /// Drives the real MCPWorkspaceGrant (injected presenter) into a state.
    static func grant(_ state: GrantState) throws -> MCPWorkspaceGrant {
        var alert: NSAlert?
        var answer: ((NSApplication.ModalResponse) -> Void)?
        let grant = MCPWorkspaceGrant { proposal, callback in alert = proposal; answer = callback; return true }
        switch state {
        case .notRequested: break
        case .awaiting: try grant.request()
        case .denied: try grant.request(); answer?(.alertFirstButtonReturn)
        case .granted(let set):
            try grant.request()
            let buttons = (alert?.accessoryView as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton } ?? []
            for (capability, button) in zip(MCPWorkspaceCapability.allCases, buttons) {
                button.state = set.contains(capability) ? .on : .off
            }
            answer?(.alertSecondButtonReturn)
        }
        return grant
    }

    enum Operation: CaseIterable {
        case moveAfter, moveBefore, moveSame, moveStale, newAnchoredPane, newAnchoredTab, newDefault, newStaleAnchor
        case stackCross, stackStale, newStackedLocal, newStackedBadHost
        var endpoint: MCPDirectTabRequests.Endpoint {
            switch self {
            case .moveAfter, .moveBefore, .moveSame, .moveStale: .tabAction
            case .stackCross, .stackStale: .stackPane
            case .newStackedLocal, .newStackedBadHost: .newStackedPane
            default: .newLocalTab
            }
        }
        /// The capabilities the specification requires, written independently
        /// of production's `Endpoint.capabilities` so the oracle cannot drift
        /// with it: moving or stacking is layout, creating a terminal is
        /// create, and creating a terminal inside a stack is both. No
        /// default case, so a new operation must state its own capabilities.
        var requiredCapabilities: Set<MCPWorkspaceCapability> {
            switch self {
            case .moveAfter, .moveBefore, .moveSame, .moveStale: [.layout]
            case .stackCross, .stackStale: [.layout]
            case .newStackedLocal, .newStackedBadHost: [.create, .layout]
            case .newAnchoredPane, .newAnchoredTab, .newDefault, .newStaleAnchor: [.create]
            }
        }
    }

    /// Every grant state reachable through the native dialog (not requested,
    /// awaiting, denied, and granted with each of the 32 capability subsets)
    /// × every operation sequence of length ≤ 2 over 12 operations. Safety
    /// properties after every step: the API never changes the grant; a
    /// request is refused with 403 exactly when any capability it needs is
    /// not permitted, and any refusal changes nothing (tabs, layouts,
    /// stacks, owners, placements, panes); no existing pane or runtime is
    /// ever replaced or removed; tab sessions and pane memberships change
    /// only by a successful stack (X leaves its tab, joins Y's, and an
    /// emptied source tab is removed) or a stacked create (Y's tab gains
    /// exactly the new pane); a successful stack leaves X in Y's stack and
    /// never as a split.
    @Test func exhaustiveGrantAndOperationCheck() throws {
        let subsets: [Set<MCPWorkspaceCapability>] = (0..<32).map { mask in
            Set(MCPWorkspaceCapability.allCases.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
        }
        let states: [GrantState] = [.notRequested, .awaiting, .denied] + subsets.map { .granted($0) }
        let ops = Operation.allCases
        let sequences: [[Operation]] = [[]] + ops.map { [$0] } + ops.flatMap { a in ops.map { [a, $0] } }
        var explored = 0, steps = 0, forbidden = 0
        for state in states {
            let grant = try Self.grant(state)
            let status = grant.status, allowed = grant.allowed
            for sequence in sequences {
                let f = try Self.fixture()
                defer { f.workspace.shutdown() }
                let handler = MCPDirectTabRequests(), instance = UUID()
                let pane = f.b1.allPaneIDs.first!
                let aPane = f.a1.allPaneIDs.first!, b2Pane = f.b2.allPaneIDs.first!
                let resolve: (String) -> ConnectionProfile? = { $0 == "This Mac" ? .local : nil }
                for op in sequence {
                    let before = Identity(f.workspace), layout = Layout(f.workspace)
                    let shape = MCPStackPaneTests.Shape(f.workspace)
                    let request = UUID()
                    let response: RelaySidePanelHTTPResponse = switch op {
                    case .moveAfter: handler.tabAction(Self.move(instance, request, f.a1.id, f.b1.id, "after"), instance: instance, permits: grant.permits, workspace: f.workspace)
                    case .moveBefore: handler.tabAction(Self.move(instance, request, f.b2.id, f.b1.id, "before"), instance: instance, permits: grant.permits, workspace: f.workspace)
                    case .moveSame: handler.tabAction(Self.move(instance, request, f.b1.id, f.b1.id, "after"), instance: instance, permits: grant.permits, workspace: f.workspace)
                    case .moveStale: handler.tabAction(Self.move(instance, request, UUID(), f.b1.id, "after"), instance: instance, permits: grant.permits, workspace: f.workspace)
                    case .newAnchoredPane: handler.newLocalTab(Self.newTab(instance, request, pane: pane), instance: instance, permits: grant.permits, workspace: f.workspace)
                    case .newAnchoredTab: handler.newLocalTab(Self.newTab(instance, request, tab: f.b2.id), instance: instance, permits: grant.permits, workspace: f.workspace)
                    case .newDefault: handler.newLocalTab(Self.newTab(instance, request), instance: instance, permits: grant.permits, workspace: f.workspace)
                    case .newStaleAnchor: handler.newLocalTab(Self.newTab(instance, request, tab: UUID()), instance: instance, permits: grant.permits, workspace: f.workspace)
                    case .stackCross: handler.stackPane(MCPStackPaneTests.stack(instance, request, aPane, onto: pane), instance: instance, permits: grant.permits, workspace: f.workspace)
                    case .stackStale: handler.stackPane(MCPStackPaneTests.stack(instance, request, UUID(), onto: pane), instance: instance, permits: grant.permits, workspace: f.workspace)
                    case .newStackedLocal: handler.newStackedPane(MCPStackPaneTests.newStacked(instance, request, onto: b2Pane, host: "This Mac"), instance: instance, permits: grant.permits, workspace: f.workspace, resolve: resolve)
                    case .newStackedBadHost: handler.newStackedPane(MCPStackPaneTests.newStacked(instance, request, onto: b2Pane, host: "unconfigured.invalid"), instance: instance, permits: grant.permits, workspace: f.workspace, resolve: resolve)
                    }
                    steps += 1
                    // P1: the API never grants, widens or revokes anything.
                    #expect(grant.status == status && grant.allowed == allowed)
                    // P2: 403 exactly when a capability the operation needs is not permitted.
                    let permitted = status == "granted" && op.requiredCapabilities.isSubset(of: allowed)
                    #expect((response.status == 403) == !permitted, "\(state) \(sequence) \(op)")
                    // P3: a refused request changes nothing.
                    if response.status != 200 {
                        if response.status == 403 { forbidden += 1 }
                        #expect(Layout(f.workspace) == layout, "\(state) \(sequence) \(op)")
                        #expect(MCPStackPaneTests.Shape(f.workspace) == shape, "\(state) \(sequence) \(op)")
                    }
                    // P4: existing panes, runtimes, tab sessions and memberships are kept.
                    let after = Identity(f.workspace)
                    #expect(before.panes.allSatisfy { after.panes[$0.key] == $0.value }, "\(op)")
                    #expect(before.runtimes.allSatisfy { after.runtimes[$0.key] == $0.value }, "\(op)")
                    var expectedTabPanes = before.tabPanes, expectedSessions = before.sessions
                    // The tab a successful stack op changed: its members, in any order.
                    var reordered: UUID?
                    if response.status == 200, op == .stackCross {
                        // A1's only pane joined B1's stack; A1 itself is gone.
                        expectedTabPanes[f.b1.id]?.append(aPane)
                        reordered = f.b1.id
                        expectedTabPanes[f.a1.id] = nil
                        expectedSessions[f.a1.id] = nil
                        #expect(MCPStackPaneTests.isStacked(aPane, with: pane, in: f.workspace), "\(op)")
                        #expect(!f.workspace.tabs.contains { $0.id == f.a1.id }, "\(op)")
                    }
                    if response.status == 200, op == .newStackedLocal {
                        let created = try #require(MCPStackPaneTests.result(response).flatMap { UUID(uuidString: $0.paneID) })
                        #expect(before.panes[created] == nil && MCPStackPaneTests.isStacked(created, with: b2Pane, in: f.workspace), "\(op)")
                        expectedTabPanes[f.b2.id]?.append(created)
                        reordered = f.b2.id
                    }
                    #expect(expectedTabPanes.allSatisfy { key, value in
                        key == reordered ? after.tabPanes[key].map(Set.init) == Set(value) && after.tabPanes[key]?.count == value.count
                                         : after.tabPanes[key] == value
                    }, "\(op)")
                    #expect(after.tabPanes.keys.allSatisfy { before.tabPanes[$0] == nil || expectedTabPanes[$0] != nil }, "\(op)")
                    #expect(expectedSessions.allSatisfy { after.sessions[$0.key] == $0.value }, "\(op)")
                    // P5: a successful move leaves the tab beside its target in both projections.
                    if response.status == 200, op == .moveAfter {
                        #expect(f.workspace.workspaceTabIsBeside(f.a1.id, f.b1.id, placement: .after))
                    }
                    if response.status == 200, op == .moveBefore {
                        #expect(f.workspace.workspaceTabIsBeside(f.b2.id, f.b1.id, placement: .before))
                    }
                    // Never an applied move of the same tab or an unknown tab.
                    if op == .moveSame || op == .moveStale || op == .newStaleAnchor || op == .stackStale || op == .newStackedBadHost {
                        #expect(response.status != 200)
                    }
                }
                explored += 1
            }
        }
        #expect(states.count == 35 && sequences.count == 157)
        #expect(explored == 35 * 157)
        print("MCPTabMove bounded check: \(states.count) grant states × \(sequences.count) sequences (len ≤ 2, 12 ops) = \(explored) runs, \(steps) steps, \(forbidden) forbidden")
    }
}
