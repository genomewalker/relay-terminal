import Foundation

struct RemoteCatalogPane: Decodable, Identifiable, Sendable {
    let paneID: String
    let workspaceID: String?
    let tabID: String?
    let parentPaneID: String?
    let title: String?
    let contentKind: String
    let command: String?
    let directory: String?
    let state: String
    let workerPID: Int?
    let shellPID: Int?
    let lastSequence: UInt64
    let recoverable: Bool
    let unfiled: Bool
    /// Carried over by a relayd upgrade; relayd's own garbage collection skips it.
    var retained: Bool? = nil
    var updatedAt: String? = nil

    var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case parentPaneID = "parent_pane_id"
        case title
        case contentKind = "content_kind"
        case command, directory, state
        case workerPID = "worker_pid"
        case shellPID = "shell_pid"
        case lastSequence = "last_sequence"
        case recoverable, unfiled, retained
        case updatedAt = "updated_at"
    }
}

struct RemoteCatalogSnapshot: Decodable, Sendable {
    let schema: Int
    let revision: UInt64
    let panes: [RemoteCatalogPane]
    let workspaceStates: [String: WorkspaceSnapshot]?

    enum CodingKeys: String, CodingKey {
        case schema, revision, panes
        case workspaceStates = "workspace_states"
    }

    var sessions: [RemoteSessionRecord] {
        let grouped = Dictionary(grouping: panes) { pane in
            pane.workspaceID.map { "workspace:\($0)" } ?? "unfiled:\(pane.paneID)"
        }
        return grouped.map { key, panes in
            RemoteSessionRecord(
                id: key,
                workspaceID: panes.first?.workspaceID,
                panes: panes.sorted {
                    if $0.tabID == $1.tabID { return $0.paneID < $1.paneID }
                    return ($0.tabID ?? $0.paneID) < ($1.tabID ?? $1.paneID)
                },
                workspaceSnapshot: panes.first?.workspaceID.flatMap { workspaceStates?[$0] }
            )
        }
        .sorted {
            if $0.recoverable != $1.recoverable { return $0.recoverable }
            return $0.id < $1.id
        }
    }
}

struct RemoteSessionRecord: Identifiable, Sendable {
    let id: String
    let workspaceID: String?
    let panes: [RemoteCatalogPane]
    let workspaceSnapshot: WorkspaceSnapshot?

    var recoverable: Bool { panes.contains(where: \.recoverable) }
    var isUnfiled: Bool { workspaceID == nil }
    var tabCount: Int { Set(panes.map { $0.tabID ?? $0.paneID }).count }
    var activeAgentCount: Int {
        panes.count { pane in
            let command = pane.command?.lowercased() ?? ""
            return pane.state == "running" && (command.contains("codex") || command.contains("claude"))
        }
    }
    var label: String {
        if isUnfiled { return panes.first?.title ?? "Recovered pane" }
        if let id = workspaceID.flatMap(UUID.init(uuidString:)),
           let name = workspaceSnapshot?.sessionNames?[id], !name.isEmpty { return name }
        return panes.first(where: { !($0.title ?? "").isEmpty })?.title ?? "Remote session"
    }
}

enum RemoteCatalogError: LocalizedError {
    case failed(String)
    case networkUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .networkUnavailable: "VPN or network route unavailable. Relay will retry automatically."
        case .invalidResponse: "The host returned an invalid Relay session catalog."
        }
    }

    var shouldRetryAutomatically: Bool {
        if case .networkUnavailable = self { return true }
        return false
    }
}

enum RemoteCatalogService {
    static func load(profile: ConnectionProfile) async throws -> RemoteCatalogSnapshot {
        let captured = try await RelayHostExecution.capture(profile: profile,
            command: RelayHostExecution.daemonCommand(profile: profile, arguments: ["sessions"]))
        guard captured.exitCode == 0 else {
            throw RemoteCatalogError.failed(String(data: captured.stderr, encoding: .utf8) ?? "Could not read Relay sessions")
        }
        guard let snapshot = try? JSONDecoder().decode(RemoteCatalogSnapshot.self, from: captured.stdout),
              snapshot.schema == 1 else { throw RemoteCatalogError.invalidResponse }
        return snapshot
    }
}

enum RemotePaneControlService {
    static func terminate(profile: ConnectionProfile, paneID: UUID) async throws {
        let captured = try await RelayHostExecution.capture(profile: profile,
            command: RelayHostExecution.daemonCommand(profile: profile,
                arguments: ["terminate", "--session", paneID.uuidString.lowercased(), "--forget"]))
        guard captured.exitCode == 0 else {
            throw RemoteCatalogError.failed(String(data: captured.stderr, encoding: .utf8) ?? "Could not terminate the remote pane")
        }
    }

    /// Removes the record of a pane whose worker is no longer valid.
    /// relayd refuses while the pane's worker is still alive.
    static func forget(profile: ConnectionProfile, paneID: UUID) async throws {
        let captured = try await RelayHostExecution.capture(profile: profile,
            command: RelayHostExecution.daemonCommand(profile: profile,
                arguments: ["forget", "--session", paneID.uuidString.lowercased()]))
        guard captured.exitCode == 0 else {
            throw RemoteCatalogError.failed(String(data: captured.stderr, encoding: .utf8) ?? "Could not remove the pane record")
        }
    }

    /// Clears one dead pane by exact ID: stops a leftover worker relayd still
    /// validates, then removes the record. Works for upgrade-retained panes.
    static func clear(profile: ConnectionProfile, paneID: UUID, workerValid: Bool,
                      pause: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }) async throws {
        guard workerValid else { return try await forget(profile: profile, paneID: paneID) }
        do {
            try await terminate(profile: profile, paneID: paneID)
        } catch RemoteCatalogError.failed {
            // The worker may still be exiting after the signal, or may have
            // exited before it. relayd's forget refuses while it is alive.
            await pause()
            try await forget(profile: profile, paneID: paneID)
        }
    }
}
