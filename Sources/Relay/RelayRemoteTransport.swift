import Foundation

struct RelayStatus: Sendable {
    let state: String
    let exitCode: Int?
    let message: String?
    let outputReset: Bool
    let eventReset: Bool
    let capabilities: [String]
    let clientCount: Int?
    let programStatus: [RelayProgramStatusRecord]?
    let programStatusRevision: UInt64?
    let programStatusReplay: Bool?

    init(
        state: String,
        exitCode: Int? = nil,
        message: String? = nil,
        outputReset: Bool = false,
        eventReset: Bool = false,
        capabilities: [String] = [],
        clientCount: Int? = nil,
        programStatus: [RelayProgramStatusRecord]? = nil,
        programStatusRevision: UInt64? = nil,
        programStatusReplay: Bool? = nil
    ) {
        self.state = state
        self.exitCode = exitCode
        self.message = message
        self.outputReset = outputReset
        self.eventReset = eventReset
        self.capabilities = capabilities
        self.clientCount = clientCount
        self.programStatus = programStatus
        self.programStatusRevision = programStatusRevision
        self.programStatusReplay = programStatusReplay
    }
}

struct RelayArtifact: Sendable {
    let path: String
    let data: Data
}

enum SSHConnectionFailureKind: Equatable, Sendable {
    case networkRoute
    case interrupted
    case authentication
    case remoteConfiguration
}

struct SSHConnectionFailure: Equatable, Sendable {
    let kind: SSHConnectionFailureKind
    let detail: String

    var shouldRetry: Bool {
        kind == .networkRoute || kind == .interrupted
    }

    /// The host name did not resolve: a DNS problem, which can persist after
    /// the VPN is back while the system resolver still holds an old answer.
    var isNameLookup: Bool {
        let detail = detail.lowercased()
        return ["could not resolve hostname", "nodename nor servname provided", "temporary failure in name resolution"]
            .contains(where: detail.contains)
    }

    var userMessage: String {
        switch kind {
        case .networkRoute:
            isNameLookup
                ? "Can't look up this host's name (DNS). If the VPN is connected, macOS may still be using an old lookup; Relay keeps retrying."
                : "VPN or network route unavailable."
        case .interrupted:
            "Connection interrupted."
        case .authentication:
            detail.isEmpty ? "SSH authentication needs attention." : detail
        case .remoteConfiguration:
            detail.isEmpty ? "The remote Relay installation needs attention." : detail
        }
    }

    static func diagnose(_ diagnostic: String, terminationStatus: Int32? = nil) -> SSHConnectionFailure {
        let normalized = diagnostic.lowercased()
        let routeFailures = [
            "network is unreachable",
            "no route to host",
            "operation timed out",
            "connection timed out",
            "could not resolve hostname",
            "nodename nor servname provided",
            "temporary failure in name resolution",
            "connection refused",
        ]
        if routeFailures.contains(where: normalized.contains) {
            return SSHConnectionFailure(kind: .networkRoute, detail: conciseDetail(diagnostic))
        }

        let authenticationFailures = [
            "permission denied",
            "host key verification failed",
            "remote host identification has changed",
            "too many authentication failures",
        ]
        if authenticationFailures.contains(where: normalized.contains) {
            return SSHConnectionFailure(kind: .authentication, detail: conciseDetail(diagnostic))
        }

        let configurationFailures = [
            "relayd: command not found",
            ".local/bin/relayd: no such file",
            "unknown command \"attach\"",
            "unknown command: node",
        ]
        if configurationFailures.contains(where: normalized.contains) {
            return SSHConnectionFailure(kind: .remoteConfiguration, detail: conciseDetail(diagnostic))
        }

        // After known permanent failures have been removed, an SSH exit is
        // recoverable. This includes a cleanly closed multiplexed master and
        // a process Relay intentionally restarts to retransmit queued input.
        _ = terminationStatus
        return SSHConnectionFailure(kind: .interrupted, detail: conciseDetail(diagnostic))
    }

    static func diagnoseNodeTransport(
        _ diagnostic: String,
        terminationStatus: Int32,
        reachedProtocolReady: Bool
    ) -> SSHConnectionFailure {
        let failure = diagnose(diagnostic, terminationStatus: terminationStatus)
        guard !reachedProtocolReady,
              terminationStatus == 0,
              failure.kind == .interrupted,
              conciseDetail(diagnostic).isEmpty else {
            return failure
        }
        return SSHConnectionFailure(
            kind: .remoteConfiguration,
            detail: "The remote Relay supervisor closed the shared node stream before its handshake."
        )
    }

    private static func conciseDetail(_ diagnostic: String) -> String {
        let lines = diagnostic
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("** WARNING:") }
        return String((lines.last ?? "").prefix(220))
    }
}

enum RelayPaneAttachPolicy {
    // The node stream itself has already completed SSH authentication before a
    // pane hello is sent. At normal HPC latencies this response is measured in
    // milliseconds. Compatibility recovery for durable workers is slower but
    // still bounded; only fall back after that complete window instead of
    // displaying an empty pane through repeated watchdog cycles.
    // A current worker normally attaches in a few milliseconds. A durable
    // worker from an older relayd can require a bounded compatibility repaint:
    // probing takes up to 0.5 seconds, opening its observer up to two seconds,
    // two resize barriers up to 1.5 seconds total, and lease release 0.15 seconds.
    // Allow a little transport/scheduling margin beyond that 4.15-second bound.
    // Do not mistake that deliberate work
    // for a dead multiplex route and fan the pane out onto another SSH process.
    static let handshakeTimeoutMilliseconds = 5_000
    /// A pane still waiting this long for its shared node checks that the
    /// node is still the pooled one for its host and, if it is not, rejoins.
    static let nodeRecoveryCheckMilliseconds = 15_000
    static let dedicatedTransportAfterAttempt = 1

    static func retryDelayMilliseconds(attempt: Int, waitingForInputLease: Bool) -> Int {
        if waitingForInputLease {
            // The worker keeps the previous input lease for five seconds so a
            // dropped connection can reclaim it. Retry just after that grace
            // period, then continue at a quiet bounded cadence.
            return min(15_000, 5_500 + max(0, attempt - 1) * 1_500)
        }
        return min(5_000, 250 * (1 << min(max(0, attempt - 1), 4)))
    }

    static func shouldUseDedicatedTransport(attempt: Int) -> Bool {
        attempt >= dedicatedTransportAfterAttempt
    }
}

enum TerminalViewportCommitPolicy {
    static func isSignalSafe(viewportChanged: Bool, exactWorker: Bool, exactSupervisor: Bool) -> Bool {
        !viewportChanged || exactWorker || exactSupervisor
    }
}

/// A single admitted packet. Dispatch is once-only and runs after the IO
/// binding lock has been released, since a writer can synchronously report an
/// error to the connection owner even from its writeAsync entry point.
final class RelayPromptControlAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () -> Void)?
    init(_ operation: @escaping @Sendable () -> Void) { self.operation = operation }
    @discardableResult func dispatch() -> Bool {
        lock.lock()
        let pending = operation
        operation = nil
        lock.unlock()
        guard let pending else { return false }
        pending()
        return true
    }
}

final class RelayRemoteTransport: @unchecked Sendable {
    private let lock = NSLock()
    // Dedicated reader callbacks and producer replacement share this barrier.
    // Recursive because an output callback may detach its own transport.
    private let dedicatedDeliveryLock = NSRecursiveLock()
    private var process: Process?
    private var writer: (any RelayFrameWriting)?
    private var nodeChannel: RelayNodeChannel?
    private var detached = false
    private var deliveryEpoch = UUID() {
        didSet {
            pendingAgentReceipts.reset()
            // A repaint still outstanding from the retired producer cannot
            // complete against output delivered by its replacement.
            pendingViewportAck = nil
        }
    }
    private var pendingAgentReceipts = RelayAgentEventReceipts()
    private var lastSequence: UInt64 = 0
    private var lastEventSequence: UInt64 = 0
    private var reconnectAttempt = 0
    private var reconnectScheduled = false
    private var inputBacklog = Data()
    private var latestResize: (UInt16, UInt16)?
    private let inputClientID = RelayInputClientIdentity.id
    private var pendingInputs: [UInt64: Data] = [:]
    private var pendingInputBytes = 0
    private var inputOverflowed = false
    private var attachRepaintPending = false
    private var attached = false {
        didSet {
            if !attached {
                promptEditorConnectionID = UUID()
                promptEditorControlGranted = false
                signalPromptEditorLeaseChangedLocked()
            }
        }
    }
    private var promptEditorConnectionID = UUID()
    private var promptEditorControlGranted = false
    private var attachedWithInputLease = false
    private var promptEditorLeaseObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var hasAttachedWorker = false
    private var supportsInputAcknowledgements = false
    /// The worker accepts Relay's own keystrokes as automation input, which it
    /// does not count as a human takeover of context rotation.
    private var supportsAutomationInput = false
    /// Consecutive dedicated reattachments made only to obtain the input lease.
    private var dedicatedLeaseRetryAttempt = 0
    /// Pending acknowledged sequences that were sent as automation input. A
    /// reconnect replays them with the same classification.
    private var automationInputSequences: Set<UInt64> = []
    private var supportsViewportCommits = false
    private var supportsSupervisorViewportCommits = false
    private var supportsExactViewportCommits = false
    private var supportsExactSupervisorViewportCommits = false
    private var viewportGeneration: UInt64 = 0
    private var pendingViewportAck: (generation: UInt64, repaintSequence: UInt64)?
    private var onViewportCommitted: (@Sendable (UInt64, UUID) -> Void)?
    private var sessionEnded = false
    private var attachRetryCount = 0
    private var attachRetryScheduled = false
    private var nodeRecoveryScheduled = false
    /// The current attempt to join a shared node. Replaced by every attempt
    /// and cancelled by detach, so a superseded attempt cannot register.
    private var nodeAdmission: RelayNodeAdmission?
    /// The shared node pool; tests supply their own.
    var nodePool = RelayNodeTransportPool.shared
    var nodeRecoveryCheckMilliseconds = RelayPaneAttachPolicy.nodeRecoveryCheckMilliseconds
    private var diagnosticSessionID = "unknown"
    private var inputDiagnosticCount = 0
    private var connectionContext: RelayConnectionContext?

    init() {}

    /// Adopt an already owned framed connection without dialing or creating a
    /// process. The caller supplies the capabilities from its attach response;
    /// the same didAttach path installs acknowledgement and control state.
    init(attachedFrameWriter: any RelayFrameWriting, profile: ConnectionProfile,
        paneID: UUID, capabilities: [String], controlGranted: Bool,
        observeAgentsOnly: Bool = false,
        onOutput: @escaping @Sendable (Data, UInt64, UUID) -> Void = { _, _, _ in },
        onStatus: @escaping @Sendable (RelayStatus, UUID) -> Void = { _, _ in },
        onAgentEvent: @escaping @Sendable (Data, UUID) -> Void = { _, _ in },
        onArtifact: @escaping @Sendable (RelayArtifact, UUID) -> Void = { _, _ in }) {
        precondition(profile.backend == .relay)
        let context = RelayConnectionContext(profile: profile,
            sessionID: paneID.uuidString.lowercased(), parentSessionID: nil,
            workspaceSessionID: nil, tabID: nil, paneTitle: "", contentKind: "terminal",
            requiresExistingWorker: true, onOutput: onOutput, onStatus: onStatus,
            onAgentEvent: onAgentEvent, onArtifact: onArtifact, onDisconnect: { _, _ in },
            observeAgentsOnly: observeAgentsOnly)
        connectionContext = context
        diagnosticSessionID = context.sessionID
        writer = attachedFrameWriter
        didAttach(context: context, capabilities: capabilities, controlGranted: controlGranted)
    }

    func promptEditorControlLease(paneID: UUID, hostID: UUID, requireIdleInput: Bool = true) -> RelayPromptEditorControlLease? {
        lock.lock(); defer { lock.unlock() }
        guard let context = connectionContext, context.profile.id == hostID,
              context.sessionID == paneID.uuidString.lowercased(),
              RelayPromptEditorLeasePolicy.admits(attached: attached, detached: detached,
                writerAvailable: writer != nil, controlGranted: promptEditorControlGranted,
                observer: context.observeAgentsOnly, acknowledgedInput: supportsInputAcknowledgements,
                pendingInput: requireIdleInput && (!pendingInputs.isEmpty || !inputBacklog.isEmpty),
                overflowed: inputOverflowed) else { return nil }
        return RelayPromptEditorControlLease(connectionID: promptEditorConnectionID,
            clientID: inputClientID, hostID: hostID, paneID: paneID)
    }

    func promptEditorLeaseEvents() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            // Some state notifications occur under the transport lock. Remove
            // subscriptions asynchronously, never re-enter that lock inline.
            Task.detached { [weak self] in
                self?.removePromptEditorLeaseObserver(id)
            }
        }
        lock.lock()
        promptEditorLeaseObservers[id] = continuation
        continuation.yield(())
        lock.unlock()
        return stream
    }

    private func signalPromptEditorLeaseChangedLocked() {
        for continuation in promptEditorLeaseObservers.values { continuation.yield(()) }
    }

    private func removePromptEditorLeaseObserver(_ id: UUID) {
        lock.lock(); promptEditorLeaseObservers.removeValue(forKey: id); lock.unlock()
    }

    deinit {
        for continuation in promptEditorLeaseObservers.values { continuation.finish() }
        nodeAdmission?.cancel()
        nodeChannel?.close()
        if let process, process.processIdentifier != 0 { process.terminate() }
    }

    func setInitialViewport(_ viewport: RelayViewport) {
        lock.lock()
        latestResize = (viewport.columns, viewport.rows)
        lock.unlock()
    }

    func setViewportCommitHandler(_ handler: @escaping @Sendable (UInt64, UUID) -> Void) {
        lock.lock()
        onViewportCommitted = handler
        lock.unlock()
    }

    func start(
        profile: ConnectionProfile,
        sessionID: String,
        parentSessionID: String?,
        workspaceSessionID: String?,
        tabID: String?,
        paneTitle: String,
        contentKind: String,
        workingDirectory: String? = nil,
        requiresExistingWorker: Bool = false,
        initialLastSequence: UInt64 = 0,
        forceAttachRepaint: Bool = false,
        onOutput: @escaping @Sendable (Data, UInt64, UUID) -> Void,
        onStatus: @escaping @Sendable (RelayStatus, UUID) -> Void,
        onAgentEvent: @escaping @Sendable (Data, UUID) -> Void,
        onArtifact: @escaping @Sendable (RelayArtifact, UUID) -> Void,
        onDisconnect: @escaping @Sendable (String, UUID) -> Void,
        observeAgentsOnly: Bool = false
    ) {
        let context = RelayConnectionContext(
            profile: profile,
            sessionID: sessionID,
            parentSessionID: parentSessionID,
            workspaceSessionID: workspaceSessionID,
            tabID: tabID,
            paneTitle: paneTitle,
            contentKind: contentKind,
            requiresExistingWorker: requiresExistingWorker,
            onOutput: onOutput,
            onStatus: onStatus,
            onAgentEvent: onAgentEvent,
            onArtifact: onArtifact,
            onDisconnect: onDisconnect,
            observeAgentsOnly: observeAgentsOnly,
            workingDirectory: workingDirectory
        )
        lock.lock()
        connectionContext = context
        diagnosticSessionID = sessionID
        inputDiagnosticCount = 0
        detached = false
        lastSequence = initialLastSequence
        lastEventSequence = 0
        reconnectAttempt = 0
        reconnectScheduled = false
        pendingInputs.removeAll(keepingCapacity: true)
        automationInputSequences.removeAll(keepingCapacity: true)
        pendingInputBytes = 0
        inputOverflowed = false
        attachRepaintPending = forceAttachRepaint
        deliveryEpoch = UUID()
        attached = false
        hasAttachedWorker = false
        supportsInputAcknowledgements = false
        supportsAutomationInput = false
        supportsViewportCommits = false
        supportsSupervisorViewportCommits = false
        supportsExactViewportCommits = false
        supportsExactSupervisorViewportCommits = false
        pendingViewportAck = nil
        sessionEnded = false
        attachRetryCount = 0
        attachRetryScheduled = false
        if latestResize == nil {
            latestResize = (RelayViewport.default.columns, RelayViewport.default.rows)
        }
        lock.unlock()
        connectMultiplexed(context)
    }

    private func connectMultiplexed(_ context: RelayConnectionContext) {
        lock.lock()
        guard !detached else {
            lock.unlock()
            return
        }
        nodeAdmission?.cancel()
        let admission = RelayNodeAdmission()
        nodeAdmission = admission
        let nodePool = self.nodePool
        lock.unlock()
        // The node registers this pane only while `admission` is current; a
        // detach or newer attempt in the meantime makes it refuse.
        guard let channel = nodePool.attach(
            profile: context.profile,
            sessionID: context.sessionID,
            admission: admission,
            onReady: { [weak self] channel in self?.openMultiplexed(context, channel: channel, admission: admission) },
            onFrame: { [weak self] frame in self?.receive(frame, context: context) },
            onDisconnect: { [weak self] failure in self?.nodeDisconnected(context, failure: failure) }
        ) else { return }
        lock.lock()
        guard !detached, admission.isActive else {
            lock.unlock()
            // Superseded after joining: release only this channel's own
            // subscription (a successor's registration is left untouched).
            channel.close()
            return
        }
        // The current attempt owns the route; a channel left by an earlier
        // attempt of this transport is closed.
        let replaced = nodeChannel === channel ? nil : nodeChannel
        nodeChannel = channel
        writer = channel
        lock.unlock()
        replaced?.close()
        scheduleNodeRecoveryCheck(context)
    }

    /// The shared-node channel this pane currently uses (tests).
    var currentNodeChannel: RelayNodeChannel? {
        lock.lock()
        defer { lock.unlock() }
        return nodeChannel
    }

    /// While this pane waits for its shared node, periodically confirm that
    /// the node is still the pooled one for the host (a parked pooled node is
    /// asked to reconnect now). A pane left on a replaced node rejoins the
    /// pool instead of waiting for callbacks that node will never deliver.
    private func scheduleNodeRecoveryCheck(_ context: RelayConnectionContext) {
        lock.lock()
        guard !detached, !sessionEnded, !attached, !nodeRecoveryScheduled, nodeChannel != nil else {
            lock.unlock()
            return
        }
        nodeRecoveryScheduled = true
        let delay = nodeRecoveryCheckMilliseconds
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.nodeRecoveryScheduled = false
            guard !self.detached, !self.sessionEnded, !self.attached, !self.attachRetryScheduled,
                  let channel = self.nodeChannel else {
                self.lock.unlock()
                return
            }
            let pool = self.nodePool
            self.lock.unlock()
            guard pool.paneNeedsNewNode(channel, profile: context.profile) else {
                self.scheduleNodeRecoveryCheck(context)
                return
            }
            self.lock.lock()
            guard !self.detached, !self.attached, self.nodeChannel === channel else {
                self.lock.unlock()
                return
            }
            self.deliveryEpoch = UUID()
            self.nodeChannel = nil
            self.writer = nil
            self.supportsSupervisorViewportCommits = false
            self.supportsExactSupervisorViewportCommits = false
            self.lock.unlock()
            channel.close()
            RelayDiagnostics.shared.record(category: "connection", name: "pane-node-rejoined", details: [
                "pane_id": context.sessionID,
            ])
            context.onStatus(RelayStatus(
                state: "reconnecting",
                message: "This pane's shared connection was replaced; rejoining the current one."
            ), self.deliveryEpochSnapshot())
            // Detach or restart may run during the status callback; the
            // admission in connectMultiplexed is what fences that.
            self.connectMultiplexed(context)
        }
    }

    private func openMultiplexed(_ context: RelayConnectionContext, channel: RelayNodeChannel,
        admission: RelayNodeAdmission) {
        lock.lock()
        // RelayNodeConnection can already be ready when a second pane joins.
        // Its callback may therefore arrive before attach() returns and before
        // connectMultiplexed stores the channel. Adopt that same channel here
        // instead of dropping the only Hello handshake for this pane, unless
        // its attempt has been superseded.
        if nodeChannel == nil, !detached, admission.isActive {
            nodeChannel = channel
            writer = channel
        }
        guard !detached, nodeChannel === channel else {
            lock.unlock()
            return
        }
        let resumeSequence = lastSequence
        let resumeEventSequence = lastEventSequence
        let viewport = latestResize ?? (RelayViewport.default.columns, RelayViewport.default.rows)
        deliveryEpoch = UUID()
        attached = false
        writer = channel
        supportsSupervisorViewportCommits =
            channel.supports("viewport_commit_compat_v1") ||
            channel.supports("viewport_commit_compat_v2")
        supportsExactSupervisorViewportCommits = channel.supports("viewport_commit_compat_v2")
        lock.unlock()
        let hello = multiplexedHello(context, viewport: viewport,
            resumeSequence: resumeSequence, resumeEventSequence: resumeEventSequence)
        let payload = (try? JSONSerialization.data(withJSONObject: hello.compactMapValues { $0 })) ?? Data()
        TerminalReplayTrace.log("hello pane=\(context.sessionID) seq=\(resumeSequence) viewport=\(viewport.0)x\(viewport.1) existing=\(context.requiresExistingWorker)")
        channel.writeAsync(type: .hello, payload: payload)
        scheduleAttachWatchdog(context, channel: channel)
    }

    /// The next shared-channel Hello for the installed context (tests).
    func nextMultiplexedHello() -> [String: Any]? {
        lock.lock()
        let context = connectionContext
        let viewport = latestResize ?? (RelayViewport.default.columns, RelayViewport.default.rows)
        let resumeSequence = lastSequence
        let resumeEventSequence = lastEventSequence
        lock.unlock()
        guard let context else { return nil }
        return multiplexedHello(context, viewport: viewport,
            resumeSequence: resumeSequence, resumeEventSequence: resumeEventSequence)
    }

    private func multiplexedHello(_ context: RelayConnectionContext, viewport: (UInt16, UInt16),
        resumeSequence: UInt64, resumeEventSequence: UInt64) -> [String: Any] {
        var hello: [String: Any] = [
            "version": 1,
            "session_id": context.sessionID,
            "cols": viewport.0,
            "rows": viewport.1,
            "last_seq": resumeSequence,
            "last_event_seq": resumeEventSequence,
            "client_id": inputClientID.uuidString.lowercased(),
        ]
        lock.lock()
        let requiresExistingWorker = context.requiresExistingWorker || hasAttachedWorker
        lock.unlock()
        if requiresExistingWorker { hello["require_existing_worker"] = true }
        lock.lock()
        let repaintPending = attachRepaintPending
        lock.unlock()
        if repaintPending { hello["repaint_pulse"] = true }
        if context.observeAgentsOnly {
            hello["observe_events"] = true
        } else {
            hello["terminal_only"] = true
            hello["observe_program_status"] = true
            hello["parent_session_id"] = context.parentSessionID
            hello["workspace_id"] = context.workspaceSessionID
            hello["tab_id"] = context.tabID
            hello["pane_title"] = context.paneTitle
            hello["content_kind"] = context.contentKind
            if let directory = context.workingDirectory { hello["working_directory"] = directory }
            if !context.profile.command.isEmpty { hello["command"] = context.profile.command }
        }
        return hello
    }

    private func nodeDisconnected(_ context: RelayConnectionContext, failure: SSHConnectionFailure) {
        lock.lock()
        guard !detached, !sessionEnded else {
            lock.unlock()
            return
        }
        deliveryEpoch = UUID()
        attached = false
        if failure.kind == .remoteConfiguration {
            let channel = nodeChannel
            nodeChannel = nil
            writer = nil
            supportsSupervisorViewportCommits = false
            supportsExactSupervisorViewportCommits = false
            lock.unlock()
            channel?.close()
            context.onStatus(RelayStatus(
                state: "compatibility_mode",
                message: "This host has an older relayd; using one SSH stream per pane until it is updated."
            ), deliveryEpochSnapshot())
            connect(context)
            return
        }
        if !failure.shouldRetry {
            let channel = nodeChannel
            nodeChannel = nil
            writer = nil
            supportsSupervisorViewportCommits = false
            supportsExactSupervisorViewportCommits = false
            lock.unlock()
            channel?.close()
            context.onStatus(RelayStatus(state: "error", message: failure.userMessage), deliveryEpochSnapshot())
            return
        }
        lock.unlock()
        let state = failure.kind == .networkRoute ? "waiting_for_network" : "reconnecting"
        context.onStatus(RelayStatus(
            state: state,
            message: failure.userMessage + " The shared node connection is retrying automatically."
        ), deliveryEpochSnapshot())
        scheduleNodeRecoveryCheck(context)
    }

    private func receive(_ frame: RelayWireFrame, context: RelayConnectionContext) {
        switch frame.type {
        case .output:
            receiveOutput(frame.payload, context: context)
        case .status:
            guard let decoded = try? JSONDecoder().decode(StatusWirePayload.self, from: frame.payload) else { return }
            if decoded.outputReset == true || decoded.eventReset == true {
                lock.lock()
                if decoded.outputReset == true { lastSequence = 0 }
                if decoded.eventReset == true { lastEventSequence = 0; deliveryEpoch = UUID() }
                lock.unlock()
            }
            if decoded.state == "attached" {
                TerminalReplayTrace.log("attached pane=\(context.sessionID) reset=\(decoded.outputReset == true)")
                let capabilities = decoded.capabilities ?? []
                negotiateProgramStatus(context: context, capabilities: capabilities)
                let controlGranted = !capabilities.contains("input_lease_v1") || decoded.controlGranted == true
                if controlGranted {
                    didAttach(context: context, capabilities: capabilities, controlGranted: decoded.controlGranted)
                } else {
                    owePendingAttachRepaint(capabilities: capabilities, controlGranted: decoded.controlGranted,
                        observeAgentsOnly: context.observeAgentsOnly)
                    context.onStatus(RelayStatus(
                        state: "read_only",
                        message: "Another client currently controls input for this pane. Retrying input ownership automatically.",
                        outputReset: decoded.outputReset ?? false,
                        eventReset: decoded.eventReset ?? false,
                        capabilities: capabilities
                    ), deliveryEpochSnapshot())
                    scheduleMultiplexedRetry(context, waitingForInputLease: true)
                    return
                }
            }
            if decoded.state == "caught_up" {
                TerminalReplayTrace.log("caught-up pane=\(context.sessionID)")
            }
            if decoded.state == "route_closed" {
                lock.lock()
                let shouldRecover = !detached && !sessionEnded
                deliveryEpoch = UUID()
                attached = false
                lock.unlock()
                guard shouldRecover else { return }
                context.onStatus(RelayStatus(
                    state: "reconnecting",
                    message: "This pane fell behind a fast terminal redraw; replaying its current screen."
                ), deliveryEpochSnapshot())
                scheduleMultiplexedRetry(context, waitingForInputLease: false)
                return
            }
            if decoded.state == "exited" || decoded.state == "error" { markSessionEnded() }
            context.onStatus(RelayStatus(
                state: decoded.state, exitCode: decoded.exitCode, message: decoded.message,
                outputReset: decoded.outputReset ?? false, eventReset: decoded.eventReset ?? false,
                capabilities: decoded.capabilities ?? [], clientCount: decoded.clientCount,
                programStatus: decoded.programStatus, programStatusRevision: decoded.programStatusRevision,
                programStatusReplay: decoded.normalizedProgramStatusReplay
            ), deliveryEpochSnapshot())
        case .ping:
            try? nodeChannel?.write(type: .pong)
        case .agentEvent:
            receiveAgentEvent(frame.payload, context: context)
        case .inputAck:
            if let acknowledgement = RelayWireFrame.parseInputAck(frame.payload), acknowledgement.clientID == inputClientID {
                lock.lock()
                if let removed = pendingInputs.removeValue(forKey: acknowledgement.sequence) {
                    pendingInputBytes = max(0, pendingInputBytes - removed.count)
                }
                automationInputSequences.remove(acknowledgement.sequence)
                signalPromptEditorLeaseChangedLocked()
                lock.unlock()
            }
        case .viewportAck:
            receiveViewportAck(frame.payload)
        case .artifact:
            if let artifact = RelayWireFrame.parseArtifact(frame.payload) { context.onArtifact(artifact, deliveryEpochSnapshot()) }
        default:
            return
        }
    }

    private func scheduleAttachWatchdog(_ context: RelayConnectionContext, channel: RelayNodeChannel) {
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .milliseconds(RelayPaneAttachPolicy.handshakeTimeoutMilliseconds)
        ) { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.lock.lock()
            let waiting = !self.detached && !self.attached && !self.attachRetryScheduled && self.nodeChannel === channel
            self.lock.unlock()
            if waiting { self.scheduleMultiplexedRetry(context, waitingForInputLease: false) }
        }
    }

    private func scheduleMultiplexedRetry(
        _ context: RelayConnectionContext,
        waitingForInputLease: Bool
    ) {
        lock.lock()
        guard !detached, !attached, !attachRetryScheduled, let channel = nodeChannel else {
            lock.unlock()
            return
        }
        attachRetryScheduled = true
        attachRetryCount += 1
        let attempt = attachRetryCount
        lock.unlock()

        let delay = RelayPaneAttachPolicy.retryDelayMilliseconds(
            attempt: attempt,
            waitingForInputLease: waitingForInputLease
        )
        context.onStatus(RelayStatus(
            state: "reconnecting",
            message: waitingForInputLease
                ? "Waiting to recover this pane's input lease."
                : "The pane handshake stalled; reopening only this pane."
        ), deliveryEpochSnapshot())
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self, weak channel] in
            guard let self, let channel else { return }
            self.lock.lock()
            guard !self.detached, !self.attached, self.nodeChannel === channel else {
                self.attachRetryScheduled = false
                self.lock.unlock()
                return
            }
            self.deliveryEpoch = UUID()
            self.nodeChannel = nil
            self.writer = nil
            self.supportsSupervisorViewportCommits = false
            self.supportsExactSupervisorViewportCommits = false
            self.attachRetryScheduled = false
            self.lock.unlock()
            channel.close()
            if RelayPaneAttachPolicy.shouldUseDedicatedTransport(attempt: attempt) {
                context.onStatus(RelayStatus(
                    state: "reconnecting",
                    message: "The shared pane channel did not answer; using a dedicated connection for this pane."
                ), deliveryEpochSnapshot())
                self.connect(context)
            } else {
                self.connectMultiplexed(context)
            }
        }
    }

    private func connect(_ context: RelayConnectionContext) {
        let ssh = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=2",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
        ]
        arguments += context.profile.sshConnectionArguments
        lock.lock()
        let resumeSequence = lastSequence
        let resumeEventSequence = lastEventSequence
        let viewport = latestResize ?? (RelayViewport.default.columns, RelayViewport.default.rows)
        lock.unlock()
        var dedicatedAttachRepaint = false
        if context.observeAgentsOnly {
            arguments += [
                "~/.local/bin/relayd", "observe",
                "--session", context.sessionID,
                "--last-seq", String(resumeSequence),
                "--last-event-seq", String(resumeEventSequence),
            ]
        } else {
            lock.lock()
            let repaintPending = attachRepaintPending
            lock.unlock()
            dedicatedAttachRepaint = repaintPending
            arguments += ["env", "RELAY_OBSERVE_PROGRAM_STATUS=1"]
            if repaintPending {
                // Environment negotiation is backward compatible: older
                // relayd binaries ignore it, while current supervisors turn it
                // into a one-time pre-attach viewport pulse.
                arguments += ["env", "RELAY_ATTACH_REPAINT=1"]
            }
            arguments += [
                "~/.local/bin/relayd", "attach",
                "--session", context.sessionID,
                "--cols", String(viewport.0),
                "--rows", String(viewport.1),
                "--last-seq", String(resumeSequence),
                "--last-event-seq", String(resumeEventSequence)
            ]
            if let parentSessionID = context.parentSessionID {
                arguments += ["--parent-session", parentSessionID]
            }
            if let workspaceSessionID = context.workspaceSessionID {
                arguments += ["--workspace", workspaceSessionID]
            }
            if let tabID = context.tabID {
                arguments += ["--tab", tabID]
            }
            arguments += ["--pane-title", context.paneTitle, "--content-kind", context.contentKind]
            lock.lock()
            let requiresExistingWorker = context.requiresExistingWorker || hasAttachedWorker
            lock.unlock()
            if requiresExistingWorker { arguments += ["--require-existing-worker"] }
            arguments += ["--terminal-only"]
            arguments += ["--client-id", inputClientID.uuidString.lowercased()]
            if !context.profile.command.isEmpty {
                arguments += ["--command-b64", Data(context.profile.command.utf8).base64EncodedString()]
            }
        }
        ssh.arguments = arguments
        if context.profile.kind == .local,
           let helperIndex = arguments.firstIndex(of: "~/.local/bin/relayd") {
            LocalRelayProcess.configureDedicated(ssh, observeAgentsOnly: context.observeAgentsOnly,
                repaint: dedicatedAttachRepaint)
            ssh.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relayd")
            ssh.arguments = Array(arguments.dropFirst(helperIndex + 1))
        }
        ssh.standardInput = input
        ssh.standardOutput = output
        ssh.standardError = errors

        let diagnostics = SSHDiagnosticBuffer()
        let stderrFinished = DispatchSemaphore(value: 0)
        ssh.terminationHandler = { [weak self] terminated in
            _ = stderrFinished.wait(timeout: .now() + .milliseconds(500))
            self?.connectionEnded(
                context,
                process: terminated,
                terminationStatus: terminated.terminationStatus,
                diagnostic: diagnostics.text
            )
        }

        let dedicatedWriter = RelayWireWriter(input.fileHandleForWriting) { [weak ssh] message in
            RelayDiagnostics.shared.record(category: "connection", name: "wire-write-failed", details: [
                "connection_id": context.sessionID,
                "transport": "legacy-pane",
                "reason": message,
            ])
            if ssh?.isRunning == true { ssh?.terminate() }
        }
        guard installDedicatedProcess(ssh, writer: dedicatedWriter) else { return }

        do {
            try ssh.run()
        } catch {
            scheduleReconnect(context, failure: .diagnose(error.localizedDescription), sourceProcess: ssh)
            return
        }

        // detach() can land between the store above and run(); it skips
        // terminating a not-yet-launched process, so finish that job here now
        // that the process is running.
        lock.lock()
        let cancelled = detached || process !== ssh
        lock.unlock()
        if cancelled {
            ssh.terminate()
            return
        }

        RelayBlockingIO.start(name: "relay.legacy.stderr", qos: .utility) {
            defer { stderrFinished.signal() }
            while true {
                let hasData = autoreleasepool { () -> Bool in
                    guard let chunk = try? errors.fileHandleForReading.read(upToCount: 8 << 10),
                          !chunk.isEmpty else { return false }
                    diagnostics.append(chunk)
                    return true
                }
                if !hasData { break }
            }
        }

        RelayBlockingIO.start(name: "relay.legacy.frames", qos: .userInteractive) { [weak self] in
            do {
                while true {
                    try autoreleasepool {
                        let frame = try RelayWireFrame.read(from: output.fileHandleForReading)
                        try self?.receiveDedicated(frame, context: context, sourceProcess: ssh)
                    }
                }
            } catch {
                // Process termination owns classification and retry. If the
                // framed stream itself becomes invalid, end SSH so its
                // termination handler can recover through the same path.
                if ssh.isRunning { ssh.terminate() }
            }
        }
    }

    /// Install only after prior dedicated callbacks have left the barrier.
    /// No state lock is held while waiting for callbacks or terminating a peer.
    @discardableResult
    func installDedicatedProcess(_ source: Process, writer sourceWriter: any RelayFrameWriting) -> Bool {
        dedicatedDeliveryLock.lock()
        lock.lock()
        guard !detached else {
            lock.unlock()
            dedicatedDeliveryLock.unlock()
            return false
        }
        let previous = process
        process = source
        writer = sourceWriter
        supportsSupervisorViewportCommits = false
        supportsExactSupervisorViewportCommits = false
        deliveryEpoch = UUID()
        attached = false
        lock.unlock()
        dedicatedDeliveryLock.unlock()
        if let previous, previous !== source, previous.processIdentifier != 0, previous.isRunning {
            previous.terminate()
        }
        return true
    }

    func deliveryEpochSnapshot() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return deliveryEpoch
    }

    func isCurrentDeliveryEpoch(_ epoch: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !detached && deliveryEpoch == epoch
    }

    private func isCurrentDedicatedProcess(_ source: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !detached && process === source
    }

    @discardableResult
    func performForDedicatedProcess(_ source: Process,
        _ operation: ((any RelayFrameWriting)?) throws -> Void) rethrows -> Bool {
        dedicatedDeliveryLock.lock()
        defer { dedicatedDeliveryLock.unlock() }
        lock.lock()
        let accepted = !detached && process === source
        let sourceWriter = accepted ? writer : nil
        lock.unlock()
        guard accepted else { return false }
        try operation(sourceWriter)
        return isCurrentDedicatedProcess(source)
    }

    /// Drive the shared-channel reader with the installed context (tests).
    func receiveMultiplexedFrame(_ frame: RelayWireFrame) {
        lock.lock()
        let context = connectionContext
        lock.unlock()
        guard let context else { return }
        receive(frame, context: context)
    }

    /// Owned framed peers use the actual dedicated reader and admission path.
    func receiveAttachedDedicatedFrame(_ frame: RelayWireFrame, sourceProcess: Process) throws {
        lock.lock()
        let context = connectionContext
        lock.unlock()
        guard let context else { return }
        try receiveDedicated(frame, context: context, sourceProcess: sourceProcess)
    }

    private func receiveDedicated(_ frame: RelayWireFrame, context: RelayConnectionContext,
        sourceProcess: Process) throws {
        try performForDedicatedProcess(sourceProcess) { sourceWriter in
            switch frame.type {
            case .output:
                self.receiveOutput(frame.payload, context: context)
            case .status:
                if let decoded = try? JSONDecoder().decode(StatusWirePayload.self, from: frame.payload) {
                    if decoded.outputReset == true || decoded.eventReset == true {
                        self.lock.lock()
                        if decoded.outputReset == true { self.lastSequence = 0 }
                        if decoded.eventReset == true { self.lastEventSequence = 0; self.deliveryEpoch = UUID() }
                        self.lock.unlock()
                    }
                    if decoded.state == "attached" {
                        let capabilities = decoded.capabilities ?? []
                        self.negotiateProgramStatus(context: context, capabilities: capabilities)
                        self.didAttach(context: context, capabilities: capabilities, controlGranted: decoded.controlGranted)
                        // Output stays visible, but a route without the input
                        // lease cannot type or resize. Keep asking for the lease
                        // instead of staying read-only after its holder leaves.
                        if RelayInputLeaseRetryPolicy.needsRetry(capabilities: capabilities,
                            controlGranted: decoded.controlGranted, observeAgentsOnly: context.observeAgentsOnly) {
                            // didAttach cleared the repaint debt; this attach
                            // could not pay it, so the lease retry must.
                            self.owePendingAttachRepaint(capabilities: capabilities,
                                controlGranted: decoded.controlGranted, observeAgentsOnly: context.observeAgentsOnly)
                            self.scheduleDedicatedLeaseRetry(context, sourceProcess: sourceProcess)
                        }
                    }
                    guard isCurrentDedicatedProcess(sourceProcess) else { return }
                    if decoded.state == "exited" || decoded.state == "error" { self.markSessionEnded() }
                    context.onStatus(RelayStatus(
                        state: decoded.state,
                        exitCode: decoded.exitCode,
                        message: decoded.message,
                        outputReset: decoded.outputReset ?? false,
                        eventReset: decoded.eventReset ?? false,
                        capabilities: decoded.capabilities ?? [],
                        clientCount: decoded.clientCount,
                        programStatus: decoded.programStatus, programStatusRevision: decoded.programStatusRevision,
                        programStatusReplay: decoded.normalizedProgramStatusReplay
                    ), deliveryEpochSnapshot())
                }
            case .ping:
                try sourceWriter?.write(type: .pong)
            case .agentEvent:
                receiveAgentEvent(frame.payload, context: context)
            case .inputAck:
                if let acknowledgement = RelayWireFrame.parseInputAck(frame.payload),
                   acknowledgement.clientID == self.inputClientID {
                    self.lock.lock()
                    if let removed = self.pendingInputs.removeValue(forKey: acknowledgement.sequence) {
                        self.pendingInputBytes = max(0, self.pendingInputBytes - removed.count)
                    }
                    self.automationInputSequences.remove(acknowledgement.sequence)
                    self.signalPromptEditorLeaseChangedLocked()
                    self.lock.unlock()
                }
            case .viewportAck:
                self.receiveViewportAck(frame.payload)
            case .artifact:
                if let artifact = RelayWireFrame.parseArtifact(frame.payload) {
                    context.onArtifact(artifact, deliveryEpochSnapshot())
                }
            default:
                return
            }
        }
    }

    /// The worker performs its pre-attach repaint (resizeForAttach) only for
    /// the input-lease holder. A read-only attach therefore receives replay
    /// but no repaint, while still advancing lastSequence past 0, so the
    /// worker's own cold-attach repaint no longer applies to the next Hello.
    /// Carry the repaint request to the attach that obtains the lease.
    private func owePendingAttachRepaint(capabilities: [String], controlGranted: Bool?, observeAgentsOnly: Bool) {
        guard RelayAttachRepaintPolicy.owesRepaintAfterAttach(capabilities: capabilities,
            controlGranted: controlGranted, observeAgentsOnly: observeAgentsOnly) else { return }
        lock.lock()
        attachRepaintPending = true
        lock.unlock()
    }

    /// The worker applies resize and viewport commits only from the lease holder.
    var acceptsViewportRepaint: Bool {
        lock.lock()
        defer { lock.unlock() }
        return RelayAttachRepaintPolicy.routeAcceptsResize(attached: attached && writer != nil,
            leaseCapable: attachedWithInputLease, controlGranted: promptEditorControlGranted)
    }

    /// Whether the next Hello will ask the worker for a pre-attach repaint.
    var nextAttachRequestsRepaint: Bool {
        lock.lock()
        defer { lock.unlock() }
        return attachRepaintPending
    }

    private func markSessionEnded() {
        lock.lock()
        sessionEnded = true
        lock.unlock()
    }

    /// Reconnect a dedicated read-only route so its next Hello can take the
    /// input lease. The worker grants the lease to this transport's client ID
    /// once the previous holder has gone; Hello is its only acquisition point.
    private func scheduleDedicatedLeaseRetry(_ context: RelayConnectionContext, sourceProcess: Process) {
        lock.lock()
        dedicatedLeaseRetryAttempt += 1
        let delay = RelayInputLeaseRetryPolicy.delayMilliseconds(attempt: dedicatedLeaseRetryAttempt)
        lock.unlock()
        context.onStatus(RelayStatus(state: "read_only",
            message: "Another client currently controls input for this pane. Retrying input ownership automatically."),
            deliveryEpochSnapshot())
        RelayDiagnostics.shared.record(category: "pane", name: "dedicated-lease-retry-scheduled",
            details: ["pane_id": context.sessionID, "delay_ms": String(delay)])
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self, self.isCurrentDedicatedProcess(sourceProcess) else { return }
            self.lock.lock()
            let stillReadOnly = self.attached && !self.promptEditorControlGranted && !self.reconnectScheduled
            self.lock.unlock()
            guard stillReadOnly else { return }
            self.scheduleReconnect(context, failure: .diagnose("input lease unavailable"), sourceProcess: sourceProcess)
            if sourceProcess.isRunning { sourceProcess.terminate() }
        }
    }

    private func connectionEnded(
        _ context: RelayConnectionContext,
        process endedProcess: Process,
        terminationStatus: Int32,
        diagnostic: String
    ) {
        dedicatedDeliveryLock.lock()
        defer { dedicatedDeliveryLock.unlock() }
        lock.lock()
        let isCurrent = process === endedProcess
        let shouldIgnore = detached || sessionEnded
        lock.unlock()
        guard isCurrent, !shouldIgnore else { return }

        let failure = SSHConnectionFailure.diagnose(diagnostic, terminationStatus: terminationStatus)
        if failure.shouldRetry {
            scheduleReconnect(context, failure: failure, sourceProcess: endedProcess)
        } else {
            lock.lock()
            writer = nil
            process = nil
            deliveryEpoch = UUID()
            attached = false
            lock.unlock()
            context.onStatus(RelayStatus(state: "error", exitCode: nil, message: failure.userMessage), deliveryEpochSnapshot())
        }
    }

    static func programStatusNegotiationPayload(capabilities: [String], observeAgentsOnly: Bool) -> Data? {
        guard !observeAgentsOnly, capabilities.contains("program_status_negotiation_v1") else { return nil }
        return Data(#"{"observe_program_status":true}"#.utf8)
    }

    private func negotiateProgramStatus(context: RelayConnectionContext, capabilities: [String]) {
        guard let payload = Self.programStatusNegotiationPayload(capabilities: capabilities,
            observeAgentsOnly: context.observeAgentsOnly) else { return }
        lock.lock()
        let currentWriter = writer
        lock.unlock()
        currentWriter?.writeAsync(type: .capabilities, payload: payload)
    }

    private func didAttach(context: RelayConnectionContext, capabilities: [String], controlGranted: Bool?) {
        lock.lock()
        reconnectAttempt = 0
        reconnectScheduled = false
        attached = true
        promptEditorControlGranted = capabilities.contains("input_lease_v1") && controlGranted == true
        attachedWithInputLease = capabilities.contains("input_lease_v1")
        if promptEditorControlGranted || !capabilities.contains("input_lease_v1") { dedicatedLeaseRetryAttempt = 0 }
        hasAttachedWorker = true
        attachRepaintPending = false
        attachRetryCount = 0
        attachRetryScheduled = false
        supportsInputAcknowledgements = capabilities.contains("input_ack_v1")
        supportsAutomationInput = supportsInputAcknowledgements && capabilities.contains("automation_input_v1")
        supportsViewportCommits = RelayTransportCapabilityPolicy.supportsViewportCommit(capabilities)
        supportsExactViewportCommits = RelayTransportCapabilityPolicy.supportsExactViewportCommit(capabilities)
        let needsPostAttachResize = RelayTransportCapabilityPolicy.needsPostAttachResize(capabilities)
        let backlog = inputBacklog
        inputBacklog.removeAll(keepingCapacity: true)
        signalPromptEditorLeaseChangedLocked()
        let resize = latestResize
        let writer = self.writer
        var acknowledgedFrames = pendingInputs
        if supportsInputAcknowledgements, !backlog.isEmpty {
            let sequence = RelayInputSequenceAllocator.shared.next()
            pendingInputs[sequence] = backlog
            pendingInputBytes += backlog.count
            acknowledgedFrames[sequence] = backlog
        }
        let acknowledgementsEnabled = supportsInputAcknowledgements
        let automationSequences = supportsAutomationInput ? automationInputSequences : []
        let overflowed = inputOverflowed
        inputOverflowed = false
        lock.unlock()
        if !backlog.isEmpty {
            RelayDiagnostics.shared.record(category: "terminal-input", name: "reattach-backlog", details: [
                "pane_id": context.sessionID,
                "bytes": String(backlog.count),
                "acknowledged": String(acknowledgementsEnabled),
                "terminal_report": TerminalInputDiagnosticReport.name(backlog),
            ])
        }
        if acknowledgementsEnabled {
            for (sequence, data) in acknowledgedFrames.sorted(by: { $0.key < $1.key }) {
                // A worker without automation support receives it as ordinary
                // input; that keeps the bytes and only loses the classification.
                writer?.writeAsync(
                    type: automationSequences.contains(sequence) ? .automationInputV2 : .inputV2,
                    payload: RelayWireFrame.inputV2Payload(clientID: inputClientID, sequence: sequence, data: data)
                )
            }
        } else if !backlog.isEmpty {
            writer?.writeAsync(type: .input, payload: backlog)
        }
        // Older workers need an explicit resize after attachment. New workers
        // apply the Hello viewport before replay, so avoid a redundant
        // SIGWINCH and full-screen TUI redraw on every reconnect.
        if needsPostAttachResize, let (columns, rows) = resize {
            writeResize(columns: columns, rows: rows, using: writer)
        }
        if overflowed {
            context.onStatus(RelayStatus(
                state: "input_dropped",
                exitCode: nil,
                message: "Offline input reached 64 KiB; newer keystrokes were not queued."
            ), deliveryEpochSnapshot())
        }
    }

    private func scheduleReconnect(_ context: RelayConnectionContext, failure: SSHConnectionFailure,
        sourceProcess: Process) {
        dedicatedDeliveryLock.lock()
        defer { dedicatedDeliveryLock.unlock() }
        lock.lock()
        guard !detached, !reconnectScheduled, process === sourceProcess else {
            lock.unlock()
            return
        }
        writer = nil
        process = nil
        deliveryEpoch = UUID()
        attached = false
        reconnectScheduled = true
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        lock.unlock()

        let milliseconds = min(3_000, 150 * (1 << min(attempt - 1, 4)))
        let delay = milliseconds >= 1_000
            ? String(format: "%.1f", Double(milliseconds) / 1_000) + "s"
            : String(milliseconds) + "ms"
        let state = failure.kind == .networkRoute ? "waiting_for_network" : "reconnecting"
        context.onStatus(RelayStatus(
            state: state,
            exitCode: nil,
            message: failure.userMessage + " Retrying automatically in " + delay + "."
        ), deliveryEpochSnapshot())
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.detached else {
                self.lock.unlock()
                return
            }
            self.reconnectScheduled = false
            self.lock.unlock()
            self.connect(context)
        }
    }

    /// This phase only validates and records the packet. It performs no
    /// writer, diagnostic or observer callbacks while the caller holds its
    /// original IO binding lock.
    /// `automation` marks Relay's own keystrokes (native maintenance, compiled
    /// prompts). With `requireAutomation`, a worker that cannot classify them
    /// refuses admission instead of receiving them as human input.
    func preparePromptControlInput(_ data: Data,
        expectedControlLease lease: RelayPromptEditorControlLease,
        automation: Bool = false, requireAutomation: Bool = false) -> RelayPromptControlAdmission? {
        guard !data.isEmpty, data.count <= 64 << 10 else { return nil }
        lock.lock()
        guard !requireAutomation || automation && supportsAutomationInput else {
            lock.unlock()
            return nil
        }
        guard let context = connectionContext, let writer,
              context.profile.id == lease.hostID,
              context.sessionID == lease.paneID.uuidString.lowercased(),
              promptEditorConnectionID == lease.connectionID, inputClientID == lease.clientID,
              pendingInputBytes == 0,
              RelayPromptEditorLeasePolicy.admits(attached: attached, detached: detached,
                writerAvailable: true, controlGranted: promptEditorControlGranted,
                observer: context.observeAgentsOnly, acknowledgedInput: supportsInputAcknowledgements,
                pendingInput: !pendingInputs.isEmpty || !inputBacklog.isEmpty, overflowed: inputOverflowed) else {
            lock.unlock()
            return nil
        }
        let sequence = RelayInputSequenceAllocator.shared.next()
        pendingInputs[sequence] = data
        pendingInputBytes = data.count
        let frameType: RelayWireType = automation && supportsAutomationInput ? .automationInputV2 : .inputV2
        if frameType == .automationInputV2 { automationInputSequences.insert(sequence) }
        let clientID = inputClientID
        let paneID = diagnosticSessionID
        let recordDiagnostic = inputDiagnosticCount < 8
        if recordDiagnostic { inputDiagnosticCount += 1 }
        lock.unlock()
        return RelayPromptControlAdmission { [weak self] in
            if recordDiagnostic {
                RelayDiagnostics.shared.record(category: "terminal-input", name: "transport-send",
                    details: ["pane_id": paneID, "bytes": String(data.count),
                        "writer": "true", "attached": "true", "acknowledged": "true",
                        "automation": String(frameType == .automationInputV2)])
            }
            if let self {
                self.lock.lock()
                self.signalPromptEditorLeaseChangedLocked()
                self.lock.unlock()
            }
            writer.writeAsync(type: frameType,
                payload: RelayWireFrame.inputV2Payload(clientID: clientID, sequence: sequence, data: data))
        }
    }

    @discardableResult
    func sendInput(_ data: Data, expectedControlLease: RelayPromptEditorControlLease? = nil) -> Bool {
        if let lease = expectedControlLease {
            return preparePromptControlInput(data, expectedControlLease: lease)?.dispatch() == true
        }
        guard !data.isEmpty else { return false }
        lock.lock()
        let writer = self.writer
        let canSend = writer != nil && attached
        let acknowledged = supportsInputAcknowledgements
        let shouldRecordDiagnostic = inputDiagnosticCount < 8
        if shouldRecordDiagnostic { inputDiagnosticCount += 1 }
        let diagnosticSessionID = self.diagnosticSessionID
        var inputSequence: UInt64?
        var processToRestart: Process?
        var multiplexedRetryContext: RelayConnectionContext?
        var admitted = canSend
        if canSend && acknowledged && pendingInputBytes + data.count <= 64 << 10 {
            let sequence = RelayInputSequenceAllocator.shared.next()
            inputSequence = sequence
            pendingInputs[sequence] = data
            pendingInputBytes += data.count
        } else if canSend && acknowledged {
            if inputBacklog.count + data.count <= 64 << 10 {
                inputBacklog.append(data)
            } else {
                inputOverflowed = true
                admitted = false
            }
            attached = false
            processToRestart = process
            // On the multiplexed node channel there is no dedicated process
            // to restart; reattach the pane instead, or the backlogged bytes
            // would also be sent immediately below (duplicated input) and the
            // pane's input would stall until an unrelated disconnect.
            if processToRestart == nil { multiplexedRetryContext = connectionContext }
        } else if !canSend {
            if inputBacklog.count + data.count <= 64 << 10 {
                inputBacklog.append(data)
                admitted = true
            } else {
                inputOverflowed = true
                admitted = false
            }
        }
        lock.unlock()
        if shouldRecordDiagnostic {
            RelayDiagnostics.shared.record(
                category: "terminal-input",
                name: "transport-send",
                details: [
                    "pane_id": diagnosticSessionID,
                    "bytes": String(data.count),
                    "writer": String(writer != nil),
                    "attached": String(canSend),
                    "acknowledged": String(acknowledged),
                    "terminal_report": TerminalInputDiagnosticReport.name(data),
                ]
            )
        }
        processToRestart?.terminate()
        if processToRestart != nil { return admitted }
        if let multiplexedRetryContext {
            scheduleMultiplexedRetry(multiplexedRetryContext, waitingForInputLease: false)
            return admitted
        }
        guard canSend, let writer else { return admitted }
        if let inputSequence {
            writer.writeAsync(
                type: .inputV2,
                payload: RelayWireFrame.inputV2Payload(clientID: inputClientID, sequence: inputSequence, data: data)
            )
        } else {
            writer.writeAsync(type: .input, payload: data)
        }
        return admitted
    }

    @discardableResult
    func sendResize(
        columns: UInt16,
        rows: UInt16,
        forceRepaint: Bool = false,
        viewportChanged: Bool = false,
        compatibilityRepaintPulse _: Bool = false
    ) -> UInt64? {
        lock.lock()
        latestResize = (columns, rows)
        let writer = self.writer
        // Version 1 workers applied TIOCSWINSZ and then always sent another
        // SIGWINCH. That is correct for an unchanged grid but duplicates the
        // kernel signal for a changed one. Version 2 promises exactly one
        // signal, so only it may acknowledge a changed-grid atomic commit.
        let commitIsSignalSafe = TerminalViewportCommitPolicy.isSignalSafe(
            viewportChanged: viewportChanged,
            exactWorker: supportsExactViewportCommits,
            exactSupervisor: supportsExactSupervisorViewportCommits
        )
        let useCommit = forceRepaint &&
            (supportsViewportCommits || supportsSupervisorViewportCommits) &&
            commitIsSignalSafe &&
            attached && writer != nil
        let generation: UInt64?
        if useCommit {
            viewportGeneration &+= 1
            if viewportGeneration == 0 { viewportGeneration = 1 }
            generation = viewportGeneration
            pendingViewportAck = nil
        } else {
            generation = nil
        }
        lock.unlock()
        // Only advertise the grid Ghostty actually uses. An adjacent-size
        // probe lets the TUI emit output for a grid the renderer never had,
        // mixing cursor positions and scroll regions across two dimensions.
        if let generation {
            writer?.writeAsync(
                type: .viewportCommit,
                payload: RelayWireFrame.viewportCommitPayload(
                    generation: generation,
                    columns: columns,
                    rows: rows
                )
            )
            return generation
        }
        // A pre-viewport_commit worker understands only the original resize
        // frame. Never manufacture an intermediate grid to force a redraw.
        writeResize(columns: columns, rows: rows, using: writer)
        return nil
    }

    var committedAgentEventSequence: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lastEventSequence
    }

    private func receiveAgentEvent(_ data: Data, context: RelayConnectionContext) {
        let sequence = (try? JSONDecoder().decode(EventWireEnvelope.self, from: data))?.sequence
        lock.lock()
        let epoch = deliveryEpoch
        if let sequence, sequence > lastEventSequence { pendingAgentReceipts.received(sequence) }
        lock.unlock()
        context.onAgentEvent(data, epoch)
    }

    /// Called after the native UI has consumed the event, not when its task is
    /// merely queued. Rejected old-epoch work stays eligible for durable replay.
    func acknowledgeAgentEvent(_ data: Data, deliveryEpoch epoch: UUID) {
        guard let sequence = (try? JSONDecoder().decode(EventWireEnvelope.self, from: data))?.sequence else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !detached, deliveryEpoch == epoch else { return }
        if let cursor = pendingAgentReceipts.acknowledge(sequence) {
            lastEventSequence = max(lastEventSequence, cursor)
        }
    }

    private func receiveOutput(_ payload: Data, context: RelayConnectionContext) {
        guard payload.count >= 8 else { return }
        let sequence = payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        lock.lock()
        guard !detached, RelayOutputSequencePolicy.accepts(sequence, after: lastSequence) else {
            lock.unlock()
            return
        }
        lastSequence = max(lastSequence, sequence)
        let completion = takeViewportCompletionLocked()
        let epoch = deliveryEpoch
        lock.unlock()
        context.onOutput(Data(payload.dropFirst(8)), sequence, epoch)
        if isCurrentDeliveryEpoch(epoch), let completion { completion.handler(completion.generation, completion.epoch) }
    }

    private func receiveViewportAck(_ payload: Data) {
        guard let acknowledgement = RelayWireFrame.parseViewportAck(payload) else { return }
        lock.lock()
        guard acknowledgement.generation == viewportGeneration else {
            lock.unlock()
            return
        }
        pendingViewportAck = acknowledgement
        let completion = takeViewportCompletionLocked()
        lock.unlock()
        if let completion, isCurrentDeliveryEpoch(completion.epoch) {
            completion.handler(completion.generation, completion.epoch)
        }
    }

    private func takeViewportCompletionLocked() -> (
        generation: UInt64,
        epoch: UUID,
        handler: @Sendable (UInt64, UUID) -> Void
    )? {
        guard let pendingViewportAck,
              pendingViewportAck.repaintSequence <= lastSequence,
              let onViewportCommitted else { return nil }
        self.pendingViewportAck = nil
        return (pendingViewportAck.generation, deliveryEpoch, onViewportCommitted)
    }

    private func writeResize(columns: UInt16, rows: UInt16, using writer: (any RelayFrameWriting)?) {
        var payload = Data()
        var cols = columns.bigEndian
        var lines = rows.bigEndian
        withUnsafeBytes(of: &cols) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &lines) { payload.append(contentsOf: $0) }
        writer?.writeAsync(type: .resize, payload: payload)
    }

    /// Exercise the normal route recovery without closing the shared node or worker.
    /// Only an attached multiplexed pane can enter this path; its next Hello
    /// must attach an existing worker rather than creating a replacement.
    @discardableResult
    func reconnectExistingPaneRoute() -> Bool {
        lock.lock()
        // A dedicated fallback route reopens through the same retained-worker
        // reconnect as an interrupted connection: the next Hello requires the
        // existing worker and resumes from the last acknowledged sequences.
        if !detached, !sessionEnded, attached, hasAttachedWorker, nodeChannel == nil,
           !reconnectScheduled, let dedicated = process, let context = connectionContext {
            let dedicatedWriter = writer
            lock.unlock()
            context.onStatus(RelayStatus(state: "reconnecting",
                message: "Reopening this pane's terminal route."), deliveryEpochSnapshot())
            dedicatedWriter?.writeAsync(type: .detach)
            scheduleReconnect(context, failure: .diagnose("route reopen requested"), sourceProcess: dedicated)
            if dedicated.isRunning { dedicated.terminate() }
            return true
        }
        guard !detached, !sessionEnded, attached, hasAttachedWorker,
              !attachRetryScheduled, let channel = nodeChannel,
              let context = connectionContext else {
            lock.unlock()
            return false
        }
        attached = false
        lock.unlock()
        context.onStatus(RelayStatus(state: "reconnecting",
            message: "Reopening this pane's terminal route."), deliveryEpochSnapshot())
        channel.writeAsync(type: .detach)
        // Older busy supervisors may not advertise a closed virtual route.
        // Schedule our own scoped retry as well; the normal route_closed status
        // shares the same guard and cannot queue a second retry.
        scheduleMultiplexedRetry(context, waitingForInputLease: false)
        return true
    }

    func detach() {
        dedicatedDeliveryLock.lock()
        lock.lock()
        detached = true
        deliveryEpoch = UUID()
        attached = false
        let writer = self.writer
        let channel = nodeChannel
        let ssh = process
        nodeAdmission?.cancel()
        nodeAdmission = nil
        nodeChannel = nil
        process = nil
        self.writer = nil
        lock.unlock()
        dedicatedDeliveryLock.unlock()
        try? writer?.write(type: .detach)
        channel?.close()
        // terminate() on a stored-but-never-launched Process raises an
        // uncatchable NSInvalidArgumentException; connect() re-checks
        // `detached` after run() and finishes the termination for us.
        if let ssh, ssh.processIdentifier != 0 { ssh.terminate() }
    }
}

struct RelayViewport: Equatable, Sendable {
    static let `default` = RelayViewport(columns: 120, rows: 36)

    let columns: UInt16
    let rows: UInt16

    init(columns: Int, rows: Int) {
        self.columns = UInt16(clamping: max(1, columns))
        self.rows = UInt16(clamping: max(1, rows))
    }

    init(columns: UInt16, rows: UInt16) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

enum RelayTransportCapabilityPolicy {
    static func needsPostAttachResize(_ capabilities: [String]) -> Bool {
        !capabilities.contains("viewport_attach_v1")
    }

    static func supportsViewportCommit(_ capabilities: [String]) -> Bool {
        capabilities.contains("viewport_commit_v1") ||
            capabilities.contains("viewport_commit_v2")
    }

    static func supportsExactViewportCommit(_ capabilities: [String]) -> Bool {
        capabilities.contains("viewport_commit_v2")
    }
}

final class SSHDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        if data.count < 64 << 10 {
            data.append(chunk.prefix((64 << 10) - data.count))
        }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}

private struct RelayConnectionContext: Sendable {
    let profile: ConnectionProfile
    let sessionID: String
    let parentSessionID: String?
    let workspaceSessionID: String?
    let tabID: String?
    let paneTitle: String
    let contentKind: String
    let requiresExistingWorker: Bool
    let onOutput: @Sendable (Data, UInt64, UUID) -> Void
    let onStatus: @Sendable (RelayStatus, UUID) -> Void
    let onAgentEvent: @Sendable (Data, UUID) -> Void
    let onArtifact: @Sendable (RelayArtifact, UUID) -> Void
    let onDisconnect: @Sendable (String, UUID) -> Void
    let observeAgentsOnly: Bool
    /// Starting directory for a newly created worker (relayd hello
    /// working_directory). An existing worker keeps its own directory.
    var workingDirectory: String? = nil
}

struct StatusWirePayload: Decodable {
    let state: String
    let version: String?
    let protocolVersion: Int?
    let supervisorPID: Int?
    let exitCode: Int?
    let message: String?
    let capabilities: [String]?
    let outputReset: Bool?
    let eventReset: Bool?
    let controlGranted: Bool?
    let clientCount: Int?
    let programStatus: [RelayProgramStatusRecord]?
    let programStatusRevision: UInt64?
    let programStatusReplay: Bool?

    enum CodingKeys: String, CodingKey {
        case state
        case version
        case protocolVersion = "protocol_version"
        case supervisorPID = "supervisor_pid"
        case exitCode = "exit_code"
        case message, capabilities
        case outputReset = "output_reset"
        case eventReset = "event_reset"
        case controlGranted = "control_granted"
        case clientCount = "client_count"
        case programStatus = "program_status"
        case programStatusRevision = "program_status_revision"
        case programStatusReplay = "program_status_replay"
    }

    /// Go's wire bool uses omitempty: live false is absent, replay true is
    /// explicit. Normalize only program snapshots, not unrelated statuses.
    var normalizedProgramStatusReplay: Bool? {
        state == "program_status" ? (programStatusReplay ?? false) : programStatusReplay
    }
}

struct EventWireEnvelope: Decodable {
    let sequence: UInt64?

    enum CodingKeys: String, CodingKey {
        case sequence = "relay_event_seq"
    }
}

/// A route attached without the input lease shows output but cannot type or
/// resize. Retry with backoff; another Mac may legitimately hold the lease.
enum RelayInputLeaseRetryPolicy {
    static func needsRetry(capabilities: [String], controlGranted: Bool?, observeAgentsOnly: Bool) -> Bool {
        !observeAgentsOnly && capabilities.contains("input_lease_v1") && controlGranted != true
    }

    static func delayMilliseconds(attempt: Int) -> Int {
        min(30_000, 5_000 << min(max(attempt, 1) - 1, 3))
    }
}

/// A worker denies resize and repaint to a client without the input lease.
/// The attach that later obtains the lease must request the repaint itself.
enum RelayAttachRepaintPolicy {
    /// Only attach_repaint_v2 workers repaint an unchanged grid in place.
    /// A retained v1 worker pulses a temporary row count, producing bytes for
    /// a grid the renderer never had; for those, the client's actual-grid
    /// width repaint (deferred until control is granted) remains the path.
    static func owesRepaintAfterAttach(capabilities: [String], controlGranted: Bool?, observeAgentsOnly: Bool) -> Bool {
        capabilities.contains("attach_repaint_v2") &&
            RelayInputLeaseRetryPolicy.needsRetry(capabilities: capabilities,
                controlGranted: controlGranted, observeAgentsOnly: observeAgentsOnly)
    }

    static func routeAcceptsResize(attached: Bool, leaseCapable: Bool, controlGranted: Bool) -> Bool {
        attached && (!leaseCapable || controlGranted)
    }
}

enum RelayWireType: UInt8 {
    case unsupported = 0
    case hello = 1, input, resize, output, status, detach, ping, pong, agentEvent, artifact, inputAck, inputV2, hostEvent, workspaceState, viewportCommit, viewportAck, hostRequest, hostResponse, fragment, capabilities
    /// Same payload as inputV2; the worker does not count it as human input.
    case automationInputV2 = 22
}

struct RelayWireFrame {
    static let maximumPayloadBytes = 16 << 20

    let type: RelayWireType
    let payload: Data

    /// `progress` runs after every chunk read, before the frame is complete.
    static func read(from handle: FileHandle, progress: () -> Void = {}) throws -> RelayWireFrame {
        let header = try readExactly(5, from: handle, progress: progress)
        let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(length) <= maximumPayloadBytes else { throw RelayWireError.invalidFrame }
        // Consume the declared payload before classifying the frame. A newer
        // relayd may introduce a type this app does not know yet; dropping
        // that one complete frame preserves the boundary of every frame after
        // it instead of tearing down an otherwise healthy SSH connection.
        let payload = try readExactly(Int(length), from: handle, progress: progress)
        let type = RelayWireType(rawValue: header[0]) ?? .unsupported
        return RelayWireFrame(type: type, payload: payload)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle, progress: () -> Void) throws -> Data {
        if count == 0 { return Data() }
        var data = Data()
        // read(2) returns whatever the pipe holds; FileHandle.read(upToCount:)
        // waits for the whole count, so a slow payload would show no progress.
        var chunk = [UInt8](repeating: 0, count: min(count, 64 << 10))
        while data.count < count {
            let wanted = min(count - data.count, chunk.count)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, wanted) }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard n > 0 else { throw RelayWireError.endOfStream }
            data.append(contentsOf: chunk[..<n])
            progress()
        }
        return data
    }

    static func parseArtifact(_ payload: Data) -> RelayArtifact? {
        guard payload.count >= 4 else { return nil }
        let pathLength = payload.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard pathLength > 0, Int(pathLength) <= payload.count - 4 else { return nil }
        let pathData = payload.subdata(in: 4..<(4 + Int(pathLength)))
        guard let path = String(data: pathData, encoding: .utf8) else { return nil }
        return RelayArtifact(path: path, data: payload.subdata(in: (4 + Int(pathLength))..<payload.count))
    }

    static func inputV2Payload(clientID: UUID, sequence: UInt64, data: Data) -> Data {
        var payload = Data()
        var uuid = clientID.uuid
        withUnsafeBytes(of: &uuid) { payload.append(contentsOf: $0) }
        var bigEndianSequence = sequence.bigEndian
        withUnsafeBytes(of: &bigEndianSequence) { payload.append(contentsOf: $0) }
        payload.append(data)
        return payload
    }

    static func viewportCommitPayload(
        generation: UInt64,
        columns: UInt16,
        rows: UInt16
    ) -> Data {
        var payload = Data()
        var bigEndianGeneration = generation.bigEndian
        var bigEndianColumns = columns.bigEndian
        var bigEndianRows = rows.bigEndian
        withUnsafeBytes(of: &bigEndianGeneration) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &bigEndianColumns) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &bigEndianRows) { payload.append(contentsOf: $0) }
        return payload
    }

    static func parseViewportAck(_ payload: Data) -> (
        generation: UInt64,
        repaintSequence: UInt64
    )? {
        guard payload.count == 16 else { return nil }
        let generation = payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let repaintSequence = payload.dropFirst(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard generation > 0 else { return nil }
        return (generation, repaintSequence)
    }

    static func parseInputAck(_ payload: Data) -> (clientID: UUID, sequence: UInt64)? {
        guard payload.count == 24 else { return nil }
        let uuidBytes = payload.prefix(16)
        let uuid = uuidBytes.withUnsafeBytes { bytes -> uuid_t in
            let pointer = bytes.bindMemory(to: UInt8.self)
            return (
                pointer[0], pointer[1], pointer[2], pointer[3],
                pointer[4], pointer[5], pointer[6], pointer[7],
                pointer[8], pointer[9], pointer[10], pointer[11],
                pointer[12], pointer[13], pointer[14], pointer[15]
            )
        }
        let sequence = payload.dropFirst(16).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return (UUID(uuid: uuid), sequence)
    }

    static func hostEvent(sessionID: String, inner: RelayWireFrame) -> RelayWireFrame? {
        let session = Data(sessionID.utf8)
        guard !session.isEmpty, session.count <= Int(UInt16.max) else { return nil }
        var payload = Data()
        var length = UInt16(session.count).bigEndian
        withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
        payload.append(inner.type.rawValue)
        payload.append(session)
        payload.append(inner.payload)
        return RelayWireFrame(type: .hostEvent, payload: payload)
    }

    static func parseHostEvent(_ frame: RelayWireFrame) -> (sessionID: String, inner: RelayWireFrame)? {
        guard frame.type == .hostEvent, frame.payload.count >= 3 else { return nil }
        let length = frame.payload.prefix(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        guard length > 0, 3 + Int(length) <= frame.payload.count,
              let sessionID = String(data: frame.payload.subdata(in: 3..<(3 + Int(length))), encoding: .utf8) else {
            return nil
        }
        let type = RelayWireType(rawValue: frame.payload[2]) ?? .unsupported
        return (sessionID, RelayWireFrame(type: type, payload: frame.payload.subdata(in: (3 + Int(length))..<frame.payload.count)))
    }
}

enum RelayWireError: Error { case invalidFrame, endOfStream }

protocol RelayFrameWriting: AnyObject, Sendable {
    func write(type: RelayWireType, payload: Data) throws
    func writeAsync(type: RelayWireType, payload: Data)
}

extension RelayFrameWriting {
    func write(type: RelayWireType) throws { try write(type: type, payload: Data()) }
    func writeAsync(type: RelayWireType) { writeAsync(type: type, payload: Data()) }
}

final class RelayWireWriter: RelayFrameWriting, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.relay.terminal-wire", qos: .userInteractive)
    private let onError: @Sendable (String) -> Void
    private var reportedFailure = false

    init(
        _ handle: FileHandle,
        onError: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.handle = handle
        self.onError = onError
    }

    func write(type: RelayWireType, payload: Data = Data()) throws {
        guard payload.count <= RelayWireFrame.maximumPayloadBytes else {
            let error = RelayWireError.invalidFrame
            report(error)
            throw error
        }
        var header = Data([type.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        lock.lock()
        do {
            try handle.write(contentsOf: header)
            if !payload.isEmpty { try handle.write(contentsOf: payload) }
            lock.unlock()
        } catch {
            lock.unlock()
            report(error)
            throw error
        }
    }

    func writeAsync(type: RelayWireType, payload: Data = Data()) {
        queue.async {
            // write() reports the first failure to the connection owner. The
            // owner then closes SSH, whose normal termination path reconnects
            // and replays acknowledged input rather than silently losing it.
            try? self.write(type: type, payload: payload)
        }
    }

    private func report(_ error: Error) {
        lock.lock()
        guard !reportedFailure else {
            lock.unlock()
            return
        }
        reportedFailure = true
        lock.unlock()
        onError(error.localizedDescription)
    }
}
