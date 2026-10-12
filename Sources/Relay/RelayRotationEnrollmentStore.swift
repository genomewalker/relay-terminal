import Foundation
import CryptoKit
import Darwin

/// Private effective App Server start parameters captured from verified source
/// evidence. The capture adapter must bind the exact completed-turn rollout,
/// live process incarnation, and authenticated root before constructing this.
/// These settings are never part of the model-facing capsule.
struct RelayCodexStartConfiguration: Codable, Equatable, Sendable {
    let sourceThreadID: String
    let sourceTurnID: String
    let sourcePID: Int
    let sourceProcessStart: String
    let parameters: Data
    let effort: String
    let sha256: String
    let capturedAt: Date

    func valid(sessionID: String, pid: Int, processStart: String,
               enrolledAt: Date) -> Bool {
        guard sourceThreadID == sessionID, !sourceTurnID.isEmpty,
              sourceTurnID.utf8.count <= 110, !sourceTurnID.contains("/"),
              !effort.isEmpty, effort.utf8.count <= 32,
              sourcePID == pid,
              sourceProcessStart == processStart,
              parameters.count > 0, parameters.count <= 65_536,
              sha256 == SHA256.hash(data: parameters).map({ String(format: "%02x", $0) }).joined(),
              capturedAt.timeIntervalSince1970.isFinite,
              capturedAt <= enrolledAt,
              let value = try? JSONSerialization.jsonObject(with: parameters) as? [String: Any],
              let projectDir = value["cwd"] as? String, projectDir.hasPrefix("/"),
              projectDir.utf8.count <= 4096,
              let model = value["model"] as? String, !model.isEmpty,
              let approval = value["approvalPolicy"] as? String, !approval.isEmpty,
              (value["sandbox"] != nil) != (value["permissions"] != nil) else { return false }
        return true
    }
}

/// Private current Claude settings captured from the exact live session.
/// Refresh this before a rotation decision; a saved older capture is only
/// historical restart metadata, not proof settings are still current.
struct RelayClaudeStartConfiguration: Codable, Equatable, Sendable {
    let sourceSessionID: String
    let sourcePID: Int
    let sourceProcessStart: String
    let payload: Data
    let sha256: String
    let capturedAt: Date

    func valid(sessionID: String, paneID: String, pid: Int, processStart: String,
               cwd: String, enrolledAt: Date) -> Bool {
        guard sourceSessionID == sessionID, sourcePID == pid,
              sourceProcessStart == processStart,
              payload.count > 0, payload.count <= 65_536,
              sha256 == SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined(),
              capturedAt.timeIntervalSince1970.isFinite, capturedAt <= enrolledAt,
              let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              value["session_id"] as? String == sessionID,
              value["pane_id"] as? String == paneID,
              value["source_pid"] as? Int == pid,
              value["source_start"] as? String == processStart,
              value["cwd"] as? String == cwd,
              let model = value["model"] as? String, !model.isEmpty,
              let effort = value["effort"] as? String, !effort.isEmpty,
              let mode = value["permission_mode"] as? String, !mode.isEmpty,
              let args = value["fresh_args"] as? [String], !args.isEmpty,
              args.allSatisfy({ !$0.contains("\0") }) else { return false }
        return true
    }
}

/// An enrollment binds a backend session to one retained launch and process
/// incarnation. Loading a record does not authorize a rotation or prove idle.
struct RelayRetainedRotationEnrollment: Codable, Equatable, Sendable {
    let sessionID: String
    let client: String
    let hostID: String
    let paneID: String
    let processID: Int
    let processStart: String
    let snapshotPath: String
    let snapshotSHA256: String
    let snapshot: Data
    let enrolledAt: Date
    let codexStart: RelayCodexStartConfiguration?
    let claudeStart: RelayClaudeStartConfiguration?

    init(sessionID: String, client: String, hostID: String, paneID: String,
         processID: Int, processStart: String, snapshotPath: String,
         snapshotSHA256: String, snapshot: Data, enrolledAt: Date,
         codexStart: RelayCodexStartConfiguration? = nil,
         claudeStart: RelayClaudeStartConfiguration? = nil) {
        self.sessionID = sessionID; self.client = client; self.hostID = hostID
        self.paneID = paneID; self.processID = processID; self.processStart = processStart
        self.snapshotPath = snapshotPath; self.snapshotSHA256 = snapshotSHA256
        self.snapshot = snapshot; self.enrolledAt = enrolledAt
        self.codexStart = codexStart; self.claudeStart = claudeStart
    }

    var launchIdentityValid: Bool {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 110,
              !sessionID.contains("/"), ["codex", "claude"].contains(client),
              !hostID.isEmpty, UUID(uuidString: paneID) != nil,
              processID > 0, !processStart.isEmpty, processStart.utf8.count <= 128,
              snapshotPath.hasPrefix("/"), snapshotPath.utf8.count <= 4096,
              !snapshot.isEmpty, snapshot.count <= 65_536,
              enrolledAt.timeIntervalSince1970.isFinite,
              snapshotSHA256 == SHA256.hash(data: snapshot).map({ String(format: "%02x", $0) }).joined(),
              let value = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
              value["schema"] as? Int == 1, value["client"] as? String == client,
              value["pid"] as? Int == processID,
              value["process_start"] as? String == processStart,
              value["relay_pane_id"] as? String == paneID,
              let cwd = value["cwd"] as? String, cwd.hasPrefix("/"),
              let executable = value["executable"] as? String, executable.hasPrefix("/"),
              let launch = value["launch_id"] as? String, !launch.isEmpty,
              value["effective_args"] is [String],
              let args = value["arguments"] as? [String: Any],
              args["reusable"] as? Bool == true,
              (args["fresh_args"] == nil || args["fresh_args"] is [String]) else { return false }
        return true
    }

    var valid: Bool {
        guard launchIdentityValid,
              let snapshotValue = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
              let cwd = snapshotValue["cwd"] as? String else { return false }
        if client == "codex" {
            guard let codexStart,
                  codexStart.valid(sessionID: sessionID, pid: processID,
                    processStart: processStart, enrolledAt: enrolledAt),
                  claudeStart == nil else { return false }
        } else {
            guard codexStart == nil, let claudeStart,
                  claudeStart.valid(sessionID: sessionID, paneID: paneID,
                    pid: processID, processStart: processStart,
                    cwd: cwd, enrolledAt: enrolledAt) else { return false }
        }
        return true
    }
}

/// Private durable storage with a process-wide file lock. Conflicting records
/// are rejected; replacing a process requires explicit removal and enrollment.
final class RelayRotationEnrollmentStore: @unchecked Sendable {
    private struct Envelope: Codable {
        let schema: Int
        var records: [RelayRetainedRotationEnrollment]
    }
    private let url: URL
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    func records() -> [RelayRetainedRotationEnrollment]? {
        transaction { read() }
    }

    func enroll(_ record: RelayRetainedRotationEnrollment) -> Bool {
        guard record.valid else { return false }
        return transaction {
            guard var records = self.read() else { return false }
            if let existing = records.first(where: { $0.sessionID == record.sessionID }) {
                return existing == record
            }
            guard records.count < 128, !records.contains(where: {
                $0.hostID == record.hostID && $0.paneID == record.paneID
            }) else { return false }
            records.append(record)
            return self.write(records)
        } ?? false
    }

    func remove(sessionID: String, snapshotSHA256: String) -> Bool {
        transaction {
            guard var records = self.read(), let index = records.firstIndex(where: {
                $0.sessionID == sessionID && $0.snapshotSHA256 == snapshotSHA256
            }) else { return false }
            records.remove(at: index)
            return self.write(records)
        } ?? false
    }

    private func read() -> [RelayRetainedRotationEnrollment]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size <= 12_000_000,
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schema == 1, envelope.records.count <= 128,
              envelope.records.allSatisfy(\.valid),
              Set(envelope.records.map(\.sessionID)).count == envelope.records.count,
              Set(envelope.records.map { $0.hostID + "\u{0}" + $0.paneID }).count == envelope.records.count
        else { return nil }
        return envelope.records
    }

    private func write(_ records: [RelayRetainedRotationEnrollment]) -> Bool {
        do {
            let data = try JSONEncoder().encode(Envelope(schema: 1, records: records))
            guard data.count <= 12_000_000 else { return false }
            try data.write(to: url, options: .atomic)
            guard chmod(url.path, 0o600) == 0 else { return false }
            let file = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { return false }
            defer { Darwin.close(file) }
            guard fsync(file) == 0 else { return false }
            let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { return false }
            defer { Darwin.close(directory) }
            return fsync(directory) == 0
        } catch { return false }
    }

    private func transaction<T>(_ operation: () -> T?) -> T? {
        lock.lock(); defer { lock.unlock() }
        let directory = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]) } catch { return nil }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { return nil }
        let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        return operation()
    }
}
