import CryptoKit
import Darwin
import Foundation

extension Notification.Name {
    /// Posted on the main actor with the node's connection key each time it is ready.
    static let relayNodeReady = Notification.Name("relay.node-ready")
}

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
    // Strong until close(): an open pane keeps its node, with its SSH process
    // and pending retry, alive even after the pool has replaced it. A weak
    // reference let a node outside the pool be freed silently, leaving its
    // panes waiting for a ready or disconnect callback that never came.
    private var connection: RelayNodeConnection?
    private let lock = NSLock()
    private var closed = false

    init(sessionID: String, connection: RelayNodeConnection) {
        self.sessionID = sessionID
        self.connection = connection
    }

    private var openConnection: RelayNodeConnection? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : connection
    }

    /// The node this open channel belongs to.
    var node: RelayNodeConnection? { openConnection }

    func write(type: RelayWireType, payload: Data = Data()) throws {
        guard let connection = openConnection else { throw RelayNodeTransportError.disconnected }
        try connection.write(sessionID: sessionID, frame: RelayWireFrame(type: type, payload: payload), expectedChannel: self)
    }

    func writeAsync(type: RelayWireType, payload: Data = Data()) {
        openConnection?.writeAsync(sessionID: sessionID, frame: RelayWireFrame(type: type, payload: payload), expectedChannel: self)
    }

    func supports(_ capability: String) -> Bool {
        openConnection?.supports(capability) == true
    }

    /// Tells the node whether the user is looking at this pane.
    func setFocused(_ focused: Bool) {
        openConnection?.setFocus(sessionID: sessionID, focused: focused, channel: self)
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.close(sessionID: sessionID, channel: self)
    }
}

enum RelayNodeTransportError: Error { case disconnected, invalidEnvelope }

/// The Focus frame relayd's node scheduler reads (node_focus_v1).
enum RelayNodeFocus {
    /// relayd accepts at most this many routes; more rejects the frame.
    static let maxRoutes = 4

    /// {"routes":[...]} sorted, so the same set always encodes the same way.
    /// Beyond the limit the frame lists none, which falls back to the
    /// oldest-first order instead of favouring an arbitrary subset.
    static func payload(routes: Set<String>) -> Data {
        let listed = routes.count <= maxRoutes ? routes.sorted() : []
        return (try? JSONSerialization.data(withJSONObject: ["routes": listed])) ?? Data(#"{"routes":[]}"#.utf8)
    }
}

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
    // replaced: the local process remains alive but no bytes move. One slow
    // reply is not that: a host under disk pressure (dandy-07, 2026-10-22) can
    // hold a single pong past the timeout while the stream keeps moving, and a
    // restart then reattaches every pane on the node at once. So a probe only
    // counts as missed when nothing at all arrived after it was sent, and the
    // transport restarts after three consecutive misses: about 10–12 s of total
    // silence, still well short of the previous 30–40 second freeze.
    static let intervalSeconds = 2
    static let timeoutNanoseconds: UInt64 = 6_000_000_000
    static let restartMisses = 3

    static func expired(_ pending: [UInt64: UInt64], now: UInt64) -> [UInt64] {
        guard now >= timeoutNanoseconds else { return [] }
        let boundary = now - timeoutNanoseconds
        return pending.filter { $0.value <= boundary }.map(\.key)
    }

    /// Expired probes leave `pending`. Those followed by any inbound data are
    /// covered and dropped uncounted; the rest add to `consecutiveMisses`.
    static func shouldRestart(
        pending: [UInt64: UInt64], lastInbound: UInt64?, now: UInt64, consecutiveMisses: Int
    ) -> (restart: Bool, misses: Int, expired: [UInt64]) {
        let timedOut = expired(pending, now: now)
        let missed = timedOut.filter { sequence in
            guard let lastInbound, let sentAt = pending[sequence] else { return true }
            return lastInbound <= sentAt
        }
        let misses = consecutiveMisses + missed.count
        return (misses >= restartMisses, misses, timedOut)
    }
}

/// One attempt by a pane transport to join a node. The transport cancels it
/// when it detaches, restarts or starts another attempt. A node checks it under
/// its own lock at the moment it would register the pane, so a cancelled
/// attempt can never replace the subscription of the pane's successor.
final class RelayNodeAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum RelayNodeJoin {
    case joined(RelayNodeChannel)
    case retired
    case cancelled
}

final class RelayNodeTransportPool: @unchecked Sendable {
    static let shared = RelayNodeTransportPool()
    private let lock = NSLock()
    private var nodes: [String: RelayNodeConnection] = [:]
    typealias NodeFactory = @Sendable (ConnectionProfile,
        @escaping @Sendable (RelayNodeConnection) -> Void) -> RelayNodeConnection
    private let makeNode: NodeFactory
    /// Runs after a node is looked up and before a pane or request joins it,
    /// outside the pool lock (tests interleave an eviction there).
    private var lookupHook: (@Sendable (RelayNodeConnection) -> Void)?
    var afterLookup: (@Sendable (RelayNodeConnection) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return lookupHook }
        set { lock.lock(); lookupHook = newValue; lock.unlock() }
    }

    init(makeNode: @escaping NodeFactory = { RelayNodeConnection(profile: $0, onIdle: $1) }) {
        self.makeNode = makeNode
    }

    private func pooledNode(_ profile: ConnectionProfile) -> RelayNodeConnection {
        lock.lock()
        defer { lock.unlock() }
        let key = profile.connectionKey
        if let node = nodes[key] { return node }
        let node = makeNode(profile) { [weak self] node in self?.evictIfIdle(node, key: key) }
        nodes[key] = node
        return node
    }

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

    func resumeAfterNetworkChange() {
        lock.lock(); let current = Array(nodes.values); lock.unlock()
        current.forEach { $0.resumeAfterNetworkChange() }
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
        // Without an admission the join cannot be cancelled.
        attach(profile: profile, sessionID: sessionID, admission: nil,
            onReady: onReady, onFrame: onFrame, onDisconnect: onDisconnect)!
    }

    /// Joins the pooled node unless `admission` is cancelled first (nil).
    func attach(
        profile: ConnectionProfile,
        sessionID: String,
        admission: RelayNodeAdmission?,
        onReady: @escaping @Sendable (RelayNodeChannel) -> Void,
        onFrame: @escaping @Sendable (RelayWireFrame) -> Void,
        onDisconnect: @escaping @Sendable (SSHConnectionFailure) -> Void
    ) -> RelayNodeChannel? {
        Task { @MainActor in RelayHostRegistry.shared.register(profile, origin: "Terminal connection") }
        // A node retired between lookup and join refuses the pane; the next
        // lookup finds or creates the pooled successor.
        while true {
            let node = pooledNode(profile)
            afterLookup?(node)
            switch node.addUnlessRetired(sessionID: sessionID, admission: admission, onReady: onReady,
                onFrame: onFrame, onDisconnect: onDisconnect) {
            case .joined(let channel): return channel
            case .retired: continue
            case .cancelled: return nil
            }
        }
    }

    /// Removes the pooled node for a host without closing it or its panes,
    /// the state a pane's recovery check repairs (tests).
    func abandonPooledNode(profile: ConnectionProfile) {
        lock.lock()
        nodes.removeValue(forKey: profile.connectionKey)
        lock.unlock()
    }

    /// Whether a waiting pane must leave its node: true when the channel is
    /// closed or its node is no longer the pooled one for its host. Otherwise
    /// a parked node is asked to start its transport now.
    func paneNeedsNewNode(_ channel: RelayNodeChannel, profile: ConnectionProfile) -> Bool {
        guard let node = channel.node else { return true }
        lock.lock()
        let pooled = nodes[profile.connectionKey] === node
        lock.unlock()
        if pooled { node.resumeAfterNetworkChange() }
        return !pooled
    }

    /// The current transport incarnation for a host, without creating or
    /// reconnecting it: changes whenever the node is replaced or reconnects.
    func incarnation(profile: ConnectionProfile) -> String? {
        lock.lock()
        let node = nodes[profile.connectionKey]
        lock.unlock()
        return node?.incarnation
    }

    func request(profile: ConnectionProfile, payload: Data, requiredCapability: String? = nil, timeoutSeconds: Int = 20) async throws -> Data {
        Task { @MainActor in RelayHostRegistry.shared.register(profile, origin: "Host RPC transport; requester unspecified") }
        return try await withCheckedThrowingContinuation { continuation in
            while true {
                let node = pooledNode(profile)
                afterLookup?(node)
                if node.request(payload: payload, requiredCapability: requiredCapability,
                    timeoutSeconds: timeoutSeconds, completion: { continuation.resume(with: $0) }) { return }
            }
        }
    }

    private func evictIfIdle(_ node: RelayNodeConnection, key: String) {
        lock.lock()
        defer { lock.unlock() }
        // The node decides under its own lock; once retired it admits no pane
        // or request, so nothing can join it after it leaves the pool.
        guard nodes[key] === node, node.retireIfIdle() else { return }
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

    /// False only when this node is retired: the caller sends the request to
    /// the pooled node instead. Every admitted request completes exactly once.
    @discardableResult
    func request(payload: Data, requiredCapability: String? = nil, timeoutSeconds: Int = 20, completion: @escaping @Sendable (Result<Data, Error>) -> Void) -> Bool {
        // A 4 MiB upload chunk expands to about 5.6 MiB in base64 JSON.
        // Keep requests bounded below the 16 MiB wire frame limit.
        guard (1...80).contains(timeoutSeconds), payload.count <= 8 << 20,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = object["request_id"] as? String,
              id.range(of: #"^[A-Za-z0-9_-]{1,96}$"#, options: .regularExpression) != nil else {
            completion(.failure(RelayHostRPCError.invalidRequest)); return true
        }
        lock.lock()
        guard !retired else { lock.unlock(); return false }
        guard pendingRPC[id] == nil else { lock.unlock(); completion(.failure(RelayHostRPCError.duplicateRequest)); return true }
        retainsHostConnection = true
        pendingRPC[id] = PendingRPC(payload: payload, requiredCapability: requiredCapability, completion: completion)
        resumeLocked()
        let canSend = ready
        lock.unlock()
        if canSend { flushHostRequests() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let pending = self.pendingRPC.removeValue(forKey: id); self.lock.unlock()
            pending?.completion(.failure(RelayHostRPCError.outcomeUnknown))
        }
        return true
    }

    func setFocus(sessionID: String, focused: Bool, channel: RelayNodeChannel) {
        lock.lock()
        guard subscriptions[sessionID]?.channel === channel else { lock.unlock(); return }
        let changed = focused ? focusedRoutes.insert(sessionID).inserted : focusedRoutes.remove(sessionID) != nil
        lock.unlock()
        if changed { flushFocus() }
    }

    /// Sends the current focus set when the node understands it. A node
    /// without node_focus_v1 keeps its oldest-first order.
    private func flushFocus() {
        focusSendLock.lock()
        defer { focusSendLock.unlock() }
        lock.lock()
        guard ready, !systemSleeping, let writer, capabilities.contains("node_focus_v1") else { lock.unlock(); return }
        let payload = RelayNodeFocus.payload(routes: focusedRoutes)
        lock.unlock()
        try? writer.write(type: .focus, payload: payload)
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
    private var lastStartUptime: UInt64 = 0
    private var attachedPeer = false
    /// Set once, under this lock, when the pool evicts the idle node.
    private var retired = false
    private var capabilities: Set<String> = []
    /// Routes of panes the user is looking at; sent as one Focus frame.
    private var focusedRoutes: Set<String> = []
    /// Serializes Focus sends so the node always ends on the newest set.
    private let focusSendLock = NSLock()
    private var systemSleeping = false
    private var heartbeatSequence: UInt64 = 0
    private var pendingHeartbeats: [UInt64: UInt64] = [:]
    /// Uptime of the last bytes read from the node, of any kind.
    private var lastInboundUptime: UInt64?
    private var consecutiveHeartbeatMisses = 0
    private let uptime: @Sendable () -> UInt64
    private let heartbeatTimer: DispatchSourceTimer
    private let diagnosticConnectionID: String
    private let onIdle: @Sendable (RelayNodeConnection) -> Void

    init(
        profile: ConnectionProfile,
        onIdle: @escaping @Sendable (RelayNodeConnection) -> Void = { _ in },
        uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.profile = profile
        self.onIdle = onIdle
        self.uptime = uptime
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
        attachedGeneration: Int = 0, protocolReady: Bool = true,
        onIdle: @escaping @Sendable (RelayNodeConnection) -> Void = { _ in },
        uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.init(profile: profile, onIdle: onIdle, uptime: uptime)
        generation = attachedGeneration
        writer = attachedFrameWriter
        attachedPeer = true
        ready = protocolReady
        stopped = false
    }

    deinit { heartbeatTimer.cancel() }

    var diagnosticID: String { diagnosticConnectionID }

    private let incarnationSerial = UUID()
    /// This connection object and its current process generation.
    var incarnation: String {
        lock.lock()
        defer { lock.unlock() }
        return "\(incarnationSerial.uuidString)/\(generation)"
    }

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

    /// Retires the node if it is idle, deciding under the same lock that
    /// admits panes and requests. The pool never routes anything to it again.
    func retireIfIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !retired, subscriptions.isEmpty, pendingRPC.isEmpty, stopped else { return false }
        retired = true
        return true
    }

    /// Whether `channel` is the registered route for its session (tests).
    func isRegistered(_ channel: RelayNodeChannel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions[channel.sessionID]?.channel === channel
    }

    var isRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    func supports(_ capability: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return capabilities.contains(capability)
    }

    /// Owned (unpooled) nodes are never retired, so add always joins them.
    func add(
        sessionID: String,
        onReady: @escaping @Sendable (RelayNodeChannel) -> Void,
        onFrame: @escaping @Sendable (RelayWireFrame) -> Void,
        onDisconnect: @escaping @Sendable (SSHConnectionFailure) -> Void
    ) -> RelayNodeChannel {
        guard case .joined(let channel) = join(sessionID: sessionID, admission: nil, onReady: onReady,
            onFrame: onFrame, onDisconnect: onDisconnect, refuseRetired: false) else {
            preconditionFailure("an unpooled join without admission always succeeds")
        }
        return channel
    }

    /// Joins this node unless the pool has already retired it or `admission`
    /// has been cancelled; both are decided under this node's lock.
    func addUnlessRetired(
        sessionID: String,
        admission: RelayNodeAdmission? = nil,
        onReady: @escaping @Sendable (RelayNodeChannel) -> Void,
        onFrame: @escaping @Sendable (RelayWireFrame) -> Void,
        onDisconnect: @escaping @Sendable (SSHConnectionFailure) -> Void
    ) -> RelayNodeJoin {
        join(sessionID: sessionID, admission: admission, onReady: onReady, onFrame: onFrame,
            onDisconnect: onDisconnect, refuseRetired: true)
    }

    private func join(
        sessionID: String,
        admission: RelayNodeAdmission?,
        onReady: @escaping @Sendable (RelayNodeChannel) -> Void,
        onFrame: @escaping @Sendable (RelayWireFrame) -> Void,
        onDisconnect: @escaping @Sendable (SSHConnectionFailure) -> Void,
        refuseRetired: Bool
    ) -> RelayNodeJoin {
        let channel = RelayNodeChannel(sessionID: sessionID, connection: self)
        let frameDispatcher = RelayNodeFrameDispatcher(
            label: "relay.node-pane.\(sessionID)", initiallyPaused: true
        ) { frame in
            onFrame(frame)
        }
        lock.lock()
        if refuseRetired, retired {
            lock.unlock()
            return .retired
        }
        if let admission, !admission.isActive {
            lock.unlock()
            return .cancelled
        }
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
        resumeLocked()
        if isReady { frameDispatcher.enqueueLifecycle { onReady(channel) } }
        lock.unlock()
        previous?.frameDispatcher.close()
        frameDispatcher.resume()
        return .joined(channel)
    }

    func close(sessionID: String, channel: RelayNodeChannel) {
        lock.lock()
        guard subscriptions[sessionID]?.channel === channel else {
            lock.unlock()
            return
        }
        let removed = subscriptions.removeValue(forKey: sessionID)
        let focusChanged = focusedRoutes.remove(sessionID) != nil
        let activeWriter = ready ? writer : nil
        if subscriptions.isEmpty && !retainsHostConnection {
            stopped = true
            ready = false
            writer = nil
            capabilities.removeAll(keepingCapacity: true)
            heartbeatTimer.schedule(deadline: .distantFuture)
            clearHeartbeatsLocked()
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
        if focusChanged { flushFocus() }
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

    /// A stopped node starts. A node whose transport ended and is waiting for
    /// a retry (no process) starts now, at most once per few seconds, so a
    /// host request or pane reconnect never waits on a parked transport.
    private func resumeLocked() {
        if stopped {
            stopped = false
            startLocked()
        } else if process == nil, !attachedPeer,
                  DispatchTime.now().uptimeNanoseconds &- lastStartUptime >= Self.demandRestartInterval {
            startLocked()
        }
    }

    private static let demandRestartInterval: UInt64 = 5_000_000_000

    /// Wake and network-path recovery: start any parked transport now.
    func resumeAfterNetworkChange() {
        lock.lock()
        if !stopped { resumeLocked() }
        lock.unlock()
    }

    private func startLocked() {
        lastStartUptime = DispatchTime.now().uptimeNanoseconds
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
        RelayBlockingIO.start(name: "relay.node.stderr", qos: .utility) {
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
        RelayBlockingIO.start(name: "relay.node.frames", qos: .userInteractive) { [weak self, weak ssh] in
            var fragments = RelayWireFragmentAssembler()
            do {
                // Read until EOF (readExactly throws .endOfStream) rather
                // than gating on ssh.isRunning: frames still buffered in the
                // pipe when the process exits — the final output burst, the
                // terminal "exited" status — must be drained, not dropped.
                while let self {
                    try autoreleasepool {
                        try self.readNodeFrame(from: output.fileHandleForReading, fragments: &fragments,
                            generation: currentGeneration)
                    }
                }
            } catch {
                if ssh?.isRunning == true { ssh?.terminate() }
            }
        }
    }

    /// Reads and routes one frame of the node stream. Every chunk of bytes
    /// shows the stream moving, even one partway through a large frame that
    /// takes longer than the heartbeat timeout to arrive.
    func readNodeFrame(from handle: FileHandle, fragments: inout RelayWireFragmentAssembler,
        generation currentGeneration: Int) throws {
        let raw = try RelayWireFrame.read(from: handle) { noteInbound(generation: currentGeneration) }
        if raw.type == .status,
           let status = try? JSONDecoder().decode(StatusWirePayload.self, from: raw.payload),
           status.state == "ready", status.capabilities?.contains("wire_fragments_v1") == true {
            fragments.enabled = true
        }
        if let frame = try fragments.accept(raw) {
            receive(frame, generation: currentGeneration)
        }
    }

    /// Owned framed peers enter the same generation-checked reader path.
    func receiveAttachedFrame(_ frame: RelayWireFrame, generation: Int) {
        noteInbound(generation: generation)
        receive(frame, generation: generation)
    }

    /// Inbound data of any kind proves the transport alive and ends a run of
    /// heartbeat misses; probes sent before it can no longer count as missed.
    private func noteInbound(generation currentGeneration: Int) {
        let now = uptime()
        lock.lock()
        if generation == currentGeneration, !stopped {
            lastInboundUptime = now
            consecutiveHeartbeatMisses = 0
        }
        lock.unlock()
    }

    private func clearHeartbeatsLocked() {
        pendingHeartbeats.removeAll(keepingCapacity: true)
        lastInboundUptime = nil
        consecutiveHeartbeatMisses = 0
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
                if status.capabilities?.contains("host_accounts_v1") == true {
                    RelayHostAccountSharing.shared.hostReady(profile)
                }
                NotificationCenter.default.post(name: .relayNodeReady, object: profile.connectionKey)
            }
            flushHostRequests()
            flushFocus()
            RelayDiagnostics.shared.record(category: "connection", name: "ready", details: [
                "connection_id": diagnosticConnectionID,
            ])
            return
        }
        if frame.type == .pong, frame.payload.count == 8 {
            let sequence = frame.payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let now = uptime()
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
        clearHeartbeatsLocked()
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
        // A failure classed as permanent (authentication, remote install, a
        // stream closed before the handshake) can still clear outside Relay,
        // e.g. after a network drop or an ssh-agent unlock. Keep retrying
        // slowly; never leave the node parked with no process until restart.
        let delay = failure.shouldRetry ? min(3_000, 150 * (1 << min(attempt - 1, 4))) : 30_000
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped, self.process == nil, self.generation == currentGeneration else {
                self.lock.unlock(); return
            }
            self.startLocked()
            self.lock.unlock()
        }
    }

    func setSystemSleeping(_ sleeping: Bool) {
        lock.lock()
        systemSleeping = sleeping
        clearHeartbeatsLocked()
        lock.unlock()
        if !sleeping { sendHeartbeat() }
    }

    /// The heartbeat timer's tick (tests drive it directly with their clock).
    func sendHeartbeat() {
        let now = uptime()
        lock.lock()
        guard ready, !systemSleeping, let writer else { lock.unlock(); return }
        let verdict = RelayHeartbeatPolicy.shouldRestart(
            pending: pendingHeartbeats, lastInbound: lastInboundUptime,
            now: now, consecutiveMisses: consecutiveHeartbeatMisses
        )
        let missed = verdict.misses - consecutiveHeartbeatMisses
        for sequence in verdict.expired { pendingHeartbeats.removeValue(forKey: sequence) }
        consecutiveHeartbeatMisses = verdict.misses
        let missDetails = [
            "connection_id": diagnosticConnectionID,
            "missed": String(missed),
            "consecutive_misses": String(verdict.misses),
            "last_inbound_age_ms": lastInboundUptime.map { String(now >= $0 ? (now - $0) / 1_000_000 : 0) } ?? "none",
        ]
        if verdict.restart {
            // An alive local ssh PID does not prove that the relay protocol is
            // moving. Stop the wedged transport so its normal termination
            // handler creates a fresh SSH connection and resubscribes panes.
            heartbeatTimer.schedule(deadline: .distantFuture)
            let stalledProcess = process
            lock.unlock()
            for _ in 0..<missed {
                RelayDiagnostics.shared.heartbeatTimedOut(connection: diagnosticConnectionID)
            }
            RelayDiagnostics.shared.record(category: "connection", name: "heartbeat-watchdog",
                details: missDetails.merging(["action": "restart-ssh"]) { $1 })
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

        if missed > 0 {
            // Below the threshold a silent probe is recorded and the transport kept.
            for _ in 0..<missed {
                RelayDiagnostics.shared.heartbeatTimedOut(connection: diagnosticConnectionID)
            }
            RelayDiagnostics.shared.record(category: "connection", name: "heartbeat-missed", details: missDetails)
        }
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
