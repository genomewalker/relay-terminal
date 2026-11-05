import Foundation

/// Draft bytes stay in a private file, outside settings and model receipts.
/// The journal contains only their digest and restoration state.
struct RelayAgentMaintenanceDraft: Codable, Equatable, Sendable {
    let version: Int
    let actionID: String
    let paneID: UUID
    let host: String
    let sessionID: String
    let originalOwner: RelayPromptOwnerBinding
    let text: Data
    let digest: String

    init(actionID: String, paneID: UUID, host: String, sessionID: String,
         originalOwner: RelayPromptOwnerBinding, text: Data) throws {
        guard Self.validText(text), originalOwner.isValid(for: paneID),
              originalOwner.sessionId == sessionID else { throw RelayPromptEditorRPC.Failure.invalidRequest }
        version = 1; self.actionID = actionID; self.paneID = paneID; self.host = host
        self.sessionID = sessionID; self.originalOwner = originalOwner; self.text = text
        digest = RelayPromptEditorRPC.digest(text)
    }

    static func validText(_ text: Data) -> Bool {
        text.count <= RelayPromptEditorRPC.maximumDraftBytes && !text.contains(0) &&
        String(data: text, encoding: .utf8) != nil
    }

    func valid(actionID: String, paneID: UUID, host: String, sessionID: String, digest: String) -> Bool {
        version == 1 && self.actionID == actionID && self.paneID == paneID && self.host == host &&
        self.sessionID == sessionID && originalOwner.isValid(for: paneID) &&
        originalOwner.sessionId == sessionID && Self.validText(text) &&
        self.digest == digest && RelayPromptEditorRPC.digest(text) == digest
    }
}

/// Why a draft capture was not started. Shown as the pane's maintenance hold.
struct RelayAgentMaintenanceDraftRefusal: LocalizedError, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { "Draft capture held: " + reason + "." }
}

@MainActor final class RelayAgentMaintenanceDraftStore {
    static let maximumFileBytes = 2 << 20
    let directory: URL
    init(directory: URL = RelayStateProfile.applicationSupportRoot
        .appendingPathComponent("Relay/agent-maintenance/drafts")) { self.directory = directory }

    private func url(_ actionID: String) throws -> URL {
        guard actionID.count == 64, actionID.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RelayPromptEditorRPC.Failure.invalidRequest
        }
        return directory.appendingPathComponent(actionID + ".json")
    }

    /// The directory must be a private, owned, real directory; a symlink or a
    /// shared directory could expose or redirect the draft bytes.
    private func privateDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw RelayPromptEditorRPC.Failure.invalidResponse
        }
        if (attributes[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    func save(_ draft: RelayAgentMaintenanceDraft) throws {
        let target = try url(draft.actionID)
        try privateDirectory()
        // An existing backup is immutable. An ambiguous operation cannot replace it.
        if FileManager.default.fileExists(atPath: target.path) {
            guard try load(draft.actionID) == draft else { throw RelayPromptEditorRPC.Failure.invalidResponse }
            return
        }
        let data = try JSONEncoder().encode(draft)
        guard data.count <= Self.maximumFileBytes else { throw RelayPromptEditorRPC.Failure.invalidRequest }
        // The file is created 0600 before any byte is written, then published
        // with link(2), which refuses to replace an existing backup.
        let temporary = directory.appendingPathComponent(".\(draft.actionID).\(UUID().uuidString.lowercased()).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RelayPromptEditorRPC.Failure.invalidResponse }
        defer { unlink(temporary.path) }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        let synced = written && fsync(descriptor) == 0
        guard close(descriptor) == 0, synced, link(temporary.path, target.path) == 0 else {
            throw RelayPromptEditorRPC.Failure.invalidResponse
        }
        guard try load(draft.actionID) == draft else { throw RelayPromptEditorRPC.Failure.invalidResponse }
    }

    func load(_ actionID: String) throws -> RelayAgentMaintenanceDraft {
        let target = try url(actionID)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumFileBytes else {
            throw RelayPromptEditorRPC.Failure.invalidResponse
        }
        let descriptor = open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RelayPromptEditorRPC.Failure.invalidResponse }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard let data = try handle.read(upToCount: Self.maximumFileBytes + 1),
              data.count <= Self.maximumFileBytes else { throw RelayPromptEditorRPC.Failure.invalidResponse }
        // The owner binding encodes its native wire keys in snake case.
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayAgentMaintenanceDraft.self, from: data)
    }

    /// A restored draft's backup is deleted; the journal keeps only its digest.
    func remove(_ actionID: String) throws {
        let target = try url(actionID)
        guard unlink(target.path) == 0 || errno == ENOENT else { throw RelayPromptEditorRPC.Failure.invalidResponse }
    }
}
