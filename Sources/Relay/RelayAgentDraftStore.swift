import CryptoKit
import Foundation

/// Private, bounded persistence for unsent native-conversation drafts, scoped by
/// host profile and pane. Draft text is never logged; failures record only the
/// operation and the error. A store failure never changes the in-memory draft.
final class RelayAgentDraftStore: @unchecked Sendable {
    static let shared = RelayAgentDraftStore()
    static let maximumDraftBytes = 65_536
    static let maximumEntries = 128
    private static let maximumRecordBytes = 524_288

    private struct Record: Codable {
        let version: Int
        let hostID: String
        let paneID: String
        let text: String
        let updatedAt: Date
        let attachments: [RelayAgentDraftAttachment]?
    }

    private let directory: URL
    private let persistenceEnabled: Bool
    private let queue = DispatchQueue(label: "relay.agent-drafts", qos: .utility)
    private let lock = NSLock()
    private var generations: [String: UInt64] = [:]

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["RELAY_TESTING"] == "1" ||
            Bundle.main.bundleURL.pathExtension == "xctest" ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.processName.contains("RelayPackageTests") ||
            ProcessInfo.processInfo.processName.hasPrefix("swiftpm-testing")
    }

    init(directory: URL? = nil) {
        persistenceEnabled = directory != nil || !Self.isRunningTests
        self.directory = directory ?? RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/AgentDrafts", isDirectory: true)
        SecureFiles.createPrivateDirectory(at: self.directory)
    }

    /// The stored draft for this host and pane, or nil when none is stored or it is unreadable.
    func load(hostID: String, paneID: UUID) -> String? {
        loadDraft(hostID: hostID, paneID: paneID)?.text
    }

    func loadDraft(hostID: String, paneID: UUID) -> RelayAgentStoredDraft? {
        guard persistenceEnabled, let key = Self.key(hostID: hostID, paneID: paneID) else { return nil }
        let url = fileURL(key)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= Self.maximumRecordBytes,
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.hostID == hostID, record.paneID == paneID.uuidString.lowercased(),
              record.text.utf8.count <= Self.maximumDraftBytes,
              Self.validAttachments(record.attachments ?? [], hostID: hostID, paneID: paneID),
              !record.text.isEmpty || !(record.attachments ?? []).isEmpty else { return nil }
        return RelayAgentStoredDraft(text: record.text, attachments: record.attachments ?? [])
    }

    /// Saves the latest draft; writes are coalesced so only the newest edit is written.
    /// Empty text removes the stored draft. Oversized text leaves the previous stored
    /// draft unchanged (the composer already refuses to send it).
    func save(_ text: String, hostID: String, paneID: UUID, attachments: [RelayAgentDraftAttachment] = []) {
        guard persistenceEnabled, let key = Self.key(hostID: hostID, paneID: paneID) else { return }
        guard text.utf8.count <= Self.maximumDraftBytes, Self.validAttachments(attachments, hostID: hostID, paneID: paneID) else {
            record("save-skipped-oversize", key: key, reason: "draft exceeds limit")
            return
        }
        let generation = nextGeneration(key)
        let entry = Record(version: 1, hostID: hostID, paneID: paneID.uuidString.lowercased(),
                           text: text, updatedAt: Date(), attachments: attachments)
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isCurrent(key, generation) else { return }
            let url = self.fileURL(key)
            if entry.text.isEmpty && (entry.attachments ?? []).isEmpty {
                self.removeFile(url, key: key)
                return
            }
            do {
                let data = try JSONEncoder().encode(entry)
                guard data.count <= Self.maximumRecordBytes else {
                    self.record("save-skipped-oversize", key: key, reason: "draft record exceeds limit"); return
                }
                try data.write(to: url, options: .atomic)
                SecureFiles.restrictToOwner(url)
                self.trim(keeping: url)
            } catch {
                self.record("write-failed", key: key, reason: error.localizedDescription)
            }
        }
    }

    /// Writes immediately (window close or app termination) so a pending coalesced
    /// write is not lost. Waits only for this one small bounded file.
    func saveNow(_ text: String, hostID: String, paneID: UUID, attachments: [RelayAgentDraftAttachment] = []) {
        guard persistenceEnabled, text.utf8.count <= Self.maximumDraftBytes, Self.validAttachments(attachments, hostID: hostID, paneID: paneID),
              let key = Self.key(hostID: hostID, paneID: paneID) else { return }
        let generation = nextGeneration(key)
        let entry = Record(version: 1, hostID: hostID, paneID: paneID.uuidString.lowercased(),
                           text: text, updatedAt: Date(), attachments: attachments)
        queue.sync {
            guard isCurrent(key, generation) else { return }
            let url = fileURL(key)
            if entry.text.isEmpty && (entry.attachments ?? []).isEmpty { removeFile(url, key: key); return }
            do {
                let data = try JSONEncoder().encode(entry)
                guard data.count <= Self.maximumRecordBytes else {
                    record("save-skipped-oversize", key: key, reason: "draft record exceeds limit"); return
                }
                try data.write(to: url, options: .atomic)
                SecureFiles.restrictToOwner(url)
                trim(keeping: url)
            } catch { record("write-failed", key: key, reason: error.localizedDescription) }
        }
    }

    /// Called only after a confirmed submission.
    func remove(hostID: String, paneID: UUID) {
        guard persistenceEnabled, let key = Self.key(hostID: hostID, paneID: paneID) else { return }
        let generation = nextGeneration(key)
        queue.async { [weak self] in
            guard let self, self.isCurrent(key, generation) else { return }
            self.removeFile(self.fileURL(key), key: key)
        }
    }

    private static func validAttachments(_ attachments: [RelayAgentDraftAttachment], hostID: String, paneID: UUID) -> Bool {
        attachments.count <= 32 && Set(attachments.map(\.id)).count == attachments.count &&
            attachments.allSatisfy { $0.isValid && ($0.uploadedBinding.map {
                $0.hostID == hostID && $0.paneID == paneID
            } ?? true) }
    }

    private func removeFile(_ url: URL, key: String) {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
        catch { record("remove-failed", key: key, reason: error.localizedDescription) }
    }

    /// Keeps at most `maximumEntries` drafts, discarding the least recently edited others.
    private func trim(keeping current: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]),
              files.count > Self.maximumEntries else { return }
        let dated = files.filter { $0.pathExtension == "json" && $0 != current }.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(files.count - Self.maximumEntries) { try? FileManager.default.removeItem(at: url) }
    }

    private func nextGeneration(_ key: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let next = (generations[key] ?? 0) &+ 1
        generations[key] = next
        return next
    }

    private func isCurrent(_ key: String, _ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generations[key] == generation
    }

    private func record(_ name: String, key: String, reason: String) {
        // Never include draft text.
        RelayDiagnostics.shared.record(category: "agent-draft", name: name,
                                       details: ["key": String(key.prefix(16)), "reason": reason])
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    /// File names are a digest of host and pane, so neither appears in a path.
    private static func key(hostID: String, paneID: UUID) -> String? {
        guard !hostID.isEmpty, hostID.utf8.count <= 1024 else { return nil }
        let digest = SHA256.hash(data: Data((hostID + "\u{0}" + paneID.uuidString.lowercased()).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
