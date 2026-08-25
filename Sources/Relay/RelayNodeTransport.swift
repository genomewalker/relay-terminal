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

    init(profile: ConnectionProfile) { self.profile = profile }

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
            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=auto", "-o", "ControlPersist=10m", "-o", "ControlPath=~/.ssh/relay-%C",
        ] + profile.sshConnectionArguments + ["~/.local/bin/relayd", "node"]
        ssh.standardInput = input
        ssh.standardOutput = output
        ssh.standardError = errors
        let diagnostics = SSHDiagnosticBuffer()
        process = ssh
        writer = RelayWireWriter(input.fileHandleForWriting)
        ready = false
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
            let callbacks = subscriptions.values.map { ($0.onReady, $0.channel) }
            lock.unlock()
            callbacks.forEach { callback, channel in callback(channel) }
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
        ready = false
        writer = nil
        process = nil
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let callbacks = subscriptions.values.map(\.onDisconnect)
        lock.unlock()
        let failure = SSHConnectionFailure.diagnose(diagnostic, terminationStatus: status)
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
}
