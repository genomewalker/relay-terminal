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
        case recoverable, unfiled
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
        try await Task.detached(priority: .userInitiated) {
            let ssh = Process()
            let output = Pipe()
            let errors = Pipe()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "-o", "ControlMaster=auto",
                "-o", "ControlPersist=10m",
                "-o", "ControlPath=~/.ssh/relay-%C",
            ] + profile.sshConnectionArguments + ["~/.local/bin/relayd", "sessions"]
            ssh.standardOutput = output
            ssh.standardError = errors
            let captured: CapturedProcessOutput
            do {
                captured = try ProcessCapture.run(ssh, output: output, errors: errors, timeout: 12)
            } catch {
                throw RemoteCatalogError.failed(error.localizedDescription)
            }
            let data = captured.standardOutput
            let errorData = captured.standardError
            guard ssh.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if SSHConnectionFailure.diagnose(
                    message ?? "",
                    terminationStatus: ssh.terminationStatus
                ).kind == .networkRoute {
                    throw RemoteCatalogError.networkUnavailable
                }
                throw RemoteCatalogError.failed(message?.isEmpty == false ? message! : "Could not read remote sessions.")
            }
            guard let snapshot = try? JSONDecoder().decode(RemoteCatalogSnapshot.self, from: data),
                  snapshot.schema == 1 else {
                throw RemoteCatalogError.invalidResponse
            }
            return snapshot
        }.value
    }
}

enum RemotePaneControlService {
    static func terminate(profile: ConnectionProfile, paneID: UUID) async throws {
        try await Task.detached(priority: .userInitiated) {
            let ssh = Process()
            let output = Pipe()
            let errors = Pipe()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "-o", "ControlMaster=auto",
                "-o", "ControlPersist=10m",
                "-o", "ControlPath=~/.ssh/relay-%C",
            ] + profile.sshConnectionArguments + [
                "~/.local/bin/relayd", "terminate",
                "--session", paneID.uuidString.lowercased(), "--forget",
            ]
            ssh.standardOutput = output
            ssh.standardError = errors
            let captured: CapturedProcessOutput
            do {
                captured = try ProcessCapture.run(ssh, output: output, errors: errors, timeout: 12)
            } catch {
                throw RemoteCatalogError.failed(error.localizedDescription)
            }
            let errorData = captured.standardError
            guard ssh.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw RemoteCatalogError.failed(message?.isEmpty == false ? message! : "Could not terminate the remote pane.")
            }
        }.value
    }
}
