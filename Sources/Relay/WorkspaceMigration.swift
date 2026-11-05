import Foundation
import CryptoKit

/// One reviewed, reversible step from navigator groups and legacy sessions
/// to workspace ownership. Preview is pure. Apply and undo edit both
/// records of a tab's place together: workspace ownership and its
/// organization placement (the sidebar outline). The store runs them under
/// the workspace lock and writes both or neither.

struct WorkspaceMigrationMove: Codable, Equatable, Sendable {
    let tabID: UUID
    let from: UUID?
    let to: UUID
    let order: Double
    /// On an inverse move: the owner revision the migration left. Undo
    /// reverses the entry only while it still has that revision.
    var appliedRevision: UInt64? = nil
}

/// One tab's organization placement before and after a migration. Undo
/// restores `before` only while the placement is still `after`.
struct WorkspaceMigrationPlacementMove: Codable, Equatable, Sendable {
    let tabID: UUID
    let before: WorkspaceTabPlacement?
    let after: WorkspaceTabPlacement
}

struct WorkspaceSplitRatio: Codable, Equatable, Sendable {
    let id: UUID
    let ratio: Double
}

/// An approved pane reparent, run by the model that owns the live layout.
/// The source layout is recorded when it runs, so Undo can restore it
/// exactly while the source tab is otherwise unchanged.
struct WorkspaceMigrationPaneMove: Codable, Equatable, Sendable {
    /// `pending` and `reverting` are written before the layout and resolved
    /// from where the pane actually is, so a crash between the two files
    /// never leaves Undo skipping a move that happened (`resolve`).
    enum State: String, Codable, Sendable { case planned, pending, done, rolledBack, reverting, reverted }

    let paneID: UUID
    let fromTabID: UUID
    let toTabID: UUID
    var state: State = .planned
    var sourceLayout: PaneLayout? = nil
    var sourceRatios: [WorkspaceSplitRatio]? = nil
    var movedSourceLayout: PaneLayout? = nil

    /// Settles an interrupted step from the pane's actual tab.
    mutating func resolve(paneTab: UUID?) {
        switch state {
        case .pending: state = paneTab == toTabID ? .done : .rolledBack
        case .reverting: state = paneTab == toTabID ? .done : .reverted
        default: break
        }
    }
}

/// QA-F01b: how far a migration reaches. `partial` changes only what the
/// request names; `global` is the full reconcile.
enum WorkspaceMigrationScope: String, Codable, Sendable { case partial, global }

struct WorkspaceMigrationRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let appliedAt: Date
    let sourceChecksums: [String: String]
    let resultChecksum: String
    let forward: [WorkspaceMigrationMove]
    let inverse: [WorkspaceMigrationMove]
    let created: [UUID]
    /// Records as they were before the migration changed or removed them.
    let replaced: [WorkspaceRecord]
    /// Project groups that did not become workspaces. They and their
    /// placements remain for Undo and views.
    var retiredGroups: [WorkspaceGroup] = []
    var paneMoves: [WorkspaceMigrationPaneMove] = []
    /// Placement edits that made the sidebar show each tab in its new
    /// workspace, and groups created for workspaces that had none. Optional
    /// so records saved before two-layer migrations still decode.
    var placementMoves: [WorkspaceMigrationPlacementMove]? = nil
    var createdGroups: [UUID]? = nil
    var undoneAt: Date?
    /// The MCP caller that applied or undid it; nil for the user's buttons.
    var appliedBy: String? = nil
    var undoneBy: String? = nil
}

struct WorkspaceMigrationPreview: Equatable, Sendable {
    enum Source: String, Sendable { case projectGroup, sessionFallback, override, currentOwner }

    struct Row: Equatable, Sendable {
        let tabID: UUID
        let title: String
        let legacySessionID: UUID
        let legacySessionName: String
        let groupPath: [String]
        let currentWorkspaceID: UUID?
        let workspaceID: UUID
        let workspaceName: String
        let source: Source
        /// Before the migration, the tab's ownership and its sidebar
        /// placement name different workspaces (shown as a flagged row).
        var layersDisagree: Bool = false
    }

    struct Workspace: Equatable, Sendable {
        let id: UUID
        let name: String
        let order: Double
        let tabIDs: [UUID]
        let aliases: [String]
        let isNew: Bool
        /// A project group that had no tabs before any override.
        let isEmptyGroup: Bool
    }

    /// Distinct sources whose names normalize alike; merged into `workspaceID`.
    struct Collision: Equatable, Sendable {
        let name: String
        let sources: [String]
        let workspaceID: UUID
    }

    let id: UUID
    let rows: [Row]
    let workspaces: [Workspace]
    let removed: [WorkspaceRecord]
    let collisions: [Collision]
    let retiredGroups: [WorkspaceGroup]
    let paneMoves: [WorkspaceMigrationPaneMove]
    /// Pane → why its requested move cannot run. Apply refuses while any exist.
    let refusals: [UUID: WorkspaceMoveRefusal]
    let sourceChecksums: [String: String]
    /// QA-F01b: `.partial` changes only the tabs and panes the request names.
    var scope: WorkspaceMigrationScope = .global

    /// Tabs whose ownership and sidebar placement disagree today.
    var disagreements: [UUID] { rows.filter(\.layersDisagree).map(\.tabID) }
}

enum WorkspaceMigration {
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Deterministic ID for a workspace that exists only by name, so two
    /// instances applying the same mapping create the same record.
    static func workspaceID(named name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("relay.workspace:" + normalized(name)).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
    }

    static func checksum<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    private struct GroupDigest: Encodable { let id: UUID; let parentID: UUID?; let order: Double; let name: String; let kind: String }

    /// Covers what the mapping reads: tab ↔ legacy session and panes, group
    /// structure and placements (not collapse state), and current ownership.
    static func checksums(tabs: [WorkspaceTabReference], organization: WorkspaceOrganizationSnapshot,
                          ownership: WorkspaceOwnershipSnapshot) -> [String: String] {
        let pairs = tabs.map { [$0.id.uuidString.lowercased(), $0.sessionID.uuidString.lowercased()]
            + $0.paneIDs.map { $0.uuidString.lowercased() }.sorted() }.sorted { $0[0] < $1[0] }
        let groups = organization.groups.sorted { $0.id.uuidString < $1.id.uuidString }
            .map { GroupDigest(id: $0.id, parentID: $0.parentID, order: $0.order, name: $0.name, kind: $0.kind.rawValue) }
        return ["tabs": checksum(pairs),
                "organization": checksum([checksum(groups), checksum(organization.placements.sorted { $0.id.uuidString < $1.id.uuidString })]),
                "ownership": ownership.ownershipChecksum]
    }

    /// Depth-first navigator order; groups with a missing or cyclic parent follow at the root.
    private static func outline(_ groups: [WorkspaceGroup]) -> [WorkspaceGroup] {
        var result: [WorkspaceGroup] = [], seen: Set<UUID> = []
        func sorted(_ items: [WorkspaceGroup]) -> [WorkspaceGroup] {
            items.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        }
        func visit(_ parent: UUID?) {
            for group in sorted(groups.filter { $0.parentID == parent }) where seen.insert(group.id).inserted {
                result.append(group)
                visit(group.id)
            }
        }
        visit(nil)
        for group in sorted(groups) where !seen.contains(group.id) {
            seen.insert(group.id)
            result.append(group)
            visit(group.id)
        }
        return result
    }

    /// Leaf first, stopping at a missing parent or a cycle.
    private static func chain(_ id: UUID?, _ groups: [UUID: WorkspaceGroup]) -> [WorkspaceGroup] {
        var result: [WorkspaceGroup] = [], seen: Set<UUID> = [], next = id
        while let current = next, let group = groups[current], seen.insert(current).inserted {
            result.append(group)
            next = group.parentID
        }
        return result
    }

    /// Default mapping: a tab goes to its nearest enclosing project group
    /// (task groups fold into it); otherwise to its legacy session, named
    /// by that session's group if one exists. `overrides` (tab → workspace
    /// name, "Inbox" for the Inbox) re-file individual tabs. Project groups
    /// emptied by overrides are dropped; already empty ones are kept only
    /// with `keepEmptyGroups`. `paneMoves` (pane → destination tab) are
    /// approved reparents into a new split leaf; a move that would empty its
    /// source tab, or names an unknown pane or tab, is listed in `refusals`.
    static func preview(tabs: [WorkspaceTabReference], organization: WorkspaceOrganizationSnapshot,
                        ownership: WorkspaceOwnershipSnapshot, overrides: [UUID: String] = [:],
                        paneMoves: [UUID: UUID] = [:], keepEmptyGroups: Bool = true,
                        scope requested: WorkspaceMigrationScope? = nil,
                        id: UUID = UUID()) -> WorkspaceMigrationPreview {
        let groups = Dictionary(organization.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placements = Dictionary(organization.placements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var claimOrder: [UUID] = [], byName: [String: UUID] = [:], names: [UUID: String] = [:]
        var sources: [UUID: [String]] = [:], collisions: [String: WorkspaceMigrationPreview.Collision] = [:]
        func claim(_ id: UUID, name: String, source: String, intentional: Bool = false) -> UUID {
            let key = normalized(name)
            if let existing = byName[key] {
                if existing != id, !intentional, !(sources[id]?.contains(source) ?? false) {
                    var collision = collisions[key] ?? .init(name: names[existing]!, sources: sources[existing] ?? [], workspaceID: existing)
                    if !collision.sources.contains(source) { collision = .init(name: collision.name, sources: collision.sources + [source], workspaceID: existing) }
                    collisions[key] = collision
                }
                return existing
            }
            byName[key] = id; names[id] = name; sources[id] = [source]; claimOrder.append(id)
            return id
        }
        func path(_ chain: [WorkspaceGroup]) -> String { chain.reversed().map(\.name).joined(separator: " / ") }

        // QA-F01b: an explicit scope wins. Without one, a request with any
        // override (even a blank name) or any pane move is partial; only an
        // empty request is the global reconcile, so a request is never
        // promoted to global. A partial operation leaves every tab it does
        // not name exactly as it is, in both layers, removes no workspace and
        // keeps every existing workspace's name and order. A blank override
        // names no workspace, so in a partial operation it moves nothing.
        let isNamed: (UUID) -> Bool = { !(overrides[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
        let scope = requested ?? (!overrides.isEmpty || !paneMoves.isEmpty ? .partial : .global)
        let partial = scope == .partial
        let projects = outline(organization.groups).filter { $0.kind == .project }
        for group in projects { _ = claim(group.id, name: group.name, source: path(chain(group.id, groups))) }
        var assigned: [UUID: [UUID]] = [:], baseCounts: [UUID: Int] = [:], aliases: [UUID: [String]] = [:]
        var rows: [WorkspaceMigrationPreview.Row] = []
        for tab in tabs {
            let groupID = placements[tab.id].map { $0.groupID.flatMap { groups[$0] != nil ? $0 : nil } } ?? tab.sessionID
            let links = chain(groupID, groups)
            let groupPath = links.isEmpty && placements[tab.id] == nil ? [tab.sessionName] : links.reversed().map(\.name)
            if partial, !isNamed(tab.id) {
                // Untouched: reported with its current owner, never assigned.
                let owner = ownership.owner(of: tab.id)
                let shown = links.first(where: { $0.kind == .project })?.id
                    ?? links.first(where: { $0.kind == .session && $0.id != tab.sessionID })?.id ?? tab.sessionID
                let ungrouped = placements[tab.id] != nil && links.isEmpty
                let target = owner ?? shown
                rows.append(.init(tabID: tab.id, title: tab.title, legacySessionID: tab.sessionID, legacySessionName: tab.sessionName,
                    groupPath: groupPath, currentWorkspaceID: owner, workspaceID: target,
                    workspaceName: target == WorkspaceOwnershipSnapshot.inboxID ? "Inbox"
                        : ownership.workspace(target)?.name ?? groups[target]?.name ?? tab.sessionName,
                    source: .currentOwner,
                    layersDisagree: owner.map { $0 == WorkspaceOwnershipSnapshot.inboxID ? !ungrouped : $0 != shown } ?? false))
                continue
            }
            var target: UUID, source: WorkspaceMigrationPreview.Source
            if let project = links.first(where: { $0.kind == .project }) {
                target = claim(project.id, name: project.name, source: path(chain(project.id, groups)))
                source = .projectGroup
            } else if let session = links.first(where: { $0.kind == .session }), session.id != tab.sessionID {
                // Shown in another session's group (a cross-session move).
                target = claim(session.id, name: session.name, source: "session group: " + session.name)
                source = .sessionFallback
            } else {
                let name = groups[tab.sessionID]?.name ?? tab.sessionName
                target = claim(tab.sessionID, name: name, source: "session: " + tab.sessionName)
                source = .sessionFallback
            }
            baseCounts[target, default: 0] += 1
            // The workspace the sidebar shows the tab in, against its owner.
            // An Inbox tab agrees when it is placed Ungrouped.
            let owner = ownership.owner(of: tab.id)
            let ungrouped = placements[tab.id] != nil && links.isEmpty
            let disagree = owner.map { $0 == WorkspaceOwnershipSnapshot.inboxID ? !ungrouped : $0 != target } ?? false
            // QA-F01: an unplaced tab the request does not name keeps its
            // canonical owner whenever that owner was decided (admitted,
            // moved, migrated or the Inbox), i.e. it is not the tab's own
            // legacy session workspace. An unplaced tab's legacy path is only
            // its birth session, which is not a user decision. An explicit
            // sidebar placement still proposes its group by default (the
            // reconcile tested by defaultApplyReconcilesKaikuToItsSidebarGroup).
            // `disagree` above still compares the owner with the sidebar.
            let named = !(overrides[tab.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            if !named, placements[tab.id] == nil, let owner, owner != tab.sessionID, let record = ownership.workspace(owner) {
                if owner != WorkspaceOwnershipSnapshot.inboxID, names[owner] == nil {
                    names[owner] = record.name; sources[owner] = ["current owner"]; claimOrder.append(owner)
                    if byName[normalized(record.name)] == nil { byName[normalized(record.name)] = owner }
                }
                // Undo the legacy target's count; this tab does not go there.
                baseCounts[target, default: 1] -= 1
                target = owner
                source = .currentOwner
            }
            if let name = overrides[tab.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                source = .override
                if normalized(name) == normalized(WorkspaceOwnershipSnapshot.inbox.name) {
                    target = WorkspaceOwnershipSnapshot.inboxID
                } else {
                    let existing = byName[normalized(name)]
                        ?? ownership.workspaces.first { !$0.isInbox && normalized($0.name) == normalized(name) }?.id
                    target = claim(existing ?? workspaceID(named: name), name: name, source: "override", intentional: true)
                }
            }
            assigned[target, default: []].append(tab.id)
            let alias = source == .currentOwner ? "" : groupPath.joined(separator: " / ")
            if !alias.isEmpty, normalized(alias) != normalized(names[target] ?? "Inbox"), !(aliases[target] ?? []).contains(alias) {
                aliases[target, default: []].append(alias)
            }
            rows.append(.init(tabID: tab.id, title: tab.title, legacySessionID: tab.sessionID, legacySessionName: tab.sessionName,
                groupPath: groupPath, currentWorkspaceID: ownership.owner(of: tab.id), workspaceID: target,
                workspaceName: target == WorkspaceOwnershipSnapshot.inboxID ? "Inbox" : names[target]!, source: source,
                layersDisagree: disagree))
        }
        let projectIDs = Set(projects.map(\.id))
        var workspaces: [WorkspaceMigrationPreview.Workspace] = []
        // A partial operation appends new workspaces after the existing ones.
        var nextOrder = (ownership.workspaces.filter { !$0.isInbox }.map(\.order).max() ?? -1) + 1
        for id in claimOrder {
            let tabIDs = assigned[id] ?? []
            let emptyGroup = projectIDs.contains(id) && (baseCounts[id] ?? 0) == 0
            let record = ownership.workspace(id)
            if partial {
                // Only workspaces that receive a named tab; no group becomes a workspace by itself.
                guard !tabIDs.isEmpty else { continue }
                let order = record?.order ?? nextOrder
                if record == nil { nextOrder += 1 }
                workspaces.append(.init(id: id, name: record?.name ?? names[id]!, order: order, tabIDs: tabIDs,
                    aliases: aliases[id] ?? [], isNew: record == nil, isEmptyGroup: false))
                continue
            }
            guard !tabIDs.isEmpty || (emptyGroup && keepEmptyGroups) else { continue }
            workspaces.append(.init(id: id, name: names[id]!, order: Double(workspaces.count), tabIDs: tabIDs,
                aliases: aliases[id] ?? [], isNew: record == nil, isEmptyGroup: emptyGroup))
        }
        let inbox = WorkspaceOwnershipSnapshot.inboxID
        workspaces.append(.init(id: inbox, name: "Inbox", order: WorkspaceOwnershipSnapshot.inbox.order,
            tabIDs: assigned[inbox] ?? [], aliases: aliases[inbox] ?? [], isNew: false, isEmptyGroup: false))
        let kept = Set(workspaces.map(\.id))
        var moves: [WorkspaceMigrationPaneMove] = [], refusals: [UUID: WorkspaceMoveRefusal] = [:]
        let tabIDs = Set(tabs.map(\.id))
        for (paneID, toTabID) in paneMoves.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let source = tabs.first(where: { $0.paneIDs.contains(paneID) }) else { refusals[paneID] = .unknownPane; continue }
            guard tabIDs.contains(toTabID) else { refusals[paneID] = .unknownTab; continue }
            guard source.id != toTabID else { refusals[paneID] = .samePlace; continue }
            let leaving = paneMoves.filter { source.paneIDs.contains($0.key) && $0.value != source.id }.count
            guard source.paneIDs.count > leaving else { refusals[paneID] = .lastPaneInTab; continue }
            moves.append(WorkspaceMigrationPaneMove(paneID: paneID, fromTabID: source.id, toTabID: toTabID))
        }
        return WorkspaceMigrationPreview(id: id, rows: rows, workspaces: workspaces,
            removed: partial ? [] : ownership.workspaces.filter { !$0.isInbox && !kept.contains($0.id) },
            collisions: claimOrder.filter { !partial || kept.contains($0) }.compactMap { id in collisions.values.first { $0.workspaceID == id } },
            retiredGroups: partial ? [] : projects.filter { !kept.contains($0.id) }, paneMoves: moves, refusals: refusals,
            sourceChecksums: checksums(tabs: tabs, organization: organization, ownership: ownership), scope: scope)
    }

    /// Ownership and placement deltas, computed together and checked before
    /// anything is written: afterwards every migrated tab is owned by its
    /// target workspace and shown there in the sidebar. `current` must
    /// equal the preview's checksums, recomputed by the caller under the
    /// workspace lock; `tabs` are the tabs those checksums cover.
    static func apply(_ preview: WorkspaceMigrationPreview, to ownership: WorkspaceOwnershipSnapshot,
                      organization: WorkspaceOrganizationSnapshot, tabs: [WorkspaceTabReference],
                      current: [String: String], paneMoves: [WorkspaceMigrationPaneMove]? = nil,
                      at date: Date = Date(), caller: String? = nil) throws
        -> (ownership: WorkspaceOwnershipSnapshot, organization: WorkspaceOrganizationSnapshot) {
        guard preview.sourceChecksums == current, !ownership.migrations.contains(where: { $0.id == preview.id }) else {
            throw WorkspaceOwnershipError.staleMigration
        }
        if let refusal = preview.refusals.sorted(by: { $0.key.uuidString < $1.key.uuidString }).first?.value { throw refusal }
        var next = ownership, replaced: [WorkspaceRecord] = [], created: [UUID] = []
        let removed = Set(preview.removed.map(\.id))
        replaced += next.workspaces.filter { removed.contains($0.id) }
        next.workspaces.removeAll { removed.contains($0.id) }
        for item in preview.workspaces {
            if let index = next.workspaces.firstIndex(where: { $0.id == item.id }) {
                let before = next.workspaces[index]
                if !before.isInbox {
                    next.workspaces[index].name = item.name
                    next.workspaces[index].order = item.order
                }
                next.workspaces[index].aliases = Array((before.aliases + item.aliases.filter { !before.aliases.contains($0) }).prefix(64))
                if next.workspaces[index] != before { replaced.append(before) }
            } else {
                next.workspaces.append(WorkspaceRecord(id: item.id, name: String(item.name.prefix(120)), order: item.order,
                    favourite: false, hostDefaults: [:], isInbox: false, aliases: Array(item.aliases.prefix(64))))
                created.append(item.id)
            }
        }
        var forward: [WorkspaceMigrationMove] = [], inverse: [WorkspaceMigrationMove] = []
        for item in preview.workspaces {
            // QA-F01b: in a partial operation the named tabs follow the tabs
            // already there, whose order is left as it is.
            let base = preview.scope == .partial ? (ownership.owners
                .filter { $0.workspaceID == item.id && !item.tabIDs.contains($0.id) }.map(\.order).max() ?? -1) + 1 : 0
            for (index, tabID) in item.tabIDs.enumerated() {
                let order = base + Double(index)
                let previous = ownership.owners.first { $0.id == tabID }
                forward.append(.init(tabID: tabID, from: previous?.workspaceID, to: item.id, order: order))
                if let index = next.owners.firstIndex(where: { $0.id == tabID }) {
                    next.owners[index].place(in: item.id, order: order, at: date)
                } else {
                    next.owners.append(WorkspaceTabOwner(id: tabID, workspaceID: item.id, order: order, updatedAt: date))
                }
                if let previous {
                    inverse.append(.init(tabID: tabID, from: item.id, to: previous.workspaceID, order: previous.order,
                                         appliedRevision: next.owners.first { $0.id == tabID }?.revision))
                }
            }
        }
        let ids = Set(next.workspaces.map(\.id))
        next.owners.removeAll { !ids.contains($0.workspaceID) }
        let placed = place(preview, tabs: tabs, organization: organization, ownership: next)
        var record = WorkspaceMigrationRecord(id: preview.id, appliedAt: date, sourceChecksums: current,
            resultChecksum: next.ownershipChecksum, forward: forward, inverse: inverse, created: created, replaced: replaced,
            retiredGroups: preview.retiredGroups, paneMoves: paneMoves ?? preview.paneMoves, appliedBy: caller)
        record.placementMoves = placed.moves
        record.createdGroups = placed.createdGroups
        next.migrations.append(record)
        if next.migrations.count > 64 { next.migrations.removeFirst(next.migrations.count - 64) }
        try WorkspaceOwnershipSnapshot.validate(next)
        try RelaySharedWorkspaceStore.validateOrganization(placed.organization)
        // Never report a migration that left either layer short of its target.
        let migrated = Set(preview.workspaces.flatMap(\.tabIDs))
        let targets = Dictionary(preview.workspaces.flatMap { item in item.tabIDs.map { ($0, item.id) } }, uniquingKeysWith: { first, _ in first })
        guard migrated.allSatisfy({ next.owner(of: $0) == targets[$0] }),
              disagreeing(tabs: tabs, organization: placed.organization, ownership: next).isDisjoint(with: migrated) else {
            throw WorkspaceOwnershipError.layersDisagree
        }
        return (next, placed.organization)
    }

    /// Tabs whose ownership and sidebar placement name different workspaces.
    static func disagreeing(tabs: [WorkspaceTabReference], organization: WorkspaceOrganizationSnapshot,
                            ownership: WorkspaceOwnershipSnapshot) -> Set<UUID> {
        Set(preview(tabs: tabs, organization: organization, ownership: ownership).disagreements)
    }

    /// Places every migrated tab whose sidebar placement disagrees with its
    /// new owner into that workspace's group (Ungrouped for the Inbox),
    /// after its current members. A workspace without a group gets one with
    /// its ID: a session group for a legacy session, else a project group.
    /// Tabs that already agree keep their placement, task groups included.
    private static func place(_ preview: WorkspaceMigrationPreview, tabs: [WorkspaceTabReference],
                              organization: WorkspaceOrganizationSnapshot, ownership: WorkspaceOwnershipSnapshot)
        -> (organization: WorkspaceOrganizationSnapshot, moves: [WorkspaceMigrationPlacementMove], createdGroups: [UUID]) {
        var next = organization, moves: [WorkspaceMigrationPlacementMove] = [], createdGroups: [UUID] = []
        let wrong = disagreeing(tabs: tabs, organization: organization, ownership: ownership)
        let sessions = Set(tabs.map(\.sessionID))
        for item in preview.workspaces {
            for tabID in item.tabIDs where wrong.contains(tabID) {
                let groupID: UUID? = item.id == WorkspaceOwnershipSnapshot.inboxID ? nil : item.id
                if let groupID, !next.groups.contains(where: { $0.id == groupID }) {
                    let order = (next.groups.filter { $0.parentID == nil }.map(\.order).max() ?? -1) + 1
                    next.groups.append(WorkspaceGroup(id: groupID, parentID: nil, order: order, name: String(item.name.prefix(120)),
                                                      kind: sessions.contains(groupID) ? .session : .project, collapsed: false))
                    createdGroups.append(groupID)
                }
                let order = (next.placements.filter { $0.groupID == groupID && $0.id != tabID }.map(\.order).max() ?? -1) + 1
                let after = WorkspaceTabPlacement(id: tabID, groupID: groupID, order: order)
                let before = next.placements.first { $0.id == tabID }
                next.placements.removeAll { $0.id == tabID }
                next.placements.append(after)
                moves.append(.init(tabID: tabID, before: before, after: after))
            }
        }
        return (next, moves, createdGroups)
    }

    /// Reverses only the ownership edits still in place: a tab moved or
    /// reordered since (a newer owner revision) stays where it is, and tabs
    /// filed later are kept, with any created workspace that still holds them.
    ///
    /// Placement follows ownership tab by tab: a tab's placement is restored
    /// exactly when its ownership is, and only while it is still the
    /// migration's; a tab changed since in either layer keeps both.
    static func undo(_ id: UUID, in ownership: WorkspaceOwnershipSnapshot, organization: WorkspaceOrganizationSnapshot,
                     at date: Date = Date(), caller: String? = nil) throws
        -> (ownership: WorkspaceOwnershipSnapshot, organization: WorkspaceOrganizationSnapshot) {
        guard let index = ownership.migrations.firstIndex(where: { $0.id == id }) else { throw WorkspaceOwnershipError.unknownMigration }
        let record = ownership.migrations[index]
        guard record.undoneAt == nil else { throw WorkspaceOwnershipError.alreadyUndone }
        var next = ownership
        for previous in record.replaced {
            if let position = next.workspaces.firstIndex(where: { $0.id == previous.id }) {
                next.workspaces[position].name = previous.name
                next.workspaces[position].order = previous.order
                next.workspaces[position].aliases = previous.aliases
            } else {
                next.workspaces.append(previous)
            }
        }
        var placed = organization
        let placementMoves = Dictionary((record.placementMoves ?? []).map { ($0.tabID, $0) }, uniquingKeysWith: { first, _ in first })
        for move in record.inverse where next.workspace(move.to) != nil {
            guard let position = next.owners.firstIndex(where: { $0.id == move.tabID }),
                  next.owners[position].workspaceID == move.from,
                  move.appliedRevision.map({ next.owners[position].revision == $0 }) ?? true else { continue }
            if let placement = placementMoves[move.tabID] {
                guard placed.placements.first(where: { $0.id == move.tabID }) == placement.after else { continue }
                placed.placements.removeAll { $0.id == move.tabID }
                if let before = placement.before { placed.placements.append(before) }
            }
            next.owners[position].place(in: move.to, order: move.order, at: date)
        }
        // Groups the migration created go once nothing is shown in them.
        for group in record.createdGroups ?? []
        where !placed.placements.contains(where: { $0.groupID == group }) && !placed.groups.contains(where: { $0.parentID == group }) {
            placed.groups.removeAll { $0.id == group }
        }
        let created = Set(record.created)
        next.workspaces.removeAll { workspace in
            created.contains(workspace.id) && !next.owners.contains { $0.workspaceID == workspace.id }
        }
        next.migrations[index].undoneAt = date
        next.migrations[index].undoneBy = caller
        try WorkspaceOwnershipSnapshot.validate(next)
        try RelaySharedWorkspaceStore.validateOrganization(placed)
        return (next, placed)
    }
}
