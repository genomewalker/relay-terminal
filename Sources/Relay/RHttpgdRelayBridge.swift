import Foundation
@preconcurrency import Network

typealias RHttpgdProxyRPC = @Sendable (Data) async throws -> Data

/// One ephemeral native stream per HTTP/WebSocket connection. The captured
/// host/project never changes; bytes never enter a durable host-stream log.
actor RHttpgdNativeStream {
    let proxyID = "httpgd-" + UUID().uuidString.lowercased()
    private let profile: ConnectionProfile
    private let directory: String
    private let port: Int
    private let rpc: RHttpgdProxyRPC
    private var submitted = false
    private var closed = false
    private var scopeID = ""
    private var sequence = 0
    private var offset = 0
    private var outputEnded = false
    private var closeTask: Task<Void, Never>?

    init(profile: ConnectionProfile, directory: String, port: Int, rpc: @escaping RHttpgdProxyRPC) {
        self.profile = profile; self.directory = directory; self.port = port; self.rpc = rpc
    }
    private func request(_ operation: String, fields: [String: Any] = [:]) async throws -> [String: Any] {
        var object = fields
        object["request_id"] = "rpc-" + UUID().uuidString.lowercased()
        object["proxy_id"] = proxyID
        object["scope_id"] = scopeID
        object["operation"] = operation
        let bytes = try await rpc(JSONSerialization.data(withJSONObject: object))
        guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw RHttpgdError.invalidResponse("native stream response")
        }
        if let error = response["error"] as? String { throw RHttpgdError.tunnel(error) }
        guard let result = response["result"] as? [String: Any] else {
            throw RHttpgdError.invalidResponse("native stream result")
        }
        return result
    }
    func start() async throws {
        guard !closed, !submitted, profile.kind == .ssh, (1...65535).contains(port),
              directory.hasPrefix("/"), !directory.contains("\0") else {
            throw RHttpgdError.tunnel("Invalid native stream lease")
        }
        submitted = true
        let capabilities: [String: Any]
        do { capabilities = try await request("loopback_caps") }
        catch { throw RHttpgdError.tunnel("Native plot stream support is unavailable. Check the Relay helper installation for this host.") }
        guard capabilities["state"] as? String == "ready", let scope = capabilities["scope_id"] as? String,
              scope.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
            throw RHttpgdError.invalidResponse("native stream admission namespace")
        }
        scopeID = scope
        if closed { _ = try? await request("loopback_close"); throw CancellationError() }
        let result = try await request("loopback_open", fields: ["port": port])
        if closed {
            // A close before/while open is admitted is remembered by the node.
            // After a late acknowledgement, close the same lease again.
            _ = try? await request("loopback_close")
            throw CancellationError()
        }
        guard result["proxy_id"] as? String == proxyID, result["scope_id"] as? String == scopeID,
              result["state"] as? String == "open" else {
            throw RHttpgdError.invalidResponse("native stream identity")
        }
    }
    func write(_ data: Data, closeInput: Bool) async throws {
        guard submitted, !closed, !scopeID.isEmpty else { throw CancellationError() }
        if outputEnded { return }
        var consumed = 0
        repeat {
            let count = min(64 << 10, data.count - consumed)
            let chunk = data.subdata(in: consumed..<(consumed + count))
            sequence += 1
            let current = sequence
            let result: [String: Any]
            do {
                result = try await request("loopback_write", fields: ["data": chunk.base64EncodedString(),
                    "sequence": current, "close_input": closeInput && consumed + count == data.count])
            } catch {
                // read() may complete upstream EOF while this actor awaits the
                // write RPC. The node has retired that lease; no input is replayed.
                if outputEnded { return }
                // A local FIN contains no bytes. A retired upstream lease needs
                // no further half-close; the reader still proves EOF or failure.
                if closeInput, chunk.isEmpty,
                   case RHttpgdError.tunnel("loopback stream unavailable; do not replay input") = error { return }
                throw error
            }
            guard !closed, result["proxy_id"] as? String == proxyID, result["scope_id"] as? String == scopeID,
                  result["sequence"] as? Int == current else {
                throw RHttpgdError.tunnel("Native stream input outcome is unknown; it will not be replayed.")
            }
            consumed += count
        } while consumed < data.count
    }
    func read() async throws -> (Data, Bool) {
        guard submitted, !closed, !scopeID.isEmpty else { throw CancellationError() }
        let result = try await request("loopback_read", fields: ["offset": offset, "wait_millis": 15000])
        guard !closed, result["proxy_id"] as? String == proxyID, result["scope_id"] as? String == scopeID,
              let encoded = result["data"] as? String, let data = Data(base64Encoded: encoded),
              let next = result["next_offset"] as? Int, next == offset + data.count,
              let ended = result["eof"] as? Bool, !ended || data.isEmpty else {
            throw RHttpgdError.invalidResponse("native stream output identity or offset")
        }
        guard data.count <= 64 << 10 else { throw RHttpgdError.oversized(64 << 10) }
        offset = next
        outputEnded = ended
        return (data, ended)
    }
    func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true
        guard submitted, !scopeID.isEmpty else { return }
        // A cancelled pipe must still submit its close. Every concurrent closer
        // awaits the same receipt instead of returning before the RPC completes.
        let task = Task<Void, Never> { _ = try? await self.request("loopback_close") }
        closeTask = task
        await task.value
    }
}

/// A private local endpoint carried by the existing Relay node connection.
/// No SSH forward is launched. Both HTTP and WebSocket upgrades remain byte
/// streams; httpgd's existing client retains all token/content checks.
final class RHttpgdRelayBridge: @unchecked Sendable {
    let endpoint: RHttpgdEndpoint
    private let listener: NWListener
    private let profile: ConnectionProfile
    private let directory: String
    private let remotePort: Int
    private let rpc: RHttpgdProxyRPC
    private let queue = DispatchQueue(label: "relay-httpgd-native-bridge", qos: .utility)
    let connectionLimit: Int
    private let lock = NSLock()
    private var closed = false
    private var failure = ""
    private var rejectedConnections = 0
    private struct Owned: Sendable {
        let connection: NWConnection
        let stream: RHttpgdNativeStream
        var task: Task<Void, Never>?
    }
    private var owned: [UUID: Owned] = [:]
    private var closeTask: Task<Void, Never>?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !closed }
    var diagnostic: String { lock.lock(); defer { lock.unlock() }; return failure }
    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return owned.count }
    var rejectedConnectionCount: Int { lock.lock(); defer { lock.unlock() }; return rejectedConnections }

    private init(listener: NWListener, localPort: UInt16, profile: ConnectionProfile,
                 directory: String, remotePort: Int, connectionLimit: Int, rpc: @escaping RHttpgdProxyRPC) {
        self.listener = listener; endpoint = RHttpgdEndpoint(port: localPort)
        self.profile = profile; self.directory = directory; self.remotePort = remotePort; self.rpc = rpc
        self.connectionLimit = connectionLimit
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.fail("Native loopback listener ended") }
        }
    }

    static func open(profile: ConnectionProfile, remotePort: Int, directory: String,
                     rpc: RHttpgdProxyRPC? = nil) async throws -> RHttpgdRelayBridge {
        guard profile.kind == .ssh, (1...65535).contains(remotePort), directory.hasPrefix("/"),
              !directory.contains("\0") else { throw RHttpgdError.tunnel("Invalid native forwarding target") }
        let transport = rpc ?? { payload in
            try await RelayNodeTransportPool.shared.request(profile: profile, payload: payload)
        }
        let capabilitiesRequest = try JSONSerialization.data(withJSONObject: [
            "operation": "loopback_caps", "request_id": "rpc-" + UUID().uuidString.lowercased()
        ])
        let connectionLimit = try validatedConnectionLimit(await transport(capabilitiesRequest))
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        // Network requires a connection handler before listener.start. No
        // endpoint is published until the bridge installs its owning handler.
        listener.newConnectionHandler = { connection in connection.cancel() }
        let startup = RHttpgdBridgeStartup()
        let port: UInt16 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup.set(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port { startup.finish(.success(port.rawValue)) }
                        else { startup.finish(.failure(RHttpgdError.tunnel("Native loopback port unavailable"))) }
                    case .failed(let error): startup.finish(.failure(RHttpgdError.tunnel("Native loopback listener unavailable: " + error.localizedDescription)))
                    case .cancelled: startup.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.start(queue: DispatchQueue(label: "relay-httpgd-native-listener", qos: .utility))
            }
        } onCancel: { listener.cancel() }
        do { try Task.checkCancellation() }
        catch { listener.cancel(); throw error }
        return RHttpgdRelayBridge(listener: listener, localPort: port, profile: profile,
            directory: directory, remotePort: remotePort, connectionLimit: connectionLimit, rpc: transport)
    }

    static func validatedConnectionLimit(_ data: Data) throws -> Int {
        struct Capabilities: Decodable {
            struct Result: Decodable {
                let state: String
                let max_streams: Int
            }
            let result: Result?
            let error: String?
        }
        guard let capabilities = try? JSONDecoder().decode(Capabilities.self, from: data) else {
            throw RHttpgdError.invalidResponse("native stream capacity")
        }
        if let error = capabilities.error { throw RHttpgdError.tunnel(error) }
        // Match the native protocol's bounded stream budget. HTTP pools,
        // WebSockets and sockets draining a final response share this budget.
        guard let result = capabilities.result, result.state == "ready",
              (1...32).contains(result.max_streams) else {
            throw RHttpgdError.invalidResponse("native stream capacity")
        }
        return result.max_streams
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let stream = RHttpgdNativeStream(profile: profile, directory: directory, port: remotePort, rpc: rpc)
        lock.lock()
        guard !closed else { lock.unlock(); connection.cancel(); return }
        guard owned.count < connectionLimit else {
            rejectedConnections += 1
            lock.unlock(); connection.cancel(); return
        }
        owned[id] = Owned(connection: connection, stream: stream)
        lock.unlock()
        connection.start(queue: queue)
        let task = Task { [weak self] in
            guard let self else { connection.cancel(); await stream.close(); return }
            await self.pipe(connection, stream: stream)
            self.retire(id)
        }
        lock.lock()
        if !closed, var entry = owned[id] { entry.task = task; owned[id] = entry; lock.unlock() }
        else { lock.unlock(); task.cancel() }
    }

    private func pipe(_ connection: NWConnection, stream: RHttpgdNativeStream) async {
        let drain = RHttpgdStreamDrain()
        defer { drain.cancel() }
        do {
            try await stream.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        let (data, ended) = try await Self.receive(connection)
                        try await stream.write(data, closeInput: ended)
                        if ended { return }
                    }
                    throw CancellationError()
                }
                group.addTask {
                    while !Task.isCancelled {
                        let (data, ended) = try await stream.read()
                        if !data.isEmpty || ended { try await Self.send(connection, data: data, ended: ended) }
                        if ended { drain.arm(connection); return }
                    }
                    throw CancellationError()
                }
                do {
                    while let _ = try await group.next() {}
                } catch {
                    connection.cancel()
                    await stream.close()
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            // A failed lease retires only its own connection. Keep diagnostics
            // actionable without cancelling the listener or unrelated streams.
            // Listener failure and explicit detach still close the whole bridge.
            if let error = error as? RHttpgdError, !Task.isCancelled { recordFailure(error.localizedDescription) }
        }
        connection.cancel()
        await stream.close()
    }

    private static func receive(_ connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, ended, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), ended)) }
            }
        }
    }
    private static func send(_ connection: NWConnection, data: Data, ended: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Completing a default message does not half-close TCP. Forward
            // upstream EOF with the final context so HTTP clients cannot reuse
            // a connection whose remote lease has already ended.
            connection.send(content: data.isEmpty ? nil : data,
                            contentContext: ended ? .finalMessage : .defaultMessage,
                            isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
    private func retire(_ id: UUID) { lock.lock(); owned.removeValue(forKey: id); lock.unlock() }
    private func recordFailure(_ message: String) { lock.lock(); failure = message; lock.unlock() }
    private func fail(_ message: String) { recordFailure(message); close() }
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let streams = Array(owned.values); owned.removeAll()
        closeTask = Task<Void, Never> {
            for stream in streams { stream.connection.cancel(); stream.task?.cancel() }
            await withTaskGroup(of: Void.self) { group in
                for stream in streams { group.addTask { await stream.stream.close() } }
                await group.waitForAll()
            }
            for stream in streams { await stream.task?.value }
        }
        lock.unlock()
        listener.cancel()
    }
    private func closeCompletion() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }; return closeTask
    }
    /// Graceful owners can prove socket/RPC cleanup before ending their process.
    /// Synchronous hide/deinit still starts the same independent close task.
    func closeAndWait() async {
        close()
        if let completion = closeCompletion() { await completion.value }
    }
    deinit { close() }
}

private final class RHttpgdBridgeStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    func set(_ value: CheckedContinuation<UInt16, Error>) { lock.lock(); continuation = value; lock.unlock() }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
    }
}

/// After upstream EOF, let the local client drain its response and half-close.
/// The deadline matches the HTTP client's resource bound; hide/cancel still
/// closes immediately. The timer is cancelled as soon as the stream retires.
private final class RHttpgdStreamDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: Task<Void, Never>?
    func arm(_ connection: NWConnection) {
        lock.lock()
        if timer == nil {
            timer = Task {
                do { try await Task.sleep(for: .seconds(40)); connection.cancel() }
                catch {}
            }
        }
        lock.unlock()
    }
    func cancel() { lock.lock(); let current = timer; timer = nil; lock.unlock(); current?.cancel() }
    deinit { cancel() }
}
