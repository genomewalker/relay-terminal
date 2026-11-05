import Foundation
import CryptoKit

/// Workspace → Tab → Pane ownership (schema 3). A tab belongs to exactly one
/// workspace record; its legacy `sessionID` remains birth identity and the
/// compatibility projection only. Editing these records never constructs,
/// restarts, recovers, terminates or re-homes a pane or its runtime.

struct WorkspaceRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var order: Double
    var favourite: Bool
    /// `ConnectionProfile.connectionKey` → starting directory on that host.
    /// A directory is never inferred for one host from another.
    var hostDefaults: [String: String]
    var isInbox: Bool
    /// Navigator paths this workspace absorbed, kept as search aliases.
    var aliases: [String]
    /// Hidden from the navigator only; its tabs and runtimes are untouched.
    /// Optional, so schema 3 files written before it still decode.
    var hidden: Bool? = nil
}

/// `id` is the tab ID, so one tab can have only one owner record. Every
/// edit raises `revision` and stamps `updatedAt`; concurrent edits of one
/// tab resolve to the newest entry, never to a lost tab.
struct WorkspaceTabOwner: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var order: Double
    var revision: UInt64 = 1
    var updatedAt: Date = Date()

    func isNewer(than other: WorkspaceTabOwner) -> Bool {
        if revision != other.revision { return revision > other.revision }
        if updatedAt != other.updatedAt { return updatedAt > other.updatedAt }
        return workspaceID.uuidString > other.workspaceID.uuidString
    }

    mutating func place(in workspaceID: UUID, order: Double, at date: Date = Date()) {
        guard workspaceID != self.workspaceID || order != self.order else { return }
        self.workspaceID = workspaceID
        self.order = order
        revision += 1
        updatedAt = date
    }
}

/// Who creates a tab. Only `.human` (⌘T, menus) may use the visible
/// workspace; agent, MCP and assistant requests name their source pane.
enum WorkspaceTabOrigin: Equatable, Sendable {
    case human
    case agent(sourcePane: UUID?)
}

/// Where a new tab is filed, captured when its request was admitted.
enum WorkspaceTabAdmission: Equatable, Sendable {
    /// A human UI action (⌘T, menu): the visible workspace.
    case human
    /// An agent, MCP or assistant request from a source pane, or a session
    /// switcher action from a source tab: that workspace, captured then.
    case workspace(UUID)
    /// No context: the Inbox.
    case inbox
}

struct WorkspaceTabReference: Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    var title: String
    var sessionName: String
    var paneIDs: [UUID] = []
}

/// Where a pane move lands: a new split leaf beside `beside` (or the tab's
/// last pane) in any tab of any workspace, or a new tab in a workspace.
enum WorkspacePaneDestination: Equatable, Sendable {
    case split(tabID: UUID, beside: UUID?, placement: PaneDropPlacement)
    case newTab(workspaceID: UUID, index: Int?)
}

/// Why a move cannot happen; returned on hover, thrown by the move itself.
enum WorkspaceMoveRefusal: Error, LocalizedError, Equatable, Sendable {
    case unknownPane, unknownTab, unknownWorkspace, unknownTarget, samePlace, lastPaneInTab, floatingPane, rPresentationBound,
         sortedByAttention, tabClosing

    var errorDescription: String? {
        switch self {
        case .unknownPane: "That pane is no longer in this workspace."
        case .unknownTab: "That tab no longer exists."
        case .unknownWorkspace: "That workspace no longer exists."
        case .unknownTarget: "Drop beside a pane shown in the destination tab."
        case .samePlace: "The pane is already there."
        case .lastPaneInTab: "This is the only pane in its tab. Move the tab instead."
        case .floatingPane: "Dock the floating pane before moving it."
        case .rPresentationBound: "This pane is part of an R workspace. Move its tab instead."
        case .sortedByAttention: "Tabs are sorted by attention. Choose Manual sort to reorder them."
        case .tabClosing: "That tab is closing."
        }
    }
}

enum WorkspaceOwnershipError: Error, LocalizedError, Equatable {
    case unknownWorkspace, unknownTab, staleMigration, unknownMigration, alreadyUndone, layersDisagree

    var errorDescription: String? {
        switch self {
        case .unknownWorkspace: "That workspace no longer exists."
        case .unknownTab: "That tab is no longer in this workspace."
        case .staleMigration: "Tabs or groups changed after the migration preview. Preview it again."
        case .unknownMigration: "That migration is not recorded."
        case .alreadyUndone: "That migration was already undone."
        case .layersDisagree: "The migration would leave a tab's workspace and its sidebar group disagreeing. Nothing was changed."
        }
    }
}

struct WorkspaceOwnershipSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    /// Fixed, so concurrent first writers create the same Inbox and merge.
    static let inboxID = UUID(uuidString: "1B0C0000-0000-4000-8000-000000000001")!
    static let inbox = WorkspaceRecord(id: inboxID, name: "Inbox", order: 1_000_000, favourite: false,
                                       hostDefaults: [:], isInbox: true, aliases: [])
    static let empty = WorkspaceOwnershipSnapshot(schemaVersion: currentSchemaVersion,
                                                  workspaces: [inbox], owners: [], migrations: [])

    var schemaVersion: Int
    var workspaces: [WorkspaceRecord]
    var owners: [WorkspaceTabOwner]
    var migrations: [WorkspaceMigrationRecord]

    func owner(of tabID: UUID) -> UUID? { owners.first { $0.id == tabID }?.workspaceID }

    func workspace(_ id: UUID) -> WorkspaceRecord? { workspaces.first { $0.id == id } }

    var orderedWorkspaces: [WorkspaceRecord] {
        workspaces.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
    }

    func tabIDs(in workspaceID: UUID) -> [UUID] {
        owners.filter { $0.workspaceID == workspaceID }
            .sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }.map(\.id)
    }

    /// One workspace per legacy session, `id == sessionID`, in navigator
    /// order: "keep existing containers". Deterministic, so instances merge.
    static func bootstrap(tabs: [WorkspaceTabReference]) -> WorkspaceOwnershipSnapshot {
        var result = empty
        for (index, tab) in tabs.enumerated() {
            if result.workspace(tab.sessionID) == nil {
                result.workspaces.append(WorkspaceRecord(id: tab.sessionID, name: String(tab.sessionName.prefix(120)),
                    order: Double(result.workspaces.count - 1), favourite: false, hostDefaults: [:], isInbox: false, aliases: []))
            }
            result.owners.append(WorkspaceTabOwner(id: tab.id, workspaceID: tab.sessionID, order: Double(index),
                                                   revision: 0, updatedAt: .distantPast))
        }
        return result
    }

    /// Restores the invariants after an older writer or another instance
    /// changed the tabs: owners of missing tabs are dropped. An unowned tab
    /// goes to `admittedTo` (the scope captured with its request), else to
    /// its legacy session's workspace while one exists, else to the Inbox,
    /// never to whatever happens to be visible. Migration pane moves left
    /// `pending` or `reverting` by a crash settle from the pane's actual tab.
    /// Resolved, not rejected.
    mutating func reconcile(tabs: [WorkspaceTabReference], admittedTo: UUID? = nil) {
        if !workspaces.contains(where: { $0.id == Self.inboxID }) { workspaces.append(Self.inbox) }
        let live = Set(tabs.map(\.id)), known = Set(workspaces.map(\.id))
        owners.removeAll { !live.contains($0.id) || !known.contains($0.workspaceID) }
        for tab in tabs where owner(of: tab.id) == nil {
            let target = admittedTo.flatMap { known.contains($0) ? $0 : nil }
                ?? (known.contains(tab.sessionID) ? tab.sessionID : Self.inboxID)
            owners.append(WorkspaceTabOwner(id: tab.id, workspaceID: target, order: nextOrder(in: target)))
        }
        let home = Dictionary(tabs.flatMap { tab in tab.paneIDs.map { ($0, tab.id) } }, uniquingKeysWith: { first, _ in first })
        for record in migrations.indices {
            for move in migrations[record].paneMoves.indices {
                migrations[record].paneMoves[move].resolve(paneTab: home[migrations[record].paneMoves[move].paneID])
            }
        }
    }

    private func nextOrder(in workspaceID: UUID) -> Double {
        (owners.filter { $0.workspaceID == workspaceID }.map(\.order).max() ?? -1) + 1
    }

    @discardableResult
    mutating func createWorkspace(name: String, id: UUID = UUID()) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = (workspaces.filter { !$0.isInbox }.map(\.order).max() ?? -1) + 1
        workspaces.append(WorkspaceRecord(id: id, name: trimmed.isEmpty ? "New workspace" : String(trimmed.prefix(120)),
            order: order, favourite: false, hostDefaults: [:], isInbox: false, aliases: []))
        return id
    }

    /// Re-homes one tab. Validates first and edits nothing on failure.
    mutating func moveTab(_ tabID: UUID, to workspaceID: UUID, at index: Int? = nil) throws {
        guard workspace(workspaceID) != nil else { throw WorkspaceOwnershipError.unknownWorkspace }
        guard owners.contains(where: { $0.id == tabID }) else { throw WorkspaceOwnershipError.unknownTab }
        var ordered = tabIDs(in: workspaceID).filter { $0 != tabID }
        ordered.insert(tabID, at: max(0, min(index ?? ordered.count, ordered.count)))
        // Only the moved tab's entry is a new edit (revision); siblings are
        // renumbered in place, so a reorder never claims their placement.
        var next = owners
        for (order, id) in ordered.enumerated() {
            guard let position = next.firstIndex(where: { $0.id == id }) else { continue }
            if id == tabID { next[position].place(in: workspaceID, order: Double(order)) } else { next[position].order = Double(order) }
        }
        owners = next
    }

    static func validate(_ snapshot: WorkspaceOwnershipSnapshot) throws {
        let ids = Set(snapshot.workspaces.map(\.id))
        guard snapshot.schemaVersion == currentSchemaVersion,
              snapshot.workspaces.count <= 1024, snapshot.owners.count <= 4096, snapshot.migrations.count <= 64,
              ids.count == snapshot.workspaces.count,
              Set(snapshot.owners.map(\.id)).count == snapshot.owners.count,
              Set(snapshot.migrations.map(\.id)).count == snapshot.migrations.count,
              snapshot.workspaces.filter(\.isInbox).map(\.id) == [inboxID],
              snapshot.workspaces.allSatisfy({ $0.name.count <= 120 && $0.order.isFinite
                  && $0.hostDefaults.count <= 64 && $0.aliases.count <= 64 }),
              snapshot.owners.allSatisfy({ $0.order.isFinite && ids.contains($0.workspaceID) }) else {
            throw RelaySharedWorkspaceError.invalidSnapshot
        }
    }

    /// Ownership only: records and owners, not the migration log.
    var ownershipChecksum: String {
        WorkspaceMigration.checksum(OwnershipDigest(workspaces: workspaces.sorted { $0.id.uuidString < $1.id.uuidString },
            owners: owners.sorted { $0.id.uuidString < $1.id.uuidString }))
    }

    private struct OwnershipDigest: Encodable { let workspaces: [WorkspaceRecord]; let owners: [WorkspaceTabOwner] }
}

extension WorkspaceTabReference {
    static func references(_ snapshot: WorkspaceSnapshot) -> [WorkspaceTabReference] {
        snapshot.tabs.map { tab in
            let sessionID = tab.sessionID ?? tab.id
            return WorkspaceTabReference(id: tab.id, sessionID: sessionID, title: tab.name,
                sessionName: snapshot.sessionNames?[sessionID] ?? tab.name,
                paneIDs: tab.layout.paneIDs + (tab.floatingPanes ?? []).map(\.paneID))
        }
    }
}
