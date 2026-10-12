import CryptoKit
import Darwin
import Foundation

enum LocalRelayProcess {
    /// Local execution strips SSH's remote command prefix. Preserve terminal
    /// negotiation as process environment rather than losing its env arguments.
    static func configureDedicated(_ process: Process, observeAgentsOnly: Bool, repaint: Bool) {
        configure(process)
        var environment = process.environment ?? [:]
        environment.removeValue(forKey: "RELAY_OBSERVE_PROGRAM_STATUS")
        environment.removeValue(forKey: "RELAY_ATTACH_REPAINT")
        if !observeAgentsOnly {
            environment["RELAY_OBSERVE_PROGRAM_STATUS"] = "1"
            if repaint { environment["RELAY_ATTACH_REPAINT"] = "1" }
        }
        process.environment = environment
    }

    static func configure(_ process: Process) {
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PROMPT_COMMAND")
        if RelayStateProfile.configuration.isIsolated {
            // relayd derives its socket and durable worker catalog from XDG,
            // not from Relay's UI state root. Keep a candidate (or an invalid
            // quarantined profile) away from the production local daemon.
            let root = RelayStateProfile.applicationSupportRoot
            environment["XDG_RUNTIME_DIR"] = root.appendingPathComponent("relayd-runtime").path
            environment["XDG_STATE_HOME"] = root.appendingPathComponent("relayd-state").path
        }
        if let shell = getpwuid(getuid())?.pointee.pw_shell {
            environment["SHELL"] = String(cString: shell)
        }
        process.environment = environment
    }
}

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
        try connection.write(sessionID: sessionID, frame: RelayWireFrame(type: type, payload: payload), expectedChannel: self)
    }

    func writeAsync(type: RelayWireType, payload: Data = Data()) {
        connection?.writeAsync(sessionID: sessionID, frame: RelayWireFrame(type: type, payload: payload), expectedChannel: self)
    }

    func supports(_ capability: String) -> Bool {
        connection?.supports(capability) == true
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

/// Keeps a busy pane from doing terminal parsing on the one shared SSH reader.
///
/// Node mux frames are ordered per pane, but panes are independent. Calling a
/// pane callback inline made one large Codex/Claude repaint pause delivery to
/// every other pane on the host. This dispatcher preserves per-pane ordering
/// while scheduling at most one drain job, so repaint bursts do not create one
/// retained closure per frame.
final class RelayNodeFrameDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    // Never acquired by the node while its subscription lock is held.
    // Recursive because a callback may retire its own channel.
    private let deliveryLock = NSRecursiveLock()
    private let queue: DispatchQueue
    private let deliver: @Sendable (RelayWireFrame) -> Void
    private enum Delivery {
        case frame(RelayWireFrame)
        case lifecycle(@Sendable () -> Void)
    }
    private var frames: [Delivery] = []
    private var head = 0
    private var drainScheduled = false
    private var closed = false
    private var paused: Bool

    init(
        label: String,
        initiallyPaused: Bool = false,
        deliver: @escaping @Sendable (RelayWireFrame) -> Void
    ) {
        paused = initiallyPaused
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.deliver = deliver
    }

    func enqueue(_ frame: RelayWireFrame) {
        enqueueDelivery(.frame(frame))
    }

    /// Connection boundaries share the pane's ordered output queue so a new
    /// Hello or replay reset cannot overtake output from the prior connection.
    func enqueueLifecycle(_ callback: @escaping @Sendable () -> Void) {
        enqueueDelivery(.lifecycle(callback))
    }

    private func enqueueDelivery(_ delivery: Delivery) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        frames.append(delivery)
        guard !paused, !drainScheduled else {
            lock.unlock()
            return
        }
        drainScheduled = true
        lock.unlock()
        queue.async { [weak self] in self?.drain() }
    }

    func resume() {
        lock.lock()
        paused = false
        guard !closed, !drainScheduled, head < frames.count else { lock.unlock(); return }
        drainScheduled = true
        lock.unlock()
        queue.async { [weak self] in self?.drain() }
    }

    func close() {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        lock.lock()
        closed = true
        frames.removeAll(keepingCapacity: false)
        head = 0
        lock.unlock()
    }

    private func drain() {
        while true {
            deliveryLock.lock()
            lock.lock()
            guard !closed, head < frames.count else {
                frames.removeAll(keepingCapacity: true)
                head = 0
                drainScheduled = false
                lock.unlock()
                deliveryLock.unlock()
                return
            }
            let frame = frames[head]
            head += 1
            // Release delivered storage in bounded chunks without an O(n)
            // removeFirst for every frame.
            if head >= 256, head * 2 >= frames.count {
                frames.removeFirst(head)
                head = 0
            }
            lock.unlock()
            autoreleasepool {
                switch frame {
                case .frame(let frame): deliver(frame)
                case .lifecycle(let callback): callback()
                }
            }
            deliveryLock.unlock()
        }
    }
}

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

    /// Read-only observations; inspecting Network never creates or reconnects a node.
    func networkSnapshots() -> [NetworkTransportSnapshot] {
        lock.lock()
        let current = Array(nodes.values)
        lock.unlock()
        return current.map { $0.networkSnapshot() }.sorted { $0.id < $1.id }
    }

    func setSystemSleeping(_ sleeping: Bool) {
        lock.lock(); let current = Array(nodes.values); lock.unlock()
        current.forEach { $0.setSystemSleeping(sleeping) }
    }

    var cachedNodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nodes.count
    }

    func attach(
        profile: ConnectionProfile,
        sessionID: String,
        onReady: @escaping @Sendable (RelayNodeChannel) -> Void,
        onFrame: @escaping @Sendable (RelayWireFrame) -> Void,
        onDisconnect: @escaping @Sendable (SSHConnectionFailure) -> Void
    ) -> RelayNodeChannel {
        lock.lock()
        let key = profile.connectionKey
        let node = nodes[key] ?? RelayNodeConnection(
            profile: profile,
            onIdle: { [weak self] node in self?.evictIfIdle(node, key: key) }
        )
        nodes[key] = node
        lock.unlock()
        Task { @MainActor in RelayHostRegistry.shared.register(profile, origin: "Terminal connection") }
        return node.add(sessionID: sessionID, onReady: onReady, onFrame: onFrame, onDisconnect: onDisconnect)
    }

    private func rpcNode(profile: ConnectionProfile) -> RelayNodeConnection {
        lock.lock()
        let key = profile.connectionKey
        let node = nodes[key] ?? RelayNodeConnection(profile: profile,
            onIdle: { [weak self] node in self?.evictIfIdle(node, key: key) })
        nodes[key] = node
        lock.unlock()
        Task { @MainActor in RelayHostRegistry.shared.register(profile, origin: "Host RPC transport; requester unspecified") }
        return node
    }

    func request(profile: ConnectionProfile, payload: Data, requiredCapability: String? = nil) async throws -> Data {
        let node = rpcNode(profile: profile)
        return try await withCheckedThrowingContinuation { continuation in
            node.request(payload: payload, requiredCapability: requiredCapability) { continuation.resume(with: $0) }
        }
    }

    private func evictIfIdle(_ node: RelayNodeConnection, key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard nodes[key] === node, node.isIdle else { return }
        nodes.removeValue(forKey: key)
        RelayDiagnostics.shared.record(category: "connection", name: "node-evicted", details: [
            "connection_id": node.diagnosticID,
        ])
    }
}

enum RelaySSHConnectionReusePolicy {
    static func options(controlDirectory: String?, reconnectAttempt: Int) -> [String] {
        guard let controlDirectory, reconnectAttempt == 0 else {
            return ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        }
        return ["-o", "ControlMaster=auto", "-o", "ControlPersist=600", "-o", "ControlPath=\(controlDirectory)/%C"]
    }

    static func privateDirectory(scope: String) -> String? {
        let digest = SHA256.hash(data: Data(scope.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let path = "/tmp/relay-ssh-\(getuid())-\(digest)"
        let manager = FileManager.default
        do {
            if !manager.fileExists(atPath: path) {
                try manager.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let attributes = try manager.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { return nil }
            return path
        } catch { return nil }
    }
}

final class RelayNodeConnection: @unchecked Sendable {
    private struct Subscription {
        let channel: RelayNodeChannel
        let onReady: @Sendable (RelayNodeChannel) -> Void
        let frameDispatcher: RelayNodeFrameDispatcher
        let onDisconnect: @Sendable (SSHConnectionFailure) -> Void
    }

    private let profile: ConnectionProfile
    private let lock = NSLock()
    private var subscriptions: [String: Subscription] = [:]
    private struct PendingRPC {
        let payload: Data
        let requiredCapability: String?
        let completion: @Sendable (Result<Data, Error>) -> Void
        var sent: Bool = false
    }
    private var pendingRPC: [String: PendingRPC] = [:]
    private var retainsHostConnection = false

    func request(payload: Data, requiredCapability: String? = nil, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        // A 4 MiB upload chunk expands to about 5.6 MiB in base64 JSON.
        // Keep requests bounded below the 16 MiB wire frame limit.
        guard payload.count <= 8 << 20,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = object["request_id"] as? String,
              id.range(of: #"^[A-Za-z0-9_-]{1,96}$"#, options: .regularExpression) != nil else {
            completion(.failure(RelayHostRPCError.invalidRequest)); return
        }
        lock.lock()
        guard pendingRPC[id] == nil else { lock.unlock(); completion(.failure(RelayHostRPCError.duplicateRequest)); return }
        retainsHostConnection = true
        pendingRPC[id] = PendingRPC(payload: payload, requiredCapability: requiredCapability, completion: completion)
        if stopped { stopped = false; startLocked() }
        let canSend = ready
        lock.unlock()
        if canSend { flushHostRequests() }
        let timeoutSeconds = 20
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let pending = self.pendingRPC.removeValue(forKey: id); self.lock.unlock()
            pending?.completion(.failure(RelayHostRPCError.outcomeUnknown))
        }
    }

    private func flushHostRequests() {
        lock.lock()
        guard ready, !systemSleeping, let writer else { lock.unlock(); return }
        let available = capabilities
        let requests = pendingRPC.filter { !$0.value.sent }
        for (id, pending) in requests {
            if available.contains("host_rpc_v1") && (pending.requiredCapability.map(available.contains) ?? true) {
                pendingRPC[id]?.sent = true
            } else { pendingRPC.removeValue(forKey: id) }
        }
        lock.unlock()
        for (id, pending) in requests {
            guard available.contains("host_rpc_v1"), pending.requiredCapability.map(available.contains) ?? true else {
                pending.completion(.failure(RelayHostRPCError.unsupported)); continue
            }
            do { try writer.write(type: .hostRequest, payload: pending.payload) }
            catch {
                lock.lock(); let removed = pendingRPC.removeValue(forKey: id); lock.unlock()
                removed?.completion(.failure(RelayHostRPCError.outcomeUnknown))
            }
        }
    }

    private var process: Process?
    private var writer: (any RelayFrameWriting)?
    private var lastProtocolConfirmation: UInt64?
    private var usesPersistentBroker = false
    private var ready = false
    private var stopped = true
    private var generation = 0
    private var reconnectAttempt = 0
    private var capabilities: Set<String> = []
    private var systemSleeping = false
    private var heartbeatSequence: UInt64 = 0
    private var pendingHeartbeats: [UInt64: UInt64] = [:]
    private let heartbeatTimer: DispatchSourceTimer
    private let diagnosticConnectionID: String
    private let onIdle: @Sendable (RelayNodeConnection) -> Void

    init(
        profile: ConnectionProfile,
        onIdle: @escaping @Sendable (RelayNodeConnection) -> Void = { _ in }
    ) {
        self.profile = profile
        self.onIdle = onIdle
        diagnosticConnectionID = String(
            format: "%016llx", UInt64(bitPattern: Int64(profile.connectionKey.hashValue))
        )
        heartbeatTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        heartbeatTimer.schedule(deadline: .distantFuture)
        heartbeatTimer.resume()
        heartbeatTimer.setEventHandler { [weak self] in self?.sendHeartbeat() }
    }

    /// Owned pre-attached framed peer; no process, dial, heartbeat or hello is
    /// started. Subscription identity and outbound routing use the same paths
    /// as the live node connection.
    convenience init(profile: ConnectionProfile, attachedFrameWriter: any RelayFrameWriting,
        attachedGeneration: Int = 0, protocolReady: Bool = true) {
        self.init(profile: profile)
        generation = attachedGeneration
        writer = attachedFrameWriter
        ready = protocolReady
        stopped = false
    }

    deinit { heartbeatTimer.cancel() }

    var diagnosticID: String { diagnosticConnectionID }

    func networkSnapshot() -> NetworkTransportSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return NetworkTransportSnapshot(
            id: profile.connectionKey, host: profile.host,
            account: profile.user, port: profile.port,
            phase: stopped ? .inactive : ready ? .ready : reconnectAttempt > 0 ? .reconnecting : .connecting,
            generation: generation, attachedSubscriptions: subscriptions.count,
            lastConfirmedUptime: lastProtocolConfirmation, usesPersistentBroker: usesPersistentBroker
        )
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.isEmpty && stopped
    }

    func supports(_ capability: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return capabilities.contains(capability)
    }

    func add(
        sessionID: String,
        onReady: @escaping @Sendable (RelayNodeChannel) -> Void,
        onFrame: @escaping @Sendable (RelayWireFrame) -> Void,
        onDisconnect: @escaping @Sendable (SSHConnectionFailure) -> Void
    ) -> RelayNodeChannel {
        let channel = RelayNodeChannel(sessionID: sessionID, connection: self)
        let frameDispatcher = RelayNodeFrameDispatcher(
            label: "relay.node-pane.\(sessionID)", initiallyPaused: true
        ) { frame in
            onFrame(frame)
        }
        lock.lock()
        let previous = subscriptions.updateValue(
            Subscription(
                channel: channel,
                onReady: onReady,
                frameDispatcher: frameDispatcher,
                onDisconnect: onDisconnect
            ),
            forKey: sessionID
        )
        let isReady = ready
        if stopped {
            stopped = false
            startLocked()
        }
        if isReady { frameDispatcher.enqueueLifecycle { onReady(channel) } }
        lock.unlock()
        previous?.frameDispatcher.close()
        frameDispatcher.resume()
        return channel
    }

    func close(sessionID: String, channel: RelayNodeChannel) {
        lock.lock()
        guard subscriptions[sessionID]?.channel === channel else {
            lock.unlock()
            return
        }
        let removed = subscriptions.removeValue(forKey: sessionID)
        let activeWriter = ready ? writer : nil
        if subscriptions.isEmpty && !retainsHostConnection {
            stopped = true
            ready = false
            writer = nil
            capabilities.removeAll(keepingCapacity: true)
            heartbeatTimer.schedule(deadline: .distantFuture)
            pendingHeartbeats.removeAll(keepingCapacity: true)
            let process = self.process
            self.process = nil
            lock.unlock()
            removed?.frameDispatcher.close()
            process?.terminate()
            onIdle(self)
            return
        }
        lock.unlock()
        removed?.frameDispatcher.close()
        if let envelope = RelayWireFrame.hostEvent(
            sessionID: sessionID,
            inner: RelayWireFrame(type: .detach, payload: Data())
        ) {
            try? activeWriter?.write(type: envelope.type, payload: envelope.payload)
        }
    }

    func write(sessionID: String, frame: RelayWireFrame, expectedChannel: RelayNodeChannel? = nil) throws {
        guard let envelope = RelayWireFrame.hostEvent(sessionID: sessionID, inner: frame) else {
            throw RelayNodeTransportError.invalidEnvelope
        }
        lock.lock()
        let registered = expectedChannel.map { subscriptions[sessionID]?.channel === $0 } ?? true
        let writer = ready && registered ? self.writer : nil
        lock.unlock()
        guard let writer else { throw RelayNodeTransportError.disconnected }
        try writer.write(type: envelope.type, payload: envelope.payload)
    }

    func writeAsync(sessionID: String, frame: RelayWireFrame, expectedChannel: RelayNodeChannel? = nil) {
        guard let envelope = RelayWireFrame.hostEvent(sessionID: sessionID, inner: frame) else { return }
        lock.lock()
        let registered = expectedChannel.map { subscriptions[sessionID]?.channel === $0 } ?? true
        let writer = ready && registered ? self.writer : nil
        lock.unlock()
        writer?.writeAsync(type: envelope.type, payload: envelope.payload)
    }

    private func startLocked() {
        generation += 1
        let currentGeneration = generation
        usesPersistentBroker = false
        let ssh = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let diagnosticsFinished = DispatchSemaphore(value: 0)
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2",
        ] + ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
            + profile.sshConnectionArguments + ["~/.local/bin/relayd", "node"]
        if profile.kind != .local, reconnectAttempt == 0,
           let directory = RelaySSHConnectionReusePolicy.privateDirectory(
               scope: RelayStateProfile.applicationSupportRoot.path + "|" + profile.connectionKey
           ) {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relay-connection")
            if FileManager.default.isExecutableFile(atPath: helper.path) {
                // The loopback-capable node client needs a fresh broker connection.
                // Retained v2 clients predate loopback RPC interception; durable workers stay independent.
                ssh.arguments = ["client", directory + "/broker-v3-loopback.sock", "/usr/bin/ssh"] + (ssh.arguments ?? [])
                ssh.executableURL = helper
                usesPersistentBroker = true
            }
        }
        if profile.kind == .local {
            LocalRelayProcess.configure(ssh)
            ssh.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/relayd")
            ssh.arguments = ["node"]
        }
        ssh.standardInput = input
        ssh.standardOutput = output
        ssh.standardError = errors
        let diagnostics = SSHDiagnosticBuffer()
        process = ssh
        writer = RelayScheduledWireWriter(input.fileHandleForWriting) { [weak self, weak ssh] message in
            RelayDiagnostics.shared.record(category: "connection", name: "wire-write-failed", details: [
                "connection_id": self?.diagnosticConnectionID ?? "node",
                "transport": "node-mux",
                "reason": message,
            ])
            if ssh?.isRunning == true { ssh?.terminate() }
        }
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
        // A stale control master can accept a local channel while its network
        // is dead. Bound protocol startup, then retry without multiplexing.
        let startupTimeout = reconnectAttempt == 0 ? 4 : 10
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(startupTimeout)) { [weak self, weak ssh] in
            guard let self else { return }
            self.lock.lock()
            let stalled = self.generation == currentGeneration && !self.ready && !self.stopped && self.process === ssh
            self.lock.unlock()
            if stalled {
                diagnostics.append(Data("Relay node startup timed out".utf8))
                if ssh?.isRunning == true { ssh?.terminate() }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            defer { diagnosticsFinished.signal() }
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
        DispatchQueue.global(qos: .userInteractive).async { [weak self, weak ssh] in
            var fragments = RelayWireFragmentAssembler()
            do {
                // Read until EOF (readExactly throws .endOfStream) rather
                // than gating on ssh.isRunning: frames still buffered in the
                // pipe when the process exits — the final output burst, the
                // terminal "exited" status — must be drained, not dropped.
                while let self {
                    try autoreleasepool {
                        let raw = try RelayWireFrame.read(from: output.fileHandleForReading)
                        if raw.type == .status,
                           let status = try? JSONDecoder().decode(StatusWirePayload.self, from: raw.payload),
                           status.state == "ready", status.capabilities?.contains("wire_fragments_v1") == true {
                            fragments.enabled = true
                        }
                        if let frame = try fragments.accept(raw) {
                            self.receive(frame, generation: currentGeneration)
                        }
                    }
                }
            } catch {
                if ssh?.isRunning == true { ssh?.terminate() }
            }
        }
    }

    /// Owned framed peers enter the same generation-checked reader path.
    func receiveAttachedFrame(_ frame: RelayWireFrame, generation: Int) {
        receive(frame, generation: generation)
    }

    private func receive(_ frame: RelayWireFrame, generation currentGeneration: Int) {
        if frame.type == .hostResponse,
           let response = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
           let id = response["request_id"] as? String {
            lock.lock()
            guard generation == currentGeneration, !stopped else { lock.unlock(); return }
            let pending = pendingRPC.removeValue(forKey: id)
            lock.unlock()
            pending?.completion(.success(frame.payload))
            return
        }
        if frame.type == .status,
           let status = try? JSONDecoder().decode(StatusWirePayload.self, from: frame.payload),
           status.state == "ready", status.capabilities?.contains("node_mux_v1") == true {
            lock.lock()
            guard generation == currentGeneration, !stopped else { lock.unlock(); return }
            let negotiatedWriter = writer
            let negotiatedProcess = process
            lock.unlock()
            // Publish readiness only after negotiating the writer. Queued
            // pane Hellos and host RPCs must use this connection's framing.
            if status.capabilities?.contains("wire_fragments_v1") == true {
                do {
                    try negotiatedWriter?.write(type: .capabilities, payload: Data("{\"wire_fragments\":true}".utf8))
                    (negotiatedWriter as? RelayScheduledWireWriter)?.enableFragments()
                } catch {
                    if negotiatedProcess?.isRunning == true { negotiatedProcess?.terminate() }
                    return
                }
            }
            lock.lock()
            guard generation == currentGeneration, !stopped, writer === negotiatedWriter, writer != nil else { lock.unlock(); return }
            ready = true
            lastProtocolConfirmation = DispatchTime.now().uptimeNanoseconds
            capabilities = Set(status.capabilities ?? [])
            reconnectAttempt = 0
            heartbeatTimer.schedule(
                deadline: .now() + .seconds(RelayHeartbeatPolicy.intervalSeconds),
                repeating: .seconds(RelayHeartbeatPolicy.intervalSeconds),
                leeway: .seconds(2)
            )
            for subscription in subscriptions.values {
                subscription.frameDispatcher.enqueueLifecycle {
                    subscription.onReady(subscription.channel)
                }
            }
            lock.unlock()
            Task { @MainActor [profile] in
                RelayHostRegistry.shared.connection(profile, ready: true, capabilities: status.capabilities ?? [],
                    version: status.version, protocolVersion: status.protocolVersion,
                    supervisorPID: status.supervisorPID)
            }
            flushHostRequests()
            RelayDiagnostics.shared.record(category: "connection", name: "ready", details: [
                "connection_id": diagnosticConnectionID,
            ])
            return
        }
        if frame.type == .pong, frame.payload.count == 8 {
            let sequence = frame.payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            guard generation == currentGeneration, !stopped else { lock.unlock(); return }
            let sentAt = pendingHeartbeats.removeValue(forKey: sequence)
            if sentAt != nil { lastProtocolConfirmation = now }
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
        guard generation == currentGeneration, ready, !stopped else { lock.unlock(); return }
        // Admission and lifecycle enqueue use the same node lock. A reader
        // from an old process cannot route bytes into a successor subscription
        // or append them behind its disconnect/ready boundary.
        subscriptions[envelope.sessionID]?.frameDispatcher.enqueue(envelope.inner)
        lock.unlock()
    }

    private func ended(generation currentGeneration: Int, status: Int32, diagnostic: String) {
        lock.lock()
        guard generation == currentGeneration, !stopped else { lock.unlock(); return }
        let reachedProtocolReady = ready
        ready = false
        writer = nil
        capabilities.removeAll(keepingCapacity: true)
        process = nil
        reconnectAttempt += 1
        heartbeatTimer.schedule(deadline: .distantFuture)
        pendingHeartbeats.removeAll(keepingCapacity: true)
        let attempt = reconnectAttempt
        let failure = SSHConnectionFailure.diagnoseNodeTransport(
            diagnostic,
            terminationStatus: status,
            reachedProtocolReady: reachedProtocolReady
        )
        for subscription in subscriptions.values {
            subscription.frameDispatcher.enqueueLifecycle { subscription.onDisconnect(failure) }
        }
        let interrupted = Array(pendingRPC.values)
        pendingRPC.removeAll()
        lock.unlock()
        Task { @MainActor [profile] in RelayHostRegistry.shared.connection(profile, ready: false) }
        interrupted.forEach { $0.completion(.failure(RelayHostRPCError.outcomeUnknown)) }
        RelayDiagnostics.shared.record(category: "connection", name: "disconnected", details: [
            "connection_id": diagnosticConnectionID,
            "status": String(status),
            "reason": failure.userMessage,
            "retry": String(failure.shouldRetry),
        ])
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

    func setSystemSleeping(_ sleeping: Bool) {
        lock.lock()
        systemSleeping = sleeping
        pendingHeartbeats.removeAll(keepingCapacity: true)
        lock.unlock()
        if !sleeping { sendHeartbeat() }
    }

    private func sendHeartbeat() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard ready, !systemSleeping, let writer else { lock.unlock(); return }
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

 enum RelayHostRPCError: LocalizedError {
    case invalidRequest, duplicateRequest, unsupported, outcomeUnknown
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid host request"
        case .duplicateRequest: return "Request ID is already in flight"
        case .unsupported: return "Host daemon needs the host_rpc_v1 capability"
        case .outcomeUnknown: return "Host request outcome unknown; query the same job ID, never replay with a new job ID"
        }
    }
}
