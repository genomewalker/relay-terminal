import Foundation
import CryptoKit

struct PluginHPCAction: Sendable {
    let id: UUID
    let script: String

    func validate(operation: RelayPluginOperation, path: String) throws {
        if operation == .projectRun {
            let data = Data(script.utf8)
            guard data.count <= 8192,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["argv", "environment", "timeout_seconds"]),
                  let argv = object["argv"] as? [String], (1...64).contains(argv.count),
                  argv[0].hasPrefix("/"), argv.allSatisfy({ !$0.contains("\0") }),
                  let env = object["environment"] as? [String: String], env.count <= 32,
                  env.allSatisfy({ $0.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil && !$0.value.contains("\0") }),
                  let timeout = object["timeout_seconds"] as? Int, (1...60).contains(timeout) else {
                throw PluginError.invalid("Review a command object with an absolute argv executable, environment and a 1–60 second timeout (8 KiB maximum).")
            }
        } else if operation == .hpcSubmit {
            guard script.hasPrefix("#!"), script.utf8.count <= 8192, !script.contains("\0") else {
                throw PluginError.invalid("Review a complete batch script with a shebang, at most 8 KiB")
            }
        } else if operation == .hpcCancel {
            guard path.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil else {
                throw PluginError.invalid("Enter one ordinary numeric job ID. Array cancellation is not supported.")
            }
        }
    }
}

enum RelayPluginOperation: String, Codable, CaseIterable, Sendable {
    case hpcJobs, hpcAccounting, hpcDetails, hpcLogs, hpcSubmit, hpcCancel, artifacts, agentActivity, gitReview, transfers, projectActions, projectRun, rWorkspace, vpn

    var isHPC: Bool { [.hpcJobs, .hpcAccounting, .hpcDetails, .hpcLogs, .hpcSubmit, .hpcCancel].contains(self) }

    var isMutation: Bool { self == .hpcSubmit || self == .hpcCancel || self == .projectRun }

    var permissions: Set<RelayPluginPackage.Permission.Kind> {
        switch self {
        case .vpn: [.network]
        case .agentActivity: [.agentMetadata, .agentContent]
        case .hpcJobs, .hpcAccounting, .hpcDetails: [.remoteOperation]
        case .hpcLogs: [.remoteOperation, .projectRead]
        case .hpcSubmit: [.jobSubmit]
        case .hpcCancel: [.jobCancel]
        case .projectRun: [.projectExecute]
        default: [.projectRead]
        }
    }
}

struct PluginScope: Equatable, Sendable {
    let paneID: UUID
    let profile: ConnectionProfile
    let root: String

    func editorPath(_ relativePath: String) throws -> String {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PluginError.invalid("Select a file inside the reviewed project")
        }
        return (root as NSString).appendingPathComponent(relativePath)
    }

    static func captured(paneID: UUID, profile: ConnectionProfile, directory: String?, operation: RelayPluginOperation) throws -> PluginScope {
        // Scheduler and agent snapshots are connection-scoped, not file reads.
        // Never let their safe working-directory fallback authorize file tools.
        guard let root = directory ?? ([.hpcJobs, .hpcAccounting, .hpcDetails, .hpcLogs, .hpcCancel, .agentActivity].contains(operation) ? "/" : nil) else {
            throw PluginError.invalid("The pane has not reported its working directory yet.")
        }
        return try PluginScope(paneID: paneID, profile: profile, root: root)
    }

    init(paneID: UUID, profile: ConnectionProfile, root: String) throws {
        guard root.hasPrefix("/"), !root.contains("\0"), root.utf8.count <= 4096 else {
            throw PluginError.invalid("Select a pane with a known absolute working directory")
        }
        self.paneID = paneID; self.profile = profile; self.root = root
    }
}

struct PluginOperationResult: Decodable, Sendable {
    var root: String
    var text: String
    var entries: [String]
    var content: String?
    var sha256: String?
    var truncated: Bool
    var verifiedBytes: Data? = nil
    var jobs: [PluginHPCJob]? = nil
    var jobCount: Int? = nil
    var cluster: PluginHPCCluster? = nil
    var clusterError: String? = nil
    var accounting: [[String]]? = nil
    var jobDetail: PluginHPCDetail? = nil
    var directory: String? = nil
    var transfer: PluginTransferInfo? = nil

    private enum CodingKeys: String, CodingKey {
        case root, text, entries, content, sha256, truncated, jobs, directory, transfer, accounting
        case jobCount = "job_count"
        case jobDetail = "job_detail"
        case cluster
        case clusterError = "cluster_error"
    }

    func validatedHPCJobs() throws -> [PluginHPCJob] {
        guard let jobCount, jobCount >= 0 else {
            throw PluginError.invalid("This host has an older HPC helper. Update relayd through Relay’s remote setup.")
        }
        let rows = jobs ?? []
        guard rows.count <= 500, rows.count <= jobCount,
              truncated == (rows.count < jobCount),
              Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ !$0.id.isEmpty && !$0.state.isEmpty &&
                  [$0.id, $0.partition, $0.name, $0.state, $0.elapsed, $0.nodes, $0.reason].allSatisfy { $0.utf8.count <= 4096 }
              }) else { throw PluginError.invalid("Invalid Slurm job response; refresh after updating relayd") }
        return rows
    }

    func verifiedContent() throws -> Data? {
        guard let content else { return nil }
        guard let bytes = Data(base64Encoded: content), bytes.count <= 8 << 20,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw PluginError.invalid("File integrity check failed")
        }
        return bytes
    }

    func validateEnvelope(operation: RelayPluginOperation, path: String) throws {
        guard root.hasPrefix("/"), root.utf8.count <= 4096, !root.contains("\0"),
              text.utf8.count <= 3 * 128 * 1024, entries.count <= 500,
              entries.allSatisfy({ $0.utf8.count <= 8192 && !$0.contains("\0") }) else {
            throw PluginError.invalid("Invalid or oversized plugin response")
        }
        let isFile = operation == .artifacts || operation == .transfers
        if let transfer {
            guard operation == .transfers, text == path, directory == nil, entries.isEmpty,
                  transfer.size >= 0, transfer.size <= 64 * 1024 * 1024 * 1024,
                  transfer.offset >= 0, transfer.offset <= transfer.size,
                  transfer.version.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw PluginError.invalid("Invalid transfer metadata")
            }
            return
        }
        if let directory {
            let requested = path.split(separator: "/").map(String.init).joined(separator: "/")
            guard isFile, !path.hasPrefix("/"), directory == requested,
                  !directory.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                  content == nil, sha256 == nil, Set(entries).count == entries.count else {
                throw PluginError.invalid("Invalid directory response")
            }
            let prefix = directory.isEmpty ? "" : directory + "/"
            guard entries.allSatisfy({ entry in
                guard entry.hasPrefix(prefix) else { return false }
                var name = String(entry.dropFirst(prefix.count))
                if name.hasSuffix("/") { name.removeLast() }
                return !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            }) else { throw PluginError.invalid("Directory entry leaves the requested folder") }
        } else if isFile && !path.isEmpty {
            guard text == path, content != nil, sha256 != nil else {
                throw PluginError.invalid("Missing file payload or path mismatch. Update relayd and retry.")
            }
        } else if content != nil || sha256 != nil {
            throw PluginError.invalid("Unexpected file payload for this operation")
        }
    }
}

private final class PluginCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum PluginOperationRunner {
    private static let budget = PluginOperationBudget()
    // Invocation is fixed. Root/path travel as JSON on stdin, never shell source.
    static func run(_ operation: RelayPluginOperation, scope: PluginScope, path: String, stream: String = "stdout", action: PluginHPCAction? = nil, transfer: PluginTransferRequest? = nil, allUsers: Bool = false, queueUser: String = "") async throws -> PluginOperationResult {
        guard !operation.isHPC || scope.profile.kind == .ssh else {
            throw PluginError.invalid("Select a remote host to use HPC tools.")
        }
        guard operation != .agentActivity else { throw PluginError.invalid("Agent activity is supplied by Relay") }
        if operation.isMutation {
            guard let action else { throw PluginError.invalid("Review and confirm this scheduler action first") }
            try action.validate(operation: operation, path: path)
        }
        guard path.utf8.count <= 4096, !path.contains("\0") else { throw PluginError.invalid("Invalid path") }
        try await budget.acquire()
        defer { Task { await budget.release() } }
        let cancellation = PluginCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                var fields: [String: Any] = ["operation": operation.rawValue, "root": scope.root, "path": path]
                if operation == .hpcJobs { fields["all_users"] = allUsers; fields["user"] = queueUser; fields["cluster"] = true }
                if let transfer {
                    guard operation == .transfers else { throw PluginError.invalid("Invalid transfer operation") }
                    fields["transfer"] = ["mode": transfer.mode, "version": transfer.version, "offset": transfer.offset]
                }
                if operation == .hpcAccounting || operation == .hpcDetails || operation == .hpcLogs {
                    fields["path"] = ""
                    fields["job_id"] = path
                    if operation == .hpcLogs { fields["stream"] = stream }
                }
                if operation.isMutation, let action {
                    fields["path"] = ""
                    fields["job_id"] = path
                    fields["script"] = action.script
                    fields["action_id"] = action.id.uuidString
                    fields["confirmed"] = true
                }
                let request = try JSONSerialization.data(withJSONObject: ["request_id": "rpc-" + UUID().uuidString.lowercased(), "operation": "plugin", "plugin": fields])
                let response = try await RelayNodeTransportPool.shared.request(profile: scope.profile, payload: request)
                guard !cancellation.isCancelled() else { throw CancellationError() }
                guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw PluginError.invalid("Invalid host plugin response") }
                if let error = envelope["error"] as? String { throw PluginError.invalid(error) }
                guard let result = envelope["result"] else { throw PluginError.invalid("Missing host plugin result") }
                var decoded = try JSONDecoder().decode(PluginOperationResult.self, from: JSONSerialization.data(withJSONObject: result))
                try decoded.validateEnvelope(operation: operation, path: path)
                if operation == .hpcAccounting {
                    guard (decoded.accounting ?? []).count <= 500, (decoded.accounting ?? []).allSatisfy({ $0.count == 19 && $0.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }) }) else { throw PluginError.invalid("Invalid accounting response") }
                }
                if operation == .hpcJobs { _ = try decoded.validatedHPCJobs() }
                if operation == .hpcDetails || operation == .hpcLogs {
                    guard let detail = decoded.jobDetail, detail.id == path,
                          [detail.id, detail.name, detail.state, detail.account, detail.partition, detail.directory, detail.stdout, detail.stderr].allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
                          decoded.text.utf8.count <= 3 * 65536,
                          (detail.scheduler?.utf8.count ?? 0) <= 1 << 20 else {
                        throw PluginError.invalid("Missing or invalid job details; update relayd and retry")
                    }
                }
                decoded.verifiedBytes = try decoded.verifiedContent()
                if let transfer { try transfer.validate(decoded, path: path) }
                return decoded
            }.value
        } onCancel: { cancellation.cancel() }
    }
}

actor PluginOperationBudget {
    enum Failure: LocalizedError {
        case busy
        var errorDescription: String? { "Two plugin operations are already running. Wait or cancel one before retrying." }
    }
    private var active = 0
    func acquire() throws {
        guard active < 2 else { throw Failure.busy }
        active += 1
    }
    func release() { active = max(0, active - 1) }
}
