import Foundation
import Darwin

enum RelaySharedWorkspaceError: Error {
    case busy, conflictingEdit, invalidSnapshot, unavailable
}

/// One durable snapshot per profile. Each renderer submits changes relative to
/// its own last local snapshot; another renderer's independent changes survive.
/// Runtime ownership stays with the worker's existing input lease protocol.
final class RelaySharedWorkspaceStore {
    private let directory: URL
    private var uncertain = false
    private let limit = 8_388_608
    private let instanceID = UUID().uuidString.lowercased()

    init(directory: URL) { self.directory = directory }

    func preservePending(_ snapshot: WorkspaceSnapshot) throws {
        try Self.validate(snapshot)
        try locked { parent in try write(snapshot, parent: parent, name: "pending-\(instanceID).json") }
    }

    /// The pane-link janitor's fence. Runs `body` while holding the workspace
    /// lock, with the committed snapshot and the count of pending (preserved,
    /// unsaved) instance changes both read under that same lock. Every commit,
    /// pending preserve and restore takes this lock (non-blocking), so the
    /// committed panes cannot change while `body` runs; another instance gets
    /// `.busy` and its own save retries. Lock order: this lock first, then the
    /// blocking locks `body` takes (the in-flight marker lock, then the
    /// pane-link store's). Nothing holding those waits for this lock. `body`
    /// must not re-enter this store.
    func withCommittedWorkspace<T>(_ body: (_ committed: WorkspaceSnapshot?, _ pending: Int) throws -> T) throws -> T {
        try locked { parent in
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard names.count <= 8192 else { throw RelaySharedWorkspaceError.unavailable }
            let pending = names.filter { $0.hasPrefix("pending-") && $0.hasSuffix(".json") }.count
            return try body(try read(parent), pending)
        }
    }

    func pendingCount() throws -> Int {
        try locked { _ in
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard names.count <= 8192 else { throw RelaySharedWorkspaceError.unavailable }
            return names.filter { $0.hasPrefix("pending-") && $0.hasSuffix(".json") }.count
        }
    }

    func restore(legacy: Data?) throws -> WorkspaceSnapshot? {
        try locked { parent in
            if let current = try read(parent) { return current }
            guard let legacy else { return nil }
            guard legacy.count <= limit else { throw RelaySharedWorkspaceError.invalidSnapshot }
            let initial = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacy)
            try Self.validate(initial)
            try write(initial, parent: parent)
            return initial
        }
    }

    func commit(_ local: WorkspaceSnapshot, baseline: WorkspaceSnapshot?) throws -> WorkspaceSnapshot {
        try commit(local, baseline: baseline, ownership: nil, ownershipBaseline: nil).workspace
    }

    /// Tabs, panes and their workspace ownership in one locked transaction.
    /// Both merges finish before either file is written. Ownership merges per
    /// entry and never fails on a concurrent edit, so it can never block
    /// saving tabs and panes; `ownershipConflict` reports a resolved one.
    func commit(_ local: WorkspaceSnapshot, baseline: WorkspaceSnapshot?, ownership: WorkspaceOwnershipSnapshot?,
                ownershipBaseline: WorkspaceOwnershipSnapshot?) throws
        -> (workspace: WorkspaceSnapshot, ownership: WorkspaceOwnershipSnapshot?, ownershipConflict: Bool) {
        try Self.validate(local)
        if let ownership { try WorkspaceOwnershipSnapshot.validate(ownership) }
        return try locked { parent in
            let current = try read(parent)
            let merged: WorkspaceSnapshot
            if let current {
                guard let baseline else { throw RelaySharedWorkspaceError.conflictingEdit }
                merged = try Self.merge(local: local, baseline: baseline, current: current)
            } else {
                guard baseline == nil else { throw RelaySharedWorkspaceError.unavailable }
                merged = local
            }
            try Self.validate(merged)
            var owned: WorkspaceOwnershipSnapshot?, existing: WorkspaceOwnershipSnapshot?, conflict = false
            if let ownership {
                existing = try readOwnership(parent)
                var result = ownership
                if let existing {
                    let merge = try Self.mergeOwnership(local: ownership, baseline: ownershipBaseline ?? .empty, current: existing)
                    result = merge.snapshot
                    conflict = merge.conflicts > 0
                }
                result.reconcile(tabs: WorkspaceTabReference.references(merged))
                try WorkspaceOwnershipSnapshot.validate(result)
                if existing == nil { try backupBeforeVersion3(parent) }
                owned = result
            }
            try write(merged, parent: parent)
            if let owned, owned != existing { try writeOwnership(owned, parent: parent) }
            let pending = "pending-\(instanceID).json"
            if unlinkat(parent, pending, 0) == 0 {
                uncertain = true
                guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
                uncertain = false
            } else if errno != ENOENT { throw POSIXError(.EIO) }
            return (merged, owned, conflict)
        }
    }

    static func merge(local: WorkspaceSnapshot, baseline: WorkspaceSnapshot, current: WorkspaceSnapshot) throws -> WorkspaceSnapshot {
        let tabs = try entities(local.tabs, baseline.tabs, current.tabs, id: { $0.id })
        let panes = try entities(local.panes, baseline.panes, current.panes, id: { $0.id })
        let names = try entities(
            (local.sessionNames ?? [:]).map { Name(id: $0.key, name: $0.value) },
            (baseline.sessionNames ?? [:]).map { Name(id: $0.key, name: $0.value) },
            (current.sessionNames ?? [:]).map { Name(id: $0.key, name: $0.value) }, id: { $0.id })
        let presentations = try value(local.rPresentations, baseline.rPresentations, current.rPresentations)
        let tabIDs = Set(tabs.map(\.id)), paneIDs = Set(panes.map(\.id))
        let merged = WorkspaceSnapshot(tabs: tabs, panes: panes,
            sessionNames: Dictionary(uniqueKeysWithValues: names.map { ($0.id, $0.name) }),
            selectedTabID: local.selectedTabID.flatMap { tabIDs.contains($0) ? $0 : nil },
            activePaneID: local.activePaneID.flatMap { paneIDs.contains($0) ? $0 : nil },
            recoveryWindow: current.recoveryWindow, rPresentations: presentations,
            sidebarVisible: local.sidebarVisible,
            paneVisits: local.paneVisits == nil && current.paneVisits == nil ? nil
                : PaneVisitHistory.merged(local.paneVisits ?? [], current.paneVisits ?? [], keeping: paneIDs))
        try validate(merged)
        return merged
    }

    private struct Name: Codable { let id: UUID; let name: String }

    private static func entities<T: Codable>(_ local: [T], _ baseline: [T], _ current: [T], id: (T) -> UUID) throws -> [T] {
        try entities(local, baseline, current, id: id, resolve: { try value($0, $1, $2) })
    }

    private static func entities<T: Codable>(_ local: [T], _ baseline: [T], _ current: [T], id: (T) -> UUID,
                                             resolve: (T?, T?, T?) throws -> T?) throws -> [T] {
        func map(_ items: [T]) throws -> [UUID: T] {
            var result: [UUID: T] = [:]
            for item in items {
                guard result.updateValue(item, forKey: id(item)) == nil else { throw RelaySharedWorkspaceError.invalidSnapshot }
            }
            return result
        }
        let l = try map(local), b = try map(baseline), c = try map(current)
        // Preserve current order, then append independently created local entities.
        var order = current.map(id)
        order.append(contentsOf: local.map(id).filter { c[$0] == nil })
        var result: [T] = []
        for key in order {
            if let merged = try resolve(l[key], b[key], c[key]) { result.append(merged) }
        }
        return result
    }

    private static func value<T: Codable>(_ local: T?, _ baseline: T?, _ current: T?) throws -> T? {
        func object(_ item: T?) throws -> Any? {
            guard let item else { return nil }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let raw = try JSONSerialization.jsonObject(with: encoder.encode(item), options: [.fragmentsAllowed])
            // UUID-keyed Swift dictionaries encode as alternating key/value
            // arrays. Their iteration order is not a semantic workspace edit.
            if var object = raw as? [String: Any], let ratios = object["splitRatios"] as? [Any], ratios.count % 2 == 0 {
                var pairs: [(String, Any)] = []
                for index in stride(from: 0, to: ratios.count, by: 2) {
                    guard let key = ratios[index] as? String, UUID(uuidString: key) != nil else { throw RelaySharedWorkspaceError.invalidSnapshot }
                    pairs.append((key, ratios[index + 1]))
                }
                object["splitRatios"] = pairs.sorted { $0.0 < $1.0 }.flatMap { [$0.0 as Any, $0.1] }
                return object
            }
            return raw
        }
        let merged = try mergeJSON(local: object(local), baseline: object(baseline), current: object(current))
        guard let merged else { return nil }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: merged, options: [.fragmentsAllowed, .sortedKeys]))
    }

    private static func mergeJSON(local: Any?, baseline: Any?, current: Any?) throws -> Any? {
        func equal(_ a: Any?, _ b: Any?) -> Bool {
            if a == nil || b == nil { return a == nil && b == nil }
            return (a as? NSObject)?.isEqual(b) == true
        }
        if equal(local, baseline) { return current }
        if equal(current, baseline) || equal(local, current) { return local }
        guard let l = local as? [String: Any], let b = baseline as? [String: Any],
              let c = current as? [String: Any] else { throw RelaySharedWorkspaceError.conflictingEdit }
        var result: [String: Any] = [:]
        for key in Set(l.keys).union(b.keys).union(c.keys) {
            // A tab's layout, visible layout and stacks describe one arrangement.
            if ["profile", "layout", "visibleLayout", "stacks", "editorRequest", "remoteParentSessionID",
                "remoteWorkspaceSessionID", "remoteTabID"].contains(key),
               !equal(l[key], b[key]), !equal(c[key], b[key]), !equal(l[key], c[key]) {
                throw RelaySharedWorkspaceError.conflictingEdit
            }
            result[key] = try mergeJSON(local: l[key], baseline: b[key], current: c[key])
        }
        return result
    }

    static func validate(_ snapshot: WorkspaceSnapshot) throws {
        guard snapshot.tabs.count <= 4096, snapshot.panes.count <= 16384,
              snapshot.panes.allSatisfy(\.hasValidBirthHierarchy),
              Set(snapshot.tabs.map(\.id)).count == snapshot.tabs.count,
              Set(snapshot.panes.map(\.id)).count == snapshot.panes.count else { throw RelaySharedWorkspaceError.invalidSnapshot }
        let paneIDs = Set(snapshot.panes.map(\.id))
        var used = Set<UUID>()
        for tab in snapshot.tabs {
            let ids = tab.layout.paneIDs + (tab.floatingPanes ?? []).map(\.paneID)
            guard !ids.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: paneIDs),
                  used.isDisjoint(with: ids) else { throw RelaySharedWorkspaceError.invalidSnapshot }
            used.formUnion(ids)
            // Stacks only describe panes the legacy layout already places; a
            // mismatch with it is resolved on restore, not rejected here.
            if let stacks = tab.stacks {
                guard stacks.count <= 1024, stacks.allSatisfy(\.isValid),
                      Set(stacks.flatMap(\.members)).isSubset(of: Set(tab.layout.paneIDs)) else {
                    throw RelaySharedWorkspaceError.invalidSnapshot
                }
            }
        }
    }

    // MARK: Organization (schema 2): groups, tab placements, saved views.

    private static let organizationName = "organization-v2.json"
    private static let backupName = "workspace-v1.pre-v2-backup.json"

    func restoreOrganization() throws -> WorkspaceOrganizationSnapshot? {
        try locked { parent in
            try settleLayers(parent)
            return try readOrganization(parent)
        }
    }

    /// Per-entity three-way merge under the workspace lock, as for tabs and panes.
    func commitOrganization(_ local: WorkspaceOrganizationSnapshot,
                            baseline: WorkspaceOrganizationSnapshot?) throws -> WorkspaceOrganizationSnapshot {
        try Self.validateOrganization(local)
        return try locked { parent in
            let merged: WorkspaceOrganizationSnapshot
            try settleLayers(parent)
            if let current = try readOrganization(parent) {
                merged = try Self.mergeOrganization(local: local, baseline: baseline ?? .empty, current: current)
            } else {
                try backupBeforeVersion2(parent)
                merged = local
            }
            try Self.validateOrganization(merged)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try writeData(encoder.encode(merged), parent: parent, name: Self.organizationName)
            return merged
        }
    }

    static func mergeOrganization(local: WorkspaceOrganizationSnapshot, baseline: WorkspaceOrganizationSnapshot,
                                  current: WorkspaceOrganizationSnapshot) throws -> WorkspaceOrganizationSnapshot {
        WorkspaceOrganizationSnapshot(schemaVersion: WorkspaceOrganizationSnapshot.currentSchemaVersion,
            groups: try entities(local.groups, baseline.groups, current.groups, id: { $0.id }),
            placements: try entities(local.placements, baseline.placements, current.placements, id: { $0.id }),
            savedViews: try entities(local.savedViews, baseline.savedViews, current.savedViews, id: { $0.id }))
    }

    static func validateOrganization(_ snapshot: WorkspaceOrganizationSnapshot) throws {
        guard snapshot.schemaVersion == WorkspaceOrganizationSnapshot.currentSchemaVersion,
              snapshot.groups.count <= 1024, snapshot.placements.count <= 4096, snapshot.savedViews.count <= 256,
              Set(snapshot.groups.map(\.id)).count == snapshot.groups.count,
              Set(snapshot.placements.map(\.id)).count == snapshot.placements.count,
              Set(snapshot.savedViews.map(\.id)).count == snapshot.savedViews.count,
              snapshot.groups.allSatisfy({ $0.name.count <= 120 && $0.order.isFinite }),
              snapshot.placements.allSatisfy({ $0.order.isFinite }) else {
            throw RelaySharedWorkspaceError.invalidSnapshot
        }
    }

    private func readOrganization(_ parent: Int32) throws -> WorkspaceOrganizationSnapshot? {
        guard let bytes = try readData(parent, name: Self.organizationName) else { return nil }
        let snapshot = try JSONDecoder().decode(WorkspaceOrganizationSnapshot.self, from: bytes)
        try Self.validateOrganization(snapshot)
        return snapshot
    }

    /// Copies the version 1 workspace once, before the first version 2 write,
    /// so an older Relay can be restored to exactly what it last saved.
    private func backupBeforeVersion2(_ parent: Int32) throws {
        if try readData(parent, name: Self.backupName) != nil { return }
        guard let current = try readData(parent, name: "workspace-v1.json") else { return }
        try writeData(current, parent: parent, name: Self.backupName)
    }

    // MARK: Ownership (schema 3): workspace records and tab owners. A separate
    // file is the version fence: older Relays never open it, so they cannot
    // drop it, and a newer schema fails validation here instead of being
    // rewritten. Tabs an older writer adds or removes are reconciled.

    private static let ownershipName = "ownership-v3.json"

    func restoreOwnership() throws -> WorkspaceOwnershipSnapshot? {
        try locked { parent in try readOwnership(parent) }
    }

    /// Per entry, never whole-file. A tab owner edited on both sides keeps
    /// its newest revision; an edit beats a delete (reconcile later drops
    /// owners of tabs that are really gone, and gives every live tab one).
    /// Workspace records and migrations merge per field; a field changed on
    /// both sides keeps the stored version.
    static func mergeOwnership(local: WorkspaceOwnershipSnapshot, baseline: WorkspaceOwnershipSnapshot,
                               current: WorkspaceOwnershipSnapshot) throws -> (snapshot: WorkspaceOwnershipSnapshot, conflicts: Int) {
        var conflicts = 0
        func resolve<T: Codable & Equatable>(_ newest: ((T, T) -> T)?) -> (T?, T?, T?) throws -> T? {
            { l, b, c in
                if l == b { return c }
                if c == b || l == c { return l }
                conflicts += 1
                guard let l, let c else { return l ?? c }
                if let newest { return newest(l, c) }
                do { return try value(l, b, c) } catch RelaySharedWorkspaceError.conflictingEdit { return c }
            }
        }
        let owners = try entities(local.owners, baseline.owners, current.owners, id: { $0.id },
                                  resolve: resolve { $0.isNewer(than: $1) ? $0 : $1 })
        let workspaces = try entities(local.workspaces, baseline.workspaces, current.workspaces, id: { $0.id },
                                      resolve: resolve(nil))
        let migrations = try entities(local.migrations, baseline.migrations, current.migrations, id: { $0.id },
                                      resolve: resolve(nil))
        return (WorkspaceOwnershipSnapshot(schemaVersion: WorkspaceOwnershipSnapshot.currentSchemaVersion,
            workspaces: workspaces, owners: owners, migrations: migrations), conflicts)
    }

    static func migrationBackupNames(_ id: UUID) -> (workspace: String, organization: String) {
        let stem = "migration-" + id.uuidString.lowercased()
        return (stem + ".workspace-v1.json", stem + ".organization-v2.json")
    }

    private func migrationInputs(_ parent: Int32) throws
        -> (tabs: [WorkspaceTabReference], organization: WorkspaceOrganizationSnapshot, ownership: WorkspaceOwnershipSnapshot, existing: Bool) {
        guard let workspace = try read(parent) else { throw RelaySharedWorkspaceError.unavailable }
        try settleLayers(parent)
        let tabs = WorkspaceTabReference.references(workspace)
        let existing = try readOwnership(parent)
        var ownership = existing ?? .bootstrap(tabs: tabs)
        ownership.reconcile(tabs: tabs)
        return (tabs, try readOrganization(parent) ?? .empty, ownership, existing != nil)
    }

    /// The preview of what is saved, so its checksums match a later apply.
    func previewWorkspaceMigration(overrides: [UUID: String] = [:], paneMoves: [UUID: UUID] = [:],
                                   keepEmptyGroups: Bool = true, scope: WorkspaceMigrationScope? = nil) throws -> WorkspaceMigrationPreview {
        try locked { parent in
            let inputs = try migrationInputs(parent)
            return WorkspaceMigration.preview(tabs: inputs.tabs, organization: inputs.organization, ownership: inputs.ownership,
                                              overrides: overrides, paneMoves: paneMoves, keepEmptyGroups: keepEmptyGroups,
                                              scope: scope)
        }
    }

    /// Test seam: called after each intermediate migration write; throwing
    /// leaves the files exactly as a crash at that point would.
    var migrationFault: ((String) throws -> Void)?
    /// Test seam: a fault inside the two-layer write behaves as a crash
    /// (no in-process rollback), so `settleLayers` must repair it on load.
    var layerFaultIsCrash = false

    private static let layersJournalName = "migration-layers-pending.json"

    /// Written before a migration step edits both layers: the organization
    /// bytes it replaces (nil: there was no file).
    private struct LayersJournal: Codable {
        let migrationID: UUID
        let undo: Bool
        let organization: Data?
    }

    /// Writes a migration step's organization, then its ownership, as one
    /// step. A thrown error restores the organization file, so neither
    /// layer changes; after a crash between the writes, `settleLayers`
    /// does the same on the next locked read unless ownership committed.
    private func commitLayers(_ ownership: WorkspaceOwnershipSnapshot, organization: WorkspaceOrganizationSnapshot,
                              replacing current: WorkspaceOrganizationSnapshot, bytes before: Data?,
                              migrationID: UUID, undo: Bool, parent: Int32) throws {
        guard organization != current else { return try writeOwnership(ownership, parent: parent) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try Self.validateOrganization(organization)
        try writeData(encoder.encode(LayersJournal(migrationID: migrationID, undo: undo, organization: before)),
                      parent: parent, name: Self.layersJournalName)
        do {
            try writeData(encoder.encode(organization), parent: parent, name: Self.organizationName)
            try migrationFault?(undo ? "organization-undo" : "organization")
            try writeOwnership(ownership, parent: parent)
        } catch {
            if !layerFaultIsCrash {
                try? restoreOrganizationBytes(before, parent: parent)
                unlinkat(parent, Self.layersJournalName, 0)
            }
            throw error
        }
        unlinkat(parent, Self.layersJournalName, 0)
    }

    private func restoreOrganizationBytes(_ bytes: Data?, parent: Int32) throws {
        if let bytes { try writeData(bytes, parent: parent, name: Self.organizationName) }
        else if unlinkat(parent, Self.organizationName, 0) != 0 && errno != ENOENT { throw POSIXError(.EIO) }
    }

    /// Finishes an interrupted two-layer write: the step committed exactly
    /// when ownership records it (applied, or undone); otherwise the
    /// organization file goes back to the journal's bytes.
    private func settleLayers(_ parent: Int32) throws {
        guard let bytes = try readData(parent, name: Self.layersJournalName) else { return }
        let journal = try JSONDecoder().decode(LayersJournal.self, from: bytes)
        let record = try readOwnership(parent)?.migrations.first { $0.id == journal.migrationID }
        let committed = journal.undo ? record?.undoneAt != nil : record != nil
        if !committed { try restoreOrganizationBytes(journal.organization, parent: parent) }
        guard unlinkat(parent, Self.layersJournalName, 0) == 0 else { throw POSIXError(.EIO) }
    }

    /// One locked transaction. Re-checks the preview against the files,
    /// keeps both original snapshots byte-exact, then writes ownership with
    /// the pane moves `pending`, the moved layouts (`local`, already
    /// rearranged in memory by the model), and ownership with the moves
    /// `done`. A crash between writes is settled on load by `resolve`.
    func applyWorkspaceMigration(_ preview: WorkspaceMigrationPreview, paneMoves: [WorkspaceMigrationPaneMove]? = nil,
                                 workspace local: WorkspaceSnapshot? = nil, baseline: WorkspaceSnapshot? = nil,
                                 at date: Date = Date(), caller: String? = nil) throws
        -> (workspace: WorkspaceSnapshot?, ownership: WorkspaceOwnershipSnapshot, organization: WorkspaceOrganizationSnapshot) {
        try locked { parent in
            let inputs = try migrationInputs(parent)
            guard let workspaceBytes = try readData(parent, name: "workspace-v1.json"), let current = try read(parent) else {
                throw RelaySharedWorkspaceError.unavailable
            }
            let organizationBytes = try readData(parent, name: Self.organizationName)
            let organization = inputs.organization
            let moves = (paneMoves ?? []).map { move -> WorkspaceMigrationPaneMove in
                var pending = move
                pending.state = .pending
                return pending
            }
            guard moves.map(\.paneID) == preview.paneMoves.map(\.paneID), moves.isEmpty || local != nil else {
                throw WorkspaceOwnershipError.staleMigration
            }
            let result = try WorkspaceMigration.apply(preview, to: inputs.ownership, organization: organization, tabs: inputs.tabs,
                current: WorkspaceMigration.checksums(tabs: inputs.tabs, organization: organization, ownership: inputs.ownership),
                paneMoves: moves, at: date, caller: caller)
            var applied = result.ownership
            var merged: WorkspaceSnapshot?
            if let local {
                let result = try Self.merge(local: local, baseline: baseline ?? current, current: current)
                let homes = WorkspaceTabReference.references(result)
                guard moves.allSatisfy({ move in homes.first { $0.paneIDs.contains(move.paneID) }?.id == move.toTabID }) else {
                    throw WorkspaceOwnershipError.staleMigration
                }
                merged = result
            }
            if !inputs.existing { try backupBeforeVersion3(parent) }
            let names = Self.migrationBackupNames(preview.id)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try writeData(workspaceBytes, parent: parent, name: names.workspace)
            try writeData(organizationBytes ?? encoder.encode(organization), parent: parent, name: names.organization)
            try commitLayers(applied, organization: result.organization, replacing: organization, bytes: organizationBytes,
                             migrationID: preview.id, undo: false, parent: parent)
            try migrationFault?("ownership-pending")
            if let merged {
                try write(merged, parent: parent)
                try migrationFault?("workspace")
                applied.reconcile(tabs: WorkspaceTabReference.references(merged))
                try WorkspaceOwnershipSnapshot.validate(applied)
                try writeOwnership(applied, parent: parent)
            }
            return (merged, applied, result.organization)
        }
    }

    /// Mirrors apply: moves the model already returned are marked
    /// `reverting`, then the layouts, then the reversed ownership.
    func undoWorkspaceMigration(_ id: UUID, workspace local: WorkspaceSnapshot? = nil, baseline: WorkspaceSnapshot? = nil,
                                at date: Date = Date(), caller: String? = nil) throws
        -> (workspace: WorkspaceSnapshot?, ownership: WorkspaceOwnershipSnapshot, organization: WorkspaceOrganizationSnapshot) {
        try locked { parent in
            try settleLayers(parent)
            guard var ownership = try readOwnership(parent), let current = try read(parent) else {
                throw WorkspaceOwnershipError.unknownMigration
            }
            ownership.reconcile(tabs: WorkspaceTabReference.references(current))
            guard let index = ownership.migrations.firstIndex(where: { $0.id == id }) else { throw WorkspaceOwnershipError.unknownMigration }
            guard ownership.migrations[index].undoneAt == nil else { throw WorkspaceOwnershipError.alreadyUndone }
            var merged = current
            if let local {
                merged = try Self.merge(local: local, baseline: baseline ?? current, current: current)
                let homes = Dictionary(WorkspaceTabReference.references(merged).flatMap { tab in tab.paneIDs.map { ($0, tab.id) } },
                                       uniquingKeysWith: { first, _ in first })
                for move in ownership.migrations[index].paneMoves.indices
                where ownership.migrations[index].paneMoves[move].state == .done
                    && homes[ownership.migrations[index].paneMoves[move].paneID] == ownership.migrations[index].paneMoves[move].fromTabID {
                    ownership.migrations[index].paneMoves[move].state = .reverting
                }
                try writeOwnership(ownership, parent: parent)
                try migrationFault?("ownership-reverting")
                try write(merged, parent: parent)
                try migrationFault?("workspace")
            }
            let organizationBytes = try readData(parent, name: Self.organizationName)
            let organization = try readOrganization(parent) ?? .empty
            let result = try WorkspaceMigration.undo(id, in: ownership, organization: organization, at: date, caller: caller)
            var undone = result.ownership
            undone.reconcile(tabs: WorkspaceTabReference.references(merged))
            try WorkspaceOwnershipSnapshot.validate(undone)
            try commitLayers(undone, organization: result.organization, replacing: organization, bytes: organizationBytes,
                             migrationID: id, undo: true, parent: parent)
            return (local == nil ? nil : merged, undone, result.organization)
        }
    }

    private func readOwnership(_ parent: Int32) throws -> WorkspaceOwnershipSnapshot? {
        guard let bytes = try readData(parent, name: Self.ownershipName) else { return nil }
        let snapshot = try JSONDecoder().decode(WorkspaceOwnershipSnapshot.self, from: bytes)
        try WorkspaceOwnershipSnapshot.validate(snapshot)
        return snapshot
    }

    private func writeOwnership(_ snapshot: WorkspaceOwnershipSnapshot, parent: Int32) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try writeData(encoder.encode(snapshot), parent: parent, name: Self.ownershipName)
    }

    /// Copies the files an older Relay reads, once, before the first schema 3 write.
    private func backupBeforeVersion3(_ parent: Int32) throws {
        for (source, backup) in [("workspace-v1.json", "workspace-v1.pre-v3-backup.json"),
                                 (Self.organizationName, "organization-v2.pre-v3-backup.json")] {
            guard try readData(parent, name: backup) == nil, let bytes = try readData(parent, name: source) else { continue }
            try writeData(bytes, parent: parent, name: backup)
        }
    }

    private func readData(_ parent: Int32, name: String) throws -> Data? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw POSIXError(.EIO) }
            return nil
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= limit,
              let bytes = try file.read(upToCount: limit + 1), bytes.count <= limit else { throw POSIXError(.EACCES) }
        return bytes
    }

    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        guard !uncertain else { throw RelaySharedWorkspaceError.unavailable }
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw POSIXError(.EIO) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(parent) }
        guard fstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
        let lock = openat(parent, ".workspace.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(lock) }
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else { throw POSIXError(.EACCES) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw RelaySharedWorkspaceError.busy }
        defer { flock(lock, LOCK_UN) }
        try validateDirectory(parent)
        return try body(parent)
    }

    private func validateDirectory(_ parent: Int32) throws {
        var pinned = stat(), named = stat()
        guard fstat(parent, &pinned) == 0, lstat(directory.path, &named) == 0,
              named.st_mode & S_IFMT == S_IFDIR, named.st_uid == getuid(),
              named.st_mode & 0o077 == 0, named.st_dev == pinned.st_dev,
              named.st_ino == pinned.st_ino else { throw POSIXError(.EACCES) }
    }

    private func read(_ parent: Int32) throws -> WorkspaceSnapshot? {
        let fd = openat(parent, "workspace-v1.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw POSIXError(.EIO) }
            return nil
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= limit,
              let bytes = try file.read(upToCount: limit + 1), bytes.count <= limit else { throw POSIXError(.EACCES) }
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: bytes)
        try Self.validate(snapshot)
        return snapshot
    }

    private func write(_ snapshot: WorkspaceSnapshot, parent: Int32, name destination: String = "workspace-v1.json") throws {
        if destination == "workspace-v1.json", snapshot.tabs.contains(where: { !($0.stacks ?? []).isEmpty }) {
            try backupBeforeVersion2(parent)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try writeData(encoder.encode(snapshot), parent: parent, name: destination)
    }

    private func writeData(_ data: Data, parent: Int32, name destination: String) throws {
        guard data.count <= limit else { throw RelaySharedWorkspaceError.invalidSnapshot }
        let name = ".workspace-" + UUID().uuidString + ".tmp"
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd); unlinkat(parent, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw POSIXError(.EIO) }
        try validateDirectory(parent)
        // Once rename is attempted, uncertainty prevents later blind writes.
        uncertain = true
        guard renameat(parent, name, parent, destination) == 0,
              fsync(parent) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw POSIXError(.EIO) }
        try validateDirectory(parent)
        uncertain = false
    }
}
