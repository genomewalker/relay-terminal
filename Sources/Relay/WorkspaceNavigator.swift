import Combine
import CryptoKit
import Foundation

/// What the navigator holds while the pointer is over it, and which rows are
/// expanded. Kept apart from the workspace so these redraw only the navigator.
@MainActor final class WorkspaceNavigatorHold: ObservableObject {
    @Published var ranks: [UUID: Int]?
    @Published var inbox: [AttentionInboxEntry]?
    /// Keyed by ID, not by row, so a row moving between the pinned, unpinned
    /// and hidden lists keeps its state.
    @Published var collapsedWorkspaces: Set<UUID> = []
    @Published var expandedTabs: Set<UUID> = []
}

/// A drop in the workspace navigator or tab rail. Each case is one atomic,
/// object-preserving move of the ownership API; `canDrop` is the hover check.
enum WorkspaceNavigatorDrop: Equatable, Sendable {
    /// A new split leaf in that tab, whatever its workspace or legacy session.
    case paneOnTab(paneID: UUID, tabID: UUID)
    /// The pane's own new tab in that workspace.
    case paneOnWorkspace(paneID: UUID, workspaceID: UUID)
    case tabOnWorkspace(tabID: UUID, workspaceID: UUID, index: Int?)
    /// Into the target tab's workspace, just before it.
    case tabBeforeTab(tabID: UUID, targetTabID: UUID)
    case workspaceBefore(workspaceID: UUID, targetID: UUID?)
}

/// A sidebar inbox row: the pane, why it is listed and since when.
struct AttentionInboxEntry: Identifiable, Equatable {
    let paneID: UUID
    let alert: RelayAttentionAlert
    let title: String
    let occurredAt: Date?
    var id: UUID { paneID }
}

/// The inbox shows its first rows; the rest wait behind "Show more".
enum AttentionInboxPage {
    static let limit = 5

    static func visible(_ entries: [AttentionInboxEntry], showingAll: Bool) -> (rows: [AttentionInboxEntry], hiddenCount: Int) {
        guard !showingAll, entries.count > limit else { return (entries, 0) }
        return (Array(entries.prefix(limit)), entries.count - limit)
    }
}

extension WorkspaceModel {
    func canDrop(_ drop: WorkspaceNavigatorDrop) -> WorkspaceMoveRefusal? {
        switch drop {
        case let .paneOnTab(paneID, tabID):
            return canMovePane(paneID, to: .split(tabID: tabID, beside: nil, placement: .trailing))
        case let .paneOnWorkspace(paneID, workspaceID):
            return canMovePane(paneID, to: .newTab(workspaceID: workspaceID, index: nil))
        case let .tabOnWorkspace(tabID, workspaceID, index):
            // The navigator's drop (no index) onto the tab's own workspace.
            if index == nil, let refusal = attentionSortedTabMove(tabID, within: workspaceID) { return refusal }
            return canMoveTab(tabID, toWorkspace: workspaceID)
        case let .tabBeforeTab(tabID, targetTabID):
            guard tabID != targetTabID else { return .samePlace }
            guard let workspaceID = workspaceID(forTab: targetTabID) else { return .unknownTab }
            if let refusal = attentionSortedTabMove(tabID, within: workspaceID) { return refusal }
            return canMoveTab(tabID, toWorkspace: workspaceID)
        case let .workspaceBefore(workspaceID, targetID):
            return canMoveWorkspace(workspaceID, before: targetID)
        }
    }

    /// In attention order an unpinned tab's place is the sort's, so moving it
    /// within its own workspace would change nothing shown.
    private func attentionSortedTabMove(_ tabID: UUID, within workspaceID: UUID) -> WorkspaceMoveRefusal? {
        guard navigatorSort == .attention, !isTabPinned(tabID), self.workspaceID(forTab: tabID) == workspaceID else { return nil }
        return .sortedByAttention
    }

    /// A pane dropped on the visible tab is revealed there. Every other drop
    /// is hidden bookkeeping: nothing is selected, mounted, attached or resized.
    func performDrop(_ drop: WorkspaceNavigatorDrop) throws {
        if let refusal = canDrop(drop) { throw refusal }
        switch drop {
        case let .paneOnTab(paneID, tabID):
            try movePane(paneID, to: .split(tabID: tabID, beside: nil, placement: .trailing), reveal: tabID == selectedTabID)
        case let .paneOnWorkspace(paneID, workspaceID):
            try movePane(paneID, to: .newTab(workspaceID: workspaceID, index: nil))
        case let .tabOnWorkspace(tabID, workspaceID, index):
            let from = self.workspaceID(forTab: tabID)
            try moveTab(tabID, toWorkspace: workspaceID, at: index)
            unrankMovedTab(tabID, from: from, to: workspaceID)
        case let .tabBeforeTab(tabID, targetTabID):
            guard let workspaceID = workspaceID(forTab: targetTabID) else { throw WorkspaceMoveRefusal.unknownTab }
            let from = self.workspaceID(forTab: tabID)
            let others = tabs(inWorkspace: workspaceID).map(\.id).filter { $0 != tabID }
            try moveTab(tabID, toWorkspace: workspaceID, at: others.firstIndex(of: targetTabID))
            unrankMovedTab(tabID, from: from, to: workspaceID)
        case let .workspaceBefore(workspaceID, targetID):
            // A drag in attention order would be re-sorted away once the pointer
            // leaves, so it switches the navigator to Manual. The arranged order
            // is kept; only the dragged workspace moves in it. The hold stays
            // until the pointer leaves, so the inbox above does not go live
            // under it; Manual order ignores the held ranks.
            if navigatorSort == .attention { setNavigatorSortMode(.manual) }
            try moveWorkspace(workspaceID, before: targetID)
        }
    }

    /// A held rank is an offset among the old workspace's tabs; in another
    /// workspace the tab is unranked, so it goes last there until release.
    private func unrankMovedTab(_ tabID: UUID, from: UUID?, to workspaceID: UUID) {
        guard from != workspaceID, navigatorHold?[tabID] != nil else { return }
        navigatorHold?[tabID] = nil
    }

    /// Pinned workspaces first, as arranged, then navigator order; the Inbox
    /// last. Hidden ones are listed apart. A query matches a workspace's name,
    /// aliases or tabs. In attention order only the unpinned rest is sorted
    /// as `attentionOrdered` does; pinned and hidden ones keep their order.
    /// While focusing, only focused workspaces are listed.
    func navigatorWorkspaces(matching query: String = "", sort: WorkspaceNavigationState.NavigatorSort = .manual,
                             inbox: AgentIntelligenceStore = .shared,
                             navigation: WorkspaceNavigationState? = nil) -> (shown: [WorkspaceRecord], hidden: [WorkspaceRecord]) {
        let navigation = navigation ?? navigationState
        let focused = focusedWorkspaceIDs()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = ownership.orderedWorkspaces.filter { record in
            guard focused.isEmpty || focused.contains(record.id) else { return false }
            return needle.isEmpty || ([record.name] + record.aliases).contains { $0.localizedCaseInsensitiveContains(needle) }
                || tabs(inWorkspace: record.id).contains { $0.name.localizedCaseInsensitiveContains(needle) }
        }
        func arrange(_ part: [WorkspaceRecord]) -> [WorkspaceRecord] {
            guard sort == .attention else { return part }
            return heldOrder(attentionOrdered(part, panes: { self.tabs(inWorkspace: $0.id).flatMap { self.paneIDs(inTab: $0.id) } },
                                              lastUse: { self.tabs(inWorkspace: $0.id).compactMap { navigation.lastUse(.tab, id: $0.id) }.max() },
                                              inbox: inbox))
        }
        let shown = matching.filter { $0.hidden != true }
        return (shown.filter { $0.favourite && !$0.isInbox } + arrange(shown.filter { !$0.favourite && !$0.isInbox }) + shown.filter(\.isInbox),
                matching.filter { $0.hidden == true })
    }

    var navigatorSort: WorkspaceNavigationState.NavigatorSort { navigationState.navigatorSortMode }

    /// The focused workspaces that still exist, as one gone in another
    /// Relay's change no longer counts; empty when not focusing.
    func focusedWorkspaceIDs(from ids: [UUID]? = nil) -> Set<UUID> {
        Set((ids ?? focusedWorkspaces).filter { ownership.workspace($0) != nil })
    }

    var isFocusing: Bool { !focusedWorkspaceIDs().isEmpty }

    func focus(on id: UUID) { setFocusedWorkspaces([id]) }
    func addToFocus(_ id: UUID) { setFocusedWorkspaces(focusedWorkspaces + [id]) }
    func removeFromFocus(_ id: UUID) { setFocusedWorkspaces(focusedWorkspaces.filter { $0 != id }) }
    func endFocus() { setFocusedWorkspaces([]) }

    /// Panes outside focus that are waiting on the user or failed: what the
    /// focus bar counts so a forgotten focus does not hide them unnoticed.
    func attentionOutsideFocus(inbox: AgentIntelligenceStore = .shared) -> Int {
        guard let inside = panesInFocus() else { return 0 }
        return attentionInbox(inbox: inbox, outsideFocus: true)
            .filter { !inside.contains($0.paneID) && $0.alert != .done }.count
    }

    /// Panes in tabs of focused workspaces, floating R panels included; nil
    /// while not focusing. A pane in no tab, in a tab no workspace owns, or
    /// unknown here is outside: focus silences what it cannot place.
    func panesInFocus(focused: Set<UUID>? = nil) -> Set<UUID>? {
        let focused = focused ?? focusedWorkspaceIDs()
        guard !focused.isEmpty else { return nil }
        var inside = Set<UUID>()
        for tab in tabs {
            guard let owner = workspaceID(forTab: tab.id), focused.contains(owner) else { continue }
            inside.formUnion(paneIDs(inTab: tab.id))
        }
        return inside
    }

    func isInFocus(paneID: UUID) -> Bool { panesInFocus()?.contains(paneID) ?? true }

    /// What the focus bar offers to add: every workspace not in focus, hidden
    /// ones included, as the navigator lists none of them meanwhile.
    func workspacesOutsideFocus() -> [WorkspaceRecord] {
        let focused = focusedWorkspaceIDs()
        guard !focused.isEmpty else { return [] }
        return ownership.orderedWorkspaces.filter { !focused.contains($0.id) }
    }

    /// Keeps the navigator rows where they are shown, so nothing moves under
    /// the pointer or a drag; rows added meanwhile go last. Releasing re-sorts.
    /// `drawn` and `drawnTabs` are the rows as last drawn: pane phases reach
    /// the navigator on the activity index's tick, so the model can already
    /// be ahead, and holding that order would move rows as the pointer lands.
    func holdNavigatorOrder(sort: WorkspaceNavigationState.NavigatorSort? = nil, inbox: AgentIntelligenceStore = .shared,
                            navigation: WorkspaceNavigationState? = nil,
                            drawn: [WorkspaceRecord]? = nil, drawnTabs: [UUID: [TabModel]]? = nil) {
        guard navigatorHold == nil else { return }
        let sort = sort ?? navigatorSort
        let records = drawn ?? {
            let lists = navigatorWorkspaces(sort: sort, inbox: inbox, navigation: navigation)
            return lists.shown + lists.hidden
        }()
        var rank: [UUID: Int] = [:]
        for (index, record) in records.enumerated() {
            rank[record.id] = index
            let rail = drawnTabs?[record.id] ?? railTabs(inWorkspace: record.id, sort: sort, inbox: inbox, navigation: navigation)
            for (offset, tab) in rail.enumerated() {
                rank[tab.id] = offset
            }
        }
        navigatorHold = rank
        holdAttentionInbox(true, inbox: inbox)
    }

    func releaseNavigatorOrder() {
        navigatorHold = nil
        navigatorPointerLeftAt = nil
        holdAttentionInbox(false)
    }

    /// The inbox rows to show: frozen while the navigator is held, otherwise
    /// live. A pane closed meanwhile keeps its row, shown as closed, until
    /// release, so the rows below do not move up under the pointer.
    func shownAttentionInbox(inbox: AgentIntelligenceStore = .shared) -> [AttentionInboxEntry] {
        inboxHold ?? attentionInbox(inbox: inbox)
    }

    /// Panes needing attention since the inbox was held, not yet listed;
    /// zero when not held.
    func attentionArrivedWhileHeld(inbox: AgentIntelligenceStore = .shared) -> Int {
        guard let held = inboxHold else { return 0 }
        let listed = Set(held.map(\.paneID))
        return attentionInbox(inbox: inbox).filter { !listed.contains($0.paneID) }.count
    }

    /// A brief exit (to the search field, or past the sidebar's edge) keeps
    /// the hold; the rows re-sort only once the pointer stays away this long.
    static let navigatorHoldGrace: TimeInterval = 0.6

    /// Releases the hold once nothing needs it: the pointer has been off the
    /// list for a moment and no drag runs, also after a drag cancelled outside.
    func settleNavigatorHold(pointerInside: Bool, dragging: Bool, now: Date = Date()) {
        guard navigatorHold != nil else { return }
        guard !pointerInside, !dragging else {
            navigatorPointerLeftAt = nil
            return
        }
        let left = navigatorPointerLeftAt ?? now
        navigatorPointerLeftAt = left
        guard now.timeIntervalSince(left) >= Self.navigatorHoldGrace else { return }
        releaseNavigatorOrder()
    }

    /// The workspace's tabs a query shows: all of them when the workspace
    /// itself matches (name or alias), as `navigatorWorkspaces` matches it.
    func navigatorTabs(_ tabs: [TabModel], of record: WorkspaceRecord, matching query: String) -> [TabModel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !([record.name] + record.aliases).contains(where: { $0.localizedCaseInsensitiveContains(needle) })
        else { return tabs }
        return tabs.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    func isNavigatorWorkspaceExpanded(_ id: UUID) -> Bool { !navigatorHoldState.collapsedWorkspaces.contains(id) }

    func setNavigatorWorkspaceExpanded(_ id: UUID, _ expanded: Bool) {
        if expanded { navigatorHoldState.collapsedWorkspaces.remove(id) } else { navigatorHoldState.collapsedWorkspaces.insert(id) }
    }

    func isNavigatorTabExpanded(_ id: UUID) -> Bool { navigatorHoldState.expandedTabs.contains(id) }

    func setNavigatorTabExpanded(_ id: UUID, _ expanded: Bool) {
        if expanded { navigatorHoldState.expandedTabs.insert(id) } else { navigatorHoldState.expandedTabs.remove(id) }
    }

    /// Rows in their held ranks, unranked ones after in the given order.
    func heldOrder<Row: Identifiable>(_ rows: [Row]) -> [Row] where Row.ID == UUID {
        guard let hold = navigatorHold else { return rows }
        return rows.indices.sorted { a, b in
            switch (hold[rows[a].id], hold[rows[b].id]) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a < b
            }
        }.map { rows[$0] }
    }

    /// Waiting on the user now, or with an unread alert.
    func paneNeedsAttention(_ paneID: UUID, inbox: AgentIntelligenceStore = .shared) -> Bool {
        panes[paneID]?.phase == .needsInput || inbox.marker(for: paneID) != nil
    }

    /// Rows with a pane needing attention first, then the most recently used;
    /// ties keep the given order.
    func attentionOrdered<Row>(_ rows: [Row], panes: (Row) -> [UUID], lastUse: (Row) -> Date?,
                               inbox: AgentIntelligenceStore = .shared) -> [Row] {
        let keys = rows.map { row in
            (attention: panes(row).contains { paneNeedsAttention($0, inbox: inbox) }, used: lastUse(row) ?? .distantPast)
        }
        return rows.indices.sorted { a, b in
            if keys[a].attention != keys[b].attention { return keys[a].attention }
            return keys[a].used != keys[b].used ? keys[a].used > keys[b].used : a < b
        }.map { rows[$0] }
    }

    /// A program that exited with a non-zero status: a failure to act on.
    /// A clean exit is not attention.
    static func failedExitStatus(_ pane: PaneModel) -> Int? {
        pane.remoteExitCode.flatMap { $0 != 0 ? $0 : nil }
    }

    static func exitIdentity(_ status: Int) -> String { "exit:\(status)" }

    /// A wait is hidden only when one was dismissed and it is still that wait.
    nonisolated static func isDismissedWait(_ dismissed: String?, current: String?) -> Bool {
        dismissed != nil && dismissed == current
    }

    /// One row per pane that needs the user: waiting on input or approval,
    /// an unread error, or a program that exited with a failure. Finished
    /// turns, "Done" and failed agent tools stay unread markers but are not
    /// listed. Waiting first, then errors; newest first, then pane order.
    /// While focusing, panes outside focus are left out unless `outsideFocus`;
    /// their alerts stay unread, so they are listed again when focus ends.
    func attentionInbox(inbox: AgentIntelligenceStore = .shared, outsideFocus: Bool = false) -> [AttentionInboxEntry] {
        let unread = Dictionary(inbox.attentionPanes.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        var order = tabs.flatMap { paneIDs(inTab: $0.id) }
        let listed = Set(order)
        order += panes.keys.filter { !listed.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        let inside = outsideFocus ? nil : panesInFocus()
        var seen = Set<UUID>()
        var entries: [(entry: AttentionInboxEntry, index: Int)] = []
        for (index, id) in order.enumerated() where seen.insert(id).inserted && inside?.contains(id) != false {
            guard let pane = panes[id] else { continue }
            let item = unread[id]
            let program = RelayWorkOverviewIndex.mostUrgentProgramState(pane.programStatus.records.map(\.state))
            if let status = Self.failedExitStatus(pane) {
                // The exit is the newest fact: a report, approval, wait or
                // activity ("Started") from before it is stale. Dismissed:
                // hidden until the exit changes.
                guard !Self.isDismissedWait(dismissedAttention[id], current: Self.exitIdentity(status)) else { continue }
                entries.append((AttentionInboxEntry(paneID: id, alert: .error, title: "Exited with status \(status)",
                                                    occurredAt: pane.lastActivity), index))
            } else if pane.phase != .needsInput,
               RelayWorkOverviewIndex.needsAttention(phase: pane.phase, approvals: pane.pendingAgentApprovals, programState: program) {
                // An approval or a blocked or failed program report: the same
                // predicate the fleet board and Go to pane use.
                entries.append((AttentionInboxEntry(paneID: id, alert: program == "error" ? .error : .needsInput,
                                                    title: item?.title ?? pane.activitySummary,
                                                    occurredAt: item?.occurredAt ?? pane.lastActivity), index))
            } else if pane.phase == .needsInput {
                // Dismissed in this wait: hidden until a new wait starts.
                guard !Self.isDismissedWait(dismissedAttention[id], current: pane.waitIdentity) else { continue }
                if let item, item.alert == .needsInput {
                    entries.append((AttentionInboxEntry(paneID: id, alert: .needsInput, title: item.title, occurredAt: item.occurredAt), index))
                } else {
                    let waiting = pane.agentActivities.last { $0.phase == .needsInput }
                    entries.append((AttentionInboxEntry(paneID: id, alert: .needsInput, title: waiting?.label ?? pane.activitySummary,
                                                        occurredAt: waiting?.occurredAt ?? pane.lastActivity), index))
                }
            } else if let item, let alert = item.alert, alert.needsUser {
                // Finished turns and failed tools stay unread markers; they
                // are not things the user must act on.
                entries.append((AttentionInboxEntry(paneID: id, alert: alert, title: item.title, occurredAt: item.occurredAt), index))
            }
        }
        return entries.sorted { a, b in
            if a.entry.alert.inboxRank != b.entry.alert.inboxRank { return a.entry.alert.inboxRank < b.entry.alert.inboxRank }
            switch (a.entry.occurredAt, b.entry.occurredAt) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.index < b.index
            }
        }.map(\.entry)
    }

    /// Applies the open preview for an agent, only if it is exactly the one
    /// the agent read (ID and checksum) and has no refusals or collisions.
    /// The store still refuses it if the workspace changed since.
    @discardableResult
    func applyWorkspaceMigration(previewID: UUID, checksum: String, caller: String) throws -> UUID {
        guard let preview = migrationPreview, preview.id == previewID, migrationChecksum == checksum else {
            throw WorkspaceMigrationPlanInboxError.previewMismatch
        }
        guard preview.refusals.isEmpty, preview.collisions.isEmpty else { throw WorkspaceMigrationPlanInboxError.previewNotClean }
        try applyWorkspaceMigration(preview, caller: caller)
        return preview.id
    }

    /// The open preview's checksum: the exact plan bytes, the preview's ID,
    /// what it read (tabs, organization, ownership) and what it would do.
    var migrationChecksum: String? { migrationPreview.map { $0.checksum(plan: migrationPlan?.digest ?? "") } }

    func migrationPreviewSummary(_ preview: WorkspaceMigrationPreview, plan: String?) -> [String: Any] {
        ["status": "staged", "plan": plan as Any, "preview_id": preview.id.uuidString.lowercased(), "checksum": migrationChecksum as Any,
         "tabs": preview.rows.count, "workspaces": preview.workspaces.count, "pane_moves": preview.paneMoves.count,
         "refusals": preview.refusals.count, "collisions": preview.collisions.count,
         "layer_disagreements": preview.disagreements.count]
    }

    /// State for MCP: the open preview (with the checksum apply requires),
    /// the plan folder and the migration log.
    func workspaceMigrationControlState(inbox: WorkspaceMigrationPlanInbox = .shared) -> [String: Any] {
        func id(_ value: UUID) -> String { value.uuidString.lowercased() }
        var result: [String: Any] = ["schema_version": 1, "apply": "preview_checksum"]
        if let preview = migrationPreview {
            result["preview"] = [
                "id": id(preview.id),
                "checksum": migrationChecksum as Any,
                "plan": migrationPlan?.name as Any,
                "staged": migrationPlan?.staged ?? false,
                "rows": preview.rows.map { row in
                    ["tab_id": id(row.tabID), "title": row.title, "legacy_session": row.legacySessionName,
                     "group_path": row.groupPath, "current_workspace_id": row.currentWorkspaceID.map(id) as Any,
                     "workspace_id": id(row.workspaceID), "workspace": row.workspaceName, "source": row.source.rawValue,
                     "layers_disagree": row.layersDisagree] as [String: Any]
                },
                // Tabs whose ownership and sidebar placement disagree today;
                // apply moves both layers of each to its target.
                "layer_disagreements": preview.disagreements.map(id),
                "workspaces": preview.workspaces.map { ["id": id($0.id), "name": $0.name, "tab_ids": $0.tabIDs.map(id), "new": $0.isNew] as [String: Any] },
                "pane_moves": preview.paneMoves.map { ["pane_id": id($0.paneID), "from_tab_id": id($0.fromTabID), "to_tab_id": id($0.toTabID)] },
                "refusals": Dictionary(uniqueKeysWithValues: preview.refusals.map { (id($0.key), $0.value.localizedDescription) }),
                "retired_groups": preview.retiredGroups.map(\.name),
                "scope": preview.scope.rawValue,
                "collisions": preview.collisions.map { ["name": $0.name, "sources": $0.sources] as [String: Any] }
            ] as [String: Any]
        }
        result["plans_directory"] = inbox.directory.path
        result["plans"] = inbox.list().map { ["name": $0.name, "size": $0.size, "modified": $0.modified.timeIntervalSince1970] as [String: Any] }
        result["migrations"] = ownership.migrations.map { record in
            ["id": id(record.id), "applied_at": record.appliedAt.timeIntervalSince1970,
             "undone": record.undoneAt != nil, "applied_by": record.appliedBy ?? "user",
             "undone_by": record.undoneAt == nil ? NSNull() : (record.undoneBy ?? "user") as Any,
             "pane_moves": record.paneMoves.map { ["pane_id": id($0.paneID), "state": $0.state.rawValue] }] as [String: Any]
        }
        return result
    }
}

extension WorkspaceMigrationPreview {
    private struct Digest: Encodable {
        let plan: String
        let id: UUID
        let sources: [String: String]
        let rows: [[String]]
        let moves: [[String]]
        let refusals: [String]
    }

    /// `plan` is the digest of the plan bytes the preview was built from.
    func checksum(plan: String) -> String {
        func text(_ value: UUID) -> String { value.uuidString.lowercased() }
        return WorkspaceMigration.checksum(Digest(plan: plan, id: id, sources: sourceChecksums,
            rows: rows.map { [text($0.tabID), text($0.workspaceID), $0.workspaceName] },
            moves: paneMoves.map { [text($0.paneID), text($0.fromTabID), text($0.toTabID)] },
            refusals: refusals.keys.map(text).sorted()))
    }
}

enum WorkspaceMigrationPlanError: Error, LocalizedError, Equatable {
    case invalidIdentifier(String)
    case invalidScope(String)

    var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(value): "The migration plan names an invalid tab or pane ID: \(value)."
        case let .invalidScope(value): "The migration plan's scope must be \"partial\" or \"global\", not \"\(value)\"."
        }
    }
}

/// The reviewed mapping, as data (`work/workspace-migration-plan-*.json`):
/// tab → workspace name overrides, pane → destination tab moves, and
/// whether empty groups are kept. Other keys are ignored.
struct WorkspaceMigrationPlan: Codable, Equatable, Sendable {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    var overrides: [String: String] = [:]
    var paneMoves: [String: String] = [:]
    var keepEmptyGroups: Bool = true
    /// "partial" or "global"; absent means partial when the plan has any
    /// override (even a blank name) or pane move, else global (QA-F01b).
    /// Any other value is rejected.
    var scope: String? = nil

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overrides = try container.decodeIfPresent([String: String].self, forKey: .overrides) ?? [:]
        paneMoves = try container.decodeIfPresent([String: String].self, forKey: .paneMoves) ?? [:]
        keepEmptyGroups = try container.decodeIfPresent(Bool.self, forKey: .keepEmptyGroups) ?? true
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
    }

    static func parse(_ data: Data) throws -> (overrides: [UUID: String], paneMoves: [UUID: UUID], keepEmptyGroups: Bool,
                                               scope: WorkspaceMigrationScope?) {
        let plan = try JSONDecoder().decode(Self.self, from: data)
        func uuid(_ value: String) throws -> UUID {
            guard let id = UUID(uuidString: value) else { throw WorkspaceMigrationPlanError.invalidIdentifier(value) }
            return id
        }
        var overrides: [UUID: String] = [:], moves: [UUID: UUID] = [:]
        for (tab, name) in plan.overrides { overrides[try uuid(tab)] = name }
        for (pane, tab) in plan.paneMoves { moves[try uuid(pane)] = try uuid(tab) }
        var scope: WorkspaceMigrationScope?
        if let raw = plan.scope {
            guard let value = WorkspaceMigrationScope(rawValue: raw) else { throw WorkspaceMigrationPlanError.invalidScope(raw) }
            scope = value
        }
        return (overrides, moves, plan.keepEmptyGroups, scope)
    }
}
