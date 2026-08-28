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
        Bundle.main.bundleURL.pathExtension == "xctest" ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.processName.contains("RelayPackageTests") ||
            ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
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
            guard let data = try? JSONEncoder.relayState.encode(state), data.count <= 4 << 20 else { return }
            self.lock.lock()
            let current = self.generations[paneID] == generation
            self.lock.unlock()
            guard current else { return }
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
