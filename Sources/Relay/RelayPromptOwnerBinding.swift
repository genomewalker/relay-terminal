import Foundation

/// Kernel identities read from this pane's host. Does not authorize or send input.
struct RelayPromptOwnerBinding: Equatable, Codable, Sendable {
    let version: Int
    let paneId: String
    let nodeBootId: String
    let workerPid: Int
    let workerStart: UInt64
    let shellPid: Int
    let shellStart: UInt64
    let provider: String
    let processId: Int
    let processStart: UInt64
    let sessionId: String?
    let transcriptIdentity: String?
    var inputOnly: Bool? = nil

    private enum WireKeys: String, CodingKey {
        case version, provider
        case paneId = "pane_id", nodeBootId = "node_boot_id"
        case workerPid = "worker_pid", workerStart = "worker_start"
        case shellPid = "shell_pid", shellStart = "shell_start"
        case processId = "process_id", processStart = "process_start"
        case sessionId = "session_id", transcriptIdentity = "transcript_identity", inputOnly = "input_only"
    }

    func encode(to encoder: Encoder) throws {
        var wire = encoder.container(keyedBy: WireKeys.self)
        try wire.encode(version, forKey: .version)
        try wire.encode(paneId, forKey: .paneId)
        try wire.encode(nodeBootId, forKey: .nodeBootId)
        try wire.encode(workerPid, forKey: .workerPid)
        try wire.encode(workerStart, forKey: .workerStart)
        try wire.encode(shellPid, forKey: .shellPid)
        try wire.encode(shellStart, forKey: .shellStart)
        try wire.encode(provider, forKey: .provider)
        try wire.encode(processId, forKey: .processId)
        try wire.encode(processStart, forKey: .processStart)
        try wire.encodeIfPresent(sessionId, forKey: .sessionId)
        try wire.encodeIfPresent(transcriptIdentity, forKey: .transcriptIdentity)
        try wire.encodeIfPresent(inputOnly, forKey: .inputOnly)
    }

    var isInputOnly: Bool { inputOnly == true }

    func isValid(for paneID: UUID) -> Bool {
        guard version == 1, paneId == paneID.uuidString.lowercased(),
              !nodeBootId.isEmpty, nodeBootId.utf8.count <= 128,
              workerPid > 1, workerStart > 0, shellPid > 1, shellStart > 0,
              processId > 1, processStart > 0 else { return false }
        if provider == "shell" {
            return processId == shellPid && processStart == shellStart &&
                sessionId == nil && transcriptIdentity == nil && inputOnly != true
        }
        if inputOnly == true {
            guard let identity = transcriptIdentity, identity.hasPrefix("input:") else { return false }
            let epoch = identity.dropFirst(6)
            guard epoch.count == 48, epoch.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        } else if transcriptIdentity?.hasPrefix("input:") == true { return false }
        return ["claude", "codex"].contains(provider) &&
            sessionId?.isEmpty == false && (sessionId?.utf8.count ?? 0) <= 128 &&
            transcriptIdentity?.isEmpty == false && (transcriptIdentity?.utf8.count ?? 0) <= 80
    }
}

/// Keep host provenance together with every kernel identity.
struct RelayPromptOwnerIdentity: Equatable, Sendable {
    let hostID: UUID
    let binding: RelayPromptOwnerBinding

    func permitsHistoryRestore(observed: RelayPromptOwnerIdentity?,
        expected: TerminalPromptBuffer.Snapshot,
        rendered: TerminalPromptBuffer.Snapshot?) -> Bool {
        observed == self && rendered == expected
    }
}

enum TerminalPromptReconnectBoundaryPolicy {
    static func invalidatesHistory(executionChanged: Bool, replaying: Bool,
        remoteSequence: UInt64, knownSequence: UInt64) -> Bool {
        executionChanged && (!replaying || (remoteSequence > 0 && remoteSequence > knownSequence))
    }
}
