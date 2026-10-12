import AppKit
import Foundation
@preconcurrency import Network
import Testing
@testable import Relay

private let sampleToken = String(repeating: "ab", count: 32)
private let sampleSession = RWorkspaceSession(version: 1, session_id: "sess-1", pid: 4242, host: "hpc", working_directory: "/home/u",
                                              artifact_root: "/home/u/proj/relay-results/pane", capabilities: ["evaluate", "httpgd"])

private func descriptorJSON(_ overrides: [String: Any] = [:]) -> Data {
    var fields: [String: Any] = ["version": 1, "session_id": "sess-1", "pid": 4242, "host": "127.0.0.1", "port": 60347,
                                 "token": sampleToken, "device": 3, "artifact_root": "/home/u/proj/relay-results/pane",
                                 "httpgd_version": "2.1.4", "started_at": "2026-09-19 10:00:00 UTC"]
    for (key, value) in overrides { fields[key] = value }
    return try! JSONSerialization.data(withJSONObject: fields)
}

@Test("httpgd descriptors are session-bound, loopback-only and token-checked")
func httpgdDescriptorValidation() throws {
    let root = "/home/u/proj/relay-results/pane"
    let good = try RHttpgdDescriptor.decode(descriptorJSON())
    try good.validate(session: sampleSession, root: root)
    let hostile: [[String: Any]] = [
        ["host": "0.0.0.0"], ["host": "10.0.0.5"], ["host": "localhost"], ["host": "evil.example"],
        ["port": 0], ["port": 70000], ["token": "abc"], ["token": String(repeating: "Z", count: 64)],
        ["token": sampleToken + "\n"], ["session_id": "sess-2"], ["pid": 1], ["artifact_root": "/home/u/proj/relay-results/other"],
        ["artifact_root": "/home/u/proj/relay-results/pane/../pane"], ["version": 2], ["device": 1], ["device": 5000],
        ["httpgd_version": String(repeating: "v", count: 65)],
    ]
    for override in hostile {
        let descriptor = try RHttpgdDescriptor.decode(descriptorJSON(override))
        #expect(throws: (any Error).self, "accepted \(override)") { try descriptor.validate(session: sampleSession, root: root) }
    }
    // Wrong root for a matching descriptor (renamed project directory).
    #expect(throws: (any Error).self) { try good.validate(session: sampleSession, root: "/home/u/moved/relay-results/pane") }
    // A stale session snapshot must not validate a newer descriptor either.
    let renewed = RWorkspaceSession(version: 1, session_id: "sess-9", pid: 4242, host: "hpc", working_directory: "/home/u",
                                    artifact_root: root, capabilities: ["evaluate", "httpgd"])
    #expect(throws: (any Error).self) { try good.validate(session: renewed, root: root) }
    #expect(throws: (any Error).self) { try RHttpgdDescriptor.decode(Data(repeating: 0x20, count: 9000)) }
    #expect(throws: (any Error).self) { try RHttpgdDescriptor.decode(Data("{}".utf8)) }
}

@Test("httpgd token never appears in descriptions, reflection or status text")
func httpgdTokenRedaction() throws {
    let descriptor = try RHttpgdDescriptor.decode(descriptorJSON())
    #expect(!"\(descriptor)".contains(sampleToken))
    #expect(!String(reflecting: descriptor).contains(sampleToken))
    var dumped = ""
    dump(descriptor, to: &dumped)
    #expect(!dumped.contains(sampleToken))
    #expect("\(descriptor)".contains("60347"))
    let error = RHttpgdError.unauthorized.localizedDescription
    #expect(!error.contains(sampleToken))
}

@Test("Native forwarding rejects foreign profiles, ports and directories")
func httpgdNativeBridgeValidation() async throws {
    let profile = ConnectionProfile.sshConfigHost("fixture")
    await #expect(throws: (any Error).self) { try await RHttpgdRelayBridge.open(profile: .local, remotePort: 60347, directory: "/") }
    await #expect(throws: (any Error).self) { try await RHttpgdRelayBridge.open(profile: profile, remotePort: 0, directory: "/") }
    await #expect(throws: (any Error).self) { try await RHttpgdRelayBridge.open(profile: profile, remotePort: 60347, directory: "relative") }
}

@Test("Native plot bridge uses the host's bounded stream capacity")
func httpgdNativeBridgeCapacity() throws {
    func response(_ capacity: Any, state: String = "ready") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["result": ["state": state, "max_streams": capacity]])
    }
    #expect(try RHttpgdRelayBridge.validatedConnectionLimit(response(32)) == 32)
    #expect(try RHttpgdRelayBridge.validatedConnectionLimit(response(8)) == 8)
    for invalid: Any in [0, -1, 33, true, "32"] {
        #expect(throws: (any Error).self) { try RHttpgdRelayBridge.validatedConnectionLimit(response(invalid)) }
    }
    #expect(throws: (any Error).self) { try RHttpgdRelayBridge.validatedConnectionLimit(response(32, state: "closed")) }
}

@Test("httpgd start command is bound to the validated session and capability")
func httpgdStartCommand() throws {
    let command = try RWorkspaceCommand.httpgdStart(session: sampleSession, root: sampleSession.artifact_root)
    #expect(command == "relay_r_httpgd_start(\"/home/u/proj/relay-results/pane\")")
    let legacy = RWorkspaceSession(version: 1, session_id: "s", pid: 1, host: "h", working_directory: "/", artifact_root: "/r", capabilities: ["evaluate"])
    #expect(!legacy.supportsHttpgd)
    #expect(throws: (any Error).self) { try RWorkspaceCommand.httpgdStart(session: legacy, root: "/r") }
    #expect(throws: (any Error).self) { try RWorkspaceCommand.httpgdStart(session: sampleSession, root: "/elsewhere") }
    let decoded = try JSONDecoder().decode(RWorkspaceSession.self, from: Data("""
    {"version":1,"session_id":"a","pid":2,"host":"h","working_directory":"/w","artifact_root":"/w/r","capabilities":["evaluate","httpgd"],"httpgd_installed":false}
    """.utf8))
    #expect(decoded.httpgd_installed == false && decoded.supportsHttpgd)
}

// MARK: - Loopback mock of httpgd's HTTP + WebSocket surface

private func samplePNG(width: Int = 8, height: Int = 6) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

/// Mirrors httpgd 2.1.x behaviour: token guard on API routes, an unauthenticated
/// echoing WebSocket at "/", and the newest plot for unknown ids.
private final class MockHttpgdServer: @unchecked Sendable {
    let token: String
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock-httpgd")
    private let lock = NSLock()
    private var requests: [(line: String, headers: [String: String])] = []
    private var sockets: [NWConnection] = []
    private var connections: [NWConnection] = []
    var plotIDs = ["0", "1"]
    var upid = 10
    var renderPayload: Data? = nil

    init(token: String) throws {
        self.token = token
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = self?.listener.port?.rawValue ?? 0; ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var seen: [(line: String, headers: [String: String])] { lock.lock(); defer { lock.unlock() }; return requests }
    var socketCount: Int { lock.lock(); defer { lock.unlock() }; return sockets.count }

    func broadcast(_ text: String) {
        lock.lock(); let targets = sockets; lock.unlock()
        for socket in targets { socket.send(content: RelaySidePanelWebSocket.serverFrame(opcode: 0x1, payload: Data(text.utf8)), completion: .idempotent) }
    }

    func stop() {
        listener.cancel()
        lock.lock(); let all = connections + sockets; lock.unlock()
        for connection in all { connection.cancel() }
    }

    /// Simulates the R side dropping its socket without closing the device.
    func dropSockets() {
        lock.lock(); let dropped = sockets; sockets = []; lock.unlock()
        for socket in dropped { socket.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, complete, _ in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            switch RelaySidePanelHTTPRequest.parse(accumulated) {
            case .incomplete: if !complete { self.receive(connection, buffer: accumulated) }
            case .invalid: connection.cancel()
            case .request(let request): self.handle(request, on: connection)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data, extra: String = "") {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extra)\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func stateJSON() -> Data {
        Data("{\"upid\":\(upid),\"hsize\":\(plotIDs.count),\"active\":true}".utf8)
    }

    private func handle(_ request: RelaySidePanelHTTPRequest, on connection: NWConnection) {
        lock.lock(); requests.append((request.method + " " + request.path, request.headers)); lock.unlock()
        let components = URLComponents(string: "http://127.0.0.1" + request.path)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let path = components?.path ?? request.path
        if request.headers["upgrade"]?.lowercased() == "websocket", let key = request.headers["sec-websocket-key"] {
            // No token check, exactly like httpgd.
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(RelaySidePanelWebSocket.acceptValue(for: key))\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.sockets.append(connection); self.lock.unlock()
                self.drain(connection)
            })
            return
        }
        let presented = request.headers["x-httpgd-token"] ?? query["token"]
        guard presented == token else { return respond(connection, status: "401 Unauthorized", type: "text/plain", body: Data("Unauthorized".utf8)) }
        switch path {
        case "/state": respond(connection, status: "200 OK", type: "application/json", body: stateJSON())
        case "/plots":
            let limit = Int(query["limit"] ?? "0") ?? 0
            let ids = limit > 0 ? Array(plotIDs.prefix(limit)) : plotIDs
            let body = "{\"plots\":[\(ids.map { "{\"id\":\"\($0)\"}" }.joined(separator: ","))],\"state\":\(String(decoding: stateJSON(), as: UTF8.self))}"
            respond(connection, status: "200 OK", type: "application/json", body: Data(body.utf8))
        case "/plot":
            guard query["renderer"] == "png" else { return respond(connection, status: "200 OK", type: "image/svg+xml", body: Data("<svg/>".utf8)) }
            respond(connection, status: "200 OK", type: "image/png", body: renderPayload ?? samplePNG())
        case "/remove":
            if let id = query["id"], let index = plotIDs.firstIndex(of: id) { plotIDs.remove(at: index) } else if !plotIDs.isEmpty { plotIDs.removeLast() }
            upid += 1
            respond(connection, status: "200 OK", type: "application/json", body: stateJSON())
        case "/clear": plotIDs = []; upid += 1; respond(connection, status: "200 OK", type: "application/json", body: stateJSON())
        case "/redirect": respond(connection, status: "302 Found", type: "text/plain", body: Data(), extra: "Location: http://127.0.0.1:\(port)/state\r\n")
        case "/big": respond(connection, status: "200 OK", type: "application/json", body: Data(repeating: 0x30, count: RHttpgdLimits.stateBytes + 1))
        default: respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
        }
    }

    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
            if complete || error != nil {
                self?.lock.lock(); self?.sockets.removeAll { $0 === connection }; self?.lock.unlock()
                return
            }
            self?.drain(connection)
        }
    }
}

private func fetchState(_ client: RHttpgdClient) async throws -> RHttpgdState { try await client.state() }

@Test("httpgd client authenticates by header, refuses redirects and bounds bodies")
func httpgdClientTransport() async throws {
    let server = try MockHttpgdServer(token: sampleToken)
    defer { server.stop() }
    #expect(server.port > 0)
    let endpoint = RHttpgdEndpoint(port: server.port)
    let client = RHttpgdClient(endpoint: endpoint, token: sampleToken)
    defer { client.invalidate() }
    let state = try await fetchState(client)
    #expect(state == RHttpgdState(upid: 10, hsize: 2, active: true))
    let listing = try await client.plots(limit: 500)
    #expect(listing.ids == ["0", "1"] && listing.state.hsize == 2)
    let png = try await client.render(id: "1", width: 9000, height: -5, zoom: 7)
    #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    let wrong = RHttpgdClient(endpoint: endpoint, token: String(repeating: "cd", count: 32))
    defer { wrong.invalidate() }
    await #expect(throws: RHttpgdError.unauthorized) { try await wrong.state() }
    await #expect(throws: RHttpgdError.unknownPlot) { try await client.render(id: "x; DROP", width: 1, height: 1, zoom: 1) }
    await #expect(throws: RHttpgdError.redirected) { try await client.stateAt(path: "/redirect") }
    await #expect(throws: RHttpgdError.oversized(RHttpgdLimits.stateBytes)) { try await client.stateAt(path: "/big") }
    await #expect(throws: RHttpgdError.invalidResponse("content type")) { try await client.stateAt(path: "/plot") }
    let seen = server.seen
    #expect(!seen.isEmpty)
    for request in seen {
        #expect(!request.line.contains(sampleToken), "token leaked into URL: \(request.line)")
        #expect(!request.line.contains("token="))
    }
    #expect(seen.contains { $0.line.hasPrefix("GET /state") && $0.headers["x-httpgd-token"] == sampleToken })
    if let render = seen.first(where: { $0.line.hasPrefix("GET /plot?") }) {
        #expect(render.line.contains("width=4000") && render.line.contains("height=100") && render.line.contains("zoom=3.00") && render.line.contains("renderer=png"))
    } else { Issue.record("no render request") }
    #expect(seen.filter { $0.line.hasPrefix("GET /state") && $0.headers["x-httpgd-token"] == sampleToken }.count == 1, "redirect must not be followed")
    #expect(seen.contains { $0.line.hasPrefix("GET /plots?") && $0.line.contains("limit=200") })
}

@Test("httpgd change socket is a hint: history is re-read through authenticated HTTP")
@MainActor
func httpgdSocketTriggersResync() async throws {
    let server = try MockHttpgdServer(token: sampleToken)
    defer { server.stop() }
    let connection = RHttpgdConnection()
    connection.watchesWhileInactive = true
    let client = RHttpgdClient(endpoint: RHttpgdEndpoint(port: server.port), token: sampleToken)
    try await connection.attach(api: client, label: "mock")
    #expect(connection.phase == .connected)
    #expect(connection.plotIDs == ["0", "1"] && connection.selectedID == "1")
    connection.setViewport(size: CGSize(width: 300, height: 200), scale: 2)
    for _ in 0..<100 where connection.image == nil { try await Task.sleep(for: .milliseconds(50)) }
    #expect(connection.image != nil && connection.imageBytes != nil)
    for _ in 0..<100 where server.socketCount == 0 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(server.socketCount == 1)
    server.plotIDs = ["0", "1", "2"]
    server.upid = 11
    server.broadcast("{\"upid\":11,\"hsize\":3,\"active\":true}")
    for _ in 0..<100 where connection.plotIDs.count != 3 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(connection.plotIDs == ["0", "1", "2"] && connection.selectedID == "2" && connection.followsNewest)
    #expect(connection.socketLive)
    // A forged message claiming plots exist changes nothing: the listing rules.
    server.broadcast("{\"upid\":99,\"hsize\":50,\"active\":true}")
    try await Task.sleep(for: .milliseconds(300))
    #expect(connection.plotIDs.count == 3 && connection.deviceState?.hsize == 3)
    // A dropped socket reconnects with backoff and re-reads history on the way back.
    connection.reconnectDelays = [.milliseconds(50), .milliseconds(50)]
    server.dropSockets()
    for _ in 0..<100 where connection.socketLive { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!connection.socketLive)
    for _ in 0..<100 where server.socketCount == 0 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(server.socketCount == 1 && connection.phase == .connected)
    server.plotIDs = ["0", "1", "2"]
    server.broadcast("{\"upid\":12,\"hsize\":3,\"active\":true}")
    for _ in 0..<100 where !connection.socketLive { try await Task.sleep(for: .milliseconds(50)) }
    #expect(connection.socketLive && connection.plotIDs.count == 3)
    // Browsing back stops following; the newest arrival re-follows only on request.
    connection.selectPrevious()
    #expect(connection.selectedID == "1" && !connection.followsNewest)
    server.plotIDs = ["0", "1", "2", "3"]
    server.broadcast("{}")
    for _ in 0..<100 where connection.plotIDs.count != 4 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(connection.selectedID == "1" && connection.unseenPlotCount == 1)
    await connection.resync()
    #expect(connection.unseenPlotCount == 1, "Repeated listings must not count the same plot twice")
    server.plotIDs = ["0", "1", "2"]
    await connection.resync()
    #expect(connection.selectedID == "1" && connection.unseenPlotCount == 0)
    server.plotIDs = ["0", "1", "2", "3"]
    await connection.resync()
    #expect(connection.unseenPlotCount == 1)
    connection.selectNewest()
    #expect(connection.selectedID == "3" && connection.followsNewest)
    #expect(connection.unseenPlotCount == 0)
    // Removal re-lists first, so a stale selection is never forwarded to /remove.
    connection.select(id: "1")
    server.plotIDs = ["0", "2", "3"]
    await connection.removeSelected()
    #expect(!server.seen.contains { $0.line.hasPrefix("GET /remove") })
    #expect(connection.plotIDs == ["0", "2", "3"])
    connection.select(id: "2")
    await connection.removeSelected()
    #expect(server.seen.contains { $0.line == "GET /remove?id=2" })
    #expect(connection.plotIDs == ["0", "3"])
    for request in server.seen { #expect(!request.line.contains(sampleToken)) }
    connection.disconnect()
    #expect(connection.phase == .idle && connection.image == nil && connection.imageBytes == nil && connection.plotIDs.isEmpty)
    for _ in 0..<100 where server.socketCount != 0 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(server.socketCount == 0)
}

private final class FakeHttpgdAPI: RHttpgdAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var _ids = ["0", "1"]
    private var _renders: [(id: String, width: Int, height: Int, zoom: Double)] = []
    var renderDelay: Duration = .milliseconds(80)
    var socketURL: URL?
    var stateError: RHttpgdError?

    var ids: [String] { get { lock.lock(); defer { lock.unlock() }; return _ids } set { lock.lock(); _ids = newValue; lock.unlock() } }
    var renders: [(id: String, width: Int, height: Int, zoom: Double)] { lock.lock(); defer { lock.unlock() }; return _renders }

    func state() async throws -> RHttpgdState { if let stateError { throw stateError }; return RHttpgdState(upid: 1, hsize: ids.count, active: true) }
    func plots(limit: Int) async throws -> RHttpgdPlotList { RHttpgdPlotList(state: try await state(), ids: Array(ids.prefix(limit))) }
    private func record(_ render: (id: String, width: Int, height: Int, zoom: Double)) {
        lock.withLock { _renders.append(render) }
    }

    func render(id: String, width: Int, height: Int, zoom: Double) async throws -> Data {
        record((id, width, height, zoom))
        try await Task.sleep(for: renderDelay)
        return samplePNG()
    }
    func remove(id: String) async throws -> RHttpgdState { ids.removeAll { $0 == id }; return try await state() }
    func clear() async throws -> RHttpgdState { ids = []; return try await state() }
    func makeWebSocket() -> URLSessionWebSocketTask? { socketURL.map { URLSession.shared.webSocketTask(with: $0) } }
    func invalidate() {}
}

@Test("Renders are latest-only with debounced resizes and clamped dimensions")
@MainActor
func httpgdRenderCoalescing() async throws {
    let api = FakeHttpgdAPI()
    let connection = RHttpgdConnection()
    connection.resizeDebounce = .milliseconds(100)
    try await connection.attach(api: api, label: "fake")
    for _ in 0..<100 where connection.image == nil { try await Task.sleep(for: .milliseconds(20)) }
    let baseline = api.renders.count
    #expect(baseline == 1)
    // A resize burst collapses into one render after the debounce.
    for step in 0..<30 {
        connection.setViewport(size: CGSize(width: 400 + step, height: 300 + step), scale: 2)
        try await Task.sleep(for: .milliseconds(2))
    }
    try await Task.sleep(for: .milliseconds(400))
    #expect(api.renders.count == baseline + 1)
    #expect(api.renders.last.map { $0.width == 858 && $0.height == 658 && $0.zoom == 2 } == true)
    // Selection changes while a render is in flight collapse to the newest state.
    connection.select(id: "0"); connection.select(id: "1"); connection.select(id: "0"); connection.select(id: "1"); connection.select(id: "0")
    try await Task.sleep(for: .milliseconds(500))
    #expect(api.renders.count <= baseline + 3)
    #expect(connection.renderedKey?.id == "0" && connection.selectedID == "0" && !connection.followsNewest)
    // Same key again is served from the existing bitmap.
    let before = api.renders.count
    connection.select(id: "0")
    try await Task.sleep(for: .milliseconds(200))
    #expect(api.renders.count == before)
    // Oversized viewports never exceed the documented render bound.
    connection.setViewport(size: CGSize(width: 10_000, height: 9_000), scale: 3)
    try await Task.sleep(for: .milliseconds(400))
    #expect(api.renders.last.map { $0.width == 4000 && $0.height == 4000 && $0.zoom == 3 } == true)
    connection.disconnect()
}

@Test("Socket loss reconnects a bounded number of times, then fails closed")
@MainActor
func httpgdBoundedReconnect() async throws {
    let api = FakeHttpgdAPI()
    api.socketURL = URL(string: "ws://127.0.0.1:1/")
    let connection = RHttpgdConnection()
    connection.watchesWhileInactive = true
    api.renderDelay = .milliseconds(1)
    connection.reconnectDelays = [.milliseconds(100), .milliseconds(100), .milliseconds(100)]
    try await connection.attach(api: api, label: "fake")
    #expect(connection.phase == .connected)
    for _ in 0..<100 where connection.image == nil && connection.phase == .connected { try await Task.sleep(for: .milliseconds(10)) }
    let displayedBytes = connection.imageBytes
    #expect(displayedBytes != nil)
    for _ in 0..<200 where connection.phase == .connected { try await Task.sleep(for: .milliseconds(50)) }
    guard case .failed(let message) = connection.phase else { Issue.record("expected failure, got \(connection.phase)"); return }
    #expect(message.contains("repeated retries"))
    #expect(connection.plotIDs.isEmpty && connection.hasStaleImage && connection.imageBytes == displayedBytes)
    connection.disconnect()
    #expect(connection.image == nil && connection.imageBytes == nil && !connection.hasStaleImage)
    // A stale descriptor (401 on verification) never becomes a connection.
    let stale = FakeHttpgdAPI()
    stale.stateError = .unauthorized
    let second = RHttpgdConnection()
    await #expect(throws: RHttpgdError.unauthorized) { try await second.attach(api: stale, label: "stale") }
    #expect(second.phase != .connected)
}

@Test("Transport failure retains a stale plot; resetting the session clears it")
@MainActor
func httpgdStaleImageAfterTransportFailure() async throws {
    let api = FakeHttpgdAPI()
    api.renderDelay = .milliseconds(1)
    let connection = RHttpgdConnection()
    try await connection.attach(api: api, label: "first session")
    for _ in 0..<100 where connection.image == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(connection.image != nil && !connection.hasStaleImage)
    let displayedBytes = connection.imageBytes
    api.stateError = .unauthorized
    await connection.resync()
    guard case .failed = connection.phase else { Issue.record("expected disconnected failure"); return }
    #expect(connection.hasStaleImage && connection.imageBytes == displayedBytes)
    #expect(connection.plotIDs.isEmpty && connection.selectedID == nil)
    let renders = api.renders.count
    connection.selectNewest()
    connection.setViewport(size: CGSize(width: 400, height: 300), scale: 1)
    try await Task.sleep(for: .milliseconds(200))
    #expect(api.renders.count == renders, "A stale figure cannot resume requests on the old device")
    let next = FakeHttpgdAPI()
    next.renderDelay = .seconds(1)
    try await connection.attach(api: next, label: "new session")
    #expect(!connection.hasStaleImage && connection.image == nil && connection.imageBytes == nil)
    connection.disconnect()
    #expect(connection.image == nil && connection.imageBytes == nil && connection.renderedKey == nil)
    try await Task.sleep(for: .milliseconds(50))
    #expect(connection.image == nil, "A cancelled old render cannot repopulate reset results")
}

/// Real device: remote/r/test-relay-httpgd-live.sh starts a disposable R
/// process with the companion and sets RELAY_HTTPGD_LIVE_DIR. Without it the
/// test passes vacuously and says so.
@Test("Live httpgd device: descriptor, token, history, resize and change socket")
@MainActor
func httpgdLiveDevice() async throws {
    guard let directory = ProcessInfo.processInfo.environment["RELAY_HTTPGD_LIVE_DIR"] else {
        print("httpgdLiveDevice: SKIPPED (no live device; run remote/r/test-relay-httpgd-live.sh)")
        return
    }
    let root = directory + "/results"
    let sessionBytes = try Data(contentsOf: URL(fileURLWithPath: root + "/session.json"))
    let session = try JSONDecoder().decode(RWorkspaceSession.self, from: sessionBytes)
    let descriptorBytes = try Data(contentsOf: URL(fileURLWithPath: root + "/httpgd.json"))
    let attributes = try FileManager.default.attributesOfItem(atPath: root + "/httpgd.json")
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    let descriptor = try RHttpgdDescriptor.decode(descriptorBytes)
    try descriptor.validate(session: session, root: session.artifact_root)
    let connection = RHttpgdConnection()
    connection.watchesWhileInactive = true
    let wrong = RHttpgdClient(endpoint: RHttpgdEndpoint(port: UInt16(descriptor.port)), token: String(repeating: "00", count: 32))
    await #expect(throws: RHttpgdError.unauthorized) { try await wrong.state() }
    wrong.invalidate()
    let client = RHttpgdClient(endpoint: RHttpgdEndpoint(port: UInt16(descriptor.port)), token: descriptor.token)
    try await connection.attach(api: client, label: "live")
    #expect(connection.plotIDs.count == 1 && connection.selectedID != nil)
    connection.setViewport(size: CGSize(width: 320, height: 240), scale: 2)
    for _ in 0..<200 where connection.renderedKey?.width != 640 || connection.rendering { try await Task.sleep(for: .milliseconds(50)) }
    guard let first = connection.imageBytes, let source = CGImageSourceCreateWithData(first as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        Issue.record("no rendered image"); return
    }
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 640 && properties[kCGImagePropertyPixelHeight] as? Int == 480)
    // Redraw at a new size goes back to R (its event loop is idle in Sys.sleep).
    connection.setViewport(size: CGSize(width: 500, height: 200), scale: 1)
    for _ in 0..<200 where connection.renderedKey?.width != 500 || connection.rendering { try await Task.sleep(for: .milliseconds(50)) }
    guard let second = connection.imageBytes, let source2 = CGImageSourceCreateWithData(second as CFData, nil),
          let properties2 = CGImageSourceCopyPropertiesAtIndex(source2, 0, nil) as? [CFString: Any] else {
        Issue.record("no resized image"); return
    }
    #expect(properties2[kCGImagePropertyPixelWidth] as? Int == 500 && properties2[kCGImagePropertyPixelHeight] as? Int == 200)
    // Live status only flips on the first message; provoke one via a new plot.
    FileManager.default.createFile(atPath: directory + "/plot-request", contents: nil)
    for _ in 0..<200 where connection.plotIDs.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(connection.plotIDs.count == 2 && connection.followsNewest && connection.socketLive)
    #expect(connection.selectedID == connection.plotIDs.last)
    connection.selectPrevious()
    for _ in 0..<200 where connection.renderedKey?.id != connection.plotIDs.first { try await Task.sleep(for: .milliseconds(50)) }
    #expect(connection.renderedKey?.id == connection.plotIDs.first)
    connection.selectNewest()
    await connection.removeSelected()
    #expect(connection.plotIDs.count == 1)
    #expect(!connection.status.contains(descriptor.token))
    connection.disconnect()
    #expect(connection.phase == .idle && connection.imageBytes == nil)
}

private struct HttpgdNativeFixtureSnapshot: Sendable {
    let operations: [String]
    let input: Data
    let closedInputs: [Bool]
    let port: Int
    let usedDurableJob: Bool
    let cancellations: Int
}
private actor HttpgdNativeRPCFixture {
    private let scope = String(repeating: "ab", count: 16)
    private let delayStart: Bool
    private let startedPair = AsyncStream<Void>.makeStream()
    var startedStream: AsyncStream<Void> { startedPair.stream }
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var id = ""
    private var operations: [String] = []
    private var input = Data()
    private var closedInputs: [Bool] = []
    private var port = 0
    private var usedDurableJob = false
    private var cancellations = 0
    private var chunks = [Data("first".utf8), Data("second".utf8), Data()]
    init(delayStart: Bool = false) { self.delayStart = delayStart }
    func releaseStart() { startContinuation?.resume(); startContinuation = nil }
    func snapshot() -> HttpgdNativeFixtureSnapshot {
        .init(operations: operations, input: input, closedInputs: closedInputs,
              port: port, usedDurableJob: usedDurableJob, cancellations: cancellations)
    }
    func request(_ data: Data) async throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let operation = try #require(object["operation"] as? String)
        let requestID = try #require(object["request_id"] as? String)
        operations.append(operation)
        if object["job_id"] != nil || object["command"] != nil || object["argv"] != nil { usedDurableJob = true }
        var result: [String: Any]
        switch operation {
        case "loopback_caps": result = ["scope_id": scope, "state": "ready"]
        case "loopback_open":
            id = try #require(object["proxy_id"] as? String)
            port = try #require(object["port"] as? Int)
            #expect(object["scope_id"] as? String == scope)
            if delayStart {
                await withCheckedContinuation { continuation in
                    startContinuation = continuation
                    startedPair.continuation.yield(())
                }
            }
            result = ["proxy_id": id, "scope_id": scope, "state": "open"]
        case "loopback_write":
            #expect(object["proxy_id"] as? String == id)
            #expect(object["scope_id"] as? String == scope)
            let encoded = try #require(object["data"] as? String)
            let bytes = try #require(Data(base64Encoded: encoded))
            #expect(bytes.count <= 64 << 10)
            input.append(bytes)
            closedInputs.append(object["close_input"] as? Bool ?? false)
            #expect(object["sequence"] as? Int == closedInputs.count)
            result = ["proxy_id": id, "scope_id": scope, "sequence": closedInputs.count]
        case "loopback_read":
            #expect(object["proxy_id"] as? String == id)
            let offset = try #require(object["offset"] as? Int)
            let chunk = chunks.removeFirst()
            result = ["proxy_id": id, "scope_id": scope, "data": chunk.base64EncodedString(),
                      "next_offset": offset + chunk.count, "eof": chunk.isEmpty]
        case "loopback_close":
            cancellations += 1
            result = ["proxy_id": id, "scope_id": scope, "state": "closed"]
        default: throw RHttpgdError.invalidResponse("fixture operation")
        }
        return try JSONSerialization.data(withJSONObject: ["request_id": requestID, "result": result])
    }
}

@Test("Native httpgd streams keep sequenced input and half-close without host jobs")
func httpgdNativeStreamInputAndContext() async throws {
    let fixture = HttpgdNativeRPCFixture()
    let stream = RHttpgdNativeStream(profile: .sshConfigHost("fixture"), directory: "/captured/root", port: 60347,
                                    rpc: { try await fixture.request($0) })
    try await stream.start()
    let input = Data(repeating: 0xab, count: (64 << 10) + 7)
    try await stream.write(input, closeInput: true)
    await stream.close()
    let observed = await fixture.snapshot()
    #expect(observed.input == input)
    #expect(observed.closedInputs == [false, true])
    #expect(observed.operations == ["loopback_caps", "loopback_open", "loopback_write", "loopback_write", "loopback_close"])
    #expect(observed.port == 60347)
    #expect(!observed.usedDurableJob)
}
@Test("Native httpgd streams drain all buffered chunks before EOF")
func httpgdNativeStreamTerminalOutputDrain() async throws {
    let fixture = HttpgdNativeRPCFixture()
    let stream = RHttpgdNativeStream(profile: .sshConfigHost("fixture"), directory: "/captured/root", port: 60347,
                                    rpc: { try await fixture.request($0) })
    try await stream.start()
    let first = try await stream.read(), second = try await stream.read(), last = try await stream.read()
    #expect(first.0 == Data("first".utf8) && !first.1)
    #expect(second.0 == Data("second".utf8) && !second.1)
    #expect(last.0.isEmpty && last.1)
    await stream.close()
}
@Test("Closing during native stream startup cannot reopen the admitted lease")
func httpgdNativeStreamCloseDuringStartup() async throws {
    let fixture = HttpgdNativeRPCFixture(delayStart: true)
    let stream = RHttpgdNativeStream(profile: .sshConfigHost("fixture"), directory: "/captured/root", port: 60347,
                                    rpc: { try await fixture.request($0) })
    let startup = Task { try await stream.start() }
    var iterator = await fixture.startedStream.makeAsyncIterator()
    _ = await iterator.next()
    await stream.close()
    await fixture.releaseStart()
    await #expect(throws: CancellationError.self) { try await startup.value }
    let observed = await fixture.snapshot()
    #expect(observed.operations.filter { $0 == "loopback_open" }.count == 1)
    #expect(observed.cancellations == 2)
    #expect(!observed.usedDurableJob)
}
@Test("Native stream validates captured project before any remote operation")
func httpgdNativeStreamRejectsRelativeContext() async throws {
    let fixture = HttpgdNativeRPCFixture()
    let stream = RHttpgdNativeStream(profile: .sshConfigHost("fixture"), directory: "relative", port: 60347,
                                    rpc: { try await fixture.request($0) })
    await #expect(throws: (any Error).self) { try await stream.start() }
    #expect(await fixture.snapshot().operations.isEmpty)
}

private final class HttpgdGoRPCFixture: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var buffer = Data()
    private var closed = false
    init(path: String) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { self?.failPending() } else { self?.receive(data) }
        }
        try process.run()
    }
    func request(_ data: Data) async throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let id = try #require(object["request_id"] as? String)
        return try await withCheckedThrowingContinuation { continuation in
            enqueue(data, id: id, continuation: continuation)
        }
    }
    private func enqueue(_ data: Data, id: String, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !closed else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        pending[id] = continuation
        do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])); lock.unlock() }
        catch { pending.removeValue(forKey: id); lock.unlock(); continuation.resume(throwing: error) }
    }
    private func receive(_ data: Data) {
        var answers: [(CheckedContinuation<Data, Error>, Data)] = []
        lock.lock()
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let id = object["request_id"] as? String, let waiter = pending.removeValue(forKey: id) {
                answers.append((waiter, line))
            }
        }
        lock.unlock()
        for (waiter, line) in answers { waiter.resume(returning: line) }
    }
    private func failPending() {
        lock.lock(); let waiters = Array(pending.values); pending.removeAll(); lock.unlock()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }
    func close() {
        lock.lock(); guard !closed else { lock.unlock(); return }; closed = true; lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        failPending()
        if process.isRunning { process.terminate() }
    }
    deinit { close() }
}

@Test("App bridge carries large HTTP responses and WebSocket notifications through the Go stream fixture")
func httpgdNativeBridgeGoInterop() async throws {
    guard let path = ProcessInfo.processInfo.environment["RELAY_HTTPGD_RPC_FIXTURE"],
          FileManager.default.isExecutableFile(atPath: path) else {
        print("httpgdNativeBridgeGoInterop: SKIPPED (no Go RPC fixture configured)"); return
    }
    let fixture = try HttpgdGoRPCFixture(path: path)
    defer { fixture.close() }
    let server = try MockHttpgdServer(token: sampleToken)
    defer { server.stop() }
    let payload = samplePNG() + Data(repeating: 0x61, count: 3 << 20)
    server.renderPayload = payload
    let bridge = try await RHttpgdRelayBridge.open(profile: .sshConfigHost("fixture"), remotePort: Int(server.port),
        directory: "/captured/root", rpc: { try await fixture.request($0) })
    defer { bridge.close() }
    let client = RHttpgdClient(endpoint: bridge.endpoint, token: sampleToken)
    defer { client.invalidate() }
    // Real TCP EOF must reach URLSession before it sends another request.
    for _ in 0..<6 { #expect(try await client.state().active) }
    let listing = try await client.plots(limit: 20)
    let id = try #require(listing.ids.first)
    let rendered = try await client.render(id: id, width: 720, height: 576, zoom: 1)
    #expect(rendered == payload)
    let socket = try #require(client.makeWebSocket())
    socket.resume()
    defer { socket.cancel(with: .goingAway, reason: nil) }
    try await socket.send(.string("ready"))
    server.broadcast("native-fixture-wake")
    let message = try await socket.receive()
    if case .string(let value) = message { #expect(value == "native-fixture-wake") }
    else { Issue.record("Native WebSocket notification changed") }
    #expect(bridge.isRunning)
    #expect(server.seen.filter { !$0.line.hasPrefix("GET /") || !$0.headers.keys.contains("upgrade") }
        .allSatisfy { $0.headers["x-httpgd-token"] == sampleToken })
}

@Test("Visible inactive plots keep watching; occlusion suspends and restoration resyncs")
@MainActor
func httpgdVisibleInactivePresentationKeepsWatching() async throws {
    let server = try MockHttpgdServer(token: sampleToken)
    defer { server.stop() }
    let connection = RHttpgdConnection()
    defer { connection.disconnect() }
    var visible = true
    connection.applicationIsActive = { false }
    connection.presentationIsVisible = { visible }
    #expect(!connection.watchesWhileInactive)
    let client = RHttpgdClient(endpoint: RHttpgdEndpoint(port: server.port), token: sampleToken)
    try await connection.attach(api: client, label: "visible inactive")
    for _ in 0..<100 where server.socketCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(server.socketCount == 1)
    server.plotIDs = ["0", "1", "2"]
    server.broadcast("{}")
    for _ in 0..<100 where connection.plotIDs.count != 3 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(connection.plotIDs.count == 3 && connection.selectedID == "2")
    visible = false
    connection.reconcileWatching()
    for _ in 0..<100 where server.socketCount != 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(server.socketCount == 0 && !connection.socketLive)
    server.plotIDs = ["0", "1", "2", "3"]
    visible = true
    connection.reconcileWatching()
    for _ in 0..<100 where connection.plotIDs.count != 4 || server.socketCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(connection.plotIDs.count == 4 && connection.selectedID == "3")
    #expect(server.socketCount == 1)
}
