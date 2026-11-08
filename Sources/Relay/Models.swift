import CryptoKit
import Foundation
import SwiftUI

enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

enum PaneDropPlacement: Equatable, Sendable {
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

/// Panes stacked in one layout slot. Only `selected` occupies the tab's
/// `layout`; the other members are hidden but keep their runtimes.
struct PaneStack: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var members: [UUID]
    var selected: UUID

    var isValid: Bool {
        members.count >= 2 && Set(members).count == members.count && members.contains(selected)
    }

    /// Split IDs for the legacy projection: stable per stack and position, so
    /// older readers keep their divider ratios and a projection compares exactly.
    static func projectionSplitID(stack: UUID, index: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("relay-stack-projection:\(stack.uuidString.lowercased()):\(index)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension PaneLayout {
    func replacingPane(_ target: UUID, with node: PaneLayout) -> PaneLayout {
        switch self {
        case .pane(let id):
            return id == target ? node : self
        case .split(let id, let axis, let first, let second):
            return .split(id: id, axis: axis, first: first.replacingPane(target, with: node),
                          second: second.replacingPane(target, with: node))
        }
    }

    /// Every pane tiled, each stack expanded into splits in member order.
    /// Older Relay versions read this and show every stacked pane.
    func legacyProjection(stacks: [PaneStack]) -> PaneLayout {
        stacks.reduce(self) { layout, stack in
            guard stack.isValid, layout.paneIDs.contains(stack.selected) else { return layout }
            let hidden = stack.members.filter { $0 != stack.selected }
            var node = PaneLayout.pane(stack.selected)
            for (index, member) in hidden.enumerated() {
                node = .split(id: PaneStack.projectionSplitID(stack: stack.id, index: index),
                              axis: .horizontal, first: node, second: .pane(member))
            }
            return layout.replacingPane(stack.selected, with: node)
        }
    }
}

struct FloatingPanePlacement: Codable, Equatable, Identifiable, Sendable {
    let paneID: UUID
    var originX: Double
    var originY: Double
    var width: Double
    var height: Double
    // Optional for backward-compatible decoding of existing workspaces.
    var minimized: Bool? = nil

    var isMinimized: Bool { minimized == true }

    var id: UUID { paneID }

    static func initial(paneID: UUID, index: Int) -> FloatingPanePlacement {
        let cascade = Double(index % 6) * 28
        return FloatingPanePlacement(
            paneID: paneID,
            originX: 56 + cascade,
            originY: 46 + cascade,
            width: 620,
            height: 410
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
        backend: .relay
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
            guard !requestedCommand.isEmpty else { return nil }
            // SSH command mode otherwise closes the PTY when the agent ends.
            // Run the configured command as a child, then enter the login shell.
            let bootstrap = "\"${SHELL:-/bin/sh}\" -lc " + ShellQuoting.quote(requestedCommand) +
                "; exec \"${SHELL:-/bin/sh}\" -il"
            return "exec /bin/sh -c " + ShellQuoting.quote(bootstrap)
        case .relay:
            return nil
        }
    }
}

enum AgentKind: String, Codable, CaseIterable, Sendable {
    case shell
    case claude
    case codex
    case other

    static func provider(_ name: String) -> AgentKind? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "relay": return nil
        case "shell": return .shell
        case "claude", "claude-code": return .claude
        case "codex", "codex-cli": return .codex
        default: return .other
        }
    }

    var usesNativePromptEditing: Bool { self == .claude || self == .codex }

    var label: String {
        switch self {
        case .shell: "Shell"
        case .claude: "Claude"
        case .codex: "Codex"
        case .other: "Other harness"
        }
    }

    var symbol: String {
        switch self {
        case .shell: "terminal"
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .other: "cpu"
        }
    }
}

/// The one set of words for a pane's state, used by the pane chrome, the
/// navigator, Go to pane and accessibility labels.
enum PaneDisplayState: CaseIterable, Equatable, Sendable {
    case working, idle, needsInput, exited, connecting, connectionLost

    var label: String {
        switch self {
        case .working: "Working"
        // Quiet output is all Relay observes; readiness is not confirmed.
        case .idle: "Idle"
        case .needsInput: "Needs input"
        case .exited: "Exited"
        case .connecting: "Connecting"
        case .connectionLost: "Connection lost"
        }
    }

    init(_ phase: AgentPhase) {
        switch phase {
        case .connecting: self = .connecting
        case .active: self = .working
        case .quiet: self = .idle
        case .needsInput: self = .needsInput
        case .exited: self = .exited
        }
    }
}

enum AgentPhase: String, Codable, CaseIterable, Sendable {
    case connecting
    case active
    case quiet
    case needsInput
    case exited

    var label: String { PaneDisplayState(self).label }

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
    case reconnecting(String)
    case waitingForNetwork(String)
    case disconnected(String)

    var label: String {
        switch self {
        case .connecting: PaneDisplayState.connecting.label
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .waitingForNetwork: "VPN required"
        case .disconnected: PaneDisplayState.connectionLost.label
        }
    }

    var symbol: String {
        switch self {
        case .connecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .connected: "checkmark.circle.fill"
        case .reconnecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .waitingForNetwork: "network.slash"
        case .disconnected: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .connecting: RelayTheme.blue
        case .connected: RelayTheme.mint
        case .reconnecting: RelayTheme.blue
        case .waitingForNetwork: RelayTheme.coral
        case .disconnected: RelayTheme.coral
        }
    }

    var errorMessage: String? {
        if case .disconnected(let message) = self { return message }
        return nil
    }

    var recoveryMessage: String? {
        switch self {
        case .reconnecting(let message), .waitingForNetwork(let message): message
        default: nil
        }
    }

    var isWaitingForNetwork: Bool {
        if case .waitingForNetwork = self { return true }
        return false
    }
}

struct SubagentActivity: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let label: String
    let startedAt: Date
    var provider: AgentKind = .shell
    var threadID: String? = nil
    var phase: AgentPhase = .active
    var completedAt: Date?
    var updates: [SubagentUpdate] = []
    // Peer messages alone are not evidence of parentage.
    var reportedChild: Bool? = nil
}

struct SubagentUpdate: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let message: String
    let occurredAt: Date
}

struct AgentActivityItem: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let label: String
    let phase: AgentPhase
    let occurredAt: Date
}

struct AgentResourceUsage: Equatable, Codable, Sendable {
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
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
            // Require a real agent banner. The bare word "anthropic" matched
            // ordinary shell output (grep anthropic, package.json, a path
            // under node_modules), flipping a plain shell to .claude — after
            // which forcesLocalSelection stayed true and click-to-place
            // synthesized arrow keys into bash. There is no raw-output path
            // back to .shell, so the match must be specific.
            if lower.contains("claude code") || lower.contains("claude.ai/code") {
                kind = .claude
            } else if lower.contains("openai codex") || lower.contains("codex cli") {
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

    @discardableResult
    mutating func markQuiet() -> Bool {
        guard phase == .active else { return false }
        phase = .quiet
        return true
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
    private static let agentTimestampFormatter = ISO8601DateFormatter()
    private static let fractionalAgentTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseAgentTimestamp(_ value: String) -> Date? {
        fractionalAgentTimestampFormatter.date(from: value) ?? agentTimestampFormatter.date(from: value)
    }
    let id: UUID
    let profile: ConnectionProfile
    let contentKind: PaneContentKind
    let requiresExistingWorker: Bool
    @Published var title: String
    @Published var customName: String?
    @Published var directory: String?
    /// A starting directory requested for a new worker. Not a claim about the
    /// shell's real cwd: `directory` changes only from observed cwd reports.
    let requestedStartDirectory: String?
    @Published var uploadProgress: RelayTransferProgress?
    var uploadProgressID: UUID?
    @Published var nativeConversationVisible = false
    @Published var lastCommandExitCode: Int?
    @Published var lastCommandDurationNanos: UInt64?
    @Published var programStatus = RelayProgramStatusSnapshot()
    private var programStatusAttention = RelayProgramStatusAttention()
    @Published var terminalProgressPercent: Int?
    @Published var terminalProgressState: String?
    /// How each submit's input reached this pane, from counts only (no content).
    var promptProvenance = RelayPromptProvenanceLog()
    private(set) var detector = AgentSignalDetector() {
        didSet {
            // A wait seen in terminal output; agent events name theirs in raiseWait.
            guard agentEventInProgress == nil, detector.phase == .needsInput, oldValue.phase != .needsInput else { return }
            terminalWaits &+= 1
            waitIdentity = "terminal:\(terminalWaits)"
        }
    }
    /// The latest wait, so a dismissed wait is told from a later one: the
    /// agent event that asked for the user, which a snapshot replaying that
    /// same event leaves unchanged, or a count of waits seen in terminal output.
    private(set) var waitIdentity: String?
    private var terminalWaits: UInt64 = 0
    /// The agent event being applied, by its replay-stable digest.
    private var agentEventInProgress: String?

    /// An agent event asking for the user: each one is a new wait.
    private func raiseWait(kind: AgentKind, excerpt: String) {
        detector.applyStructuredEvent(kind: kind, phase: .needsInput, excerpt: excerpt)
        if let event = agentEventInProgress { waitIdentity = "event:" + event }
    }
    private(set) var harnessIdentity: AgentHarnessIdentity?
    private(set) var reportedHarnessName: String?
    private(set) var lastActivity = Date()
    private(set) var lastCompletedAgentTurn: Date?
    private(set) var lastNetworkConversationTurn: NetworkConversationTurn?
    var activeSubagents: Int { subagents.count { $0.phase == .active } }
    private(set) var subagents: [SubagentActivity] = []
    private(set) var agentActivities: [AgentActivityItem] = []
    private(set) var taskPlans: [AgentTaskPlan] = []
    private(set) var agentResourceUsage: AgentResourceUsage?
    private(set) var agentProgressPercent: Int?
    private(set) var pendingAgentApprovals = 0
    private(set) var agentLastInputAt = Date.distantPast
    private(set) var agentInputRevision: UInt64 = 0
    @Published var connectionState: PaneConnectionState {
        didSet {
            guard oldValue != connectionState else { return }
            agentInputRevision &+= 1
            switch connectionState {
            case .connecting, .reconnecting, .waitingForNetwork:
                if case .connected = oldValue { supervisorReconnectSamples.append(Date()) }
            case .connected:
                RelayHostAccountSharing.shared.hostReady(profile)
            case .disconnected:
                break
            }
        }
    }
    @Published private(set) var remoteClientCount: Int?
    @Published var remoteExitCode: Int?
    @Published var artifacts: [PaneArtifact] = []
    @Published var richContents: [RelaySurfaceContent] = []
    @Published var durableSurfaceContents: [RelaySurfaceContent] = []
    @Published var durableSurfaceError: String?
    var presentedRichContents: [RelaySurfaceContent] { richContents + durableSurfaceContents }
    @Published var inlineRichRegions: [RelayInlineRichRegion] = []
    @Published var richContentRequested = false
    var richContentExplicit = false
    @Published var artifactError: String?
    private var dismissedArtifactIdentities: Set<String> = []
    /// The provider account this pane's agent was started in and the account
    /// the running agent reports. Part of the agent identity: restart, resume
    /// and recovery keep it, and Relay never changes it to resolve a mismatch.
    @Published private(set) var agentAccount: RelayPaneAgentAccountState?
    private(set) var previewRequest = UUID()
    private var previewTask: Task<Void, Never>?
    @Published var editorRequest: EditorOpenRequest?
    @Published var isRestoringTerminal = false
    @Published var hasTerminalSnapshot = false
    private var structuredAgentRunning: Bool?
    private var activeAgentRoots: [String: AgentKind] = [:]
    private var activeAgentRootObservations: [String: AgentProcessRootObservation] = [:]
    private var legacyRootReplayThroughCursor: UInt64?
    var networkAgentRoots: [String] { activeAgentRoots.keys.sorted() }
    private var seenAgentEventHashes: [Data: Date] = [:]
    private var seenAgentEventOrder: [(Data, Date)] = []
    private var conversationContext = TerminalConversationContextBuffer()
    private var agentMonitor: RelayHostAgentMonitorToken?
    private var agentEventCursor: UInt64 = 0
    private var agentPersistenceTask: Task<Void, Never>?
    private var agentUIRefreshTask: Task<Void, Never>?
    private var agentSnapshotReplayDepth = 0
    let remoteParentSessionID: String?
    private(set) var remoteWorkspaceSessionID: String?
    private(set) var remoteTabID: String?
    private var composerStorage: PaneComposerState?
    /// The agent composer lives with the pane, not its view, so moving,
    /// stacking or regrouping never loses typed text or in-flight uploads.
    var composerState: PaneComposerState {
        if let composerStorage { return composerStorage }
        let created = PaneComposerState()
        composerStorage = created
        return created
    }
    var composerStateIfCreated: PaneComposerState? { composerStorage }
    private var quietTask: Task<Void, Never>?
    private var supervisorOutputSamples: [(Date, Int)] = []
    private var supervisorReconnectSamples: [Date] = []
    lazy var runtime = TerminalRuntime(pane: self)
    lazy var editorRuntime = RemoteEditorRuntime(pane: self)
    var networkForegroundPID: pid_t? { runtime.networkForegroundPID }

    init(
        id: UUID = UUID(),
        profile: ConnectionProfile,
        contentKind: PaneContentKind = .terminal,
        requiresExistingWorker: Bool = false,
        remoteParentSessionID: String? = nil,
        editorRequest: EditorOpenRequest? = nil,
        customName: String? = nil,
        directory: String? = nil,
        startDirectory: String? = nil,
        savedAgentState: PersistedAgentPaneState? = nil
    ) {
        self.id = id
        self.profile = profile
        self.contentKind = contentKind
        self.requiresExistingWorker = requiresExistingWorker
        self.remoteParentSessionID = remoteParentSessionID
        self.editorRequest = editorRequest
        self.customName = customName
        self.directory = directory
        self.requestedStartDirectory = startDirectory
        self.title = contentKind == .editor ? "Editor" : profile.name
        self.remoteExitCode = nil
        self.connectionState = profile.backend == .relay
            ? .connecting
            : .connected
        dismissedArtifactIdentities = ArtifactDismissalStore.load(paneID: id)
        restoreAgentAccount(RelayPaneAccountStore.shared.load(paneID: id))
        // An editor has no agent: a saved phase would read as "Working" before it starts.
        if profile.backend == .relay, contentKind == .terminal,
           let saved = savedAgentState ?? AgentStateStore.shared.load(paneID: id) {
            agentEventCursor = saved.replayCursor
            if saved.hasCurrentProcessRootState {
                for root in saved.processRoots ?? [] where AgentKind.provider(root.observation.provider) == root.kind {
                    activeAgentRoots[root.id] = root.kind
                    activeAgentRootObservations[root.id] = root.observation
                }
            } else {
                legacyRootReplayThroughCursor = saved.cursor
            }
            subagents = saved.subagents
            agentActivities = saved.activities
            taskPlans = AgentTaskPlan.bounded(saved.plans ?? [])
            agentResourceUsage = saved.resourceUsage
            agentProgressPercent = saved.progressPercent
            pendingAgentApprovals = saved.pendingApprovals
            detector.applyStructuredEvent(kind: saved.kind, phase: saved.phase, excerpt: saved.summary)
            // Observers do not run during init: a restored wait takes its saved
            // identity, so it lists, can be dismissed and stays dismissed when a
            // reconnect replays its event; older saved state has none.
            if detector.phase == .needsInput { waitIdentity = saved.waitIdentity ?? "restored" }
            structuredAgentRunning = saved.kind == .shell ? false : true
        }
    }

    var kind: AgentKind { harnessIdentity?.kind ?? detector.kind }
    var harnessLabel: String { harnessIdentity?.label ?? (kind == .other ? reportedHarnessName ?? kind.label : kind.label) }
    var phase: AgentPhase { detector.phase }
    /// A live node connection does not mean this pane's terminal is running.
    /// Keep transport state intact for reconnect logic, but report the pane's
    /// lifecycle when an attached worker has exited or is still restoring.
    var connectionStatusLabel: String {
        if let editorStartLabel { return editorStartLabel }
        guard contentKind == .terminal, profile.backend == .relay,
              connectionState == .connected else { return connectionState.label }
        if phase == .exited { return "Exited" }
        // Agent detection can retain its initial phase after a successful
        // worker attachment. It is not evidence of transport startup.
        if isRestoringTerminal { return "Restoring" }
        return connectionState.label
    }
    /// An editor is created "connecting" but asks to connect only when its
    /// runtime starts; a start or reconnect in flight is reported as such.
    private var editorStartLabel: String? {
        guard contentKind == .editor else { return nil }
        if connectionState == .connecting { return connectionRequested ? "Starting" : "Not started" }
        // A start that failed before the editor was ever drawn did not lose a
        // connection the user saw; its banner offers Retry.
        if case .disconnected = connectionState, !editorViewShown { return "Not started" }
        return nil
    }
    /// Set once the editor's view has been drawn.
    var editorViewShown = false
    private var connectionRequested = false
    var recentConversationContext: [String] { conversationContext.lines }
    var displayName: String { customName ?? title }
    var activitySummary: String {
        if let editorStartLabel { return editorStartLabel }
        if let activity = agentActivities.last { return activity.label }
        return phase.label
    }

    func assignRemoteHierarchy(workspaceSessionID: UUID, tabID: UUID) {
        remoteWorkspaceSessionID = workspaceSessionID.uuidString.lowercased()
        remoteTabID = tabID.uuidString.lowercased()
    }

    func focus() {
        guard !RelayLaunchMode.isRunningTests else { return }
        switch contentKind {
        case .terminal: runtime.focus()
        case .editor: editorRuntime.focus()
        }
    }

    func recordCommandCompletion(exitCode: Int?, durationNanos: UInt64) {
        lastCommandExitCode = exitCode
        lastCommandDurationNanos = durationNanos
        // Shell integration reports completion after the foreground command
        // returns. Provider hooks can be absent on crashes or early CLI exits.
        // Restore presentation without closing or replacing the pane's PTY.
        activeAgentRoots.removeAll(keepingCapacity: true)
        activeAgentRootObservations.removeAll(keepingCapacity: true)
        subagents.removeAll(keepingCapacity: true)
        pendingAgentApprovals = 0
        agentProgressPercent = nil
        structuredAgentRunning = false
        detector.resetToShell()
        reconcileHarnessKind()
        nativeConversationVisible = false
        scheduleAgentStatePersistence()
    }

    func recordTerminalProgress(state: String?, percent: Int?) {
        guard terminalProgressState != state || terminalProgressPercent != percent else { return }
        terminalProgressState = state
        terminalProgressPercent = percent
    }

    /// Whether this pane asked for agent events and kernel harness identity.
    private(set) var agentMonitoringRequested = false
    /// Whether this pane holds a live subscription to a host agent monitor.
    var isAgentMonitored: Bool { agentMonitor != nil }
    /// How often the host's agent event observer attached for this pane.
    private(set) var agentObserverAttachments = 0

    /// `monitor` defaults to the shared one, which tests never reach.
    func startAgentMonitoring(monitor: RelayHostAgentMonitor? = nil) {
        guard agentMonitor == nil,
              RelayAgentMonitoringAdmission.allows(profile: profile, contentKind: contentKind) else { return }
        agentMonitoringRequested = true
        guard monitor != nil || !RelayLaunchMode.isRunningTests else { return }
        agentMonitor = (monitor ?? RelayHostAgentMonitor.shared).subscribe(
            profile: profile,
            sessionID: id.uuidString.lowercased(),
            lastEventSequence: agentEventCursor,
            onEvent: { [weak self] data in self?.receivedAgentEvent(data) },
            onObserverAttached: { [weak self] in self?.agentObserverAttached() },
            onHarness: { [weak self] identity in self?.receivedHarnessIdentity(identity) }
        )
    }

    /// The host's agent event observer (re)attached. That is no evidence
    /// about this pane's terminal route, so it leaves the exit code and the
    /// connection state alone; only `connected()` from the terminal or editor
    /// runtime changes them. Events may have been missed, so re-identify.
    func agentObserverAttached() {
        agentObserverAttachments += 1
        agentMonitor?.expectHarnessChange()
    }

    func stopAgentMonitoring() {
        agentMonitoringRequested = false
        agentMonitor?.stop()
        agentMonitor = nil
    }

    func stopRuntime() {
        agentPersistenceTask?.cancel()
        agentPersistenceTask = nil
        agentUIRefreshTask?.cancel()
        agentUIRefreshTask = nil
        persistAgentStateNow()
        stopAgentMonitoring()
        RelayAgentAccountDirectory.shared.untrackObservedPane(self)
        guard !RelayLaunchMode.isRunningTests else { return }
        switch contentKind {
        case .terminal: runtime.stop()
        case .editor: editorRuntime.stop()
        }
    }

    func restartRuntime() {
        guard !RelayLaunchMode.isRunningTests else { return }
        switch contentKind {
        case .terminal: runtime.restart()
        case .editor: editorRuntime.restart()
        }
    }

    func received(_ text: String) {
        if connectionState != .connected { connectionState = .connected }
        let previousKind = detector.kind
        let previousPhase = detector.phase
        detector.ingest(text, detectAgentKind: harnessIdentity == nil && structuredAgentRunning != false)
        if previousKind != .shell || detector.kind != .shell {
            conversationContext.ingest(text)
        }
        lastActivity = Date()
        supervisorOutputSamples.append((lastActivity, text.utf8.count))
        pruneSupervisorSamples(now: lastActivity)
        if previousKind != detector.kind || previousPhase != detector.phase {
            objectWillChange.send()
        }
        if previousKind != detector.kind, agentMonitor != nil {
            RelayHostAgentMonitor.shared.expectHarnessChange(profile: profile, sessionID: id.uuidString.lowercased())
        }
        // Shell TUIs can repaint many times per second. They do not need an
        // agent quiet timer, and repeatedly cancelling/creating one forces
        // otherwise unrelated SwiftUI updates. Structured agent events own
        // their own lifecycle; keep this fallback only for legacy raw-output
        // detection.
        let needsLegacyQuietTimer = structuredAgentRunning == nil &&
            detector.kind != .shell && detector.phase == .active
        guard needsLegacyQuietTimer else {
            quietTask?.cancel()
            quietTask = nil
            return
        }
        quietTask?.cancel()
        quietTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard let self, !Task.isCancelled else { return }
            self.quietTask = nil
            if self.detector.markQuiet() {
                self.objectWillChange.send()
            }
        }
    }

    func supervisorTelemetry(now: Date = Date()) -> RelaySupervisorTelemetry {
        pruneSupervisorSamples(now: now)
        let reachable: Bool
        if case .connected = connectionState { reachable = true } else { reachable = false }
        let tokens = agentResourceUsage.map {
            $0.inputTokens + $0.cachedInputTokens + $0.outputTokens
        }
        return RelaySupervisorTelemetry(
            identity: RelaySupervisedSessionID(
                paneID: id,
                sessionID: remoteWorkspaceSessionID ?? remoteParentSessionID ?? id.uuidString.lowercased(),
                generation: agentInputRevision
            ),
            observedAt: now,
            hasActiveRequest: detector.phase == .active,
            isReachable: reachable,
            outputBytesPerMinute: supervisorOutputSamples.reduce(0) { $0 + $1.1 },
            retriesInWindow: 0,
            secondsSinceProgress: max(0, now.timeIntervalSince(lastActivity)),
            contextTokens: tokens,
            contextLimit: nil,
            restartsInWindow: supervisorReconnectSamples.count,
            hasDurableCheckpoint: lastCompletedAgentTurn != nil
        )
    }

#if DEBUG
    func installSupervisorAcceptanceFixture(now: Date = Date()) {
        guard RelaySupervisorAcceptanceFixture.isEnabled,
              contentKind == .terminal,
              profile.backend == .relay else { return }
        structuredAgentRunning = true
        lastCompletedAgentTurn = now
        lastActivity = now
        supervisorOutputSamples = [(now, 200 * 1_024 * 1_024)]
        detector.applyStructuredEvent(
            kind: .codex,
            phase: .active,
            excerpt: "Disposable supervisor acceptance fixture"
        )
        objectWillChange.send()
    }
#endif

    private func pruneSupervisorSamples(now: Date) {
        supervisorOutputSamples.removeAll { $0.0 < now.addingTimeInterval(-60) }
        supervisorReconnectSamples.removeAll { $0 < now.addingTimeInterval(-600) }
    }

    func dismissArtifact(_ id: UUID) {
        if let artifact = artifacts.first(where: { $0.id == id }), !artifact.userRequested {
            dismissedArtifactIdentities.insert(artifact.contentIdentity)
            ArtifactDismissalStore.record(artifact.contentIdentity, paneID: self.id)
        }
        artifacts.removeAll { $0.id == id }
        invalidatePreviewRequest()
    }

    func receivedArtifact(path: String, data: Data) {
        let artifact = PaneArtifact(remotePath: path, data: data)
        guard RelayPreferences.shared.showArtifactPreviews,
              !dismissedArtifactIdentities.contains(artifact.contentIdentity),
              !artifacts.contains(where: { $0.contentIdentity == artifact.contentIdentity }) else { return }
        // The pane presents one generated asset at a time. Retaining an
        // invisible stack made Close reveal the previous image immediately,
        // which looked as if the button had failed.
        artifacts = [artifact]
        artifactError = nil
    }

    /// A preview the user asked for is shown even when automatic previews are off or the
    /// same content was dismissed earlier, and closing it records no dismissal.
    func presentRequestedArtifact(_ artifact: PaneArtifact) {
        invalidatePreviewRequest()
        show(requested: artifact)
    }

    /// Latest request wins: every explicit preview (and Close) supersedes earlier loads,
    /// so a slow earlier file can never replace a later one when it finishes.
    @discardableResult
    func openPreview(_ load: @escaping @Sendable () async -> PaneArtifact) -> Task<Void, Never> {
        invalidatePreviewRequest()
        let request = previewRequest
        let task = Task { @MainActor [weak self] in
            let artifact = await load()
            guard let self, !Task.isCancelled, self.previewRequest == request else { return }
            if let failure = artifact.failure {
                RelayDiagnostics.shared.record(category: "artifact", name: "open_failed", details: [
                    "path": artifact.remotePath, "message": failure,
                ])
            }
            self.show(requested: artifact)
        }
        previewTask = task
        return task
    }

    private func invalidatePreviewRequest() {
        previewTask?.cancel(); previewTask = nil
        previewRequest = UUID()
    }

    private func show(requested artifact: PaneArtifact) {
        var artifact = artifact
        artifact.userRequested = true
        artifacts = [artifact]
        artifactError = nil
    }

    func exited(exitCode: Int? = nil) {
        remoteExitCode = exitCode
        detector.markExited()
    }

    @Published var terminalInputTransportMessage: String?
    @Published var terminalInputDraftMessage: String?
    var terminalInputMessage: String? { terminalInputDraftMessage ?? terminalInputTransportMessage }

    func connected() {
        remoteExitCode = nil
        RelayHostAgentMonitor.shared.expectHarnessChange(profile: profile, sessionID: id.uuidString.lowercased())
        if detector.phase == .connecting {
            detector.applyStructuredEvent(kind: detector.kind, phase: .active, excerpt: "Terminal connected")
        }
        connectionState = .connected
    }

    func recordRemoteClientCount(_ count: Int) {
        remoteClientCount = max(0, count)
    }

    func beginTerminalRestore() {
        guard contentKind == .terminal else { return }
        isRestoringTerminal = true
    }

    func showTerminalSnapshot() {
        guard contentKind == .terminal else { return }
        hasTerminalSnapshot = true
        isRestoringTerminal = false
    }

    func finishTerminalRestore() {
        hasTerminalSnapshot = true
        isRestoringTerminal = false
    }

    func reconnecting() {
        connectionRequested = true
        remoteExitCode = nil
        connectionState = .connecting
        detector = AgentSignalDetector()
    }

    func connectionInterrupted(_ message: String) {
        connectionState = .reconnecting(message)
    }

    func waitingForNetwork(_ message: String) {
        connectionState = .waitingForNetwork(message)
    }

    func disconnected(_ message: String) {
        connectionState = .disconnected(message)
        detector.markExited()
    }

    /// The content-free fingerprint of a UserPromptSubmit hook.
    static func providerPromptFingerprint(_ event: [String: Any]) -> RelayPromptFingerprint? {
        if let length = (event["prompt_length"] as? NSNumber)?.intValue, let prefix = event["prompt_sha256_prefix"] as? String {
            return RelayPromptFingerprint(length: length, sha256Prefix: prefix)
        }
        return (event["prompt"] as? String).map(RelayPromptFingerprint.init)
    }

    func userEnteredInput() {
        agentLastInputAt = Date()
        agentInputRevision &+= 1
        detector.acknowledgeInput()
    }

    func receivedAgentEvent(_ data: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agentName = envelope["agent"] as? String,
              let event = envelope["event"] as? [String: Any] else { return }
        let priorCursor = agentEventCursor
        if let cursor = (envelope["relay_event_seq"] as? NSNumber)?.uint64Value {
            agentEventCursor = max(agentEventCursor, cursor)
        }
        let incomingEventName = (event["hook_event_name"] as? String) ?? (event["type"] as? String)
        let outerEvent = agentEventInProgress
        defer {
            reconcileHarnessKind()
            agentEventInProgress = outerEvent
            if agentSnapshotReplayDepth == 0, incomingEventName != "RelayStateSnapshot",
               let through = legacyRootReplayThroughCursor,
               let sequence = (envelope["relay_event_seq"] as? NSNumber)?.uint64Value,
               sequence >= through {
                legacyRootReplayThroughCursor = nil
            }
            scheduleAgentStatePersistence()
        }
        if incomingEventName == "RelayStateSnapshot" {
            if legacyRootReplayThroughCursor != nil,
               let sequence = (envelope["relay_event_seq"] as? NSNumber)?.uint64Value {
                legacyRootReplayThroughCursor = sequence
                if sequence == 0 && (event["events"] as? [[String: Any]] ?? []).isEmpty {
                    legacyRootReplayThroughCursor = nil
                }
            }
            subagents.removeAll(keepingCapacity: true)
            activeAgentRoots.removeAll(keepingCapacity: true)
            activeAgentRootObservations.removeAll(keepingCapacity: true)
            detector.resetToShell()
            structuredAgentRunning = false
            nativeConversationVisible = false
            pendingAgentApprovals = 0
            agentProgressPercent = nil
            seenAgentEventHashes.removeAll(keepingCapacity: true)
            seenAgentEventOrder.removeAll(keepingCapacity: true)
            agentSnapshotReplayDepth += 1
            for embedded in event["events"] as? [[String: Any]] ?? [] {
                guard JSONSerialization.isValidJSONObject(embedded),
                      let encoded = try? JSONSerialization.data(withJSONObject: embedded) else { continue }
                receivedAgentEvent(encoded)
            }
            agentSnapshotReplayDepth -= 1
            scheduleAgentUIRefresh()
            return
        }
        var normalizedEnvelope = envelope
        normalizedEnvelope.removeValue(forKey: "relay_event_seq")
        normalizedEnvelope.removeValue(forKey: "relay_recorded_at")
        if let normalized = try? JSONSerialization.data(withJSONObject: normalizedEnvelope, options: [.sortedKeys]) {
            let digest = Data(SHA256.hash(data: normalized))
            let now = Date()
            if let previous = seenAgentEventHashes[digest], now.timeIntervalSince(previous) < 1 { return }
            agentEventInProgress = digest.base64EncodedString()
            seenAgentEventHashes[digest] = now
            seenAgentEventOrder.append((digest, now))
            let expiry = now.addingTimeInterval(-1)
            let retained = seenAgentEventOrder.drop { $0.1 < expiry }
            if retained.startIndex != seenAgentEventOrder.startIndex || seenAgentEventOrder.count > 4_096 {
                let keep = Array(retained.suffix(4_096))
                seenAgentEventHashes = Dictionary(uniqueKeysWithValues: keep.map { ($0.0, $0.1) })
                seenAgentEventOrder = keep
            }
        }
        if agentSnapshotReplayDepth == 0,
           ((envelope["relay_event_seq"] as? NSNumber)?.uint64Value ?? UInt64.max) > priorCursor {
            RelayRecoveryStore.shared.recordAgentEvent(paneID: id, profile: profile, event: event)
        }
        if agentName == "relay", event["type"] as? String == "peer_message_delivered" {
            // relayd wrote a peer message to this pane's native inbox, outside the
            // desktop key path: programmatic input. Content-free; never replayed.
            guard agentSnapshotReplayDepth == 0,
                  ((envelope["relay_event_seq"] as? NSNumber)?.uint64Value ?? UInt64.max) > priorCursor,
                  let messageID = event["message_id"] as? String else { return }
            promptProvenance.daemonDelivery(messageID: messageID, at: Date())
            return
        }
        if agentName == "relay",
           event["type"] as? String == "open_file",
           let paths = event["paths"] as? [String],
           !paths.isEmpty {
            // Commands are not agent state: replaying an old request must not
            // reopen a closed editor or steal focus on app launch/reconnect.
            guard agentSnapshotReplayDepth == 0,
                  ((envelope["relay_event_seq"] as? NSNumber)?.uint64Value ?? UInt64.max) > priorCursor,
                  Self.isFreshEditorRequest(envelope, now: Date()) else { return }
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
        guard let kind = AgentKind.provider(agentName) else { return }
        if kind == .other { reportedHarnessName = AgentHarnessIdentity.label(for: agentName) }
        let providerIdentity = kind == .other ? agentName.lowercased() : kind.rawValue
        let eventName = (event["hook_event_name"] as? String)
            ?? (event["type"] as? String)
            ?? "Agent event"
        let tool = event["tool_name"] as? String
        let agentType = event["agent_type"] as? String
        let threadID = event["thread_id"] as? String
        let message = (event["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let occurredAt = Self.agentEventDate(event: event, envelope: envelope)
        if let plan = AgentTaskPlan.decode(event: event, provider: kind.rawValue, now: occurredAt)
            ?? AgentTaskPlan.applyingTask(event: event, provider: kind.rawValue, plans: taskPlans, now: occurredAt) {
            if let index = taskPlans.firstIndex(where: { $0.id == plan.id }) {
                if taskPlans[index].updatedAt <= plan.updatedAt { taskPlans[index] = plan }
            } else {
                taskPlans.append(plan)
            }
            taskPlans = AgentTaskPlan.bounded(taskPlans)
        }
        let subagentID = (event["agent_id"] as? String)
            ?? (event["subagent_id"] as? String)
            ?? (event["thread_id"] as? String)
        let notificationType = event["notification_type"] as? String
        let fromPeerID = event["from_peer_id"] as? String
        let toPeerID = event["to_peer_id"] as? String
        let rootID = (event["root_id"] as? String) ?? providerIdentity
        let intelligenceSourceID = (event["event_id"] as? String)
            ?? (envelope["relay_event_seq"] as? NSNumber).map { "relay-seq:\($0.uint64Value)" }

        if eventName != "SessionEnd" {
            structuredAgentRunning = true
        }

        switch eventName {
        case "PermissionRequest":
            pendingAgentApprovals += 1
            raiseWait(kind: kind, excerpt: "Approval: \(tool ?? "permission requested")")
            recordActivity("Approval needed for \(tool ?? "a tool")", phase: .needsInput)
            announceAgentAttention("Approval needed for \(tool ?? "an agent tool")")
            recordIntelligenceEvent(
                provider: kind, agentID: subagentID ?? rootID, eventKind: .attention,
                title: "Approval needed for \(tool ?? "an agent tool")",
                detail: message ?? "The agent is waiting for permission before it can continue.",
                occurredAt: occurredAt, sourceID: intelligenceSourceID, alert: .needsInput
            )
        case "Notification" where notificationType == "permission_prompt" || notificationType == "idle_prompt":
            raiseWait(kind: kind, excerpt: event["message"] as? String ?? PaneDisplayState.needsInput.label)
            recordActivity(event["message"] as? String ?? PaneDisplayState.needsInput.label, phase: .needsInput)
            announceAgentAttention(event["message"] as? String ?? "Agent needs input")
            recordIntelligenceEvent(
                provider: kind, agentID: subagentID ?? rootID, eventKind: .attention,
                title: "\(kind.label) needs your input",
                detail: message ?? "The agent is waiting for input.", occurredAt: occurredAt,
                // An idle prompt follows a finished turn, which already alerted.
                sourceID: intelligenceSourceID, alert: notificationType == "permission_prompt" ? .needsInput : nil
            )
        case "SubagentStart":
            let identifier = subagentID ?? UUID().uuidString
            subagents.removeAll { $0.id == identifier }
            subagents.append(SubagentActivity(
                id: identifier,
                label: agentType ?? "Subagent",
                startedAt: occurredAt,
                provider: kind,
                threadID: threadID,
                phase: .active,
                reportedChild: true
            ))
            pruneCompletedSubagents()
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Subagent: \(agentType ?? "working")")
            recordActivity("Started \(agentType ?? "subagent")", phase: .active)
        case "SubagentStop":
            if let subagentID {
                if let index = subagents.firstIndex(where: { $0.id == subagentID }) {
                    subagents[index].phase = .quiet
                    subagents[index].completedAt = occurredAt
                    if let message, !message.isEmpty {
                        appendSubagentUpdate(message, occurredAt: occurredAt, at: index)
                    }
                } else {
                    subagents.append(SubagentActivity(
                        id: subagentID,
                        label: agentType ?? "Subagent",
                        startedAt: occurredAt,
                        provider: kind,
                        threadID: threadID,
                        phase: .quiet,
                        completedAt: occurredAt,
                        updates: message.map { [SubagentUpdate(id: UUID(), message: $0, occurredAt: occurredAt)] } ?? []
                    ))
                }
            } else if let index = subagents.lastIndex(where: { $0.phase == .active }) {
                subagents[index].phase = .quiet
                subagents[index].completedAt = occurredAt
                if let message, !message.isEmpty {
                    appendSubagentUpdate(message, occurredAt: occurredAt, at: index)
                }
            }
            pruneCompletedSubagents()
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Subagent finished")
            recordActivity("Subagent finished", phase: .quiet)
            let completedLabel = agentType ?? subagentID ?? "Subagent"
            recordIntelligenceEvent(
                provider: kind, agentID: subagentID, eventKind: .completion,
                title: "\(AgentLabelFormatter.humanize(completedLabel)) finished",
                detail: message ?? "The subagent completed its task.", occurredAt: occurredAt,
                sourceID: intelligenceSourceID
            )
        case "SubagentUpdate":
            if let subagentID,
               let index = subagents.firstIndex(where: { $0.id == subagentID }),
               let message, !message.isEmpty {
                appendSubagentUpdate(message, occurredAt: occurredAt, at: index)
                detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: subagents[index].label)
            }
        case "PeerMessage":
            let rootNames: Set<String> = ["root", "/root", "claude-root", "codex-root"]
            var peerIDs: [String] = []
            for candidate in [fromPeerID, toPeerID].compactMap({ $0 }) where !rootNames.contains(candidate) {
                if !peerIDs.contains(candidate) { peerIDs.append(candidate) }
            }
            if peerIDs.isEmpty, let fallback = fromPeerID ?? toPeerID { peerIDs = [fallback] }
            for peerID in peerIDs {
                let peerLabel = AgentLabelFormatter.pathComponent(peerID)
                let index: Int
                if let existing = subagents.firstIndex(where: { $0.id == peerID || $0.threadID == peerID }) {
                    index = existing
                } else {
                    subagents.append(SubagentActivity(
                        id: peerID, label: peerLabel, startedAt: occurredAt,
                        provider: kind, threadID: peerID, phase: .active
                    ))
                    index = subagents.count - 1
                }
                if let message, !message.isEmpty {
                    let otherID = peerID == fromPeerID ? toPeerID : fromPeerID
                    let otherLabel = otherID.map(AgentLabelFormatter.pathComponent) ?? "peer"
                    let direction = peerID == fromPeerID ? "Sent to \(otherLabel)" : "Received from \(otherLabel)"
                    appendSubagentUpdate("\(direction)\n\(message)", occurredAt: occurredAt, at: index)
                }
            }
            let summary = peerIDs.last.map(AgentLabelFormatter.pathComponent) ?? "peer"
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Peer: \(summary)")
            recordActivity("Peer message · \(summary)", phase: .active)
            let from = fromPeerID ?? rootID
            let to = toPeerID ?? "peer"
            recordIntelligenceEvent(
                provider: kind, agentID: subagentID ?? threadID, eventKind: .peer,
                title: "\(AgentLabelFormatter.humanize(from)) → \(AgentLabelFormatter.humanize(to))",
                detail: message ?? "Peer coordination event", occurredAt: occurredAt,
                fromPeerID: fromPeerID, toPeerID: toPeerID, sourceID: intelligenceSourceID
            )
        case "PeerInteraction":
            let label = agentType ?? subagentID ?? "peer"
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Contacted \(label)")
            recordActivity("Contacted \(label)", phase: .active)
        case "PreToolUse":
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Using \(tool ?? "tool")")
            recordActivity("Using \(tool ?? "tool")", phase: .active)
        case "PostToolUse":
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Finished \(tool ?? "tool")")
            recordActivity("Finished \(tool ?? "tool")", phase: .quiet)
        case "PostToolUseFailure":
            raiseWait(kind: kind, excerpt: "Failed \(tool ?? "tool")")
            recordActivity("Failed \(tool ?? "tool")", phase: .needsInput)
            recordIntelligenceEvent(
                provider: kind, agentID: subagentID ?? rootID, eventKind: .failure,
                title: "\(tool ?? "Agent tool") failed",
                detail: message ?? "The tool failed and may need attention.", occurredAt: occurredAt,
                sourceID: intelligenceSourceID, alert: .toolFailed
            )
        case "UserPromptSubmit", "turn/started":
            pendingAgentApprovals = 0
            if eventName == "UserPromptSubmit", agentSnapshotReplayDepth == 0,
               ((envelope["relay_event_seq"] as? NSNumber)?.uint64Value ?? UInt64.max) > priorCursor,
               let fingerprint = Self.providerPromptFingerprint(event) {
                // relayd reduced the prompt to a length, a hash prefix and any
                // peer-message ID; a raw prompt is reduced here and dropped.
                promptProvenance.providerPrompt(fingerprint, peerMessageID: event["prompt_peer_message_id"] as? String,
                    promptSource: (event["prompt_source"] as? String) ?? (event["promptSource"] as? String), at: Date())
            }
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Thinking")
            recordActivity("Thinking", phase: .active)
        case "Stop", "turn/completed":
            RelayRotationTurnObserver.shared.observe(hostID: profile.id.uuidString.lowercased(),
                paneID: id.uuidString.lowercased(), client: kind.rawValue,
                sessionID: threadID ?? (event["session_id"] as? String), eventName: eventName,
                eventSequence: (envelope["relay_event_seq"] as? NSNumber)?.uint64Value,
                priorCursor: priorCursor, replayDepth: agentSnapshotReplayDepth)
            if lastNetworkConversationTurn == nil || lastNetworkConversationTurn!.occurredAt <= occurredAt {
                lastNetworkConversationTurn = NetworkConversationTurn(occurredAt: occurredAt, speaker: kind.label,
                    text: message.flatMap { $0.isEmpty ? nil : String($0.prefix(4096)) })
            }
            lastCompletedAgentTurn = max(lastCompletedAgentTurn ?? occurredAt, occurredAt)
            pendingAgentApprovals = 0
            agentProgressPercent = nil
            detector.applyStructuredEvent(kind: kind, phase: .quiet, excerpt: PaneDisplayState.idle.label)
            recordActivity(PaneDisplayState.idle.label, phase: .quiet)
            recordIntelligenceEvent(
                provider: kind, agentID: subagentID ?? rootID, eventKind: .completion,
                title: "\(kind.label) completed a turn",
                detail: message ?? "The agent finished and is ready.", occurredAt: occurredAt,
                sourceID: intelligenceSourceID, alert: .done
            )
        case "AgentProgress":
            agentProgressPercent = (event["progress_percent"] as? NSNumber)?.intValue
            let label = agentProgressPercent.map { "Progress · \($0)%" } ?? "Progress update"
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: label)
            recordActivity(label, phase: .active)
        case "ResourceUsage":
            agentResourceUsage = AgentResourceUsage(
                inputTokens: (event["input_tokens"] as? NSNumber)?.intValue ?? 0,
                cachedInputTokens: (event["cached_input_tokens"] as? NSNumber)?.intValue ?? 0,
                outputTokens: (event["output_tokens"] as? NSNumber)?.intValue ?? 0
            )
            recordActivity("Usage updated", phase: detector.phase)
        case "ArtifactUpdate":
            let artifactType = event["artifact_type"] as? String ?? "artifact"
            recordActivity("Updated \(artifactType)", phase: .active)
            recordIntelligenceEvent(
                provider: kind, agentID: subagentID ?? rootID, eventKind: .artifact,
                title: "Updated \(artifactType)",
                detail: message ?? (event["path"] as? String ?? "Agent artifact updated"), occurredAt: occurredAt,
                sourceID: intelligenceSourceID
            )
        case "ThreadStatus":
            let status = event["status"] as? String ?? "updated"
            let terminalStatus = ["idle", "notLoaded", "not_loaded"].contains(status)
            detector.applyStructuredEvent(kind: kind, phase: terminalStatus ? .quiet : .active, excerpt: status)
            recordActivity("Thread \(status)", phase: terminalStatus ? .quiet : .active)
        case "SessionEnd":
            pendingAgentApprovals = 0
            agentProgressPercent = nil
            if AgentProcessRootLifecycle.canRetire(activeAgentRootObservations[rootID],
                sequence: (envelope["relay_event_seq"] as? NSNumber)?.uint64Value ?? 0,
                occurredAt: occurredAt) {
                activeAgentRoots.removeValue(forKey: rootID)
                activeAgentRootObservations.removeValue(forKey: rootID)
            }
            for legacyRoot in AgentProcessRootLifecycle.legacyEndedRoots(rootID: rootID,
                provider: providerIdentity, source: event["source"] as? String,
                sequence: (envelope["relay_event_seq"] as? NSNumber)?.uint64Value ?? 0,
                occurredAt: occurredAt, observations: activeAgentRootObservations) {
                activeAgentRoots.removeValue(forKey: legacyRoot)
                activeAgentRootObservations.removeValue(forKey: legacyRoot)
            }
            let providerStillRunning = activeAgentRoots.values.contains(kind)
            if !providerStillRunning {
                subagents.removeAll { $0.provider == kind }
            }
            if providerStillRunning {
                detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: PaneDisplayState.working.label)
                structuredAgentRunning = true
            } else if let remaining = activeAgentRoots.values.first {
                detector.applyStructuredEvent(kind: remaining, phase: .active, excerpt: PaneDisplayState.working.label)
                structuredAgentRunning = true
            } else {
                detector.resetToShell()
                structuredAgentRunning = false
                nativeConversationVisible = false
            }
            // A second, short-lived root of the same provider (a version
            // check, a hook's `claude -p`) must not label the pane's running
            // conversation as ended: on dandy-07 (2026-10-30) a 1 s root left
            // 20 live Claude panes reading "Claude session ended".
            if activeAgentRoots.isEmpty {
                recordActivity("\(kind.label) session ended", phase: .quiet)
            }
            recordIntelligenceEvent(
                provider: kind, agentID: rootID, eventKind: .session,
                title: "\(kind.label) session ended",
                detail: message ?? "The agent process exited; its activity history remains available.",
                occurredAt: occurredAt, sourceID: intelligenceSourceID
            )
        case "SessionStart":
            activeAgentRoots[rootID] = kind
            activeAgentRootObservations[rootID] = .init(provider: providerIdentity, source: event["source"] as? String,
                sequence: (envelope["relay_event_seq"] as? NSNumber)?.uint64Value ?? 0,
                occurredAt: occurredAt)
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: "Started")
            recordActivity("Started", phase: .active)
        default:
            detector.applyStructuredEvent(kind: kind, phase: .active, excerpt: eventName)
            recordActivity(eventName, phase: .active)
        }
        lastActivity = Date()
        let urgent = eventName == "PermissionRequest" || eventName == "PostToolUseFailure" ||
            eventName == "SessionEnd" ||
            (eventName == "Notification" &&
             (notificationType == "permission_prompt" || notificationType == "idle_prompt"))
        scheduleAgentUIRefresh(immediate: urgent && agentSnapshotReplayDepth == 0)
    }

    static func isFreshEditorRequest(_ envelope: [String: Any], now: Date) -> Bool {
        guard let stamp = envelope["relay_recorded_at"] as? String,
              let date = parseAgentTimestamp(stamp) else { return false }
        // rcode is an interactive action, not a durable task. Permit modest
        // clock skew, but never execute historical commands from the journal.
        let age = now.timeIntervalSince(date)
        return age >= -30 && age <= 30
    }

    private func scheduleAgentStatePersistence() {
        guard agentPersistenceTask == nil else { return }
        agentPersistenceTask = Task { @MainActor [weak self] in
            let delay = RelayApplicationActivityState.allowsContinuousUpdates ? 500 : 2_000
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.agentPersistenceTask = nil
            self.persistAgentStateNow()
        }
    }

    private func scheduleAgentUIRefresh(immediate: Bool = false) {
        if immediate {
            agentUIRefreshTask?.cancel()
            agentUIRefreshTask = Task { @MainActor [weak self] in
                // Even urgent status must not publish synchronously from a
                // SwiftUI callback. One actor turn is imperceptible to the
                // user and prevents re-entrant AttributeGraph updates.
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.agentUIRefreshTask = nil
                self.objectWillChange.send()
            }
            return
        }
        guard agentUIRefreshTask == nil else { return }
        agentUIRefreshTask = Task { @MainActor [weak self] in
            let delay = RelayApplicationActivityState.allowsContinuousUpdates ? 80 : 1_000
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.agentUIRefreshTask = nil
            self.objectWillChange.send()
        }
    }

    private func persistAgentStateNow() {
        guard profile.backend == .relay else { return }
        AgentStateStore.shared.save(
            PersistedAgentPaneState(
                plans: taskPlans,
                processRootIdentityVersion: legacyRootReplayThroughCursor == nil ? 1 : nil,
                processRoots: activeAgentRoots.keys.sorted().compactMap { id in
                    guard let kind = activeAgentRoots[id], let observation = activeAgentRootObservations[id] else { return nil }
                    return PersistedAgentProcessRoot(id: id, kind: kind, observation: observation)
                },
                // Terminal waits are counted per run, so only an event's identity is kept.
                waitIdentity: waitIdentity?.hasPrefix("event:") == true ? waitIdentity : nil,
                cursor: agentEventCursor,
                kind: kind,
                phase: phase,
                summary: activitySummary,
                subagents: subagents,
                activities: agentActivities,
                resourceUsage: agentResourceUsage,
                progressPercent: agentProgressPercent,
                pendingApprovals: pendingAgentApprovals
            ),
            paneID: id
        )
    }

    func cycleAgentKind() {
        let next: AgentKind = switch detector.kind {
        case .shell: .claude
        case .claude: .codex
        case .codex: .shell
        case .other: .shell
        }
        setAgentKind(next)
    }

    func setAgentKind(_ kind: AgentKind) {
        objectWillChange.send()
        harnessIdentity = nil
        reportedHarnessName = nil
        detector.overrideKind(kind)
        if contentKind == .terminal, !RelayLaunchMode.isRunningTests {
            runtime.agentKindDidChange(kind)
        }
    }

    func receivedHarnessIdentity(_ identity: AgentHarnessIdentity) {
        guard identity.paneID == id, identity.kind != nil else { return }
        let previousKind = kind
        let changed = harnessIdentity != identity
        harnessIdentity = identity
        reconcileHarnessKind()
        if changed { objectWillChange.send() }
        if previousKind != kind, contentKind == .terminal, !RelayLaunchMode.isRunningTests {
            runtime.agentKindDidChange(kind)
        }
        if changed { scheduleAgentStatePersistence() }
    }

    private func reconcileHarnessKind() {
        guard let observed = harnessIdentity?.kind else { return }
        detector.overrideKind(observed)
        structuredAgentRunning = observed != .shell
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

    private func recordIntelligenceEvent(
        provider: AgentKind,
        agentID: String?,
        eventKind: AgentInboxEventKind,
        title: String,
        detail: String,
        occurredAt: Date,
        fromPeerID: String? = nil,
        toPeerID: String? = nil,
        sourceID: String? = nil,
        alert: RelayAttentionAlert? = nil
    ) {
        AgentIntelligenceStore.shared.record(AgentInboxEvent(
            paneID: id,
            host: profile.kind == .ssh ? profile.host : "This Mac",
            provider: provider,
            agentID: agentID,
            kind: eventKind,
            title: title,
            detail: detail,
            occurredAt: occurredAt,
            fromPeerID: fromPeerID,
            toPeerID: toPeerID,
            sourceID: sourceID,
            alert: alert
        ))
    }

    private static func agentEventDate(event: [String: Any], envelope: [String: Any]) -> Date {
        if let value = (event["occurred_at"] as? String) ?? (envelope["relay_recorded_at"] as? String),
           let date = parseAgentTimestamp(value) {
            return date
        }
        if let number = (event["occurred_at"] as? NSNumber) ?? (envelope["relay_recorded_at"] as? NSNumber) {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        return Date()
    }

    func applyProgramStatus(_ status: RelayStatus, deliveryEpoch: UUID,
                            now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let previous = programStatus.records
        guard programStatus.applyTransportStatus(status, deliveryEpoch: deliveryEpoch),
              status.state == "program_status", let revision = programStatus.revision else { return }
        let transitions = programStatusAttention.consume(previous: previous,
            current: programStatus.records, revision: revision, deliveryEpoch: deliveryEpoch,
            replay: status.programStatusReplay != false, now: now)
        for transition in transitions {
            AgentIntelligenceStore.shared.record(transition.inboxEvent(paneID: id,
                host: profile.kind == .ssh ? profile.host : "This Mac",
                paneName: displayName, occurredAt: Date()))
        }
    }

    private func announceAgentAttention(_ message: String) {
        guard let window = NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func appendSubagentUpdate(_ message: String, occurredAt: Date, at index: Int) {
        // The full transcript remains authoritative on the remote host. The
        // sidebar only needs a useful recent tail; bounding it prevents a busy
        // peer tree from retaining tens or hundreds of megabytes locally.
        let bounded = String(message.prefix(4_096))
        guard subagents.indices.contains(index), subagents[index].updates.last?.message != bounded else { return }
        subagents[index].updates.append(SubagentUpdate(id: UUID(), message: bounded, occurredAt: occurredAt))
        subagents[index].updates = Array(subagents[index].updates.suffix(20))
    }

    private func pruneCompletedSubagents() {
        guard subagents.count > 500 else { return }
        var excess = subagents.count - 500
        subagents.removeAll { subagent in
            guard excess > 0, subagent.phase != .active else { return false }
            excess -= 1
            return true
        }
    }
}

@MainActor
final class TabModel: ObservableObject, Identifiable {
    @Published var executionContext: RelayExecutionContext?
    // Lazy and separately observed: dock updates do not invalidate tab layout.
    lazy var chrome = WorkspaceChrome()
    let id: UUID
    let sessionID: UUID
    @Published var name: String
    @Published var layout: PaneLayout {
        didSet { notePanesLeft(oldValue.paneIDs + floatingPanes.map(\.paneID) + hiddenStackPaneIDs, via: "layout") }
    }
    @Published var floatingPanes: [FloatingPanePlacement] {
        didSet { notePanesLeft(layout.paneIDs + oldValue.map(\.paneID) + hiddenStackPaneIDs, via: "floatingPanes") }
    }
    @Published var splitRatios: [UUID: Double]
    /// Told which panes left this tab, and through which property. A pane
    /// can leave for a moment while it moves within the tab.
    var onPanesLeft: ((_ paneIDs: [UUID], _ via: String) -> Void)?
    var canvasSize: CGSize = .zero
    var savedArrangement: PaneArrangementSnapshot?
    @Published var rLayoutEditorID: UUID?

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

    /// Stacks whose selected member sits in `layout`. Hidden members appear
    /// nowhere else in the tab, and are never stopped by a stack change.
    @Published var stacks: [PaneStack] = [] {
        didSet {
            let hidden = oldValue.flatMap { stack in stack.members.filter { $0 != stack.selected } }
            notePanesLeft(layout.paneIDs + floatingPanes.map(\.paneID) + hidden, via: "stacks")
        }
    }

    private func notePanesLeft(_ previous: [UUID], via property: String) {
        guard let onPanesLeft else { return }
        let current = Set(allPaneIDs)
        let left = previous.filter { !current.contains($0) }
        if !left.isEmpty { onPanesLeft(left, property) }
    }

    var allPaneIDs: [UUID] { layout.paneIDs + floatingPanes.map(\.paneID) + hiddenStackPaneIDs }

    var hiddenStackPaneIDs: [UUID] { stacks.flatMap { stack in stack.members.filter { $0 != stack.selected } } }

    func stack(containing paneID: UUID) -> PaneStack? { stacks.first { $0.members.contains(paneID) } }

    func stack(id: UUID) -> PaneStack? { stacks.first { $0.id == id } }

    var legacyLayoutProjection: PaneLayout { layout.legacyProjection(stacks: stacks) }

    static func legacyProjection(of layout: PaneLayout, stacks: [PaneStack]) -> PaneLayout {
        layout.legacyProjection(stacks: stacks)
    }

    /// Accepts a saved stack table only if it reproduces the saved legacy
    /// layout exactly. Otherwise an older writer rearranged the tab, and the
    /// legacy layout (which still holds every pane) wins.
    func restoreLayout(legacy: PaneLayout, visible: PaneLayout?, stacks saved: [PaneStack]?) {
        if let visible, let saved, !saved.isEmpty, saved.allSatisfy(\.isValid),
           Set(saved.map(\.id)).count == saved.count,
           visible.legacyProjection(stacks: saved) == legacy {
            layout = visible
            stacks = saved
        } else {
            layout = legacy
            stacks = []
        }
    }

    /// Takes a pane out of this tab's tiled area or stack. A showing stack
    /// member hands its slot to the next member rather than collapsing the
    /// split. Returns false if the pane was not tiled or stacked here.
    @discardableResult
    func detachTiledPane(_ paneID: UUID) -> Bool {
        if let index = stacks.firstIndex(where: { $0.members.contains(paneID) }) {
            var stack = stacks[index]
            let position = stack.members.firstIndex(of: paneID)!
            stack.members.remove(at: position)
            if stack.selected == paneID {
                let next = stack.members[min(position, stack.members.count - 1)]
                layout = layout.swapping(paneID, next)
                stack.selected = next
            }
            if stack.members.count < 2 { stacks.remove(at: index) } else { stacks[index] = stack }
            return true
        }
        guard layout.paneIDs.contains(paneID), let remaining = layout.removing(paneID) else { return false }
        layout = remaining
        return true
    }

    /// Keeps the stack table consistent after any direct `layout` assignment:
    /// a stack whose showing member left the layout promotes another member
    /// that is still there, or else re-tiles its hidden members so no pane is
    /// ever dropped from the tab.
    func reconcileStacks() {
        var kept: [PaneStack] = []
        var claimed = Set(floatingPanes.map(\.paneID))
        for var stack in stacks {
            stack.members = stack.members.filter { !claimed.contains($0) }
            let tiled = Set(layout.paneIDs)
            let showing = stack.members.filter { tiled.contains($0) }
            if !showing.contains(stack.selected), let first = showing.first { stack.selected = first }
            if !tiled.contains(stack.selected) {
                for member in stack.members where !tiled.contains(member) {
                    let anchor = layout.paneIDs.last!
                    layout = layout.splitting(anchor, axis: .horizontal, with: member)
                }
                continue
            }
            // Members tiled elsewhere in the layout are no longer hidden here.
            stack.members = stack.members.filter { $0 == stack.selected || !tiled.contains($0) }
            claimed.formUnion(stack.members)
            if stack.members.count >= 2 { kept.append(stack) }
        }
        if kept != stacks { stacks = kept }
    }

    /// Initialize new dividers without rebalancing the user's other splits.
    func reconcileSplitRatios() {
        var ratios: [UUID: Double] = [:]
        func visit(_ node: PaneLayout) {
            guard case let .split(id, _, first, second) = node else { return }
            let saved = splitRatios[id] ?? 0.5
            ratios[id] = saved.isFinite && saved > 0 && saved < 1 ? saved : 0.5
            visit(first)
            visit(second)
        }
        visit(layout)
        if splitRatios != ratios { splitRatios = ratios }
    }

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

struct PaneArrangementSnapshot {
    let layout: PaneLayout
    let floating: [FloatingPanePlacement]
    let ratios: [UUID: Double]
    let active: UUID?
    let results: [UUID: Bool]
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
        if let data = RelayStateProfile.defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {
            profiles = saved
        }
        recentHostKeys = RelayStateProfile.defaults.stringArray(forKey: recentDefaultsKey) ?? []
        refreshSSHConfig()
    }

    /// Each refresh makes new profiles (new ids) for the same aliases; a
    /// host choice that must survive it keys by `connectionKey`.
    func refreshSSHConfig(configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")) {
        sshConfigHosts = SSHConfigDiscovery.hosts(configURL: configURL).map(ConnectionProfile.sshConfigHost)
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
        RelayStateProfile.defaults.set(recentHostKeys, forKey: recentDefaultsKey)
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
        RelayStateProfile.defaults.set(data, forKey: defaultsKey)
    }
}

extension ConnectionProfile {
    var connectionKey: String {
        usesSSHConfig ? "config:\(host)" : "ssh:\(destination):\(port)"
    }
}

extension PaneModel {
    /// The raw account label (list_panes "account"): recorded, else inferred.
    var agentAccountLabel: String? { agentAccount?.label }

    /// Display only (list_panes "accountDisplay"); see `displayLabel`. Never a
    /// move target or an account comparison.
    var agentAccountDisplay: String? { agentAccount?.displayLabel }

    /// Records the account a launch selected. A pane keeps its recorded
    /// account until a new agent is started in it.
    func recordAgentAccount(_ account: RelayAgentAccount) {
        guard account.isValid else { return }
        var state = RelayPaneAgentAccountState(recorded: account)
        if let current = agentAccount, current.observedProvider == account.provider {
            state.observedProvider = current.observedProvider
            state.observedDirectory = current.observedDirectory
            state.observedLabel = current.observedLabel
        }
        agentAccount = state
        RelayPaneAccountStore.shared.save(state, paneID: id)
    }

    /// A slot rename keeps the pane's account: only its label changes.
    func relabelAgentAccount(provider: String, from old: String, to new: String) {
        guard var state = agentAccount, let recorded = state.recorded, recorded.provider == provider, recorded.label == old
        else { return }
        state.recorded = RelayAgentAccount(provider: provider, label: new, dir: recorded.dir)
        if state.observedProvider == provider, state.observedLabel == old { state.observedLabel = new }
        agentAccount = state
        RelayPaneAccountStore.shared.save(state, paneID: id)
    }

    /// Records what the running agent uses. A difference from the recorded
    /// account is reported, never corrected.
    /// Adopts the account saved for this pane. A saved inferred label is
    /// re-derived now if the host registry is already read, and not shown
    /// until it is: it may be a guess made before that registry arrived.
    func restoreAgentAccount(_ saved: RelayPaneAgentAccountState?,
                             accounts: RelayAgentAccountDirectory = .shared) {
        agentAccount = saved
        guard saved?.observedDirectory != nil else { return }
        accounts.trackObservedPane(self)
        let key = RelayAgentAccountDirectory.hostKey(profile)
        let cached = accounts.statuses[key] != nil
        agentAccount = saved?.restored(registryCached: cached)
        if cached { accounts.relabelObservedPanes([self], hostKey: key) }
    }

    func observeAgentAccount(provider: String, directory: String, label: String?, matches: Bool? = nil) {
        guard RelayAgentAccount.providers.contains(provider), RelayAgentAccount.validDirectory(directory) else { return }
        RelayAgentAccountDirectory.shared.trackObservedPane(self)
        var state = agentAccount ?? RelayPaneAgentAccountState()
        guard state.observedProvider != provider || state.observedDirectory != directory || state.observedLabel != label ||
              state.observedMatches != matches else { return }
        state.observedProvider = provider
        state.observedDirectory = directory
        state.observedLabel = label
        state.observedMatches = matches
        agentAccount = state
        RelayPaneAccountStore.shared.save(state, paneID: id)
    }
}
