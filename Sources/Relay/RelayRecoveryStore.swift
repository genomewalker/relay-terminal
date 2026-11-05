import Foundation
import Darwin

/// Recovery metadata is evidence, never authority for sending agent input.
/// Provider transcripts remain on their original host.
@MainActor final class RelayRecoveryStore {
    static let shared = RelayRecoveryStore()

    struct Link: Codable, Sendable {
        let from: String
        let to: String
        let kind: String
    }
    struct Event: Codable, Sendable {
        let schemaVersion: Int
        let id: UUID
        let occurredAt: Date
        let kind: String
        let host: String
        let paneID: UUID?
        let directory: String?
        let links: [Link]
    }
    private let directory: URL
    private let writer = DispatchQueue(label: "relay.recovery.graph", qos: .utility)
    private var membership: [UUID: UUID] = [:]
    private var knownConversations: [UUID: String] = [:]

    /// `directory` overrides the profile's recovery store, for tests.
    init(directory: URL = RelayStateProfile.applicationSupportRoot
        .appendingPathComponent("Relay/Recovery", isDirectory: true)) {
        self.directory = directory
    }

    private func archiveURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("closed-\(id.uuidString.lowercased()).json")
    }

    func saveClosedPane(_ entry: ClosedPaneRecovery) {
        do {
            SecureFiles.createPrivateDirectory(at: directory)
            let data = try JSONEncoder().encode(entry)
            let url = archiveURL(entry.id)
            try data.write(to: url, options: .atomic)
            SecureFiles.restrictToOwner(url)
            record(kind: "pane_closed", paneID: entry.pane.id, profile: entry.pane.profile,
                directory: entry.pane.directory, links: [
                    .init(from: "pane:\(entry.pane.id)", to: "tab:\(entry.tab.id)", kind: "belonged_to"),
                    .init(from: "tab:\(entry.tab.id)", to: "workspace:\(entry.tab.sessionID ?? entry.tab.id)", kind: "belongs_to")
                ])
        } catch { report(error) }
    }

    func loadClosedPanes() -> [ClosedPaneRecovery] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        // Archives survive app restarts. Bound the menu read without deleting
        // older recovery records; each file is independently atomic.
        let entries = files.filter { $0.lastPathComponent.hasPrefix("closed-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> ClosedPaneRecovery? in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 1 << 20, let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ClosedPaneRecovery.self, from: data)
            }.sorted { $0.closedAt > $1.closedAt }
        var seen: Set<UUID> = []
        return entries.filter { seen.insert($0.pane.id).inserted }
    }

    func removeClosedPane(_ id: UUID) {
        do { try FileManager.default.removeItem(at: archiveURL(id)) }
        catch { report(error) }
    }

    func observeWorkspace(_ snapshot: WorkspaceSnapshot) {
        let profiles = Dictionary(uniqueKeysWithValues: snapshot.panes.map { ($0.id, $0.profile) })
        var next: [UUID: UUID] = [:]
        for tab in snapshot.tabs {
            for paneID in tab.layout.paneIDs + (tab.floatingPanes ?? []).map(\.paneID) {
                next[paneID] = tab.id
                guard membership[paneID] != tab.id, let profile = profiles[paneID] else { continue }
                record(kind: membership[paneID] == nil ? "pane_observed" : "pane_moved", paneID: paneID,
                    profile: profile, links: [
                        .init(from: "pane:\(paneID)", to: "tab:\(tab.id)", kind: "belongs_to"),
                        .init(from: "tab:\(tab.id)", to: "workspace:\(tab.sessionID ?? tab.id)", kind: "belongs_to")
                    ])
            }
        }
        membership = next
    }

    func observeConversation(_ binding: RelayAgentConversationBinding, profile: ConnectionProfile, directory: String?) {
        let identity = "conversation:\(profile.connectionKey):\(binding.provider):\(binding.sessionID)"
        guard knownConversations[binding.paneID] != identity else { return }
        knownConversations[binding.paneID] = identity
        record(kind: "conversation_bound", paneID: binding.paneID, profile: profile, directory: directory,
            links: [.init(from: identity, to: "pane:\(binding.paneID)", kind: "ran_in")])
    }

    func recordRestore(source: UUID, destination: UUID, plan: RelaySavedConversationPlan, profile: ConnectionProfile) {
        record(kind: "conversation_restore_requested", paneID: destination, profile: profile, directory: plan.directory,
            links: [
                .init(from: "pane:\(destination)", to: "pane:\(source)", kind: "restored_from"),
                .init(from: "conversation:\(profile.connectionKey):\(plan.provider):\(plan.sessionID)",
                    to: "pane:\(destination)", kind: "resume_requested_in")
            ])
    }

    func recordAgentEvent(paneID: UUID, profile: ConnectionProfile, event: [String: Any]) {
        guard let kind = event["hook_event_name"] as? String ?? event["type"] as? String,
              ["SessionStart", "SessionEnd", "PeerMessage", "SubagentStart", "SubagentStop"].contains(kind) else { return }
        var links: [Link] = []
        for key in ["from_peer_id", "to_peer_id", "thread_id", "session_id", "agent_id", "root_id"] {
            guard let value = event[key] as? String, !value.isEmpty, value.utf8.count <= 512 else { continue }
            links.append(.init(from: "pane:\(paneID)", to: "agent-reference:\(profile.connectionKey):\(value)", kind: key))
        }
        record(kind: kind, paneID: paneID, profile: profile, links: links)
    }

    func record(kind: String, paneID: UUID?, profile: ConnectionProfile, directory: String? = nil, links: [Link] = []) {
        let event = Event(schemaVersion: 1, id: UUID(), occurredAt: Date(), kind: kind,
            host: profile.connectionKey, paneID: paneID, directory: directory, links: links)
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        let payload = data
        let root = self.directory
        writer.async {
            SecureFiles.createPrivateDirectory(at: root)
            let url = root.appendingPathComponent("events.jsonl")
            do {
                // O_APPEND and the advisory lock coordinate separate Relay
                // windows/processes as well as this writer queue.
                let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, mode_t(0o600))
                guard fd >= 0 else { throw POSIXError(.EIO) }
                defer { Darwin.close(fd) }
                guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
                defer { flock(fd, LOCK_UN) }
                try payload.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw POSIXError(.EIO) }
                        offset += count
                    }
                }
            } catch {
                RelayDiagnostics.shared.record(category: "recovery", name: "graph-write-failed",
                    details: ["reason": error.localizedDescription])
            }
        }
    }

    private func report(_ error: Error) {
        RelayDiagnostics.shared.record(category: "recovery", name: "archive-failed",
            details: ["reason": error.localizedDescription])
    }
}
