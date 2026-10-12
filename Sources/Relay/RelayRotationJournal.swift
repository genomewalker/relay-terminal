import Foundation
import Darwin

enum RelayRotationPhase: Int, Codable, Comparable, Sendable {
    case startIntent
    case freshThreadStarted
    case firstTurnCompleted
    case chittaAcknowledged
    case oldThreadRetired

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct RelayRotationRecord: Codable, Equatable, Sendable {
    let claimID: String
    let sourceThreadID: String
    let epoch: String
    let capsuleRevision: Int
    let codeHead: String
    var phase: RelayRotationPhase
    var freshThreadID: String?
    private enum CodingKeys: String, CodingKey {
        case claimID, sourceThreadID, epoch, capsuleRevision, codeHead, phase, freshThreadID
    }

    init(claimID: String, sourceThreadID: String, epoch: String, capsuleRevision: Int,
         codeHead: String, phase: RelayRotationPhase, freshThreadID: String?) {
        self.claimID = claimID; self.sourceThreadID = sourceThreadID; self.epoch = epoch
        self.capsuleRevision = capsuleRevision; self.codeHead = codeHead
        self.phase = phase; self.freshThreadID = freshThreadID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        claimID = try values.decode(String.self, forKey: .claimID)
        sourceThreadID = try values.decode(String.self, forKey: .sourceThreadID)
        if let text = try? values.decode(String.self, forKey: .epoch) { epoch = text }
        else { epoch = String(try values.decode(Int.self, forKey: .epoch)) }
        capsuleRevision = try values.decode(Int.self, forKey: .capsuleRevision)
        codeHead = try values.decode(String.self, forKey: .codeHead)
        phase = try values.decode(RelayRotationPhase.self, forKey: .phase)
        freshThreadID = try values.decodeIfPresent(String.self, forKey: .freshThreadID)
    }

}

/// Persist start intent before thread/start. If its reply is lost, Relay must
/// reconcile with Chitta and Codex; it must not create another fresh thread.
final class RelayRotationJournal: @unchecked Sendable {
    private struct Envelope: Codable { let schema: Int; var records: [RelayRotationRecord] }
    private let url: URL
    private let lock = NSLock()

    init(url: URL = RelayStateProfile.applicationSupportRoot
        .appendingPathComponent("Relay/Rotation/journal.json")) {
        self.url = url
    }

    func record(_ value: RelayRotationRecord) -> Bool {
        persist(value, requireNewIntent: false)
    }

    /// Only the caller that durably creates the intent may call thread/start.
    func begin(_ value: RelayRotationRecord) -> Bool {
        guard value.phase == .startIntent else { return false }
        return persist(value, requireNewIntent: true)
    }

    private func persist(_ value: RelayRotationRecord, requireNewIntent: Bool) -> Bool {
        guard !value.epoch.isEmpty && value.epoch.utf8.count <= 110, value.capsuleRevision > 0,
              !value.claimID.isEmpty, value.claimID.utf8.count <= 110,
              !value.sourceThreadID.isEmpty, value.sourceThreadID.utf8.count <= 110,
              value.codeHead.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil,
              value.freshThreadID.map({ !$0.isEmpty && $0.utf8.count <= 110 }) ?? true else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let transaction = beginTransaction() else { return false }
        defer { endTransaction(transaction) }
        var records: [RelayRotationRecord]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let loaded = loadUnlocked() else { return false }
            records = loaded
        } else { records = [] }

        if let index = records.firstIndex(where: { $0.claimID == value.claimID }) {
            guard !requireNewIntent else { return false }
            let old = records[index]
            guard old.sourceThreadID == value.sourceThreadID, old.epoch == value.epoch,
                  old.capsuleRevision == value.capsuleRevision, old.codeHead == value.codeHead,
                  value.phase >= old.phase,
                  value.phase.rawValue <= old.phase.rawValue + 1,
                  (old.freshThreadID == nil || old.freshThreadID == value.freshThreadID),
                  (value.phase == .startIntent) == (value.freshThreadID == nil) else { return false }
            records[index] = value
        } else {
            guard value.phase == .startIntent, value.freshThreadID == nil,
                  !records.contains(where: {
                      $0.sourceThreadID == value.sourceThreadID && $0.epoch == value.epoch
                  }), records.count < 128 else { return false }
            records.append(value)
        }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Envelope(schema: 1, records: records))
            guard data.count <= 65_536 else { return false }
            try data.write(to: url, options: .atomic)
            SecureFiles.restrictToOwner(url)
            // Persist both contents and the atomic rename before any lifecycle
            // side effect. A failed sync consumes the intent and fails closed.
            let fileDescriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fileDescriptor >= 0 else { return false }
            defer { Darwin.close(fileDescriptor) }
            guard fsync(fileDescriptor) == 0 else { return false }
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryDescriptor >= 0 else { return false }
            defer { Darwin.close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else { return false }
            return true
        } catch { return false }
    }

    func records() -> [RelayRotationRecord]? {
        lock.lock()
        defer { lock.unlock() }
        guard let transaction = beginTransaction() else { return nil }
        defer { endTransaction(transaction) }
        return FileManager.default.fileExists(atPath: url.path) ? loadUnlocked() : []
    }

    private func beginTransaction() -> Int32? {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let file = directory.appendingPathComponent(".rotation.lock")
        let descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private func endTransaction(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private func loadUnlocked() -> [RelayRotationRecord]? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 65_536,
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schema == 1, envelope.records.count <= 128,
              Set(envelope.records.map(\.claimID)).count == envelope.records.count,
              Set(envelope.records.map { "\($0.sourceThreadID):\($0.epoch)" }).count == envelope.records.count else { return nil }
        return envelope.records
    }
}
