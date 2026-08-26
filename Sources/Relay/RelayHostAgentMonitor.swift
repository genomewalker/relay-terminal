import Foundation

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

        init(profile: ConnectionProfile) { self.profile = profile }
    }

    private var hosts: [String: HostEntry] = [:]

    func subscribe(
        profile: ConnectionProfile,
        sessionID: String,
        onEvent: @escaping (Data) -> Void,
        onAttached: @escaping () -> Void
    ) -> RelayHostAgentMonitorToken {
        let key = hostKey(profile)
        let entry = hosts[key] ?? HostEntry(profile: profile)
        hosts[key] = entry
        let subscriptionID = UUID()
        entry.subscriptions[subscriptionID] = Subscription(
            sessionID: sessionID, onEvent: onEvent, onAttached: onAttached
        )
        if entry.eventCursors[sessionID] == nil { entry.eventCursors[sessionID] = 0 }
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

    private static func eventSequence(in payload: Data) -> UInt64? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let number = object["relay_event_seq"] as? NSNumber else { return nil }
        return number.uint64Value
    }
}

private final class RelayHostAgentTransport: @unchecked Sendable {
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
        for (sessionID, lastEventSequence) in sessions {
            let channel = RelayNodeTransportPool.shared.attach(
                profile: profile,
                sessionID: sessionID,
                onReady: { channel in
                    let payload = (try? JSONSerialization.data(withJSONObject: [
                        "version": 1,
                        "session_id": sessionID,
                        "cols": 1,
                        "rows": 1,
                        "last_seq": 0,
                        "last_event_seq": lastEventSequence,
                        "observe_events": true,
                    ])) ?? Data()
                    channel.writeAsync(type: .hello, payload: payload)
                },
                onFrame: { frame in
                    if frame.type == .agentEvent {
                        onEvent(sessionID, frame.payload)
                    } else if frame.type == .status,
                              let status = try? JSONDecoder().decode(StatusWirePayload.self, from: frame.payload),
                              status.state == "attached" {
                        onAttached()
                    }
                },
                onDisconnect: { [weak self] failure in
                    if failure.kind == .remoteConfiguration {
                        self?.startLegacy(
                            profile: profile,
                            sessions: sessions,
                            onEvent: onEvent,
                            onAttached: onAttached
                        )
                    } else if !failure.shouldRetry {
                        self?.stop()
                    }
                }
            )
            lock.lock()
            if stopped {
                lock.unlock()
                channel.close()
            } else {
                channels[sessionID] = channel
                lock.unlock()
            }
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
        process?.terminate()
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
        ssh.standardOutput = output
        ssh.standardError = FileHandle.nullDevice
        ssh.terminationHandler = { [weak self] ended in self?.didEnd(ended) }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        process = ssh
        lock.unlock()
        do {
            try ssh.run()
            onAttached?()
        } catch {
            didEnd(ssh)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.readFrames(output.fileHandleForReading)
        }
    }

    private func readFrames(_ handle: FileHandle) {
        while let frame = try? RelayWireFrame.read(from: handle) {
            guard let envelope = RelayWireFrame.parseHostEvent(frame), envelope.inner.type == .agentEvent else { continue }
            onEvent?(envelope.sessionID, envelope.inner.payload)
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
