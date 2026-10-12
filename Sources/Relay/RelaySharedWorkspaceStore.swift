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
        try Self.validate(local)
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
            try write(merged, parent: parent)
            let pending = "pending-\(instanceID).json"
            if unlinkat(parent, pending, 0) == 0 {
                uncertain = true
                guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
                uncertain = false
            } else if errno != ENOENT { throw POSIXError(.EIO) }
            return merged
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
            sidebarVisible: local.sidebarVisible)
        try validate(merged)
        return merged
    }

    private struct Name: Codable { let id: UUID; let name: String }

    private static func entities<T: Codable>(_ local: [T], _ baseline: [T], _ current: [T], id: (T) -> UUID) throws -> [T] {
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
            if let merged = try value(l[key], b[key], c[key]) { result.append(merged) }
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
            if ["profile", "layout", "editorRequest", "remoteParentSessionID"].contains(key),
               !equal(l[key], b[key]), !equal(c[key], b[key]), !equal(l[key], c[key]) {
                throw RelaySharedWorkspaceError.conflictingEdit
            }
            result[key] = try mergeJSON(local: l[key], baseline: b[key], current: c[key])
        }
        return result
    }

    static func validate(_ snapshot: WorkspaceSnapshot) throws {
        guard snapshot.tabs.count <= 4096, snapshot.panes.count <= 16384,
              Set(snapshot.tabs.map(\.id)).count == snapshot.tabs.count,
              Set(snapshot.panes.map(\.id)).count == snapshot.panes.count else { throw RelaySharedWorkspaceError.invalidSnapshot }
        let paneIDs = Set(snapshot.panes.map(\.id))
        var used = Set<UUID>()
        for tab in snapshot.tabs {
            let ids = tab.layout.paneIDs + (tab.floatingPanes ?? []).map(\.paneID)
            guard !ids.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: paneIDs),
                  used.isDisjoint(with: ids) else { throw RelaySharedWorkspaceError.invalidSnapshot }
            used.formUnion(ids)
        }
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
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
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
