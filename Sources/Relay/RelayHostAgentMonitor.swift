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
    private let hostKey: String
    private let subscriptionID: UUID
    private var stopped = false

    init(hostKey: String, subscriptionID: UUID) {
        self.hostKey = hostKey
        self.subscriptionID = subscriptionID
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        RelayHostAgentMonitor.shared.unsubscribe(hostKey: hostKey, subscriptionID: subscriptionID)
    }
}

@MainActor
final class RelayHostAgentMonitor {
    static let shared = RelayHostAgentMonitor()

    private struct Subscription {
        let sessionID: String
        let onEvent: (Data) -> Void
        let onAttached: () -> Void
        let onHarness: ((AgentHarnessIdentity) -> Void)?
    }

    // Access is confined to RelayHostAgentMonitor's main-actor methods. The
    // unchecked conformance only permits a weak identity token to cross the
    // transport callback boundary before it is re-entered on MainActor.
    private final class HostEntry: @unchecked Sendable {
        let profile: ConnectionProfile
        var subscriptions: [UUID: Subscription] = [:]
        var eventCursors: [String: UInt64] = [:]
        var transport: RelayHostAgentTransport?
        var restartTask: Task<Void, Never>?
        var harnessTask: Task<Void, Never>?

        init(profile: ConnectionProfile) { self.profile = profile }
    }

    private var hosts: [String: HostEntry] = [:]

    func subscribe(
        profile: ConnectionProfile,
        sessionID: String,
        lastEventSequence: UInt64,
        onEvent: @escaping (Data) -> Void,
        onAttached: @escaping () -> Void,
        onHarness: ((AgentHarnessIdentity) -> Void)? = nil
    ) -> RelayHostAgentMonitorToken {
        let key = hostKey(profile)
        let entry = hosts[key] ?? HostEntry(profile: profile)
        hosts[key] = entry
        let subscriptionID = UUID()
        entry.subscriptions[subscriptionID] = Subscription(
            sessionID: sessionID, onEvent: onEvent, onAttached: onAttached, onHarness: onHarness
        )
        entry.eventCursors[sessionID] = max(entry.eventCursors[sessionID] ?? 0, lastEventSequence)
        scheduleRestart(key: key, entry: entry)
        return RelayHostAgentMonitorToken(hostKey: key, subscriptionID: subscriptionID)
    }

    func unsubscribe(hostKey: String, subscriptionID: UUID) {
        guard let entry = hosts[hostKey] else { return }
        entry.subscriptions.removeValue(forKey: subscriptionID)
        let retainedSessions = Set(entry.subscriptions.values.map(\.sessionID))
        entry.eventCursors = entry.eventCursors.filter { retainedSessions.contains($0.key) }
        if entry.subscriptions.isEmpty {
            entry.restartTask?.cancel()
            entry.harnessTask?.cancel()
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
            self.startHarnessIdentification(key: key, entry: entry)
            entry.transport?.stop()
            let transport = RelayHostAgentTransport()
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
            } onAttached: { [weak self, weak entry] in
                Task { @MainActor in
                    guard let self, let entry, self.hosts[key] === entry else { return }
                    entry.subscriptions.values.forEach { $0.onAttached() }
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
            var retryDelay: Double = 3
            while !Task.isCancelled {
                guard let self, let entry, self.hosts[key] === entry else { return }
                let panes = Array(Set(entry.subscriptions.values.filter { $0.onHarness != nil }.map(\.sessionID))).sorted()
                if !panes.isEmpty {
                    do {
                        try Task.checkCancellation()
                        let command = RelayHostExecution.daemonCommand(profile: entry.profile,
                            arguments: ["agent-harnesses"] + panes)
                        let output = try await RelayHostExecution.capture(profile: entry.profile, command: command,
                            timeout: 8, maximumBytes: 256 << 10)
                        try Task.checkCancellation()
                        guard self.hosts[key] === entry else { return }
                        if output.exitCode == 0 {
                            let report = try JSONDecoder().decode(AgentHarnessReport.self, from: output.stdout)
                            if report.version == 1 {
                                retryDelay = 3
                                for identity in report.panes where panes.contains(identity.paneID.uuidString.lowercased()) {
                                    for subscription in entry.subscriptions.values where subscription.sessionID == identity.paneID.uuidString.lowercased() {
                                        subscription.onHarness?(identity)
                                    }
                                }
                            }
                        } else {
                            retryDelay = min(60, retryDelay * 2)
                        }
                    } catch is CancellationError { return }
                    catch { retryDelay = min(60, retryDelay * 2) }
                }
                do { try await Task.sleep(for: .seconds(RelayApplicationActivityState.allowsContinuousUpdates ? retryDelay : max(15, retryDelay))) }
                catch { return }
            }
        }
    }

    private static func eventSequence(in payload: Data) -> UInt64? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let number = object["relay_event_seq"] as? NSNumber else { return nil }
        return number.uint64Value
    }
}

private final class RelayHostAgentTransport: @unchecked Sendable {
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

    func start(
        profile: ConnectionProfile,
        sessions: [String: UInt64],
        onEvent: @escaping @Sendable (String, Data) -> Void,
        onAttached: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        stopped = false
        lock.unlock()
        for (sessionID, cursor) in sessions {
            startMultiplexedObserver(
                profile: profile,
                sessionID: sessionID,
                cursor: cursor,
                allSessions: sessions,
                onEvent: onEvent,
                onAttached: onAttached
            )
        }
    }

    private func startMultiplexedObserver(
        profile: ConnectionProfile,
        sessionID: String,
        cursor: UInt64,
        allSessions: [String: UInt64],
        onEvent: @escaping @Sendable (String, Data) -> Void,
        onAttached: @escaping @Sendable () -> Void
    ) {
        let routeID = "observer_" + UUID().uuidString.lowercased()
        let eventCursor = EventCursor(cursor)
        let created = RelayNodeTransportPool.shared.attach(
            profile: profile,
            sessionID: routeID,
            onReady: { [weak self] channel in
                guard let self else { return }
                guard channel.supports("node_mux_v2") else {
                    self.startLegacy(
                        profile: profile,
                        sessions: allSessions,
                        onEvent: onEvent,
                        onAttached: onAttached
                    )
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
                        onAttached()
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
        sessions: [String: UInt64],
        onEvent: @escaping @Sendable (String, Data) -> Void,
        onAttached: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        guard !stopped, legacyTransport == nil else { lock.unlock(); return }
        let activeChannels = Array(channels.values)
        channels.removeAll()
        let legacy = RelayLegacyHostAgentTransport()
        legacyTransport = legacy
        lock.unlock()
        activeChannels.forEach { $0.close() }
        legacy.start(profile: profile, sessions: sessions, onEvent: onEvent, onAttached: onAttached)
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
