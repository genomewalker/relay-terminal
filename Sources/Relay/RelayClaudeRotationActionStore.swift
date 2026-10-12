import Foundation
import CryptoKit
import Darwin

/// Each physical action is claimed durably before its first side effect. A
/// claimed action is reconciled by observation; it is never sent again.
final class RelayClaudeRotationActionStore: @unchecked Sendable {
    struct Record: Codable, Sendable {
        let fingerprint: String
        let completed: Bool
        let result: Data?
    }
    private let directory: URL
    private let lock = NSLock()
    init(directory: URL) { self.directory = directory }

    func read(intent: String, action: String) throws -> Record? {
        try transaction { try load(path(intent, action)) }
    }

    /// Retain the exact record as evidence while removing it from active enumeration.
    func retire(intent: String, action: String) throws -> Bool {
        try transaction {
            let source = path(intent, action)
            guard try load(source) != nil else { return false }
            let archived = directory.appendingPathComponent(
                ".previous-\(UUID().uuidString.lowercased())-\(source.lastPathComponent)")
            try FileManager.default.moveItem(at: source, to: archived)
            try syncDirectory()
            return true
        }
    }

    func records(limit: Int) throws -> [Record] {
        try transaction {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.range(of: #"^[0-9a-f]{64}\.json$"#, options: .regularExpression) != nil }
            guard files.count <= limit else { throw RelayRotationAdapterError.mismatchedEvidence }
            return try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { try load($0) }
        }
    }

    /// Explicitly replace a saved pane relationship, retaining its previous
    /// binding as evidence. Message and rotation receipts remain immutable.
    func replacePaneLink(intent: String, result: Data) throws {
        guard result.count <= 65536 else { throw RelayRotationAdapterError.mismatchedEvidence }
        try transaction {
            let url = path(intent, "link")
            if let prior = try load(url) {
                guard prior.completed else { throw RelayRotationAdapterError.mismatchedEvidence }
                if prior.result == result { return }
                let previous = directory.appendingPathComponent(".previous-\(UUID().uuidString.lowercased())-\(url.lastPathComponent)")
                try Data(contentsOf: url).write(to: previous, options: .atomic)
                guard chmod(previous.path, 0o600) == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            }
            let data = try JSONEncoder().encode(Record(fingerprint: intent, completed: true, result: result))
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, 0o600) == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            defer { Darwin.close(fd) }
            guard fsync(fd) == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            try syncDirectory()
        }
    }

    func claim(intent: String, action: String, fingerprint: String) throws -> Bool {
        try transaction {
            let url = path(intent, action)
            if try load(url) != nil { return false }
            let data = try JSONEncoder().encode(Record(fingerprint: fingerprint, completed: false, result: nil))
            let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            try file.write(contentsOf: data)
            guard fsync(fd) == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            try syncDirectory()
            return true
        }
    }

    func complete(intent: String, action: String, fingerprint: String, result: Data) throws {
        guard result.count <= 65536 else { throw RelayRotationAdapterError.mismatchedEvidence }
        try transaction {
            let url = path(intent, action)
            guard let old = try load(url), old.fingerprint == fingerprint else {
                throw RelayRotationAdapterError.mismatchedEvidence
            }
            if old.completed {
                guard old.result == result else { throw RelayRotationAdapterError.mismatchedEvidence }
                return
            }
            let data = try JSONEncoder().encode(Record(fingerprint: fingerprint, completed: true, result: result))
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, 0o600) == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            defer { Darwin.close(fd) }
            guard fsync(fd) == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
            try syncDirectory()
        }
    }

    private func path(_ intent: String, _ action: String) -> URL {
        let bytes = Data((intent + "\u{0}" + action).utf8)
        let name = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
    private func load(_ url: URL) throws -> Record? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 100000 else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }
    private func syncDirectory() throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        let fd = Darwin.open(directory.appendingPathComponent(".lock").path,
                             O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RelayRotationAdapterError.mismatchedEvidence }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, flock(fd, LOCK_EX) == 0 else {
            throw RelayRotationAdapterError.mismatchedEvidence
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}
