@preconcurrency import Network
import AppKit
import CryptoKit
import Foundation

struct RelaySidePanelState: Encodable, Sendable {
    let version = 3
    let selectedPaneID: String?
    let terminalFontFamily: String
    let terminalFontSize: Double
    let sessions: [Session]

    struct Session: Encodable, Sendable {
        let id: String
        let name: String
        let pinned: Bool
        let tabs: [Tab]
    }

    struct Tab: Encodable, Sendable {
        let id: String
        let name: String
        let pinned: Bool
        let selected: Bool
        let panes: [Pane]
    }

    struct Pane: Encodable, Sendable {
        let id: String
        let name: String
        let host: String
        let directory: String?
        let contentKind: String
        let terminalAvailable: Bool
        let agent: String
        let phase: String
        let connection: String
        let selected: Bool
        let summary: String
    }

    struct Activity: Encodable, Sendable {
        let id: String
        let label: String
        let phase: String
        let occurredAt: Date
    }

    struct Subagent: Encodable, Sendable {
        let id: String
        let label: String
        let provider: String
        let phase: String
        let updates: [String]
    }
}

struct RelaySidePanelPaneDetail: Encodable, Sendable {
    let id: String
    let context: [String]
    let activities: [RelaySidePanelState.Activity]
    let subagents: [RelaySidePanelState.Subagent]
}

struct RelaySidePanelHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum ParseResult: Equatable, Sendable {
        case incomplete
        case invalid
        case request(RelaySidePanelHTTPRequest)
    }

    static func parse(_ data: Data) -> ParseResult {
        guard data.count <= 64 << 10 else { return .invalid }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return .incomplete }
        guard let headerText = String(
            data: data[..<headerRange.lowerBound], encoding: .utf8
        ) else { return .invalid }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }
        let requestParts = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard requestParts.count == 3,
              requestParts[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        guard contentLength >= 0, contentLength <= 32 << 10 else { return .invalid }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return .incomplete }
        return .request(RelaySidePanelHTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: String(requestParts[1]),
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + contentLength)])
        ))
    }

    func isAuthorized(token: String) -> Bool {
        headers["x-relay-token"] == token
    }

    func isAuthorizedWebSocket(token: String) -> Bool {
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().contains("upgrade") == true,
              headers["origin"] == "http://127.0.0.1:47471" else { return false }
        let protocols = headers["sec-websocket-protocol"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        return protocols.contains("relay-v1") && protocols.contains(token)
    }
}

enum RelaySidePanelWebSocket {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    struct Frame: Sendable {
        let final: Bool
        let opcode: UInt8
        let payload: Data
    }

    enum ParseResult: Sendable {
        case incomplete
        case invalid
        case frame(Frame)
    }

    static func acceptValue(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    static func serverFrame(opcode: UInt8, payload: Data = Data()) -> Data {
        var result = Data([0x80 | opcode])
        if payload.count < 126 {
            result.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            result.append(126)
            var length = UInt16(payload.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        } else {
            result.append(127)
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        }
        result.append(payload)
        return result
    }

    static func parseClientFrame(_ buffer: inout Data) -> ParseResult {
        guard buffer.count >= 2 else { return .incomplete }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.index(after: buffer.startIndex)]
        let final = first & 0x80 != 0
        let opcode = first & 0x0f
        guard first & 0x70 == 0,
              [0x0, 0x1, 0x2, 0x8, 0x9, 0xA].contains(opcode),
              second & 0x80 != 0 else { return .invalid }
        var offset = 2
        var length = Int(second & 0x7f)
        if length == 126 {
            guard buffer.count >= offset + 2 else { return .incomplete }
            length = Int(buffer[buffer.index(buffer.startIndex, offsetBy: offset)]) << 8 |
                Int(buffer[buffer.index(buffer.startIndex, offsetBy: offset + 1)])
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return .incomplete }
            var value: UInt64 = 0
            for index in 0..<8 {
                value = (value << 8) | UInt64(
                    buffer[buffer.index(buffer.startIndex, offsetBy: offset + index)]
                )
            }
            guard value <= UInt64(1 << 20) else { return .invalid }
            length = Int(value)
            offset += 8
        }
        guard length <= 1 << 20,
              buffer.count >= offset + 4 + length else { return .incomplete }
        if opcode >= 0x8, (!final || length > 125) { return .invalid }
        let mask = (0..<4).map { index in
            buffer[buffer.index(buffer.startIndex, offsetBy: offset + index)]
        }
        offset += 4
        var payload = Data(count: length)
        payload.withUnsafeMutableBytes { destination in
            guard let bytes = destination.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<length {
                bytes[index] = buffer[
                    buffer.index(buffer.startIndex, offsetBy: offset + index)
                ] ^ mask[index & 3]
            }
        }
        buffer.removeFirst(offset + length)
        return .frame(Frame(final: final, opcode: opcode, payload: payload))
    }
}

private final class RelaySidePanelTerminalSocket: @unchecked Sendable {
    typealias DataHandler = @Sendable (UUID, Data) -> Void
    typealias ResizeHandler = @Sendable (UUID, UInt16, UInt16) -> Void
    typealias LifecycleHandler = @Sendable (UUID) -> Void

    let id = UUID()
    private let connection: NWConnection
    private let onInput: DataHandler
    private let onResize: ResizeHandler
    private let onClaim: LifecycleHandler
    private let onRelease: LifecycleHandler
    private let onReady: LifecycleHandler
    private let onClose: LifecycleHandler
    private let lock = NSLock()
    private var receiveBuffer = Data()
    private var fragmentedOpcode: UInt8?
    private var fragmentedPayload = Data()
    private var pendingWire: [Data] = []
    private var pendingWireBytes = 0
    private var sending = false
    private var initialSent = false
    private var pendingTerminal = Data()
    private var closed = false

    init(
        connection: NWConnection,
        onInput: @escaping DataHandler,
        onResize: @escaping ResizeHandler,
        onClaim: @escaping LifecycleHandler,
        onRelease: @escaping LifecycleHandler,
        onReady: @escaping LifecycleHandler,
        onClose: @escaping LifecycleHandler
    ) {
        self.connection = connection
        self.onInput = onInput
        self.onResize = onResize
        self.onClaim = onClaim
        self.onRelease = onRelease
        self.onReady = onReady
        self.onClose = onClose
    }

    func start(handshake: Data) {
        connection.send(content: handshake, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.close(); return }
            self.onReady(self.id)
            self.receive()
        })
    }

    func enqueueTerminal(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if !initialSent {
            pendingTerminal.append(data)
            if pendingTerminal.count > 8 << 20 {
                closed = true
                lock.unlock()
                connection.cancel()
                onClose(id)
                return
            }
            lock.unlock()
            return
        }
        lock.unlock()
        enqueueWire(RelaySidePanelWebSocket.serverFrame(opcode: 0x2, payload: data))
    }

    func sendViewport(_ viewport: RelayViewport, ownsInput: Bool) {
        let message = "{\"type\":\"viewport\",\"columns\":\(viewport.columns)," +
            "\"rows\":\(viewport.rows),\"ownsInput\":\(ownsInput)}"
        enqueueWire(RelaySidePanelWebSocket.serverFrame(opcode: 0x1, payload: Data(message.utf8)))
    }

    func sendInitial(snapshot: Data, viewport: RelayViewport, ownsInput: Bool) {
        lock.lock()
        guard !closed, !initialSent else { lock.unlock(); return }
        initialSent = true
        let pending = pendingTerminal
        pendingTerminal = Data()
        lock.unlock()
        sendViewport(viewport, ownsInput: ownsInput)
        var reset = Data("\u{001B}c".utf8)
        reset.append(snapshot)
        enqueueWire(RelaySidePanelWebSocket.serverFrame(opcode: 0x2, payload: reset))
        if !pending.isEmpty {
            enqueueWire(RelaySidePanelWebSocket.serverFrame(opcode: 0x2, payload: pending))
        }
    }

    private func enqueueWire(_ data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        pendingWire.append(data)
        pendingWireBytes += data.count
        if pendingWireBytes > 8 << 20 {
            closed = true
            lock.unlock()
            connection.cancel()
            onClose(id)
            return
        }
        guard !sending else { lock.unlock(); return }
        sending = true
        let next = pendingWire.removeFirst()
        pendingWireBytes -= next.count
        lock.unlock()
        sendWire(next)
    }

    private func sendWire(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.close(); return }
            self.lock.lock()
            guard !self.closed else { self.lock.unlock(); return }
            guard !self.pendingWire.isEmpty else {
                self.sending = false
                self.lock.unlock()
                return
            }
            let next = self.pendingWire.removeFirst()
            self.pendingWireBytes -= next.count
            self.lock.unlock()
            self.sendWire(next)
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.receiveBuffer.append(data) }
            guard self.receiveBuffer.count <= 1 << 20 else { self.close(); return }
            while true {
                switch RelaySidePanelWebSocket.parseClientFrame(&self.receiveBuffer) {
                case .incomplete:
                    if isComplete || error != nil { self.close() } else { self.receive() }
                    return
                case .invalid:
                    self.close()
                    return
                case .frame(let frame):
                    guard self.consume(frame) else { self.close(); return }
                }
            }
        }
    }

    private func consume(_ frame: RelaySidePanelWebSocket.Frame) -> Bool {
        switch frame.opcode {
        case 0x0:
            guard fragmentedOpcode != nil else { return false }
            fragmentedPayload.append(frame.payload)
            guard fragmentedPayload.count <= 1 << 20 else { return false }
            if frame.final {
                let opcode = fragmentedOpcode!
                let payload = fragmentedPayload
                fragmentedOpcode = nil
                fragmentedPayload = Data()
                return consumeMessage(opcode: opcode, payload: payload)
            }
            return true
        case 0x1, 0x2:
            guard fragmentedOpcode == nil else { return false }
            if frame.final { return consumeMessage(opcode: frame.opcode, payload: frame.payload) }
            fragmentedOpcode = frame.opcode
            fragmentedPayload = frame.payload
            return true
        case 0x8:
            return false
        case 0x9:
            enqueueWire(RelaySidePanelWebSocket.serverFrame(opcode: 0xA, payload: frame.payload))
            return true
        case 0xA:
            return true
        default:
            return false
        }
    }

    private func consumeMessage(opcode: UInt8, payload: Data) -> Bool {
        guard opcode == 0x2, let kind = payload.first else { return false }
        switch kind {
        case 0x01:
            guard payload.count > 1 else { return true }
            onInput(id, Data(payload.dropFirst()))
        case 0x02:
            guard payload.count == 5 else { return false }
            let columns = UInt16(payload[1]) << 8 | UInt16(payload[2])
            let rows = UInt16(payload[3]) << 8 | UInt16(payload[4])
            onResize(id, columns, rows)
        case 0x03:
            onClaim(id)
        case 0x04:
            onRelease(id)
        default:
            return false
        }
        return true
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        connection.cancel()
        onClose(id)
    }
}

private struct RelaySidePanelPrompt: Decodable {
    let text: String
}

struct RelaySidePanelInputOwnership: Sendable {
    private var owners: [UUID: UUID] = [:]

    mutating func claim(socketID: UUID, paneID: UUID) {
        owners[paneID] = socketID
    }

    @discardableResult
    mutating func release(socketID: UUID, paneID: UUID) -> Bool {
        guard owners[paneID] == socketID else { return false }
        owners.removeValue(forKey: paneID)
        return true
    }

    func owns(socketID: UUID, paneID: UUID) -> Bool {
        owners[paneID] == socketID
    }
}

private struct RelaySidePanelHTTPResponse: Sendable {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data

    static func json(_ value: some Encodable, status: Int = 200, reason: String = "OK") -> Self {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return Self(status: status, reason: reason, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ value: String, status: Int, reason: String) -> Self {
        Self(
            status: status, reason: reason,
            contentType: "text/plain; charset=utf-8", body: Data(value.utf8)
        )
    }

    var wireData: Data {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "X-Content-Type-Options: nosniff\r\n"
        header += "Referrer-Policy: no-referrer\r\n"
        header += "Cross-Origin-Resource-Policy: same-origin\r\n"
        header += "Connection: close\r\n\r\n"
        var result = Data(header.utf8)
        result.append(body)
        return result
    }
}

/// A deliberately small companion surface for Codex's browser panel. It is
/// reachable only on IPv4 loopback and every state-changing or state-reading
/// API call requires a persistent random token. The token travels in the URL
/// fragment, which browsers never include in the initial HTTP request.
@MainActor
final class RelaySidePanelServer {
    static let port: NWEndpoint.Port = 47_471
    private static let tokenDefaultsKey = "relay.side-panel-token.v1"

    private weak var workspace: WorkspaceModel?
    private let token: String
    private let queue = DispatchQueue(label: "app.relay.side-panel", qos: .utility)
    private var listener: NWListener?
    private var terminalSockets: [UUID: RelaySidePanelTerminalSocket] = [:]
    private var terminalSocketPanes: [UUID: UUID] = [:]
    private var terminalMirrorIDs: [UUID: UUID] = [:]
    /// Every pane has one browser input/geometry owner. All other browser
    /// panels are read-only mirrors, so two Codex chats cannot race the PTY or
    /// continuously resize it to different grids.
    private var terminalInputOwnership = RelaySidePanelInputOwnership()
    private var terminalPaneViewports: [UUID: RelayViewport] = [:]
    private var applicationObservers: [NSObjectProtocol] = []
    private(set) var errorMessage: String?

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        self.token = Self.loadOrCreateToken()
        start()
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            applicationObservers.append(center.addObserver(
                forName: name, object: NSApp, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.broadcastAllTerminalViewports()
                    guard name == NSApplication.didBecomeActiveNotification else { return }
                    // Input ownership changes immediately when Relay becomes
                    // active, but the browser may have committed a different
                    // PTY grid while it was foreground. Reclaim every visible
                    // native pane after AppKit has installed the active
                    // workspace layout; otherwise the browser width survives
                    // until a divider happens to move.
                    await Task.yield()
                    self.workspace?.applicationPresentationChanged(visible: true)
                }
            })
        }
    }

    deinit {
        for observer in applicationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    var accessURL: URL {
        URL(string: "http://127.0.0.1:\(Self.port.rawValue)/#\(token)")!
    }

    func copyAccessLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accessURL.absoluteString, forType: .string)
    }

    private static func loadOrCreateToken() -> String {
        if let existing = UserDefaults.standard.string(forKey: tokenDefaultsKey),
           existing.count >= 64 { return existing }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") +
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(token, forKey: tokenDefaultsKey)
        return token
    }

    private func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(IPv4Address.loopback), port: Self.port
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.errorMessage = nil
                        RelayDiagnostics.shared.record(
                            category: "side-panel", name: "ready",
                            details: ["endpoint": "loopback"]
                        )
                    case .failed(let error):
                        self.errorMessage = error.localizedDescription
                        RelayDiagnostics.shared.record(
                            category: "side-panel", name: "listener-failed",
                            details: ["error": error.localizedDescription]
                        )
                    default: break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                switch RelaySidePanelHTTPRequest.parse(buffer) {
                case .request(let request):
                    if request.path.hasSuffix("/terminal"),
                       request.headers["upgrade"]?.lowercased() == "websocket" {
                        self.upgradeTerminal(request, on: connection)
                    } else {
                        self.respond(await self.route(request), on: connection)
                    }
                case .invalid:
                    self.respond(.text("Bad request", status: 400, reason: "Bad Request"), on: connection)
                case .incomplete:
                    if error != nil || isComplete || buffer.count >= 64 << 10 {
                        self.respond(.text("Bad request", status: 400, reason: "Bad Request"), on: connection)
                    } else {
                        self.receive(connection, accumulated: buffer)
                    }
                }
            }
        }
    }

    private func respond(_ response: RelaySidePanelHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.wireData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func upgradeTerminal(
        _ request: RelaySidePanelHTTPRequest,
        on connection: NWConnection
    ) {
        guard request.method == "GET", request.isAuthorizedWebSocket(token: token),
              let key = request.headers["sec-websocket-key"],
              request.headers["sec-websocket-version"] == "13",
              let workspace else {
            respond(.text("Unauthorized", status: 401, reason: "Unauthorized"), on: connection)
            return
        }
        let parts = request.path.split(separator: "/")
        guard parts.count == 4, parts[0] == "api", parts[1] == "panes",
              parts[3] == "terminal", let paneID = UUID(uuidString: String(parts[2])),
              let pane = workspace.panes[paneID], pane.contentKind == .terminal,
              pane.profile.kind == .ssh, pane.profile.backend == .relay else {
            respond(.text("Pane unavailable", status: 409, reason: "Conflict"), on: connection)
            return
        }

        let socket = RelaySidePanelTerminalSocket(
            connection: connection,
            onInput: { [weak self] socketID, data in
                Task { @MainActor [weak self] in
                    // Only the foreground application may own keyboard input.
                    // When Relay itself is active, the browser mirror remains
                    // readable but cannot become a second PTY writer.
                    guard let self, !NSApp.isActive,
                          self.terminalInputOwnership.owns(socketID: socketID, paneID: paneID),
                          let pane = self.workspace?.panes[paneID] else { return }
                    _ = pane.runtime.sendSidePanelTerminalInput(data)
                }
            },
            onResize: { [weak self] socketID, columns, rows in
                Task { @MainActor [weak self] in
                    guard let self, !NSApp.isActive,
                          self.terminalInputOwnership.owns(socketID: socketID, paneID: paneID),
                          let pane = self.workspace?.panes[paneID] else { return }
                    guard pane.runtime.resizeForSidePanel(columns: columns, rows: rows) else { return }
                    self.terminalViewportDidChange(
                        RelayViewport(columns: columns, rows: rows), paneID: paneID
                    )
                }
            },
            onClaim: { [weak self] socketID in
                Task { @MainActor [weak self] in
                    self?.claimTerminalInput(socketID: socketID, paneID: paneID)
                }
            },
            onRelease: { [weak self] socketID in
                Task { @MainActor [weak self] in
                    self?.releaseTerminalInput(socketID: socketID, paneID: paneID)
                }
            },
            onReady: { [weak self] socketID in
                Task { @MainActor [weak self] in
                    guard let self,
                          let socket = self.terminalSockets[socketID],
                          let pane = self.workspace?.panes[paneID] else { return }
                    let mirrorID = pane.runtime.beginSidePanelTerminalMirror(
                        deliver: { [weak socket] data in socket?.enqueueTerminal(data) },
                        viewportChanged: { [weak self] viewport in
                            Task { @MainActor [weak self] in
                                self?.terminalViewportDidChange(viewport, paneID: paneID)
                            }
                        },
                        ready: { [weak self, weak socket] snapshot, viewport in
                            Task { @MainActor [weak self, weak socket] in
                                guard let self, let socket else { return }
                                self.terminalPaneViewports[paneID] = viewport
                                socket.sendInitial(
                                    snapshot: snapshot,
                                    viewport: viewport,
                                    ownsInput: self.browserOwnsInput(socket.id, paneID: paneID)
                                )
                            }
                        }
                    )
                    guard let mirrorID else { socket.close(); return }
                    self.terminalMirrorIDs[socketID] = mirrorID
                }
            },
            onClose: { [weak self] socketID in
                Task { @MainActor [weak self] in
                    self?.closeTerminalSocket(socketID)
                }
            }
        )
        terminalSockets[socket.id] = socket
        terminalSocketPanes[socket.id] = paneID
        let accept = RelaySidePanelWebSocket.acceptValue(for: key)
        let handshake = "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n" +
            "Sec-WebSocket-Protocol: relay-v1\r\n\r\n"
        socket.start(handshake: Data(handshake.utf8))
    }

    private func browserOwnsInput(_ socketID: UUID, paneID: UUID) -> Bool {
        !NSApp.isActive && terminalInputOwnership.owns(socketID: socketID, paneID: paneID)
    }

    private func claimTerminalInput(socketID: UUID, paneID: UUID) {
        guard terminalSockets[socketID] != nil,
              terminalSocketPanes[socketID] == paneID else { return }
        terminalInputOwnership.claim(socketID: socketID, paneID: paneID)
        broadcastTerminalViewport(paneID: paneID)
    }

    private func releaseTerminalInput(socketID: UUID, paneID: UUID) {
        guard terminalInputOwnership.release(socketID: socketID, paneID: paneID) else { return }
        broadcastTerminalViewport(paneID: paneID)
    }

    private func terminalViewportDidChange(_ viewport: RelayViewport, paneID: UUID) {
        guard terminalPaneViewports[paneID] != viewport else { return }
        terminalPaneViewports[paneID] = viewport
        broadcastTerminalViewport(paneID: paneID)
    }

    private func broadcastTerminalViewport(paneID: UUID) {
        guard let viewport = terminalPaneViewports[paneID] else { return }
        for (socketID, socketPaneID) in terminalSocketPanes where socketPaneID == paneID {
            terminalSockets[socketID]?.sendViewport(
                viewport,
                ownsInput: browserOwnsInput(socketID, paneID: paneID)
            )
        }
    }

    private func broadcastAllTerminalViewports() {
        for paneID in Set(terminalSocketPanes.values) {
            broadcastTerminalViewport(paneID: paneID)
        }
    }

    private func closeTerminalSocket(_ socketID: UUID) {
        terminalSockets.removeValue(forKey: socketID)
        let paneID = terminalSocketPanes.removeValue(forKey: socketID)
        let mirrorID = terminalMirrorIDs.removeValue(forKey: socketID)
        if let paneID, terminalInputOwnership.release(socketID: socketID, paneID: paneID) {
            broadcastTerminalViewport(paneID: paneID)
        }
        if let paneID, let mirrorID, let pane = workspace?.panes[paneID] {
            pane.runtime.endSidePanelTerminalMirror(mirrorID)
        }
        if let paneID, !terminalSocketPanes.values.contains(paneID) {
            terminalPaneViewports.removeValue(forKey: paneID)
        }
    }

    private func route(_ request: RelaySidePanelHTTPRequest) async -> RelaySidePanelHTTPResponse {
        if request.method == "GET", request.path == "/" {
            guard let url = Bundle.module.url(
                forResource: "index", withExtension: "html", subdirectory: "SidePanel"
            ), let data = try? Data(contentsOf: url) else {
                return .text("Relay panel unavailable", status: 500, reason: "Internal Server Error")
            }
            return RelaySidePanelHTTPResponse(
                status: 200, reason: "OK", contentType: "text/html; charset=utf-8", body: data
            )
        }

        if request.method == "GET" {
            let asset: (name: String, extension: String, type: String)? = switch request.path {
            case "/xterm/xterm.js": ("xterm", "js", "text/javascript; charset=utf-8")
            case "/xterm/xterm.css": ("xterm", "css", "text/css; charset=utf-8")
            case "/xterm/addon-fit.js": ("addon-fit", "js", "text/javascript; charset=utf-8")
            case "/xterm/addon-image.js": ("addon-image", "js", "text/javascript; charset=utf-8")
            default: nil
            }
            if let asset,
               let url = Bundle.module.url(
                   forResource: asset.name, withExtension: asset.extension,
                   subdirectory: "SidePanel/xterm"
               ), let data = try? Data(contentsOf: url) {
                return RelaySidePanelHTTPResponse(
                    status: 200, reason: "OK", contentType: asset.type, body: data
                )
            }
        }

        guard request.path.hasPrefix("/api/"), request.isAuthorized(token: token) else {
            return .text("Unauthorized", status: 401, reason: "Unauthorized")
        }
        guard let workspace else {
            return .text("Relay is shutting down", status: 503, reason: "Service Unavailable")
        }
        if request.method == "GET", request.path == "/api/state" {
            // Workspace state is MainActor-owned, but encoding a large agent
            // tree is pure CPU work. Keep it away from terminal input/render
            // dispatch so a busy Codex companion cannot make typing stutter.
            let state = workspace.sidePanelState()
            return await Task.detached(priority: .utility) {
                RelaySidePanelHTTPResponse.json(state)
            }.value
        }

        let parts = request.path.split(separator: "/")
        guard parts.count >= 3, parts.count <= 4,
              parts[0] == "api", parts[1] == "panes",
              let paneID = UUID(uuidString: String(parts[2])) else {
            return .text("Not found", status: 404, reason: "Not Found")
        }
        if request.method == "GET", parts.count == 3 {
            guard let detail = workspace.sidePanelDetail(for: paneID) else {
                return .text("Pane not found", status: 404, reason: "Not Found")
            }
            return await Task.detached(priority: .utility) {
                RelaySidePanelHTTPResponse.json(detail)
            }.value
        }
        guard parts.count == 4 else {
            return .text("Not found", status: 404, reason: "Not Found")
        }
        switch (request.method, String(parts[3])) {
        case ("POST", "reveal"):
            guard workspace.sidePanelReveal(paneID) else {
                return .text("Pane not found", status: 404, reason: "Not Found")
            }
            return .json(["ok": true])
        case ("POST", "prompt"):
            guard let prompt = try? JSONDecoder().decode(RelaySidePanelPrompt.self, from: request.body),
                  !prompt.text.isEmpty, prompt.text.utf8.count <= 16 << 10 else {
                return .text("Invalid prompt", status: 400, reason: "Bad Request")
            }
            guard workspace.sidePanelSendPrompt(prompt.text, to: paneID) else {
                return .text("Pane unavailable", status: 409, reason: "Conflict")
            }
            return .json(["ok": true])
        default:
            return .text("Not found", status: 404, reason: "Not Found")
        }
    }
}
