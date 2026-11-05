import Foundation
import CryptoKit
import Darwin

/// Value-free write-ahead state for private native operations. Never stores a
/// credential, proposal text, raw arguments, or a credential-derived digest.
/// IDs are never evicted: a full or unreadable journal fails closed.
final class RelayPrivateOperationJournal {
    struct Entry: Codable, Equatable {
        let owner: String
        let request: String
        var status: String
    }
    enum Failure: Error { case unavailable, conflict, full }
    private let url: URL
    private var entries: [String: Entry] = [:]
    private var available = true
    private let limit: Int

    init(url: URL, limit: Int = 1024) {
        self.url = url; self.limit = limit
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 1_048_576 else { throw Failure.unavailable }
                entries = try JSONDecoder().decode([String: Entry].self, from: data)
                guard entries.count <= limit else { throw Failure.full }
            } catch { available = false }
        }
    }
    static func digest(_ fields: [String]) -> String {
        let data = try! JSONEncoder().encode(fields)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func lookup(_ id: UUID, owner: String, request: String? = nil) throws -> String? {
        try synchronized {
            guard let entry = entries[id.uuidString] else { return nil }
            guard entry.owner == owner, request == nil || entry.request == request else { throw Failure.conflict }
            return ["awaiting_approval", "running"].contains(entry.status) ? "outcome_unknown" : entry.status
        }
    }
    func admit(_ id: UUID, owner: String, request: String) throws {
        try synchronized {
            guard entries[id.uuidString] == nil else { throw Failure.conflict }
            guard entries.count < limit else { throw Failure.full }
            entries[id.uuidString] = Entry(owner: owner, request: request, status: "awaiting_approval")
            try persist()
        }
    }
    func finish(_ id: UUID, status: String) throws {
        try synchronized {
            guard var entry = entries[id.uuidString],
                  ["running", "completed", "cancelled", "stale_or_expired", "outcome_unknown", "refused_no_changes", "not_completed"].contains(status) else { throw Failure.unavailable }
            guard status != "completed" || entry.status == "running",
                  status != "running" || entry.status == "awaiting_approval" else { throw Failure.conflict }
            entry.status = status; entries[id.uuidString] = entry
            try persist()
        }
    }
    // Separate windows/processes may address the same profile. Hold an OS lock
    // and reload under it; a stale in-memory dictionary must not erase IDs.
    private func synchronized<T>(_ body: () throws -> T) throws -> T {
        guard available else { throw Failure.unavailable }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard info.isSymbolicLink != true, info.isRegularFile == true else { throw Failure.unavailable }
                let data = try Data(contentsOf: url)
                guard data.count <= 1_048_576 else { throw Failure.unavailable }
                entries = try JSONDecoder().decode([String: Entry].self, from: data)
                guard entries.count <= limit else { throw Failure.full }
            } catch { available = false; throw Failure.unavailable }
        } else { entries = [:] }
        return try body()
    }
    private func persist() throws {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Atomic rename plus synchronize makes the admitted identity and
            // terminal result durable before any consumer/acknowledgement.
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize(); try handle.close()
            let descriptor = Darwin.open(directory.path, O_RDONLY)
            guard descriptor >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw Failure.unavailable }
        } catch { available = false; throw Failure.unavailable }
    }
}
