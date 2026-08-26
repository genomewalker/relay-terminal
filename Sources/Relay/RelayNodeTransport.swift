import Darwin
import Foundation

final class RelayNodeChannel: RelayFrameWriting, @unchecked Sendable {
    let sessionID: String
    private weak var connection: RelayNodeConnection?
    private let lock = NSLock()
    private var closed = false

    init(sessionID: String, connection: RelayNodeConnection) {
        self.sessionID = sessionID
        self.connection = connection
    }

    func write(type: RelayWireType, payload: Data = Data()) throws {
        lock.lock()
        let active = !closed
        lock.unlock()
        guard active, let connection else { throw RelayNodeTransportError.disconnected }
        try connection.write(sessionID: sessionID, frame: RelayWireFrame(type: type, payload: payload))
    }

    func writeAsync(type: RelayWireType, payload: Data = Data()) {
        connection?.writeAsync(sessionID: sessionID, frame: RelayWireFrame(type: type, payload: payload))
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        connection?.close(sessionID: sessionID, channel: self)
        connection = nil
    }
}

enum RelayNodeTransportError: Error { case disconnected, invalidEnvelope }

enum RelayHeartbeatPolicy {
    // A half-open SSH socket is the common failure mode when a VPN route is
    // replaced: the local process remains alive but no bytes move. Three
    // lightweight protocol probes give the route time to recover without
    // leaving an interactive pane frozen for the previous 30–40 seconds.
    static let intervalSeconds = 2
    static let timeoutNanoseconds: UInt64 = 6_000_000_000

    static func expired(_ pending: [UInt64: UInt64], now: UInt64) -> [UInt64] {
        guard now >= timeoutNanoseconds else { return [] }
        let boundary = now - timeoutNanoseconds
        return pending.filter { $0.value <= boundary }.map(\.key)
    }
}

final class RelayNodeTransportPool: @unchecked Sendable {
    static let shared = RelayNodeTransportPool()
    private let lock = NSLock()
    private var nodes: [String: RelayNodeConnection] = [:]

    func attach(
        profile: ConnectionProfile,
        sessionID: String,
        onReady: @escaping @Sendable (RelayNodeChannel) -> Void,
        onFrame: @escaping @Sendable (RelayWireFrame) -> Void,
        onDisconnect: @escaping @Sendable (SSHConnectionFailure) -> Void
    ) -> RelayNodeChannel {
        lock.lock()
        let key = profile.connectionKey
        let node = nodes[key] ?? RelayNodeConnection(profile: profile)
        nodes[key] = node
        lock.unlock()
        return node.add(sessionID: sessionID, onReady: onReady, onFrame: onFrame, onDisconnect: onDisconnect)
    }
}

final class RelayNodeConnection: @unchecked Sendable {
    private struct Subscription {
        let channel: RelayNodeChannel
        let onReady: @Sendable (RelayNodeChannel) -> Void
        let onFrame: @Sendable (RelayWireFrame) -> Void
        let onDisconnect: @Sendable (SSHConnectionFailure) -> Void
    }

    private let profile: ConnectionProfile
    private let lock = NSLock()
    private var subscriptions: [String: Subscription] = [:]
    private var process: Process?
    private var writer: RelayWireWriter?
    private var ready = false
    private var stopped = true
    private var generation = 0
    private var reconnectAttempt = 0
    private var heartbeatSequence: UInt64 = 0
    private var pendingHeartbeats: [UInt64: UInt64] = [:]
    private let heartbeatTimer: DispatchSourceTimer
    private let diagnosticConnectionID: String

    init(profile: ConnectionProfile) {
        self.profile = profile
        diagnosticConnectionID = String(
            format: "%016llx", UInt64(bitPattern: Int64(profile.connectionKey.hashValue))
        )
        heartbeatTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        heartbeatTimer.schedule(deadline: .distantFuture)
        heartbeatTimer.resume()
        heartbeatTimer.setEventHandler { [weak self] in self?.sendHeartbeat() }
    }

    deinit { heartbeatTimer.cancel() }

    func add(
        sessionID: String,
        onReady: @escaping @Sendable (RelayNodeChannel) -> Void,
        onFrame: @escaping @Sendable (RelayWireFrame) -> Void,
        onDisconnect: @escaping @Sendable (SSHConnectionFailure) -> Void
    ) -> RelayNodeChannel {
        let channel = RelayNodeChannel(sessionID: sessionID, connection: self)
        lock.lock()
        subscriptions[sessionID] = Subscription(channel: channel, onReady: onReady, onFrame: onFrame, onDisconnect: onDisconnect)
        let isReady = ready
        if stopped {
            stopped = false
            startLocked()
        }
        lock.unlock()
        if isReady { onReady(channel) }
        return channel
    }

    func close(sessionID: String, channel: RelayNodeChannel) {
        lock.lock()
        guard subscriptions[sessionID]?.channel === channel else {
            lock.unlock()
            return
        }
        subscriptions.removeValue(forKey: sessionID)
        let activeWriter = ready ? writer : nil
        if subscriptions.isEmpty {
            stopped = true
            ready = false
            writer = nil
            heartbeatTimer.schedule(deadline: .distantFuture)
            pendingHeartbeats.removeAll(keepingCapacity: true)
            let process = self.process
            self.process = nil
            lock.unlock()
            process?.terminate()
            return
        }
        lock.unlock()
        if let envelope = RelayWireFrame.hostEvent(
            sessionID: sessionID,
            inner: RelayWireFrame(type: .detach, payload: Data())
        ) {
            try? activeWriter?.write(type: envelope.type, payload: envelope.payload)
        }
    }

    func write(sessionID: String, frame: RelayWireFrame) throws {
        guard let envelope = RelayWireFrame.hostEvent(sessionID: sessionID, inner: frame) else {
            throw RelayNodeTransportError.invalidEnvelope
        }
        lock.lock()
        let writer = ready ? self.writer : nil
        lock.unlock()
        guard let writer else { throw RelayNodeTransportError.disconnected }
        try writer.write(type: envelope.type, payload: envelope.payload)
    }

    func writeAsync(sessionID: String, frame: RelayWireFrame) {
        guard let envelope = RelayWireFrame.hostEvent(sessionID: sessionID, inner: frame) else { return }
        lock.lock()
        let writer = ready ? self.writer : nil
        lock.unlock()
        writer?.writeAsync(type: envelope.type, payload: envelope.payload)
    }

    private func startLocked() {
        generation += 1
        let currentGeneration = generation
        let ssh = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let diagnosticsFinished = DispatchSemaphore(value: 0)
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2",
            // Relay already multiplexes every pane over this one process. A
            // persistent OpenSSH control master adds a second connection
            // owner that can survive a VPN route change and trap retries on
            // the stale TCP stream, so the node transport must always create
            // a fresh connection.
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
        ] + profile.sshConnectionArguments + ["~/.local/bin/relayd", "node"]
        ssh.standardInput = input
        ssh.standardOutput = output
        ssh.standardError = errors
        let diagnostics = SSHDiagnosticBuffer()
        process = ssh
        writer = RelayWireWriter(input.fileHandleForWriting)
        ready = false
        RelayDiagnostics.shared.record(category: "connection", name: "ssh-started", details: [
            "connection_id": diagnosticConnectionID,
            "profile": profile.name,
            "generation": String(currentGeneration),
        ])
        ssh.terminationHandler = { [weak self] process in
            _ = diagnosticsFinished.wait(timeout: .now() + .milliseconds(500))
            self?.ended(generation: currentGeneration, status: process.terminationStatus, diagnostic: diagnostics.text)
        }
        do {
            try ssh.run()
        } catch {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.ended(generation: currentGeneration, status: -1, diagnostic: error.localizedDescription)
            }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            defer { diagnosticsFinished.signal() }
            while let chunk = try? errors.fileHandleForReading.read(upToCount: 8 << 10), !chunk.isEmpty { diagnostics.append(chunk) }
        }
        DispatchQueue.global(qos: .userInteractive).async { [weak self, weak ssh] in
            do {
                while let self, let ssh, ssh.isRunning {
                    let frame = try RelayWireFrame.read(from: output.fileHandleForReading)
                    self.receive(frame, generation: currentGeneration)
                }
            } catch {
                if ssh?.isRunning == true { ssh?.terminate() }
            }
        }
    }

    private func receive(_ frame: RelayWireFrame, generation currentGeneration: Int) {
        if frame.type == .status,
           let status = try? JSONDecoder().decode(StatusWirePayload.self, from: frame.payload),
           status.state == "ready", status.capabilities?.contains("node_mux_v1") == true {
            lock.lock()
            guard generation == currentGeneration, !stopped else { lock.unlock(); return }
            ready = true
            reconnectAttempt = 0
            heartbeatTimer.schedule(
                deadline: .now() + .seconds(RelayHeartbeatPolicy.intervalSeconds),
                repeating: .seconds(RelayHeartbeatPolicy.intervalSeconds),
                leeway: .seconds(2)
            )
            let callbacks = subscriptions.values.map { ($0.onReady, $0.channel) }
            lock.unlock()
            RelayDiagnostics.shared.record(category: "connection", name: "ready", details: [
                "connection_id": diagnosticConnectionID,
            ])
            callbacks.forEach { callback, channel in callback(channel) }
            return
        }
        if frame.type == .pong, frame.payload.count == 8 {
            let sequence = frame.payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            let sentAt = pendingHeartbeats.removeValue(forKey: sequence)
            lock.unlock()
            if let sentAt {
                let milliseconds = Double(now &- sentAt) / 1_000_000
                RelayDiagnostics.shared.heartbeatAcknowledged(
                    connection: diagnosticConnectionID, rttMilliseconds: milliseconds
                )
            }
            return
        }
        guard let envelope = RelayWireFrame.parseHostEvent(frame) else { return }
        lock.lock()
        let callback = subscriptions[envelope.sessionID]?.onFrame
        lock.unlock()
        callback?(envelope.inner)
    }

    private func ended(generation currentGeneration: Int, status: Int32, diagnostic: String) {
        lock.lock()
        guard generation == currentGeneration, !stopped else { lock.unlock(); return }
        let reachedProtocolReady = ready
        ready = false
        writer = nil
        process = nil
        reconnectAttempt += 1
        heartbeatTimer.schedule(deadline: .distantFuture)
        pendingHeartbeats.removeAll(keepingCapacity: true)
        let attempt = reconnectAttempt
        let callbacks = subscriptions.values.map(\.onDisconnect)
        lock.unlock()
        let failure = SSHConnectionFailure.diagnoseNodeTransport(
            diagnostic,
            terminationStatus: status,
            reachedProtocolReady: reachedProtocolReady
        )
        RelayDiagnostics.shared.record(category: "connection", name: "disconnected", details: [
            "connection_id": diagnosticConnectionID,
            "status": String(status),
            "reason": failure.userMessage,
            "retry": String(failure.shouldRetry),
        ])
        callbacks.forEach { $0(failure) }
        guard failure.shouldRetry else { return }
        let delay = min(3_000, 150 * (1 << min(attempt - 1, 4)))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped, self.process == nil else { self.lock.unlock(); return }
            self.startLocked()
            self.lock.unlock()
        }
    }

    private func sendHeartbeat() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard ready, let writer else { lock.unlock(); return }
        let timedOut = RelayHeartbeatPolicy.expired(pendingHeartbeats, now: now)
        for sequence in timedOut { pendingHeartbeats.removeValue(forKey: sequence) }
        if !timedOut.isEmpty {
            // An alive local ssh PID does not prove that the relay protocol is
            // moving. Stop the wedged transport so its normal termination
            // handler creates a fresh SSH connection and resubscribes panes.
            heartbeatTimer.schedule(deadline: .distantFuture)
            let stalledProcess = process
            lock.unlock()
            for _ in timedOut {
                RelayDiagnostics.shared.heartbeatTimedOut(connection: diagnosticConnectionID)
            }
            RelayDiagnostics.shared.record(category: "connection", name: "heartbeat-watchdog", details: [
                "connection_id": diagnosticConnectionID,
                "missed": String(timedOut.count),
                "action": "restart-ssh",
            ])
            stalledProcess?.terminate()
            if let stalledProcess {
                let pid = stalledProcess.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) {
                    if stalledProcess.isRunning { _ = Darwin.kill(pid, SIGKILL) }
                }
            }
            return
        }
        heartbeatSequence &+= 1
        let sequence = heartbeatSequence
        pendingHeartbeats[sequence] = now
        lock.unlock()

        RelayDiagnostics.shared.heartbeatSent(connection: diagnosticConnectionID)
        var bigEndian = sequence.bigEndian
        let payload = withUnsafeBytes(of: &bigEndian) { Data($0) }
        writer.writeAsync(type: .ping, payload: payload)
    }
}
