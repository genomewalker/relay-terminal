import Foundation

enum RelayAgentObserverHello {
    static func payload(sessionID: String, lastEventSequence: UInt64) -> [String: Any] {
        [
            "version": 1,
            "session_id": sessionID,
            "cols": RelayViewport.default.columns,
            "rows": RelayViewport.default.rows,
            "last_seq": 0,
            "last_event_seq": lastEventSequence,
            "observe_events": true,
        ]
    }
}

@MainActor
final class RelayHostAgentMonitorToken {
    private let monitor: RelayHostAgentMonitor
    private let hostKey: String
    private let subscriptionID: UUID
    private let sessionID: String
    private var stopped = false

    init(monitor: RelayHostAgentMonitor, hostKey: String, subscriptionID: UUID, sessionID: String) {
        self.monitor = monitor
        self.hostKey = hostKey
        self.subscriptionID = subscriptionID
        self.sessionID = sessionID
    }

    /// The pane's agent may have changed: identify it at the fast interval.
    func expectHarnessChange() {
        guard !stopped else { return }
        monitor.expectHarnessChange(hostKey: hostKey, sessionID: sessionID)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        monitor.unsubscribe(hostKey: hostKey, subscriptionID: subscriptionID)
    }
}

/// The host stream that carries agent events. Its attachment says only that
/// this observer is attached, never that a pane's terminal route connected.
protocol RelayHostAgentObserving: AnyObject, Sendable {
    /// `onAttached` names the attached session, or nil when one stream
    /// attached for every session.
    func start(profile: ConnectionProfile, sessions: [String: UInt64],
               onEvent: @escaping @Sendable (String, Data) -> Void,
               onAttached: @escaping @Sendable (String?) -> Void)
    /// Observes one more session without disturbing the others. False when
    /// only a restart can add it.
    func addSession(_ sessionID: String, cursor: UInt64) -> Bool
    func stop()
}

@MainActor
final class RelayHostAgentMonitor {
    static let shared = RelayHostAgentMonitor(
        makeTransport: { RelayHostAgentMonitor.liveTransport() },
        queryHarnesses: RelayHostAgentMonitor.queryInstalledHelper
    )

    /// Runs `relayd agent-harnesses` for the panes; returns its exit code and stdout.
    typealias HarnessQuery = @MainActor (ConnectionProfile, [String]) async throws -> (exitCode: Int, stdout: Data)

    private let makeTransport: @MainActor () -> any RelayHostAgentObserving
    private let queryHarnesses: HarnessQuery

    /// Tests pass a controlled transport and harness query.
    init(makeTransport: @escaping @MainActor () -> any RelayHostAgentObserving, queryHarnesses: @escaping HarnessQuery) {
        self.makeTransport = makeTransport
        self.queryHarnesses = queryHarnesses
    }

    nonisolated static func liveTransport() -> any RelayHostAgentObserving { RelayHostAgentTransport() }

    static func queryInstalledHelper(profile: ConnectionProfile, panes: [String]) async throws -> (exitCode: Int, stdout: Data) {
        let command = RelayHostExecution.daemonCommand(profile: profile, arguments: ["agent-harnesses"] + panes)
        let output = try await RelayHostExecution.capture(profile: profile, command: command,
            timeout: 8, maximumBytes: 256 << 10)
        return (output.exitCode, output.stdout)
    }

    private struct Subscription {
        let sessionID: String
        let onEvent: (Data) -> Void
        let onObserverAttached: () -> Void
        let onHarness: ((AgentHarnessIdentity) -> Void)?
    }

    // Access is confined to RelayHostAgentMonitor's main-actor methods. The
    // unchecked conformance only permits a weak identity token to cross the
    // transport callback boundary before it is re-entered on MainActor.
    private final class HostEntry: @unchecked Sendable {
        let profile: ConnectionProfile
        var subscriptions: [UUID: Subscription] = [:]
        var eventCursors: [String: UInt64] = [:]
        var transport: (any RelayHostAgentObserving)?
        var restartTask: Task<Void, Never>?
        var harnessTask: Task<Void, Never>?
        var harnessNap: Task<Void, Never>?
        var identified: Set<String> = []
        var harnessHints: [String: Date] = [:]

        init(profile: ConnectionProfile) { self.profile = profile }
    }

    private var hosts: [String: HostEntry] = [:]
    private var visibleByWorkspace: [ObjectIdentifier: Set<String>] = [:]
    private var visibleSessions: Set<String> { visibleByWorkspace.values.reduce(into: []) { $0.formUnion($1) } }

    /// Harness identification is a durable host job per poll. It runs every
    /// 3 s only while the app is active and a visible pane awaits its first
    /// identity, or a pane expects a change; otherwise every 20 s.
    nonisolated static let harnessHotInterval: Double = 3
    nonisolated static let harnessColdInterval: Double = 20
    static let harnessHintLifetime: TimeInterval = 30

    nonisolated static func harnessDelay(active: Bool, panes: [String], identified: Set<String>, visible: Set<String>,
                             hints: [String: Date], now: Date, retryDelay: Double) -> Double {
        let hot = active && panes.contains { pane in
            (visible.contains(pane) && !identified.contains(pane)) || hints[pane].map { now < $0 } == true
        }
        return max(hot ? harnessHotInterval : harnessColdInterval, retryDelay)
    }

    /// The panes in a workspace's selected tab. A newly visible pane with no
    /// identity yet is identified at the fast interval.
    func setVisibleSessions(_ sessions: Set<String>, workspace: ObjectIdentifier) {
        guard sessions != visibleByWorkspace[workspace] else { return }
        visibleByWorkspace[workspace] = sessions.isEmpty ? nil : sessions
        for entry in hosts.values where entry.subscriptions.values.contains(where: {
            sessions.contains($0.sessionID) && !entry.identified.contains($0.sessionID)
        }) { entry.harnessNap?.cancel() }
    }

    /// A pane's agent may have started, stopped or been replaced: identify it
    /// at the fast interval for a while.
    func expectHarnessChange(profile: ConnectionProfile, sessionID: String) {
        expectHarnessChange(hostKey: hostKey(profile), sessionID: sessionID)
    }

    func expectHarnessChange(hostKey: String, sessionID: String) {
        guard let entry = hosts[hostKey],
              entry.subscriptions.values.contains(where: { $0.sessionID == sessionID }) else { return }
        entry.harnessHints[sessionID] = Date().addingTimeInterval(Self.harnessHintLifetime)
        entry.harnessNap?.cancel()
    }

    func subscribe(
        profile: ConnectionProfile,
        sessionID: String,
        lastEventSequence: UInt64,
        onEvent: @escaping (Data) -> Void,
        onObserverAttached: @escaping () -> Void,
        onHarness: ((AgentHarnessIdentity) -> Void)? = nil
    ) -> RelayHostAgentMonitorToken {
        let key = hostKey(profile)
        let entry = hosts[key] ?? HostEntry(profile: profile)
        hosts[key] = entry
        let subscriptionID = UUID()
        entry.subscriptions[subscriptionID] = Subscription(
            sessionID: sessionID, onEvent: onEvent, onObserverAttached: onObserverAttached, onHarness: onHarness
        )
        let observed = entry.eventCursors[sessionID] != nil
        let cursor = max(entry.eventCursors[sessionID] ?? 0, lastEventSequence)
        entry.eventCursors[sessionID] = cursor
        entry.harnessHints[sessionID] = Date().addingTimeInterval(Self.harnessHintLifetime)
        // A running stream gains the session in place: restarting it would
        // re-attach every other pane's observer for one new pane.
        let joined = entry.restartTask == nil
            && entry.transport.map { observed || $0.addSession(sessionID, cursor: cursor) } == true
        if !joined { scheduleRestart(key: key, entry: entry) }
        // Identify the new pane now, not after the current harness nap.
        entry.harnessNap?.cancel()
        return RelayHostAgentMonitorToken(monitor: self, hostKey: key, subscriptionID: subscriptionID, sessionID: sessionID)
    }

    func unsubscribe(hostKey: String, subscriptionID: UUID) {
        guard let entry = hosts[hostKey] else { return }
        entry.subscriptions.removeValue(forKey: subscriptionID)
        let retainedSessions = Set(entry.subscriptions.values.map(\.sessionID))
        entry.eventCursors = entry.eventCursors.filter { retainedSessions.contains($0.key) }
        entry.identified.formIntersection(retainedSessions)
        entry.harnessHints = entry.harnessHints.filter { retainedSessions.contains($0.key) }
        if entry.subscriptions.isEmpty {
            entry.restartTask?.cancel()
            entry.harnessTask?.cancel()
            entry.harnessNap?.cancel()
            entry.transport?.stop()
            hosts.removeValue(forKey: hostKey)
        } else {
            scheduleRestart(key: hostKey, entry: entry)
        }
    }

    private func scheduleRestart(key: String, entry: HostEntry) {
        entry.restartTask?.cancel()
        entry.restartTask = Task { [weak self, weak entry] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let entry, self.hosts[key] === entry else { return }
            entry.restartTask = nil
            self.startHarnessIdentification(key: key, entry: entry)
            entry.transport?.stop()
            let transport = self.makeTransport()
            entry.transport = transport
            let sessions = entry.eventCursors
            transport.start(profile: entry.profile, sessions: sessions) { [weak self, weak entry] sessionID, payload in
                Task { @MainActor in
                    guard let self, let entry, self.hosts[key] === entry else { return }
                    if let sequence = Self.eventSequence(in: payload) {
                        entry.eventCursors[sessionID] = max(entry.eventCursors[sessionID] ?? 0, sequence)
                    }
                    for subscription in entry.subscriptions.values where subscription.sessionID == sessionID {
                        subscription.onEvent(payload)
                    }
                }
            } onAttached: { [weak self, weak entry] sessionID in
                Task { @MainActor in
                    guard let self, let entry, self.hosts[key] === entry else { return }
                    for subscription in entry.subscriptions.values where sessionID == nil || subscription.sessionID == sessionID {
                        subscription.onObserverAttached()
                    }
                }
            }
        }
    }

    private func hostKey(_ profile: ConnectionProfile) -> String {
        ([profile.host] + profile.sshConnectionArguments).joined(separator: "\u{0}")
    }

    // One host batch covers the subscribed panes, including old live workers.
    // Run the installed helper through Relay's existing host transport so a
    // stale event journal cannot turn a running CLI into a shell.
    private func startHarnessIdentification(key: String, entry: HostEntry) {
        guard entry.harnessTask == nil else { return }
        entry.harnessTask = Task { [weak self, weak entry] in
            var retryDelay: Double = 0
            while !Task.isCancelled {
                guard let self, let entry, self.hosts[key] === entry else { return }
                let panes = Array(Set(entry.subscriptions.values.filter { $0.onHarness != nil }.map(\.sessionID))).sorted()
                if !panes.isEmpty {
                    do {
                        try Task.checkCancellation()
                        let output = try await self.queryHarnesses(entry.profile, panes)
                        try Task.checkCancellation()
                        guard self.hosts[key] === entry else { return }
                        let report = output.exitCode == 0 ? try JSONDecoder().decode(AgentHarnessReport.self, from: output.stdout) : nil
                        if let report, report.version == 1 {
                            retryDelay = 0
                            // Every pane asked about is answered, with or without an agent.
                            entry.identified.formUnion(panes)
                            for identity in report.panes where panes.contains(identity.paneID.uuidString.lowercased()) {
                                let session = identity.paneID.uuidString.lowercased()
                                for subscription in entry.subscriptions.values where subscription.sessionID == session {
                                    subscription.onHarness?(identity)
                                }
                            }
                        } else {
                            // A failed command or an unknown report version backs off alike.
                            retryDelay = min(60, max(3, retryDelay) * 2)
                        }
                    } catch is CancellationError { return }
                    catch { retryDelay = min(60, max(3, retryDelay) * 2) }
                }
                let now = Date()
                entry.harnessHints = entry.harnessHints.filter { now < $0.value }
                let delay = Self.harnessDelay(active: RelayApplicationActivityState.allowsContinuousUpdates, panes: panes,
                    identified: entry.identified, visible: self.visibleSessions, hints: entry.harnessHints,
                    now: now, retryDelay: retryDelay)
                // A hint or a newly visible pane cancels the nap, not the loop.
                let nap = Task { _ = try? await Task.sleep(for: .seconds(delay)) }
                entry.harnessNap = nap
                await withTaskCancellationHandler { await nap.value } onCancel: { nap.cancel() }
                entry.harnessNap = nil
                if Task.isCancelled { return }
            }
        }
    }

    private static func eventSequence(in payload: Data) -> UInt64? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let number = object["relay_event_seq"] as? NSNumber else { return nil }
        return number.uint64Value
    }
}

private final class RelayHostAgentTransport: RelayHostAgentObserving, @unchecked Sendable {
    private final class EventCursor: @unchecked Sendable {
        private let lock = NSLock()
        private var sequence: UInt64

        init(_ sequence: UInt64) { self.sequence = sequence }

        var value: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return sequence
        }

        func observe(_ payload: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let number = object["relay_event_seq"] as? NSNumber else { return }
            lock.lock()
            sequence = max(sequence, number.uint64Value)
            lock.unlock()
        }
    }

    private let lock = NSLock()
    private var channels: [String: RelayNodeChannel] = [:]
    private var legacyTransport: RelayLegacyHostAgentTransport?
    private var stopped = false
    private var profile: ConnectionProfile?
    private var sessions: [String: UInt64] = [:]
    private var onEvent: (@Sendable (String, Data) -> Void)?
    private var onAttached: (@Sendable (String?) -> Void)?

    func start(
        profile: ConnectionProfile,
        sessions: [String: UInt64],
        onEvent: @escaping @Sendable (String, Data) -> Void,
        onAttached: @escaping @Sendable (String?) -> Void
    ) {
        lock.lock()
        stopped = false
        self.profile = profile
        self.sessions = sessions
        self.onEvent = onEvent
        self.onAttached = onAttached
        lock.unlock()
        for (sessionID, cursor) in sessions {
            startMultiplexedObserver(
                profile: profile,
                sessionID: sessionID,
                cursor: cursor,
                onEvent: onEvent,
                onAttached: onAttached
            )
        }
    }

    func addSession(_ sessionID: String, cursor: UInt64) -> Bool {
        lock.lock()
        // The legacy observe-many command fixes its session list at launch.
        guard !stopped, legacyTransport == nil, let profile, let onEvent, let onAttached else {
            lock.unlock()
            return false
        }
        guard sessions[sessionID] == nil else { lock.unlock(); return true }
        sessions[sessionID] = cursor
        lock.unlock()
        startMultiplexedObserver(profile: profile, sessionID: sessionID, cursor: cursor,
                                 onEvent: onEvent, onAttached: onAttached)
        return true
    }

    private func startMultiplexedObserver(
        profile: ConnectionProfile,
        sessionID: String,
        cursor: UInt64,
        onEvent: @escaping @Sendable (String, Data) -> Void,
        onAttached: @escaping @Sendable (String?) -> Void
    ) {
        let routeID = "observer_" + UUID().uuidString.lowercased()
        let eventCursor = EventCursor(cursor)
        let created = RelayNodeTransportPool.shared.attach(
            profile: profile,
            sessionID: routeID,
            onReady: { [weak self] channel in
                guard let self else { return }
                guard channel.supports("node_mux_v2") else {
                    self.startLegacy(profile: profile, onEvent: onEvent, onAttached: onAttached)
                    return
                }
                // event_only is the publisher role, not an observer modifier.
                // Older workers dispatch publishers first and would wait for
                // input forever if both flags were sent.
                let hello = RelayAgentObserverHello.payload(
                    sessionID: sessionID, lastEventSequence: eventCursor.value
                )
                guard let payload = try? JSONSerialization.data(withJSONObject: hello) else { return }
                channel.writeAsync(type: .hello, payload: payload)
            },
            onFrame: { frame in
                switch frame.type {
                case .agentEvent:
                    eventCursor.observe(frame.payload)
                    onEvent(sessionID, frame.payload)
                case .status:
                    if let status = try? JSONDecoder().decode(StatusWirePayload.self, from: frame.payload),
                       status.state == "attached" {
                        onAttached(sessionID)
                    }
                default:
                    break
                }
            },
            onDisconnect: { _ in }
        )
        lock.lock()
        if stopped || legacyTransport != nil {
            lock.unlock()
            created.close()
        } else {
            channels[sessionID] = created
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let activeChannels = Array(channels.values)
        channels.removeAll()
        let legacyTransport = self.legacyTransport
        self.legacyTransport = nil
        lock.unlock()
        activeChannels.forEach { $0.close() }
        legacyTransport?.stop()
    }

    private func startLegacy(
        profile: ConnectionProfile,
        onEvent: @escaping @Sendable (String, Data) -> Void,
        onAttached: @escaping @Sendable (String?) -> Void
    ) {
        lock.lock()
        guard !stopped, legacyTransport == nil else { lock.unlock(); return }
        let sessions = self.sessions
        let activeChannels = Array(channels.values)
        channels.removeAll()
        let legacy = RelayLegacyHostAgentTransport()
        legacyTransport = legacy
        lock.unlock()
        activeChannels.forEach { $0.close() }
        legacy.start(profile: profile, sessions: sessions, onEvent: onEvent, onAttached: { onAttached(nil) })
    }
}

private final class RelayLegacyHostAgentTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var profile: ConnectionProfile?
    private var sessions: [String: UInt64] = [:]
    private var onEvent: (@Sendable (String, Data) -> Void)?
    private var onAttached: (@Sendable () -> Void)?

    func start(
        profile: ConnectionProfile,
        sessions: [String: UInt64],
        onEvent: @escaping @Sendable (String, Data) -> Void,
        onAttached: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        self.profile = profile
        self.sessions = sessions
        self.onEvent = onEvent
        self.onAttached = onAttached
        stopped = false
        lock.unlock()
        connect()
    }

    func stop() {
        lock.lock()
        stopped = true
        let process = self.process
        self.process = nil
        lock.unlock()
        // terminate() on a stored-but-never-launched Process raises an
        // uncatchable NSInvalidArgumentException; connect() re-checks
        // `stopped` after run() and finishes the termination for us.
        if let process, process.processIdentifier != 0 { process.terminate() }
    }

    private func connect() {
        lock.lock()
        guard !stopped, let profile, !sessions.isEmpty else { lock.unlock(); return }
        let sessionList = sessions.keys.sorted().map { "\($0):\(sessions[$0] ?? 0)" }.joined(separator: ",")
        lock.unlock()

        let ssh = Process()
        let input = Pipe()
        let output = Pipe()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=2",
            "-o", "ServerAliveCountMax=2", "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
        ] + profile.sshConnectionArguments + [
            "~/.local/bin/relayd", "observe-many", "--sessions", sessionList,
        ]
        ssh.standardInput = input
        if profile.kind == .local {
            LocalRelayProcess.configure(ssh)
            ssh.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relayd")
            ssh.arguments = ["observe-many", "--sessions", sessionList]
        }
        ssh.standardOutput = output
        ssh.standardError = FileHandle.nullDevice
        ssh.terminationHandler = { [weak self] ended in self?.didEnd(ended) }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        process = ssh
        lock.unlock()
        do {
            try ssh.run()
        } catch {
            didEnd(ssh)
            return
        }
        lock.lock()
        let cancelled = stopped || process !== ssh
        lock.unlock()
        if cancelled {
            ssh.terminate()
            return
        }
        onAttached?()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.readFrames(output.fileHandleForReading)
        }
    }

    private func readFrames(_ handle: FileHandle) {
        while true {
            let received = autoreleasepool { () -> Bool in
                guard let frame = try? RelayWireFrame.read(from: handle) else { return false }
                guard let envelope = RelayWireFrame.parseHostEvent(frame),
                      envelope.inner.type == .agentEvent else { return true }
                // Advance the per-session cursor so the 1-second reconnect
                // resumes from the last delivered event instead of replaying
                // the whole backlog since start() after every network blip.
                if let decoded = try? JSONDecoder().decode(EventWireEnvelope.self, from: envelope.inner.payload),
                   let sequence = decoded.sequence {
                    lock.lock()
                    sessions[envelope.sessionID] = max(sessions[envelope.sessionID] ?? 0, sequence)
                    lock.unlock()
                }
                onEvent?(envelope.sessionID, envelope.inner.payload)
                return true
            }
            if !received { return }
        }
    }

    private func didEnd(_ ended: Process) {
        lock.lock()
        guard process === ended, !stopped else { lock.unlock(); return }
        process = nil
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }
}
