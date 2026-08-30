import Foundation

struct PersistedAgentPaneState: Codable, Sendable {
    let cursor: UInt64
    let kind: AgentKind
    let phase: AgentPhase
    let summary: String
    let subagents: [SubagentActivity]
    let activities: [AgentActivityItem]
    let resourceUsage: AgentResourceUsage?
    let progressPercent: Int?
    let pendingApprovals: Int
}

final class AgentStateStore: @unchecked Sendable {
    static let shared = AgentStateStore()

    private let directory: URL
    private let queue = DispatchQueue(label: "relay.agent-state", qos: .utility)
    private let lock = NSLock()
    private var generations: [UUID: UInt64] = [:]

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["RELAY_TESTING"] == "1" ||
            Bundle.main.bundleURL.pathExtension == "xctest" ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.processName.contains("RelayPackageTests") ||
            ProcessInfo.processInfo.processName.hasPrefix("swiftpm-testing")
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Relay/AgentState", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
    }

    func load(paneID: UUID) -> PersistedAgentPaneState? {
        guard !Self.isRunningTests else { return nil }
        let url = stateURL(paneID)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 4 << 20,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? JSONDecoder.relayState.decode(PersistedAgentPaneState.self, from: data)
    }

    func save(_ state: PersistedAgentPaneState, paneID: UUID) {
        guard !Self.isRunningTests else { return }
        lock.lock()
        let generation = (generations[paneID] ?? 0) &+ 1
        generations[paneID] = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.generations[paneID] == generation
            self.lock.unlock()
            guard current else { return }
            let boundedState = state.boundedForStorage()
            guard let data = try? JSONEncoder.relayState.encode(boundedState), data.count <= 4 << 20 else { return }
            // Encoding a busy 100-agent tree is measurable. A newer event may
            // have arrived while it ran, so avoid an obsolete atomic write too.
            self.lock.lock()
            let stillCurrent = self.generations[paneID] == generation
            self.lock.unlock()
            guard stillCurrent else { return }
            let url = self.stateURL(paneID)
            do {
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                RelayDiagnostics.shared.record(category: "agent-state", name: "write-failed", details: [
                    "pane_id": paneID.uuidString.lowercased(),
                    "reason": error.localizedDescription,
                ])
            }
        }
    }

    private func stateURL(_ paneID: UUID) -> URL {
        directory.appendingPathComponent(paneID.uuidString.lowercased() + ".json")
    }
}

extension PersistedAgentPaneState {
    func boundedForStorage() -> PersistedAgentPaneState {
        let maximumSubagents = 100
        let active = subagents.filter { $0.phase == .active }
        let selected: [SubagentActivity]
        if active.count >= maximumSubagents {
            selected = Array(active.suffix(maximumSubagents))
        } else {
            let activeIDs = Set(active.map(\.id))
            let completed = subagents.filter { !activeIDs.contains($0.id) }
            let keptIDs = Set((active + completed.suffix(maximumSubagents - active.count)).map(\.id))
            selected = subagents.filter { keptIDs.contains($0.id) }
        }
        let boundedSubagents = selected.map { subagent in
            var copy = subagent
            copy.updates = copy.updates.suffix(10).map { update in
                SubagentUpdate(
                    id: update.id,
                    message: String(update.message.prefix(2_048)),
                    occurredAt: update.occurredAt
                )
            }
            return copy
        }
        return PersistedAgentPaneState(
            cursor: cursor,
            kind: kind,
            phase: phase,
            summary: String(summary.prefix(1_024)),
            subagents: boundedSubagents,
            activities: Array(activities.suffix(16)),
            resourceUsage: resourceUsage,
            progressPercent: progressPercent,
            pendingApprovals: pendingApprovals
        )
    }
}

private extension JSONEncoder {
    static var relayState: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var relayState: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
