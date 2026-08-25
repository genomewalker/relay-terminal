import Foundation
import SwiftUI

enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

enum PaneDropPlacement: Sendable {
    case leading
    case trailing
    case top
    case bottom
    case center
}

enum WorkspaceRenameTarget: Equatable, Sendable {
    case session(UUID)
    case tab(UUID)
    case pane(UUID)

    var title: String {
        switch self {
        case .session: "Rename session"
        case .tab: "Rename tab"
        case .pane: "Rename pane"
        }
    }
}

indirect enum PaneLayout: Codable, Equatable, Sendable {
    case pane(UUID)
    case split(id: UUID, axis: SplitAxis, first: PaneLayout, second: PaneLayout)

    var paneIDs: [UUID] {
        switch self {
        case .pane(let id):
            return [id]
        case .split(_, _, let first, let second):
            return first.paneIDs + second.paneIDs
        }
    }

    func splitting(
        _ target: UUID,
        axis: SplitAxis,
        with newPane: UUID,
        newPaneFirst: Bool = false
    ) -> PaneLayout {
        switch self {
        case .pane(let id) where id == target:
            return .split(
                id: UUID(),
                axis: axis,
                first: .pane(newPaneFirst ? newPane : id),
                second: .pane(newPaneFirst ? id : newPane)
            )
        case .pane:
            return self
        case .split(let id, let existingAxis, let first, let second):
            return .split(
                id: id,
                axis: existingAxis,
                first: first.splitting(target, axis: axis, with: newPane, newPaneFirst: newPaneFirst),
                second: second.splitting(target, axis: axis, with: newPane, newPaneFirst: newPaneFirst)
            )
        }
    }

    func removing(_ target: UUID) -> PaneLayout? {
        switch self {
        case .pane(let id):
            return id == target ? nil : self
        case .split(_, _, let first, let second):
            let remainingFirst = first.removing(target)
            let remainingSecond = second.removing(target)
            switch (remainingFirst, remainingSecond) {
            case (nil, nil): return nil
            case (let survivor?, nil), (nil, let survivor?): return survivor
            case (let newFirst?, let newSecond?):
                if case .split(let id, let axis, _, _) = self {
                    return .split(id: id, axis: axis, first: newFirst, second: newSecond)
                }
                return nil
            }
        }
    }

    func swapping(_ firstID: UUID, _ secondID: UUID) -> PaneLayout {
        switch self {
        case .pane(let id):
            if id == firstID { return .pane(secondID) }
            if id == secondID { return .pane(firstID) }
            return self
        case .split(let id, let axis, let first, let second):
            return .split(
                id: id,
                axis: axis,
                first: first.swapping(firstID, secondID),
                second: second.swapping(firstID, secondID)
            )
        }
    }
}

struct FloatingPanePlacement: Codable, Equatable, Identifiable, Sendable {
    let paneID: UUID
    var originX: Double
    var originY: Double
    var width: Double
    var height: Double

    var id: UUID { paneID }

    static func initial(paneID: UUID, index: Int) -> FloatingPanePlacement {
        let cascade = Double(index % 6) * 28
        return FloatingPanePlacement(
            paneID: paneID,
            originX: 56 + cascade,
            originY: 46 + cascade,
            width: 720,
            height: 480
        )
    }
}

enum ConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ssh
    case local

    var id: String { rawValue }
}

enum RemoteSessionBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case relay
    case direct

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relay: "Relay session"
        case .direct: "Direct SSH"
        }
    }

    var detail: String {
        switch self {
        case .relay: "Persistent · native reattach"
        case .direct: "Ends when SSH disconnects"
        }
    }
}

enum PaneContentKind: String, Codable, Sendable {
    case terminal
    case editor

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .editor: "Editor"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .editor: "curlybraces"
        }
    }
}

struct EditorOpenRequest: Codable, Equatable, Sendable {
    let paths: [String]
    let diff: Bool
}

struct RemoteFileOpenRequest: Sendable {
    let profile: ConnectionProfile
    let parentSessionID: String
    let request: EditorOpenRequest
}

struct ConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var kind: ConnectionKind
    var host: String
    var user: String
    var port: Int
    var command: String
    var backend: RemoteSessionBackend
    var usesSSHConfig: Bool

    init(
        id: UUID = UUID(),
        name: String = "HPC",
        kind: ConnectionKind = .ssh,
        host: String = "",
        user: String = "",
        port: Int = 22,
        command: String = "",
        backend: RemoteSessionBackend = .relay,
        usesSSHConfig: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.user = user
        self.port = port
        self.command = command
        self.backend = backend
        self.usesSSHConfig = usesSSHConfig
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, host, user, port, command, backend, usesSSHConfig
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "HPC"
        kind = try values.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? .ssh
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        user = try values.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        backend = try values.decodeIfPresent(RemoteSessionBackend.self, forKey: .backend) ?? .relay
        usesSSHConfig = try values.decodeIfPresent(Bool.self, forKey: .usesSSHConfig) ?? false
    }

    static let local = ConnectionProfile(
        name: "Local shell",
        kind: .local,
        host: "",
        user: "",
        port: 22,
        command: "",
        backend: .direct
    )

    static func sshConfigHost(_ alias: String) -> ConnectionProfile {
        ConnectionProfile(
            name: alias,
            kind: .ssh,
            host: alias,
            user: "",
            port: 22,
            command: "",
            backend: .relay,
            usesSSHConfig: true
        )
    }

    var destination: String {
        guard kind == .ssh else { return "This Mac" }
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    var subtitle: String {
        if kind == .local { return "Local login shell" }
        return usesSSHConfig ? "SSH config · \(host)" : "\(destination):\(port)"
    }

    var sshConnectionArguments: [String] {
        if usesSSHConfig { return [host] }
        return ["-p", String(port), destination]
    }

    func remoteCommand(forPane id: UUID) -> String? {
        guard kind == .ssh else { return nil }
        let requestedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

        switch backend {
        case .direct:
            return requestedCommand.isEmpty ? nil : requestedCommand
        case .relay:
            return nil
        }
    }
}

enum AgentKind: String, Codable, CaseIterable, Sendable {
    case shell
    case claude
    case codex

    var label: String {
        switch self {
        case .shell: "Shell"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .shell: "terminal"
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum AgentPhase: String, Sendable {
    case connecting
    case active
    case quiet
    case needsInput
    case exited

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .active: "Working"
        case .quiet: "Ready"
        case .needsInput: "Needs input"
        case .exited: "Exited"
        }
    }

    var color: Color {
        switch self {
        case .connecting: RelayTheme.blue
        case .active: RelayTheme.mint
        case .quiet: RelayTheme.textMuted
        case .needsInput: RelayTheme.coral
        case .exited: RelayTheme.red
        }
    }
}

enum PaneConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case disconnected(String)

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnected: "Connection lost"
        }
    }

    var symbol: String {
        switch self {
        case .connecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .connected: "checkmark.circle.fill"
        case .disconnected: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .connecting: RelayTheme.blue
        case .connected: RelayTheme.mint
        case .disconnected: RelayTheme.coral
        }
    }

    var errorMessage: String? {
        if case .disconnected(let message) = self { return message }
        return nil
    }
}

struct SubagentActivity: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let startedAt: Date
    var phase: AgentPhase = .active
}

struct AgentActivityItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    let phase: AgentPhase
    let occurredAt: Date
}

struct AgentSignalDetector: Sendable {
    private(set) var kind: AgentKind = .shell
    private(set) var phase: AgentPhase = .connecting
    private(set) var excerpt = "Opening session…"
    private var buffer = ""

    mutating func ingest(_ text: String, detectAgentKind: Bool = true) {
        let scanBoundary = String(buffer.suffix(512))
        buffer = String((buffer + text).suffix(12_000))
        let lower = (scanBoundary + text).lowercased()

        if detectAgentKind {
            if lower.contains("claude code") || lower.contains("claude.ai/code") || lower.contains("anthropic") {
                kind = .claude
            } else if lower.contains("openai codex") || lower.contains("codex cli") || lower.contains("codex>") {
                kind = .codex
            }
        }

        let attentionSignals = [
            "do you want to proceed?",
            "would you like to",
            "allow this command",
            "approve this",
            "requires approval",
            "press enter to continue",
            "waiting for your input",
            "yes/no",
            "(y/n)",
            "[y/n]"
        ]
        phase = attentionSignals.contains(where: lower.contains) ? .needsInput : .active
        excerpt = Self.lastReadableLine(in: buffer) ?? "Receiving output…"
    }

    mutating func markQuiet() {
        if phase == .active { phase = .quiet }
    }

    mutating func markExited() {
        phase = .exited
        excerpt = "Session ended"
    }

    mutating func resetToShell() {
        kind = .shell
        phase = .quiet
        excerpt = "Shell"
        buffer = ""
    }

    mutating func acknowledgeInput() {
        if phase == .needsInput { phase = .active }
    }

    mutating func overrideKind(_ newKind: AgentKind) {
        kind = newKind
    }

    mutating func applyStructuredEvent(kind: AgentKind, phase: AgentPhase, excerpt: String) {
        self.kind = kind
        self.phase = phase
        self.excerpt = excerpt
    }

    private static func lastReadableLine(in text: String) -> String? {
        let stripped = text
            .replacingOccurrences(of: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])", with: "", options: .regularExpression)
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        return stripped.map { String($0.prefix(120)) }
    }
}

@MainActor
final class PaneModel: ObservableObject, Identifiable {
    let id: UUID
    let profile: ConnectionProfile
    let contentKind: PaneContentKind
    @Published var title: String
    @Published var customName: String?
    @Published var directory: String?
    private(set) var detector = AgentSignalDetector()
    private(set) var lastActivity = Date()
    @Published var activeSubagents = 0
    @Published var subagents: [SubagentActivity] = []
    @Published var agentActivities: [AgentActivityItem] = []
    @Published var connectionState: PaneConnectionState
    @Published var remoteExitCode: Int?
    @Published var artifacts: [PaneArtifact] = []
    @Published var artifactError: String?
    @Published var editorRequest: EditorOpenRequest?
    @Published var isRestoringTerminal = false
    private var structuredAgentRunning: Bool?
    private var agentMonitor: RelayRemoteTransport?
    let remoteParentSessionID: String?
    private var quietTask: Task<Void, Never>?
    lazy var runtime = TerminalRuntime(pane: self)
    lazy var editorRuntime = RemoteEditorRuntime(pane: self)

    init(
        id: UUID = UUID(),
        profile: ConnectionProfile,
        contentKind: PaneContentKind = .terminal,
        remoteParentSessionID: String? = nil,
        editorRequest: EditorOpenRequest? = nil,
        customName: String? = nil
    ) {
        self.id = id
        self.profile = profile
        self.contentKind = contentKind
        self.remoteParentSessionID = remoteParentSessionID
        self.editorRequest = editorRequest
        self.customName = customName
        self.title = contentKind == .editor ? "Editor" : profile.name
        self.remoteExitCode = nil
        self.connectionState = profile.kind == .ssh && profile.backend == .relay
            ? .connecting
            : .connected
    }

    var kind: AgentKind { detector.kind }
    var phase: AgentPhase { detector.phase }
    var displayName: String { customName ?? title }
    var activitySummary: String {
        if let activity = agentActivities.last { return activity.label }
        return switch phase {
        case .connecting: "Starting"
        case .active: "Working"
        case .quiet: "Ready"
        case .needsInput: "Needs input"
        case .exited: "Exited"
        }
    }

    func focus() {
        switch contentKind {
        case .terminal: runtime.focus()
        case .editor: editorRuntime.focus()
        }
    }

    func startAgentMonitoring() {
        guard agentMonitor == nil,
              contentKind == .terminal,
              profile.kind == .ssh,
              profile.backend == .relay else { return }
        let monitor = RelayRemoteTransport()
        agentMonitor = monitor
        monitor.start(
            profile: profile,
            sessionID: id.uuidString.lowercased(),
            parentSessionID: nil,
            onOutput: { _ in },
            onStatus: { [weak self, weak monitor] status in
                Task { @MainActor [weak self, weak monitor] in
                    guard let self else { return }
                    if status.state == "attached" {
                        self.connected()
                    } else if status.state == "exited" {
                        self.exited(exitCode: status.exitCode)
                    } else if status.state == "error", self.agentMonitor === monitor {
                        self.stopAgentMonitoring()
                    }
                }
            },
            onAgentEvent: { [weak self] data in
                Task { @MainActor [weak self] in self?.receivedAgentEvent(data) }
            },
            onArtifact: { _ in },
            onDisconnect: { _ in },
            observeAgentsOnly: true
        )
    }

    func stopAgentMonitoring() {
        agentMonitor?.detach()
        agentMonitor = nil
    }

    func stopRuntime() {
        stopAgentMonitoring()
        switch contentKind {
        case .terminal: runtime.stop()
        case .editor: editorRuntime.stop()
        }
    }

    func restartRuntime() {
        switch contentKind {
        case .terminal: runtime.restart()
        case .editor: editorRuntime.restart()
        }
    }

    func received(_ text: String) {
        if connectionState != .connected { connectionState = .connected }
        let previousKind = detector.kind
        let previousPhase = detector.phase
        detector.ingest(text, detectAgentKind: structuredAgentRunning != false)
        lastActivity = Date()
        if previousKind != detector.kind || previousPhase != detector.phase {
            objectWillChange.send()
        }
        quietTask?.cancel()
        quietTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard let self, !Task.isCancelled else { return }
            self.detector.markQuiet()
            self.objectWillChange.send()
        }
    }

    func dismissArtifact(_ id: UUID) {
        artifacts.removeAll { $0.id == id }
    }

    func receivedArtifact(path: String, data: Data) {
        guard RelayPreferences.shared.showArtifactPreviews,
              !artifacts.contains(where: { $0.remotePath == path }) else { return }
        artifacts.append(PaneArtifact(remotePath: path, data: data))
        artifacts = Array(artifacts.suffix(8))
        artifactError = nil
    }

    func exited(exitCode: Int? = nil) {
        remoteExitCode = exitCode
        detector.markExited()
    }

    func connected() {
        remoteExitCode = nil
        connectionState = .connected
    }

    func beginTerminalRestore() {
        guard contentKind == .terminal else { return }
        isRestoringTerminal = true
    }

    func finishTerminalRestore() {
        isRestoringTerminal = false
    }

    func reconnecting() {
        remoteExitCode = nil
        connectionState = .connecting
        detector = AgentSignalDetector()
    }

    func connectionInterrupted(_ message: String) {
        connectionState = .connecting
    }

    func disconnected(_ message: String) {
        connectionState = .disconnected(message)
        detector.markExited()
    }

    func userEnteredInput() {
        detector.acknowledgeInput()
    }

    func receivedAgentEvent(_ data: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agentName = envelope["agent"] as? String,
              let event = envelope["event"] as? [String: Any] else { return }
        if agentName == "relay",
           event["type"] as? String == "open_file",
           let paths = event["paths"] as? [String],
           !paths.isEmpty {
            NotificationCenter.default.post(
                name: .relayOpenRemoteFile,
                object: RemoteFileOpenRequest(
                    profile: profile,
                    parentSessionID: id.uuidString.lowercased(),
                    request: EditorOpenRequest(paths: paths, diff: event["diff"] as? Bool ?? false)
                )
            )
            return
        }
        let kind: AgentKind = agentName.lowercased().contains("claude") ? .claude : .codex
        let eventName = (event["hook_event_name"] as? String)
            ?? (event["type"] as? String)
            ?? "Agent event"
        let tool = event["tool_name"] as? String
        let agentType = event["agent_type"] as? String
        let subagentID = (event["agent_id"] as? String)
            ?? (event["subagent_id"] as? String)
            ?? (event["thread_id"] as? String)
        let notificationType = event["notification_type"] as? String

        if eventName == "SessionEnd" {
            structuredAgentRunning = false
        } else {
            structuredAgentRunning = true
        }

        switch eventName {
        case "PermissionRequest":
            detector.applyStructuredEvent(kind: kind, phase: .needsInput, excerpt: "Approval: \(tool ?? "permission requested")")
            recordActivity("Approval needed for \(tool ?? "a tool")", phase: .needsInput)
        case "Notification" where notificationType == "permission_prompt" || notificationType == "idle_prompt":
            detector.applyStructuredEvent(kind: kind, phase: .needsInput, excerpt: event["message"] as? String ?? "Needs input")
            recordActivity(event["message"] as? String ?? "Needs input", phase: .needsInput)
        case "SubagentStart":
            let identifier = subagentID ?? UUID().uuidString
            subagents.removeAll { $0.id == identifier }
            subagents.append(SubagentActivity(
                id: identifier,
                label: agentType ?? "Subagent",
                startedAt: Date(),
                phase: .active
            ))
            subagents = Array(subagents.suffix(16))
            activeSubagents = subagents.count { $0.phase == .active }
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Subagent: \(agentType ?? "working")")
            recordActivity("Started \(agentType ?? "subagent")", phase: .active)
        case "SubagentStop":
            if let subagentID {
                if let index = subagents.firstIndex(where: { $0.id == subagentID }) {
                    subagents[index].phase = .quiet
                } else {
                    subagents.append(SubagentActivity(
                        id: subagentID,
                        label: agentType ?? "Subagent",
                        startedAt: Date(),
                        phase: .quiet
                    ))
                }
            } else if let index = subagents.lastIndex(where: { $0.phase == .active }) {
                subagents[index].phase = .quiet
            }
            subagents = Array(subagents.suffix(16))
            activeSubagents = subagents.count { $0.phase == .active }
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Subagent finished")
            recordActivity("Subagent finished", phase: .quiet)
        case "PreToolUse":
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Using \(tool ?? "tool")")
            recordActivity("Using \(tool ?? "tool")", phase: .active)
        case "PostToolUse":
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Finished \(tool ?? "tool")")
            recordActivity("Finished \(tool ?? "tool")", phase: .quiet)
        case "PostToolUseFailure":
            detector.applyStructuredEvent(kind: kind, phase: .needsInput, excerpt: "Failed \(tool ?? "tool")")
            recordActivity("Failed \(tool ?? "tool")", phase: .needsInput)
        case "UserPromptSubmit", "turn/started":
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Thinking")
            recordActivity("Thinking", phase: .active)
        case "Stop", "turn/completed":
            detector.applyStructuredEvent(kind: kind, phase: .quiet, excerpt: "Ready")
            recordActivity("Ready", phase: .quiet)
        case "SessionEnd":
            detector.resetToShell()
            subagents.removeAll()
            activeSubagents = 0
            agentActivities.removeAll()
        case "SessionStart":
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Started")
            recordActivity("Started", phase: .active)
        default:
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: eventName)
            recordActivity(eventName, phase: .active)
        }
        lastActivity = Date()
        objectWillChange.send()
    }

    func cycleAgentKind() {
        objectWillChange.send()
        let next: AgentKind = switch detector.kind {
        case .shell: .claude
        case .claude: .codex
        case .codex: .shell
        }
        detector.overrideKind(next)
    }

    func setAgentKind(_ kind: AgentKind) {
        objectWillChange.send()
        detector.overrideKind(kind)
    }

    private func recordActivity(_ label: String, phase: AgentPhase) {
        let item = AgentActivityItem(id: UUID(), label: label, phase: phase, occurredAt: Date())
        if agentActivities.last?.label == label {
            agentActivities[agentActivities.count - 1] = item
        } else {
            agentActivities.append(item)
            agentActivities = Array(agentActivities.suffix(16))
        }
    }
}

@MainActor
final class TabModel: ObservableObject, Identifiable {
    let id: UUID
    let sessionID: UUID
    @Published var name: String
    @Published var layout: PaneLayout
    @Published var floatingPanes: [FloatingPanePlacement]
    @Published var splitRatios: [UUID: Double]

    init(
        id: UUID = UUID(),
        sessionID: UUID = UUID(),
        name: String,
        firstPane: UUID,
        floatingPanes: [FloatingPanePlacement] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.name = name
        self.layout = .pane(firstPane)
        self.floatingPanes = floatingPanes
        self.splitRatios = [:]
    }

    var allPaneIDs: [UUID] { layout.paneIDs + floatingPanes.map(\.paneID) }

    func balanceSplits() {
        _ = balance(layout)
    }

    @discardableResult
    private func balance(_ node: PaneLayout) -> Int {
        switch node {
        case .pane:
            return 1
        case .split(let id, _, let first, let second):
            let firstCount = balance(first)
            let secondCount = balance(second)
            splitRatios[id] = Double(firstCount) / Double(firstCount + secondCount)
            return firstCount + secondCount
        }
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [ConnectionProfile] = [] {
        didSet { persist() }
    }
    @Published private(set) var sshConfigHosts: [ConnectionProfile] = []
    @Published private(set) var recentHostKeys: [String] = []

    private let defaultsKey = "relay.connection-profiles.v1"
    private let recentDefaultsKey = "relay.recent-hosts.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {
            profiles = saved
        }
        recentHostKeys = UserDefaults.standard.stringArray(forKey: recentDefaultsKey) ?? []
        refreshSSHConfig()
    }

    func refreshSSHConfig() {
        sshConfigHosts = SSHConfigDiscovery.hosts().map(ConnectionProfile.sshConfigHost)
    }

    var connectableHosts: [ConnectionProfile] {
        var byKey: [String: ConnectionProfile] = [:]
        for profile in sshConfigHosts { byKey[profile.connectionKey] = profile }
        for profile in profiles where profile.kind == .ssh { byKey[profile.connectionKey] = profile }
        return byKey.values.sorted { lhs, rhs in
            let left = recentHostKeys.firstIndex(of: lhs.connectionKey) ?? Int.max
            let right = recentHostKeys.firstIndex(of: rhs.connectionKey) ?? Int.max
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func markUsed(_ profile: ConnectionProfile) {
        let key = profile.connectionKey
        recentHostKeys.removeAll { $0 == key }
        recentHostKeys.insert(key, at: 0)
        recentHostKeys = Array(recentHostKeys.prefix(8))
        UserDefaults.standard.set(recentHostKeys, forKey: recentDefaultsKey)
    }

    func save(_ profile: ConnectionProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    func remove(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

extension ConnectionProfile {
    var connectionKey: String {
        usesSSHConfig ? "config:\(host)" : "ssh:\(destination):\(port)"
    }
}
