@preconcurrency import Network
import AppKit
import Combine
import CryptoKit
import Foundation

enum RelaySidePanelAuth {
    /// Length-independent, byte-wise comparison so an attacker on loopback
    /// cannot recover the bearer token one character at a time from timing.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= Int(x ^ y)
        }
        return difference == 0
    }
}

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
        /// The navigator workspace that owns this tab; absent when unknown.
        let workspaceID: String?
        /// Broadcast scopes ("tab", "workspace") the user allowed here.
        let broadcast: [String]
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
        var backend: String? = nil
        var closeBehavior: String? = nil
        /// The agent's provider account label; never a directory or credential.
        var account: String? = nil
        var accountMismatch: Bool? = nil
        /// Display only: the label with the observed config directory
        /// ("personal · default (~/.claude)"), or the directory alone while the
        /// label is unknown. Not an account label; moves reject it.
        var accountDisplay: String? = nil
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
    var plans: [AgentTaskPlan] = []
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
        guard data.count <= ((6 << 20) + 65_536) else { return .invalid }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return data.count > 65_536 ? .invalid : .incomplete }
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
        guard headerRange.lowerBound <= 65_536 else { return .invalid }
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        let bodyLimit: Int
        if requestParts[0] == "POST" && requestParts[1] == "/api/workspace/host-request" {
            // The workspace protocol permits a 4 MiB binary upload chunk.
            // Base64 expands it to 5.34 MiB before JSON framing.
            bodyLimit = 6 << 20
        } else if requestParts[0] == "POST" && requestParts[1] == "/api/surfaces/publish" {
            bodyLimit = 1_048_576
        } else {
            bodyLimit = 192 << 10
        }
        guard contentLength >= 0, contentLength <= bodyLimit else { return .invalid }
        let bodyStart = headerRange.upperBound
        guard data.count <= bodyStart + bodyLimit else { return .invalid }
        guard data.count >= bodyStart + contentLength else { return .incomplete }
        return .request(RelaySidePanelHTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: String(requestParts[1]),
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + contentLength)])
        ))
    }

    func isAuthorized(token: String) -> Bool {
        guard let presented = headers["x-relay-token"] else { return false }
        return RelaySidePanelAuth.constantTimeEquals(presented, token)
    }

    func isAuthorizedWebSocket(token: String,
                               expectedOrigin: String = "http://127.0.0.1:47471") -> Bool {
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().contains("upgrade") == true,
              headers["origin"] == expectedOrigin else { return false }
        let protocols = headers["sec-websocket-protocol"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        guard protocols.contains("relay-v1") else { return false }
        // Constant-time to avoid leaking the token through comparison timing.
        return protocols.contains { RelaySidePanelAuth.constantTimeEquals($0, token) }
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
    let requestID: UUID?
    let instance: UUID?
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

struct RelaySidePanelHTTPResponse: Sendable {
    static func jsonObject(_ value: [String: Any]) throws -> Self {
        Self(status: 200, reason: "OK", contentType: "application/json; charset=utf-8",
             body: try JSONSerialization.data(withJSONObject: value))
    }
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

    static func desktopDiscoveryFailure(_ error: Error) -> Self {
        .text(DesktopPeerRoute.discoveryMessage(error), status: 503, reason: "Service Unavailable")
    }

    /// The standard reason phrase for each status Relay sends.
    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: status < 400 ? "OK" : status < 500 ? "Bad Request" : "Internal Server Error"
        }
    }

    /// A channel handler's JSON reply under its own status and reason phrase.
    static func channelReply(status: Int, value: [String: Any]) throws -> Self {
        let response = try jsonObject(value)
        return Self(status: status, reason: reasonPhrase(for: status), contentType: response.contentType, body: response.body)
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
final class RelaySidePanelServer: ObservableObject {
    static let port: NWEndpoint.Port = {
        NWEndpoint.Port(rawValue: RelayStateProfile.sidePanelPort) ?? 47_471
    }()
    static var origin: String { "http://127.0.0.1:\(port.rawValue)" }
    private static let tokenDefaultsKey = "relay.side-panel-token.v1"
    /// The host operations a tool caller may send through the host and
    /// workspace request routes. Account management (agent_accounts) is not
    /// among them: only Relay's native Settings sends it.
    nonisolated static let toolHostOperations: Set<String> = ["exec", "status", "input", "cancel", "plugin", "capabilities",
        "file_stat", "file_list", "file_read", "file_write", "file_verify", "process_list", "process_signal"]
    nonisolated static var toolHostOperationList: String { toolHostOperations.sorted().joined(separator: ", ") }

    private weak var workspace: WorkspaceModel?
    private let agentInputRequests = AgentInputRequests()
    private let rAutomation = RAutomationController.shared
    private let peerNetworkApprovals = PeerNetworkApproval()
    private let desktopRouteApprovals = DesktopRouteApproval()
    private let settingsControl = RelaySettingsControl()
    private let callerControl = RelayCallerControl.shared
    private lazy var mikoSupervisorChannel = RelayMikoSupervisorChannel(
        inputGranted: { [unowned self] in self.mcpWorkspaceGrant.permits(.input) },
        instance: { [unowned self] in self.agentInputRequests.instance })
    private let desktopRouteDirect = DesktopRouteDirectControl()
    /// Cross-host pane links proposed by remote panes: attested, confirmed natively, never
    /// gated by (or widening) the installation-wide layout grant.
    private lazy var paneLinkProposals = RelayPaneLinkProposals(
        confirmer: RelayPaneLinkAlertConfirmer(),
        lookup: { [unowned self] id in RelayPaneLinkPane(self.workspace?.panes[id]) },
        connect: { [unowned self] source, target, commitGuard in
            guard let workspace = self.workspace else { throw RemoteCatalogError.failed("Relay window closed.") }
            _ = try await self.paneMessaging.connect(panes: [source, target], workspace: workspace, commitGuard: commitGuard)
        },
        policyPermits: { [unowned self] caller in self.callerControl.permitted(caller) })
    private let localPaneApprovals = LocalPaneApproval()
    private let remoteInstall = RelayRemoteInstallControl()
    private lazy var relaydUpdates = RelaydHostUpdateService(dependencies: .live(resolve: { [weak self] in self?.recoveryProfile(host: $0) }))
    private let workspaceControl = WorkspaceControl()
    private let mcpWorkspaceGrant = MCPWorkspaceGrant.shared
    private let workspaceApply = WorkspaceApplyAdmission()
    private let directTabRequests = MCPDirectTabRequests()
    private let directRecoveryReceipts = RelayPaneRecoveryReceipts()
    #if DEBUG
    var recoveryFixtureGrant: MCPWorkspaceGrant?
    var recoveryFixtureLoad: (@MainActor (ConnectionProfile) async throws -> RemoteCatalogSnapshot)?
    var recoveryFixtureAttach: (@MainActor (WorkspaceModel, ConnectionProfile, RemoteCatalogPane, String) -> Bool)?
    var recoveryFixtureReady: (@MainActor (Bool) -> Void)?
    #endif
    private var accountMoveReceipts = RelayAccountMoveReceipts()
    private var terminalEditReceipts = RelayTerminalEditReceipts()
    private var directConversationResumeRequests: [UUID: MCPRecoverPaneRequest] = [:]
    private var directConversationResumeResults: [UUID: [String: String]] = [:]
    private var directTerminationRequests: [UUID: MCPTerminatePaneRequest] = [:]
    private var directTerminationResults: [UUID: [String: String]] = [:]
    private var directInputRequests: [UUID: (UUID, AgentInputProposal)] = [:]
    private var contextRotationRequests: [UUID: (UUID, RelayContextRotationRequest)] = [:]
    private var contextRotationResults: [UUID: [String: String]] = [:]
    private var installedUpdateReceipts = RelayInstalledUpdateReceipts()
    private var capacityActionReceipts = RelayCapacityActionReceipts()
    private var shellRecoveryRequests: [UUID: (UUID, RelayShellRecoveryInput)] = [:]
    private var shellRecoveryResults: [UUID: [String: String]] = [:]
    private let paneMessaging = RelayPaneMessaging.shared
    private lazy var questionNoticeDelivery = RelayQuestionNoticeDelivery(workspace: workspace)
    private lazy var desktopLinkWatch = DesktopLinkWatch(workspace: workspace)
    private lazy var workCarrier = RelayWorkCarrierLoop(workspace: workspace)
    private var directInputResults: [UUID: [String: String]] = [:]
    // MainActor admission gate: an MCP client must not fan out helper processes.
    private var peerDiscoveryInFlight = false
    private struct AccountMCPReview {
        let paneID: UUID
        let connectionKey: String
        let account: RelayAgentAccount
        let preview: RelayAgentAccountMCPPreview
        let expires: Date
    }
    private var accountMCPReviews: [String: AccountMCPReview] = [:]
    private var accountMCPSyncRequests: [UUID: MCPAccountSyncRequest] = [:]
    private var accountMCPSyncResults: [UUID: [String: String]] = [:]
    private var accountMCPSyncPending = false
    private let accountMCPJournal = RelayPrivateOperationJournal(url: RelayStateProfile.applicationSupportRoot
        .appendingPathComponent("Relay/MCPAccountOperations/receipts.json"))

    private func accountMCPOwner(_ input: MCPAccountSyncRequest, caller: String?, profile: ConnectionProfile) -> String {
        RelayPrivateOperationJournal.digest([caller ?? "legacy-unattributed", profile.connectionKey,
            input.paneID.uuidString, input.account])
    }
    private func accountMCPRequestDigest(_ input: MCPAccountSyncRequest) -> String {
        // Exclude process-instance token so a new instance can query an old ID.
        RelayPrivateOperationJournal.digest([input.paneID.uuidString, input.account, input.reviewToken])
    }
    @discardableResult private func recordAccountMCP(_ id: UUID, _ result: [String: String]) -> Bool {
        do {
            try accountMCPJournal.finish(id, status: result["status"] ?? "outcome_unknown")
            accountMCPSyncResults[id] = result
            return true
        } catch {
            accountMCPSyncResults[id] = ["status": "outcome_unknown"]
            return false
        }
    }
    private let privateSecretApproval = RelayPrivateSecretApproval()
    private let token: String
    private let queue = DispatchQueue(label: "app.relay.side-panel", qos: .utility)
    private var listener: NWListener?
    private var mcpHTTPProcess: Process?
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

    /// Routes Miko's executor may never reach, whatever its grants.
    nonisolated static func assistantMayRequest(_ path: String) -> Bool {
        path != "/api/agent-accounts/move"
    }

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        self.token = Self.loadOrCreateToken()
        workspace.assistantActionExecutor = self
        if let error = RelayStateProfile.configurationError {
            errorMessage = error
            return
        }
        start()
        questionNoticeDelivery.start()
        desktopLinkWatch.start()
        workCarrier.start()
        Task { @MainActor [weak self] in
            guard let self else { return }
            var seen: Set<String> = []
            for profile in workspace.panes.values.map(\.profile) where profile.backend == .relay && seen.insert(profile.connectionKey).inserted {
                try? await self.callerControl.attachDaemon(profile: profile)
            }
        }
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
        applicationObservers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopMCPHTTPService() }
        })
    }

    #if DEBUG
    init(recoveryFixture workspace: WorkspaceModel) {
        self.workspace = workspace
        self.token = Self.loadOrCreateToken()
        workspace.assistantActionExecutor = self
    }
    #endif

    deinit {
        for observer in applicationObservers { NotificationCenter.default.removeObserver(observer) }
        if let mcpHTTPProcess, mcpHTTPProcess.isRunning { mcpHTTPProcess.terminate() }
    }

    var accessURL: URL {
        URL(string: "http://127.0.0.1:\(Self.port.rawValue)/#\(token)")!
    }

    func copyAccessLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accessURL.absoluteString, forType: .string)
    }

    static func existingToolsToken() -> String? {
        guard let value = RelayStateProfile.defaults.string(forKey: tokenDefaultsKey), value.utf8.count >= 64 else { return nil }
        return value
    }
    private static func loadOrCreateToken() -> String {
        if let existing = RelayStateProfile.defaults.string(forKey: tokenDefaultsKey),
           existing.count >= 64 { return existing }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") +
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        RelayStateProfile.defaults.set(token, forKey: tokenDefaultsKey)
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
                        #if DEBUG
                        self.recoveryFixtureReady?(true)
                        #endif
                        RelayDiagnostics.shared.record(
                            category: "side-panel", name: "ready",
                            details: ["endpoint": "loopback"]
                        )
                        self.startMCPHTTPService()
                    case .failed(let error):
                        self.errorMessage = error.localizedDescription
                        #if DEBUG
                        self.recoveryFixtureReady?(false)
                        #endif
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

    #if DEBUG
    func startRecoveryFixture() { start() }
    func stopRecoveryFixture() { listener?.cancel(); listener = nil }
    #endif

    private func recoveryGrant() -> MCPWorkspaceGrant {
        #if DEBUG
        if let grant = recoveryFixtureGrant { return grant }
        #endif
        return mcpWorkspaceGrant
    }

    private func recoveryLoad(_ profile: ConnectionProfile) async throws -> RemoteCatalogSnapshot {
        #if DEBUG
        if let load = recoveryFixtureLoad { return try await load(profile) }
        #endif
        return try await RemoteCatalogService.load(profile: profile)
    }

    private func recoveryAttach(_ workspace: WorkspaceModel, profile: ConnectionProfile,
                                pane: RemoteCatalogPane, label: String) -> Bool {
        #if DEBUG
        if let attach = recoveryFixtureAttach { return attach(workspace, profile, pane, label) }
        #endif
        return RelayPaneRecoveryAttachment.attach(workspace: workspace, profile: profile, pane: pane, sessionLabel: label)
    }

    private func startMCPHTTPService() {
        // An isolated renderer fixture must not occupy the original clients'
        // production MCP port or load their production credential store.
        guard !RelayStateProfile.isIsolated else { return }
        guard mcpHTTPProcess == nil,
              let appExecutable = Bundle.main.executableURL else { return }
        let adapter = appExecutable.deletingLastPathComponent().appendingPathComponent("relay-mcp")
        guard FileManager.default.isExecutableFile(atPath: adapter.path) else {
            RelayDiagnostics.shared.record(
                category: "mcp-http", name: "adapter-missing",
                details: ["path": adapter.path]
            )
            return
        }
        let process = Process()
        process.executableURL = adapter
        process.arguments = ["--use-relay-token", "--http"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["RELAY_MCP_HTTP_PORT": "47472",
             "RELAY_MCP_OWNER_PID": String(ProcessInfo.processInfo.processIdentifier)],
            uniquingKeysWith: { _, new in new }
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            mcpHTTPProcess = process
            RelayDiagnostics.shared.record(
                category: "mcp-http", name: "starting",
                details: ["endpoint": "http://127.0.0.1:47472/mcp"]
            )
        } catch {
            RelayDiagnostics.shared.record(
                category: "mcp-http", name: "start-failed",
                details: ["error": error.localizedDescription]
            )
        }
    }

    private func stopMCPHTTPService() {
        guard let process = mcpHTTPProcess else { return }
        mcpHTTPProcess = nil
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
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
                    if error != nil || isComplete {
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
        guard request.method == "GET",
              request.isAuthorizedWebSocket(token: token, expectedOrigin: Self.origin),
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

    private func recoveryProfile(host: String) -> ConnectionProfile? {
        guard !host.isEmpty, host == host.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if host == "This Mac" { return .local }
        guard let workspace else { return nil }
        workspace.profileStore.refreshSSHConfig()
        let matches = workspace.profileStore.connectableHosts.filter {
            $0.host == host && $0.kind == .ssh && $0.backend == .relay
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// `assistantIdentity` is set only by the in-process Relay assistant entry
    /// below; network requests can never select it.
    private func route(_ request: RelaySidePanelHTTPRequest,
                       assistantIdentity: Bool = false, assistantActionApproved: Bool = false) async -> RelaySidePanelHTTPResponse {
        guard request.path.hasPrefix("/api/"), callerControl.authorizes(request, installationToken: token) else {
            return await dispatch(request)
        }
        if request.path == "/api/callers", request.method == "GET" {
            return .json(callerControl.listing())
        }
        if request.path == "/api/callers/audit", request.method == "GET" {
            return .json(callerControl.audit())
        }
        // Caller registration and pause/unpause are app-UI actions behind a
        // hardware click (RelayCallerManagementView). No token or grant opens
        // them over HTTP, and the assistant identity has no side door.
        if RelayCallerControl.isAdministrativePath(request.path) {
            return .text("Register or control callers in the Relay app", status: 403, reason: "Forbidden")
        }
        if let response = RelaySurfaceHTTP.handle(request, installationToken: token,
            callerControl: callerControl, publication: .shared,
            layoutGranted: mcpWorkspaceGrant.permits(.layout), assistantIdentity: assistantIdentity,
            resolvePane: { id in self.workspace?.panes[id].map { ($0.id, $0.profile.id) } },
            refreshPane: { id in if let pane = self.workspace?.panes[id] { RelaySurfacePublication.shared.restore(pane) } }) {
            return response
        }
        // GET and structured status remain available when mutations are paused.
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let readOperation = body?["operation"] as? String
        let isRead = request.method == "GET" || (request.path == "/api/host/request" &&
            ["status", "capabilities", "file_stat", "file_list", "file_read", "file_verify", "process_list"].contains(readOperation ?? ""))
        if isRead { return await dispatch(request) }
        let identity: String
        if assistantIdentity {
            identity = RelayCallerControl.assistantCaller
        } else {
            do { identity = try callerControl.identity(token: request.headers["x-relay-caller-token"]) }
            catch { return .text("Unknown caller or unavailable audit store", status: 403, reason: "Forbidden") }
        }
        guard callerControl.permitted(identity) else {
            try? callerControl.record(caller: identity, request: request, outcome: "blocked")
            return .text("This Relay caller is paused", status: 403, reason: "Forbidden")
        }
        do { try callerControl.record(caller: identity, request: request, outcome: "admitted") }
        catch { return .text("Audit could not be persisted; operation not dispatched", status: 503, reason: "Service Unavailable") }
        // An account move is user-initiated only: the assistant's executor
        // enters here with its own identity and is refused before dispatch.
        let response = assistantIdentity && !assistantActionApproved && !Self.assistantMayRequest(request.path)
            ? .text("Moving a pane to another account is user-initiated only", status: 403, reason: "Forbidden")
            : await dispatch(request, caller: identity)
        do { try callerControl.record(caller: identity, request: request, outcome: "http-\(response.status)", responseData: response.body) }
        catch { return .text("Operation outcome unresolved: completion audit failed; do not replay", status: 503, reason: "Service Unavailable") }
        return response
    }

    static func paneLinkProposalResponse(status: Int, value: [String: Any]) -> RelaySidePanelHTTPResponse {
        guard let response = try? RelaySidePanelHTTPResponse.jsonObject(value) else {
            return .text("Pane-link proposal reply could not be encoded", status: 500, reason: "Internal Server Error")
        }
        switch status {
        case 200: return response
        case 202: return RelaySidePanelHTTPResponse(status: 202, reason: "Accepted", contentType: response.contentType, body: response.body)
        default: return RelaySidePanelHTTPResponse(status: status, reason: status == 403 ? "Forbidden" : "Conflict",
                                                   contentType: response.contentType, body: response.body)
        }
    }

    /// `caller` is the audited identity of a mutating request.
    private func dispatch(_ request: RelaySidePanelHTTPRequest, caller: String? = nil) async -> RelaySidePanelHTTPResponse {
        if request.path == RelayPaneLinkProposals.path {
            // POST only, after caller identity, pause and admission audit. Never the plain
            // /api/pane-links route, which stays layout-gated and local.
            guard request.method == "POST", let caller else {
                return .text("Pane-link proposals are POST only", status: 405, reason: "Method Not Allowed")
            }
            let (status, value) = await paneLinkProposals.handle(body: request.body, caller: caller)
            guard let response = try? RelaySidePanelHTTPResponse.channelReply(status: status, value: value) else {
                return .text("Pane-link proposal reply could not be encoded", status: 500, reason: "Internal Server Error")
            }
            return response
        }
        if request.path == RelayMikoSupervisorChannel.path {
            // POST only, after caller identity, pause and admission audit.
            guard request.method == "POST", let caller else {
                return .text("Miko supervisor calls are POST only", status: 405, reason: "Method Not Allowed")
            }
            let (status, value) = await mikoSupervisorChannel.handle(body: request.body, caller: caller, workspace: workspace)
            guard let response = try? RelaySidePanelHTTPResponse.channelReply(status: status, value: value) else {
                return .text("Miko supervisor reply could not be encoded", status: 500, reason: "Internal Server Error")
            }
            return response
        }
        if request.method == "GET", request.path == "/" {
            guard let url = RelayResources.bundle?.url(
                forResource: "index", withExtension: "html", subdirectory: "SidePanel"
            ), let template = try? String(contentsOf: url, encoding: .utf8) else {
                return .text("Relay panel unavailable", status: 500, reason: "Internal Server Error")
            }
            let data = Data(template.replacingOccurrences(
                of: "__RELAY_SIDE_PANEL_PORT__", with: String(Self.port.rawValue)
            ).utf8)
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
               let url = RelayResources.bundle?.url(
                   forResource: asset.name, withExtension: asset.extension,
                   subdirectory: "SidePanel/xterm"
               ), let data = try? Data(contentsOf: url) {
                return RelaySidePanelHTTPResponse(
                    status: 200, reason: "OK", contentType: asset.type, body: data
                )
            }
        }

        guard request.path.hasPrefix("/api/"), callerControl.authorizes(request, installationToken: token) else {
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

        if request.method == "GET", request.path == "/api/hosts" {
            workspace.profileStore.refreshSSHConfig()
            let registry = RelayHostRegistry.shared
            workspace.profileStore.connectableHosts
                .filter { $0.kind == .ssh && $0.backend == .relay }
                .forEach { registry.register($0, origin: "Configured host") }
            registry.register(.local, origin: "Local Relay")
            return .json(registry.records.values.sorted { $0.id < $1.id })
        }
        if request.method == "POST", request.path == "/api/hosts/check" {
            guard mcpWorkspaceGrant.permits(.layout) else {
                return .text("MCP workspace configuration is not granted", status: 403, reason: "Forbidden")
            }
            guard request.body.count <= 4096,
                  let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  body.count == 1, let host = body["host"] as? String, host.utf8.count <= 256,
                  let profile = recoveryProfile(host: host), profile.kind == .ssh else {
                return .text("An exact configured SSH host is required", status: 400, reason: "Bad Request")
            }
            guard let report = await RelaydManager.shared.checkForRequest(profile) else {
                return .text("A host check or installation is already running", status: 409, reason: "Conflict")
            }
            return .json(report)
        }
        if request.method == "GET", request.path == "/api/intelligence/status" {
            return .json(await DesktopRouteRecoveryPlanner.shared.status())
        }
        if request.method == "POST", request.path == "/api/intelligence/check" {
            guard mcpWorkspaceGrant.permits(.layout), RelayPreferences.shared.intelligenceEnabled else {
                return .text("Enable Relay intelligence and grant workspace configuration before this check", status: 403, reason: "Forbidden")
            }
            return .json(await DesktopRouteRecoveryPlanner.shared.check())
        }
        if request.method == "GET", request.path == "/api/settings" {
            do { return .json(try settingsControl.snapshot(instance: agentInputRequests.instance)) }
            catch { return .text("Could not read settings", status: 500, reason: "Internal Server Error") }
        }
        if request.method == "POST", request.path == "/api/settings" {
            guard mcpWorkspaceGrant.permits(.layout) else {
                return .text("MCP workspace configuration is not granted", status: 403, reason: "Forbidden")
            }
            guard request.body.count <= 32768,
                  let proposal = try? JSONDecoder().decode(RelaySettingsProposal.self, from: request.body),
                  proposal.instance == agentInputRequests.instance else {
                return .text("Invalid or stale settings request", status: 400, reason: "Bad Request")
            }
            guard RelaySettingsPolicy.allows(changes: proposal.changes, assistantIdentity: caller == RelayCallerControl.assistantCaller) else {
                return .text("Miko cannot change its own policy or monitoring configuration; use the user CLI or Settings", status: 403, reason: "Forbidden")
            }
            do { return .json(try settingsControl.apply(proposal)) }
            catch RelaySettingsPolicy.ControlError.conflict {
                return .text("Settings changed or request ID conflicts", status: 409, reason: "Conflict")
            } catch {
                return .text(error.localizedDescription, status: 400, reason: "Bad Request")
            }
        }
        if request.method == "GET", request.path == "/api/control" {
            return .json(["instance": agentInputRequests.instance.uuidString.lowercased(), "policy": "installation_scoped_terminal_workspace_grant; other_domains_retain_existing_approval", "grantStatus": mcpWorkspaceGrant.status, "grantedCapabilities": mcpWorkspaceGrant.allowed.map(\.rawValue).sorted().joined(separator: ","), "workspaceActions": WorkspaceAction.allCases.map(\.rawValue).joined(separator: ",")])
        }
        if request.method == "GET", request.path == "/api/workspace/connection-targets" {
            workspace.profileStore.refreshSSHConfig()
            let remote = workspace.profileStore.connectableHosts
                .filter { $0.backend == .relay }
                .map { ["host": $0.host, "name": $0.name, "kind": "ssh"] }
            return (try? .jsonObject(["targets": [["host": "This Mac", "name": "Local shell", "kind": "local"]] + remote])) ??
                .text("Could not encode connection targets", status: 500, reason: "Internal Server Error")
        }
        if request.method == "POST", request.path == "/api/recovery/panes" {
            guard let input = try? JSONDecoder().decode(MCPRecoverablePanesRequest.self, from: request.body) else {
                return .text("Invalid recovery inventory request", status: 400, reason: "Bad Request")
            }
            let targets: [(String, ConnectionProfile)]
            if let host = input.host {
                guard let profile = recoveryProfile(host: host) else {
                    return .text("Use This Mac or an exact configured SSH host alias", status: 400, reason: "Bad Request")
                }
                targets = [(host, profile)]
            } else {
                workspace.profileStore.refreshSSHConfig()
                targets = [("This Mac", .local)] + workspace.profileStore.connectableHosts
                    .filter { $0.backend == .relay }.map { ($0.host, $0) }
            }
            var panes: [[String: Any]] = []
            var errors: [[String: String]] = []
            for (host, profile) in targets {
                do {
                    let catalog = try await RemoteCatalogService.load(profile: profile)
                    panes.append(contentsOf: catalog.panes.map { pane in
                        ["host": host, "paneID": pane.paneID, "workspaceID": pane.workspaceID ?? "",
                         "tabID": pane.tabID ?? "", "title": pane.title ?? "",
                         "contentKind": pane.contentKind, "directory": pane.directory ?? "",
                         "state": pane.state, "unfiled": pane.unfiled,
                         "recoverable": pane.recoverable,
                         "attached": UUID(uuidString: pane.paneID).map { workspace.panes[$0] != nil } ?? false] as [String: Any]
                    })
                } catch {
                    errors.append(["host": host, "error": error.localizedDescription])
                }
            }
            return (try? .jsonObject(["panes": panes, "errors": errors])) ??
                .text("Could not encode managed-pane inventory", status: 500, reason: "Internal Server Error")
        }
        if request.method == "POST", request.path == "/api/recovery/resume-conversation" {
            guard mcpWorkspaceGrant.permits(.create), mcpWorkspaceGrant.permits(.layout) else {
                return .text("Saved conversation recovery requires create and layout capabilities", status: 403, reason: "Forbidden")
            }
            guard let input = try? JSONDecoder().decode(MCPRecoverPaneRequest.self, from: request.body),
                  input.instance == agentInputRequests.instance else {
                return .text("Invalid or stale saved conversation recovery request", status: 400, reason: "Bad Request")
            }
            if let prior = directConversationResumeRequests[input.requestID] {
                guard prior == input, let result = directConversationResumeResults[input.requestID] else {
                    return .text("Conflicting conversation recovery request", status: 409, reason: "Conflict")
                }
                return .json(result)
            }
            guard let pane = workspace.panes[input.paneID],
                  (pane.profile.kind == .local ? input.host == "This Mac" : input.host == pane.profile.host) else {
                return .text("The saved conversation pane or host changed", status: 409, reason: "Conflict")
            }
            guard directConversationResumeRequests.count < 256 else {
                return .text("Conversation recovery receipt limit reached", status: 409, reason: "Conflict")
            }
            directConversationResumeRequests[input.requestID] = input
            directConversationResumeResults[input.requestID] = ["status": "resuming", "sourcePaneID": input.paneID.uuidString.lowercased()]
            do {
                let replacement = try await workspace.resumeSavedConversation(input.paneID)
                let result = ["status": "created_session_start_pending", "sourcePaneID": input.paneID.uuidString.lowercased(),
                              "paneID": replacement.uuidString.lowercased(), "host": input.host]
                directConversationResumeResults[input.requestID] = result
                return .json(result)
            } catch {
                let result = ["status": "failed", "sourcePaneID": input.paneID.uuidString.lowercased(), "error": error.localizedDescription]
                directConversationResumeResults[input.requestID] = result
                return .json(result)
            }
        }
        if request.method == "GET", request.path.hasPrefix("/api/terminal-edits/receipts/") {
            let parts = request.path.dropFirst("/api/terminal-edits/receipts/".count).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, let instance = UUID(uuidString: String(parts[0])), instance == agentInputRequests.instance,
                  let pane = UUID(uuidString: String(parts[1])), let id = UUID(uuidString: String(parts[2])) else {
                return .text("Invalid or stale terminal edit receipt request", status: 400, reason: "Bad Request")
            }
            return .json(["status": terminalEditReceipts.status(pane: pane, id: id) ?? "unknown",
                "pane_id": pane.uuidString.lowercased(), "note": "Receipt read; no input was sent."])
        }
        if request.method == "GET", request.path.hasPrefix("/api/agent-accounts/move-receipts/") {
            let parts = request.path.dropFirst("/api/agent-accounts/move-receipts/".count).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let instance = UUID(uuidString: String(parts[0])),
                  instance == agentInputRequests.instance, let id = UUID(uuidString: String(parts[1])) else {
                return .text("Invalid or stale account move receipt request", status: 400, reason: "Bad Request")
            }
            return .json(accountMoveReceipts.result(id) ?? ["status": "unknown", "message": "No retained receipt. This receipt read did not initiate a move."])
        }
        if request.method == "POST", request.path == "/api/private-secret/request" {
            guard mcpWorkspaceGrant.permits(.input),
                  let call = try? JSONDecoder().decode(MCPPrivateSecretEnvelope.self, from: request.body),
                  ["relay_request_secret", "relay_secret_receipt"].contains(call.tool),
                  call.arguments.utf8.count <= 4096,
                  let argumentsData = call.arguments.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: argumentsData)) as? [String: Any],
                  let arguments = try? JSONDecoder().decode(MCPPrivateSecretArguments.self, from: argumentsData),
                  arguments.instance == agentInputRequests.instance, arguments.requestID == call.requestID,
                  let pane = workspace.panes[call.sourcePaneID], pane.contentKind == .terminal else {
                return .text("Invalid private secret request", status: 403, reason: "Forbidden")
            }
            let allowedKeys: Set<String> = call.tool == "relay_request_secret"
                ? ["instance", "request_id", "account_id", "credential_reference", "purpose"] : ["instance", "request_id"]
            guard Set(object.keys) == allowedKeys else { return .text("Invalid private request fields", status: 400, reason: "Bad Request") }
            let profile = pane.profile
            let source: RelayPaneMessaging.PrivateSecretSource
            do { source = try await RelayPaneMessaging.shared.redeemPrivateSecretProof(pane: pane, attestation: call.attestationID,
                requestID: call.requestID, tool: call.tool, arguments: call.arguments) }
            catch { return .text("Private request source could not be verified", status: 403, reason: "Forbidden") }
            guard workspace.panes[call.sourcePaneID] === pane, pane.profile.connectionKey == profile.connectionKey else {
                return .text("Private request source changed", status: 409, reason: "Conflict")
            }
            let ownerDigest = RelayPrivateOperationJournal.digest([pane.id.uuidString,
                profile.connectionKey, source.sessionID.uuidString, String(source.pid), source.start, source.provider])
            let requestDigest = RelayPrivateOperationJournal.digest([call.arguments])
            do {
                if call.tool == "relay_secret_receipt" {
                    guard let status = try privateSecretApproval.durableStatus(call.requestID, owner: ownerDigest) else {
                        return .text("Private request unavailable", status: 404, reason: "Not Found")
                    }
                    return .json(["status": status.rawValue])
                }
                if let status = try privateSecretApproval.durableStatus(call.requestID, owner: ownerDigest, request: requestDigest) {
                    return .json(["status": status.rawValue])
                }
            } catch {
                return .text("Private request receipt unavailable or identity conflicts; nothing was repeated", status: 409, reason: "Conflict")
            }
            guard let account = arguments.accountID, RelayHostRotationRPC.validOperationID(account),
                  let reference = arguments.credentialReference, RelayHostRotationRPC.validOperationID(reference),
                  let purpose = arguments.purpose, pane.profile.backend == .relay,
                  let window = pane.runtime.view.window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                return .text("Private credential destination unavailable", status: 409, reason: "Conflict")
            }
            let statusBefore: RelayHostRotationTextRPC.Status
            do { statusBefore = try await RelayHostAccountsService(profile: profile).readHostRotationTextStatus() }
            catch { return .text("API account status unavailable", status: 409, reason: "Conflict") }
            guard workspace.panes[call.sourcePaneID] === pane, pane.profile.connectionKey == profile.connectionKey,
                  await RelayPaneMessaging.shared.privateSecretSourceIsCurrent(pane, expected: source),
                  statusBefore.supportsCredentials, let configurationID = statusBefore.configurationID,
                  let targetAccount = statusBefore.settings?.accounts?.first(where: { $0.id == account && $0.provider == "anthropic_api" }),
                  RelayAccountMCPReviewPolicy.safe(targetAccount.name) else {
                return .text("The exact API account could not be verified", status: 409, reason: "Conflict")
            }
            let proposal = RelayPrivateSecretProposal(instance: privateSecretApproval.instance, requestID: call.requestID,
                paneID: pane.id, sessionID: source.sessionID, requester: "Verified " + source.provider + " pane " + String(pane.id.uuidString.prefix(8)),
                host: pane.profile.name, purpose: purpose, destination: "New Relay API credential for " + targetAccount.name + " (" + reference + ")")
            do {
                let status = try privateSecretApproval.request(proposal, window: window, owner: ownerDigest, requestDigest: requestDigest, stillCurrent: { [weak self, weak pane] in
                    guard let self, let pane else { return false }
                    return self.workspace?.panes[call.sourcePaneID] === pane && pane.profile.connectionKey == profile.connectionKey
                }, consume: { [weak self, weak pane] value in
                    guard let self, let pane, self.workspace?.panes[call.sourcePaneID] === pane,
                          pane.profile.connectionKey == profile.connectionKey,
                          await RelayPaneMessaging.shared.privateSecretSourceIsCurrent(pane, expected: source),
                          self.workspace?.panes[call.sourcePaneID] === pane,
                          pane.profile.connectionKey == profile.connectionKey,
                          let secret = String(data: value, encoding: .utf8),
                          (16...512).contains(secret.utf8.count), secret.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                        throw RelayHostAccountSharingError.unavailable
                    }
                    let service = RelayHostAccountsService(profile: profile)
                    let current = try await service.readHostRotationTextStatus()
                    guard self.workspace?.panes[call.sourcePaneID] === pane, pane.profile.connectionKey == profile.connectionKey,
                          current.configurationID == configurationID,
                          current.settings?.accounts?.contains(targetAccount) == true,
                          await RelayPaneMessaging.shared.privateSecretSourceIsCurrent(pane, expected: source) else {
                        throw RelayHostAccountSharingError.unavailable
                    }
                    let receipt = try await service.saveHostRotationCredential(reference: reference, accountID: account, secret: secret)
                    guard receipt.status == "saved" else { throw RelayHostAccountSharingError.unavailable }
                })
                return .json(["status": status.rawValue])
            } catch { return .text("Private approval unavailable", status: 409, reason: "Conflict") }
        }
        if request.method == "POST", request.path == "/api/agent-accounts/mcp-preview" {
            guard mcpWorkspaceGrant.permits(.input) else {
                return .text("Account inspection requires the terminal input grant", status: 403, reason: "Forbidden")
            }
            guard let input = try? JSONDecoder().decode(MCPAccountPreviewRequest.self, from: request.body),
                  input.instance == agentInputRequests.instance, RelayAgentAccount.validLabel(input.account),
                  let pane = workspace.panes[input.paneID], pane.kind == .claude || pane.kind == .codex else {
                return .text("Invalid account preview request", status: 400, reason: "Bad Request")
            }
            let provider = pane.kind == .codex ? "codex" : "claude"
            guard let account = RelayAgentAccountDirectory.shared.account(for: pane.profile, provider: provider, label: input.account) else {
                return .text("Account unavailable on the pane's host", status: 409, reason: "Conflict")
            }
            do {
                let capturedProfile = pane.profile
                let preview = try await RelayAgentAccountDirectory.shared.mcpExactPreview(capturedProfile, account: account)
                guard workspace.panes[input.paneID] === pane,
                      pane.profile.connectionKey == capturedProfile.connectionKey,
                      RelayAgentAccountDirectory.shared.account(for: pane.profile, provider: provider, label: input.account) == account,
                      let token = preview.fingerprint, token.utf8.count == 129 else {
                    return .text("Account or host changed during preview", status: 409, reason: "Conflict")
                }
                accountMCPReviews = accountMCPReviews.filter { $0.value.expires > Date() }
                guard accountMCPReviews.count < 128 else { return .text("Account review queue full", status: 409, reason: "Conflict") }
                accountMCPReviews[token] = AccountMCPReview(paneID: pane.id, connectionKey: pane.profile.connectionKey,
                    account: account, preview: preview, expires: Date().addingTimeInterval(110))
                return .json(preview)
            } catch { return .text("Account preview unavailable", status: 409, reason: "Conflict") }
        }
        if request.method == "POST", request.path == "/api/agent-accounts/mcp-sync-receipt" {
            guard mcpWorkspaceGrant.permits(.input),
                  let input = try? JSONDecoder().decode(MCPAccountSyncRequest.self, from: request.body),
                  input.instance == agentInputRequests.instance,
                  let pane = workspace.panes[input.paneID] else {
                return .text("Unknown account sync request", status: 404, reason: "Not Found")
            }
            do {
                guard let status = try accountMCPJournal.lookup(input.requestID,
                    owner: accountMCPOwner(input, caller: caller, profile: pane.profile), request: accountMCPRequestDigest(input)) else {
                    return .text("Unknown account sync request", status: 404, reason: "Not Found")
                }
                return .json(accountMCPSyncResults[input.requestID] ?? ["status": status])
            } catch { return .text("Receipt unavailable or identity conflict; do not repeat the operation", status: 409, reason: "Conflict") }
        }
        if request.method == "POST", request.path == "/api/agent-accounts/mcp-sync" {
            guard mcpWorkspaceGrant.permits(.input),
                  let input = try? JSONDecoder().decode(MCPAccountSyncRequest.self, from: request.body),
                  input.instance == agentInputRequests.instance else {
                return .text("Invalid or unauthorized account sync request", status: 403, reason: "Forbidden")
            }
            guard let ownerPane = workspace.panes[input.paneID] else {
                return .text("Account pane unavailable", status: 409, reason: "Conflict")
            }
            let owner = accountMCPOwner(input, caller: caller, profile: ownerPane.profile)
            let digest = accountMCPRequestDigest(input)
            do {
                if let status = try accountMCPJournal.lookup(input.requestID, owner: owner, request: digest) {
                    return .json(accountMCPSyncResults[input.requestID] ?? ["status": status])
                }
            } catch { return .text("Receipt unavailable or identity conflict; nothing repeated", status: 409, reason: "Conflict") }
            guard accountMCPSyncRequests[input.requestID] == nil,
                  accountMCPSyncRequests.count < 256, !accountMCPSyncPending,
                  let review = accountMCPReviews[input.reviewToken], review.expires > Date(),
                  review.paneID == input.paneID, review.account.label == input.account,
                  let pane = workspace.panes[input.paneID], pane.profile.connectionKey == review.connectionKey,
                  let reviewLines = RelayAccountMCPReviewPolicy.lines(review.preview),
                  RelayAccountMCPReviewPolicy.safe(pane.profile.name),
                  RelayAccountMCPReviewPolicy.safe(review.account.displayDirectory),
                  RelayAgentAccountDirectory.shared.account(for: pane.profile, provider: review.account.provider, label: input.account) == review.account,
                  let window = pane.runtime.view.window ?? NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil else {
                return .text("Account review expired, target changed, or approval is busy", status: 409, reason: "Conflict")
            }
            do { try accountMCPJournal.admit(input.requestID, owner: owner, request: digest) }
            catch { return .text("Could not persist account sync admission; nothing started", status: 409, reason: "Conflict") }
            accountMCPSyncRequests[input.requestID] = input
            accountMCPSyncResults[input.requestID] = ["status": "awaiting_approval"]
            accountMCPSyncPending = true
            let alert = RelayTheme.alert()
            alert.messageText = "Copy reviewed MCP servers to \(review.account.label)?"
            let requester = caller == RelayCallerControl.assistantCaller ? "Relay assistant" :
                (caller == "legacy-unattributed" || caller == nil ? "Unattributed MCP client" : "Registered MCP client")
            alert.informativeText = "Requested by: \(requester)\nHost: \(pane.profile.name)\nAccount: \(review.account.displayDirectory)\nCopies definitions from the main account. Only server and key names are shown; values remain private. Conflicts are refused. Saves configuration for future launches. Running sessions keep their current MCP connections. Concurrent configuration saves are preserved; an uncertain result requires inspection before another operation."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 160))
            let text = NSTextView(frame: scroll.bounds)
            text.string = reviewLines
            text.isEditable = false
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Copy MCP servers")
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = ""
            alert.beginSheetModal(for: window) { [weak self, weak pane] response in
                guard let self else { return }
                self.accountMCPSyncPending = false
                self.accountMCPReviews.removeValue(forKey: input.reviewToken)
                guard response == .alertSecondButtonReturn else { self.recordAccountMCP(input.requestID, ["status": "cancelled"]); return }
                guard Date() < review.expires, let pane, self.workspace?.panes[input.paneID] === pane,
                      pane.profile.connectionKey == review.connectionKey,
                      RelayAgentAccountDirectory.shared.account(for: pane.profile, provider: review.account.provider, label: input.account) == review.account else {
                    self.recordAccountMCP(input.requestID, ["status": "stale_or_expired"]); return
                }
                guard self.recordAccountMCP(input.requestID, ["status": "running"]) else { return }
                let capturedProfile = pane.profile
                Task { @MainActor in
                    guard self.workspace?.panes[input.paneID] === pane,
                          pane.profile.connectionKey == capturedProfile.connectionKey,
                          RelayAgentAccountDirectory.shared.account(for: capturedProfile, provider: review.account.provider, label: input.account) == review.account else {
                        self.recordAccountMCP(input.requestID, ["status": "stale_or_expired"])
                        return
                    }
                    do {
                        let result = try await RelayAgentAccountDirectory.shared.syncMCPOnly(capturedProfile, account: review.account, reviewToken: input.reviewToken)
                        var receipt = ["mcp": result.mcp, "servers": String(result.mcpServers)]
                        if result.mcp == "refused" {
                            receipt["status"] = "refused_no_changes"
                            receipt["reason"] = result.error.map { String($0.prefix(400)) } ?? "MCP sync refused"
                        } else if result.mcp == "outcome_unknown" {
                            receipt["status"] = "outcome_unknown"
                        } else if ["updated", "unchanged", "nothing_to_merge"].contains(result.mcp), result.error == nil {
                            receipt["status"] = "completed"
                        } else { receipt["status"] = "not_completed" }
                        self.recordAccountMCP(input.requestID, receipt)
                    } catch { self.recordAccountMCP(input.requestID, ["status": "outcome_unknown"]) }
                }
            }
            return .json(accountMCPSyncResults[input.requestID]!)
        }
        if request.method == "POST", request.path == "/api/agent-accounts/move" {
            guard mcpWorkspaceGrant.permits(.input) else {
                return .text("Moving a pane to another account requires the terminal input grant", status: 403, reason: "Forbidden")
            }
            guard let input = try? JSONDecoder().decode(MCPMovePaneAccountRequest.self, from: request.body),
                  input.instance == agentInputRequests.instance, RelayAgentAccount.validLabel(input.account) else {
                return .text("Invalid or stale account move request", status: 400, reason: "Bad Request")
            }
            switch accountMoveReceipts.lookup(input) {
            case .replay(let result): return .json(result)
            case .conflict: return .text("Conflicting account move request ID", status: 409, reason: "Conflict")
            case .expired: return .json(["status": "expired", "message": RelayAccountMoveReceipts.expiredMessage])
            case .new: break
            }
            guard let pane = workspace.panes[input.paneID],
                  let provider = RelayAgentAccountMovePolicy.movableProvider(pane.kind) else {
                return .text("The pane does not run a Claude or Codex agent", status: 409, reason: "Conflict")
            }
            guard let target = RelayAgentAccountDirectory.shared.account(for: pane.profile, provider: provider, label: input.account) else {
                return .text("There is no \(provider) account named \(input.account) on the pane's host", status: 409, reason: "Conflict")
            }
            let requestID = input.requestID
            let base = ["paneID": input.paneID.uuidString.lowercased(), "account": target.label]
            guard accountMoveReceipts.begin(input, result: base.merging(["status": "moving"]) { $1 }, now: Date()) else {
                if accountMoveReceipts.usedCeilingReached {
                    return .text(RelayAccountMoveReceipts.usedCeilingMessage, status: 409, reason: "Conflict")
                }
                return .text("Account move receipt limit reached: \(accountMoveReceipts.inProgress) moves are still in progress",
                             status: 409, reason: "Conflict")
            }
            let targetWorkspace = workspace
            Task { @MainActor [weak self] in
                let outcome = await RelayAgentAccountMove.shared.move(pane, in: targetWorkspace, to: target, origin: .mcp,
                    inputGranted: self?.mcpWorkspaceGrant.permits(.input) == true)
                self?.accountMoveReceipts.finish(requestID, result: base.merging(["status": outcome.state, "message": outcome.message]) { $1 },
                                                 now: Date())
            }
            // The MCP client waits up to a minute; a longer move is reported
            // as still moving and read back with the same request_id.
            for _ in 0..<100 where accountMoveReceipts.result(requestID)?["status"] == "moving" {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return .json(accountMoveReceipts.result(requestID) ?? ["status": "expired", "message": RelayAccountMoveReceipts.expiredMessage])
        }
        if request.method == "POST", request.path == "/api/recovery/attach" {
            guard recoveryGrant().permits(.create) else {
                return .text("MCP pane recovery requires the create capability", status: 403, reason: "Forbidden")
            }
            guard let input = try? JSONDecoder().decode(MCPRecoverPaneRequest.self, from: request.body),
                  input.instance == agentInputRequests.instance else {
                return .text("Invalid or stale pane recovery request", status: 400, reason: "Bad Request")
            }
            switch directRecoveryReceipts.begin(input) {
            case .replay(let result):
                return .json(result)
            case .pending:
                return .json(["status": "pending", "paneID": input.paneID.uuidString.lowercased()])
            case .conflict:
                return .text("Conflicting recovery request ID", status: 409, reason: "Conflict")
            case .full:
                return .text("Recovery receipt limit reached", status: 409, reason: "Conflict")
            case .started:
                break
            }
            var committed = false
            defer { if !committed { directRecoveryReceipts.cancel(input) } }
            let captured = RelayPaneRecoveryCapture(workspace.panes[input.paneID])
            let capturedProfile = captured.profile
            let profile: ConnectionProfile
            if let capturedProfile {
                guard let pinned = RelayPaneRecoveryProfile.captured(capturedProfile, requestedHost: input.host) else {
                    return .text("The saved pane's host or backend does not match", status: 409, reason: "Conflict")
                }
                profile = pinned
            } else {
                guard let resolved = recoveryProfile(host: input.host) else {
                    return .text("Invalid or stale pane recovery request", status: 400, reason: "Bad Request")
                }
                profile = resolved
            }
            do {
                return try await captured.transact(current: { workspace.panes[input.paneID] },
                    permitted: { RelayPaneRecoveryAuthorization.permits(
                        grant: recoveryGrant(), callers: callerControl, caller: caller) },
                    load: { try await recoveryLoad(profile) }) { catalog in
                    guard let pane = catalog.panes.first(where: { $0.paneID.lowercased() == input.paneID.uuidString.lowercased() && $0.recoverable }) else {
                        return .text("Pane is no longer recoverable on this host", status: 409, reason: "Conflict")
                    }
                    let session = catalog.sessions.first(where: { $0.panes.contains(where: { $0.paneID == pane.paneID }) })
                    guard recoveryAttach(workspace, profile: profile,
                        pane: pane, label: session?.label ?? profile.name) else {
                        return .text("Pane recovery target does not match its existing host", status: 409, reason: "Conflict")
                    }
                    let result = ["status": "attached", "host": input.host,
                        "paneID": input.paneID.uuidString.lowercased(),
                        "tabID": (pane.tabID ?? "").lowercased()]
                    // Once attach has been dispatched, retain even an
                    // unresolved pending receipt. Never allow a retry to
                    // dispatch another reconnect after an unknown outcome.
                    committed = true
                    guard directRecoveryReceipts.finish(input, result: result) else {
                        return .text("Recovery completed but its receipt is unavailable; do not replay", status: 503, reason: "Service Unavailable")
                    }
                    return .json(result)
                }
            } catch is RelayPaneRecoveryCapture.Changed {
                return .text("The pane changed during recovery", status: 409, reason: "Conflict")
            } catch is RelayPaneRecoveryCapture.Revoked {
                return .text("MCP pane recovery permission or caller access was revoked", status: 403, reason: "Forbidden")
            } catch {
                return .text("Could not recover pane: \(error.localizedDescription)", status: 502, reason: "Bad Gateway")
            }
        }
        if request.method == "POST", request.path == "/api/recovery/terminate" {
            guard mcpWorkspaceGrant.permits(.terminate) else {
                return .text("MCP process termination is not granted", status: 403, reason: "Forbidden")
            }
            guard let input = try? JSONDecoder().decode(MCPTerminatePaneRequest.self, from: request.body),
                  input.instance == agentInputRequests.instance,
                  let profile = recoveryProfile(host: input.host) else {
                return .text("Invalid or stale termination request", status: 400, reason: "Bad Request")
            }
            if let prior = directTerminationRequests[input.requestID] {
                guard prior == input, let result = directTerminationResults[input.requestID] else {
                    return .text("Conflicting termination request ID", status: 409, reason: "Conflict")
                }
                return .json(result)
            }
            guard directTerminationRequests.count < 256 else {
                return .text("Termination receipt limit reached", status: 409, reason: "Conflict")
            }
            do {
                let catalog = try await RemoteCatalogService.load(profile: profile)
                guard catalog.panes.contains(where: {
                    $0.paneID.lowercased() == input.paneID.uuidString.lowercased() &&
                    $0.recoverable && $0.state == "running" && $0.contentKind == "terminal"
                }) else {
                    return .text("Pane is no longer a running Relay terminal on this host", status: 409, reason: "Conflict")
                }
                let attached = workspace.panes[input.paneID] != nil
                try await RemotePaneControlService.terminate(profile: profile, paneID: input.paneID)
                if attached {
                    workspace.revealPane(input.paneID, origin: .programmatic)
                    workspace.closeActivePane()
                }
                let result = ["status": "terminated", "host": input.host,
                    "paneID": input.paneID.uuidString.lowercased(), "wasAttached": String(attached)]
                directTerminationRequests[input.requestID] = input
                directTerminationResults[input.requestID] = result
                return .json(result)
            } catch {
                return .text("Could not terminate pane: \(error.localizedDescription)", status: 502, reason: "Bad Gateway")
            }
        }
        if request.method == "POST", request.path == "/api/workspace/grant" {
            do {
                try mcpWorkspaceGrant.request()
                return .json(["status": mcpWorkspaceGrant.status, "grantedCapabilities": mcpWorkspaceGrant.allowed.map(\.rawValue).sorted().joined(separator: ",")])
            } catch {
                return .text(error.localizedDescription, status: 409, reason: "Conflict")
            }
        }
        if request.method == "POST", request.path.hasPrefix("/api/workspace/select/") {
            guard mcpWorkspaceGrant.permits(.navigate) else {
                return .text("MCP pane navigation is not granted", status: 403, reason: "Forbidden")
            }
            guard let id = UUID(uuidString: String(request.path.dropFirst("/api/workspace/select/".count))) else {
                return .text("Invalid pane ID", status: 400, reason: "Bad Request")
            }
            do {
                let (tabID, paneID) = try workspace.selectWorkspacePane(id)
                return .json(["tabID": tabID.uuidString.lowercased(), "paneID": paneID.uuidString.lowercased(), "status": "selected"])
            } catch {
                return .text("Pane selection unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
            }
        }
        if request.method == "POST", request.path == "/api/workspace/apply" {
            switch workspaceApply.apply(request.body, instance: agentInputRequests.instance, permits: mcpWorkspaceGrant.permits,
                                        workspace: workspace, resolve: { self.recoveryProfile(host: $0) }) {
            case .applied(let result): return .json(result)
            case .rejected(let status, let message):
                return .text(message, status: status, reason: status == 400 ? "Bad Request" : status == 403 ? "Forbidden" : "Conflict")
            }
        }
        if request.method == "POST", request.path == "/api/workspace/rename-pane" {
            return directTabRequests.renamePane(request.body, instance: agentInputRequests.instance,
                                               permits: mcpWorkspaceGrant.permits, workspace: workspace)
        }
        if request.method == "POST", request.path == "/api/workspace/tab-action" {
            return directTabRequests.tabAction(request.body, instance: agentInputRequests.instance,
                                               permits: mcpWorkspaceGrant.permits, workspace: workspace)
        }
        if request.method == "POST", request.path == "/api/workspace/new-local-tab" {
            return directTabRequests.newLocalTab(request.body, instance: agentInputRequests.instance,
                                                 permits: mcpWorkspaceGrant.permits, workspace: workspace)
        }
        if request.method == "POST", request.path == "/api/workspace/stack-pane" {
            return directTabRequests.stackPane(request.body, instance: agentInputRequests.instance,
                                               permits: mcpWorkspaceGrant.permits, workspace: workspace)
        }
        if request.method == "POST", request.path == "/api/workspace/new-stacked-pane" {
            return directTabRequests.newStackedPane(request.body, instance: agentInputRequests.instance,
                                                    permits: mcpWorkspaceGrant.permits, workspace: workspace,
                                                    resolve: { self.recoveryProfile(host: $0) })
        }
        if request.method == "GET", request.path == "/api/plugins" {
            do { return .json(try await RelayPluginManager.shared.controlInventory()) }
            catch { return .text("Plugin inventory unavailable", status: 503, reason: "Service Unavailable") }
        }
        if request.method == "POST", request.path == "/api/workspace/request" {
            do {
                let proposal = try JSONDecoder().decode(WorkspaceProposal.self, from: request.body)
                guard proposal.validDirectory else { throw PluginError.invalid("Invalid starting directory") }
                if workspaceControl.receipt(proposal.requestID) != nil {
                    // The broker still checks instance and exact proposal equality.
                    return .json(try workspaceControl.propose(proposal, instance: agentInputRequests.instance, detail: "") { nil })
                }
                let targetProfile: ConnectionProfile?
                if let host = proposal.connectionHost {
                    guard let resolved = recoveryProfile(host: host) else {
                        throw PluginError.invalid("Connection target is not a configured Relay host")
                    }
                    targetProfile = resolved
                } else {
                    targetProfile = nil
                }
                let detail = try workspace.workspaceActionDetail(proposal)
                guard let pane = workspace.panes[proposal.paneID] else { throw PluginError.invalid("Missing pane") }
                // Captured at admission, fixed while the request awaits approval.
                let admission = workspace.tabAdmission(forSourcePane: proposal.paneID)
                return .json(try workspaceControl.propose(proposal, instance: agentInputRequests.instance, detail: detail) { [weak workspace, weak pane, targetProfile] in
                    guard let workspace, let pane else { return nil }
                    return workspace.withTabAdmission(admission) {
                        workspace.applyWorkspaceAction(proposal, expected: pane, profile: targetProfile)
                    }
                })
            } catch {
                return .text("Workspace action unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
            }
        }
        if request.method == "POST", request.path == "/api/workspace/tab-request" {
            do {
                let proposal = try JSONDecoder().decode(WorkspaceTabProposal.self, from: request.body)
                if workspaceControl.receipt(proposal.requestID) != nil {
                    return .json(try workspaceControl.propose(proposal, instance: agentInputRequests.instance, detail: "") { nil })
                }
                let detail = try workspace.workspaceTabActionDetail(proposal)
                return .json(try workspaceControl.propose(proposal, instance: agentInputRequests.instance, detail: detail) { [weak workspace] in
                    guard let workspace, let tabID = workspace.applyWorkspaceTabAction(proposal) else { return nil }
                    return (tabID, workspace.selectedTabID ?? tabID)
                })
            } catch {
                return .text("Tab action unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
            }
        }
        if request.method == "GET", request.path.hasPrefix("/api/workspace/receipts/") {
            guard let id = UUID(uuidString: String(request.path.dropFirst("/api/workspace/receipts/".count))),
                  let receipt = workspaceControl.receipt(id) else {
                return .text("Unknown receipt; do not retry automatically", status: 404, reason: "Not Found")
            }
            return .json(receipt)
        }
        if request.method == "POST", request.path == "/api/local-pane/request" {
            do {
                // This approval route has no anchor support; never ignore one.
                let proposal = try MCPDirectTabRequests.localPaneApprovalProposal(request.body)
                return .json(try localPaneApprovals.propose(proposal, instance: agentInputRequests.instance) { [weak workspace] in
                    guard let workspace else { return nil }
                    workspace.newTab(profile: .local, origin: .agent(sourcePane: nil))
                    guard let tab = workspace.selectedTabID, let pane = workspace.activePaneID else { return nil }
                    return (tab, pane)
                })
            } catch {
                return .text("Local terminal approval unavailable", status: 409, reason: "Conflict")
            }
        }
        if request.method == "GET", request.path.hasPrefix("/api/local-pane/receipts/") {
            guard let id = UUID(uuidString: String(request.path.dropFirst("/api/local-pane/receipts/".count))),
                  let receipt = localPaneApprovals.receipt(id) else {
                return .text("Unknown receipt; do not retry automatically", status: 404, reason: "Not Found")
            }
            return .json(receipt)
        }
        if request.method == "GET", request.path == "/api/pane-links" {
            do { return try .jsonObject(["links": await paneMessaging.savedLinks(workspace: workspace)]) }
            catch { return .text("Saved pane links unavailable", status: 409, reason: "Conflict") }
        }
        if request.method == "POST", request.path == "/api/pane-links" {
            guard mcpWorkspaceGrant.permits(.layout) else { return .text("Pane links require existing layout permission", status: 403, reason: "Forbidden") }
            do {
                // Cross-host links are never saved here. `proposalID` alone reads a proposal's
                // status; beside a pane pair it makes a retry idempotent.
                var linkBody = request.body
                var proposalID: UUID?
                if var object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                   let raw = object.removeValue(forKey: "proposalID") {
                    guard let text = raw as? String, let id = UUID(uuidString: text), text == id.uuidString.lowercased() else {
                        return .text("proposalID must be a lowercase UUID", status: 400, reason: "Bad Request")
                    }
                    proposalID = id
                    if object.isEmpty {
                        guard let caller else { return .text("Unknown caller", status: 403, reason: "Forbidden") }
                        let (status, value) = paneLinkProposals.statusLocal(proposalID: id, caller: caller)
                        return Self.paneLinkProposalResponse(status: status, value: value)
                    }
                    linkBody = (try? JSONSerialization.data(withJSONObject: object)) ?? request.body
                }
                let input = try JSONDecoder().decode(PaneLinkRequest.self, from: linkBody)
                let ids: [UUID]
                if let source = input.sourcePaneID, let target = input.paneID {
                    ids = [source, target]
                } else {
                    let terminals = workspace.selectedTab?.allPaneIDs.filter { workspace.panes[$0]?.contentKind == .terminal } ?? []
                    guard terminals.count == 2,
                          input.sourcePaneID.map({ terminals.contains($0) }) ?? true,
                          input.paneID.map({ terminals.contains($0) }) ?? true else {
                        return .text("Choose two exact pane IDs; the current tab does not identify a unique pair", status: 409, reason: "Conflict")
                    }
                    ids = terminals
                }
                if ids.count == 2, let first = RelayPaneLinkPane(workspace.panes[ids[0]]),
                   let second = RelayPaneLinkPane(workspace.panes[ids[1]]),
                   RelayPaneLinkProposals.crossesHosts(first, second) {
                    guard let caller else { return .text("Unknown caller", status: 403, reason: "Forbidden") }
                    let (status, value) = paneLinkProposals.proposeLocal(
                        proposalID: proposalID ?? UUID(), sourceID: ids[0], targetID: ids[1], caller: caller)
                    return Self.paneLinkProposalResponse(status: status, value: value)
                }
                return .json(try await paneMessaging.connect(panes: ids, workspace: workspace))
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        }
        if request.method == "DELETE", request.path == "/api/pane-links" {
            struct Removal: Decodable { let linkID: String }
            guard mcpWorkspaceGrant.permits(.layout) else { return .text("Pane links require existing layout permission", status: 403, reason: "Forbidden") }
            do {
                let input = try JSONDecoder().decode(Removal.self, from: request.body)
                return try .jsonObject(await paneMessaging.disconnect(linkID: input.linkID, workspace: workspace))
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        }
        if request.path == "/api/question-threads", request.method == "POST" || request.method == "DELETE" {
            // A scoped external caller is refused: the route cannot bind a pane on that caller's behalf.
            guard await RelayQuestionThreadInput.admits(caller: caller) else {
                return .text("Question threads are not available to scoped callers; use relay_bind_question_thread", status: 403, reason: "Forbidden")
            }
            guard mcpWorkspaceGrant.permits(.layout) else { return .text("Question threads require existing layout permission", status: 403, reason: "Forbidden") }
            if let refusal = RelayQuestionThreadInput.rejection(method: request.method, body: request.body) { return refusal }
            do {
                let input = try JSONDecoder().decode(RelayQuestionThreadInput.Binding.self, from: request.body)
                if request.method == "DELETE" {
                    return try .jsonObject(await paneMessaging.unbindQuestionThread(paneID: input.paneID, workspace: workspace))
                }
                guard let thread = RelayQuestionThreadInput.validID(input.threadID), let realm = RelayQuestionThreadInput.validID(input.realm) else {
                    return .text("threadID and realm are required", status: 400, reason: "Bad Request")
                }
                return try .jsonObject(await paneMessaging.bindQuestionThread(paneID: input.paneID, threadID: thread, realm: realm,
                                                                              ttl: input.ttl, workspace: workspace))
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        }
        if request.method == "GET", request.path.hasPrefix("/api/pane-messages/") {
            guard let id = UUID(uuidString: String(request.path.dropFirst("/api/pane-messages/".count))) else {
                return .text("Invalid message ID", status: 400, reason: "Bad Request")
            }
            do {
                guard let receipt = try await paneMessaging.receipt(id, workspace: workspace) else { return .text("Unknown message; do not replay", status: 404, reason: "Not Found") }
                return try .jsonObject(receipt)
            } catch { return .text("Message receipt unavailable; do not replay", status: 409, reason: "Conflict") }
        }
        if request.method == "GET", request.path == "/api/network/status" {
            let directory = RelayStateProfile.peerNetworkStatusRoot
            return await Task.detached(priority: .utility) {
                RelaySidePanelHTTPResponse.json(PeerNetworkStatus.read(directory: directory))
            }.value
        }
        if request.method == "GET", request.path == "/api/network/links" {
            return .json(PeerNetworkController.shared.configurations)
        }
        if request.method == "GET", request.path == "/api/network/desktop-tasks" {
            return await Task.detached(priority: .utility) {
                do { return RelaySidePanelHTTPResponse.json(try DesktopPeerRoute.loadedTaskDetails()) }
                catch { return .desktopDiscoveryFailure(error) }
            }.value
        }
        if request.method == "GET", request.path == "/api/network/desktop-routes" {
            return .json(DesktopPeerRoute.read().map { route in
                ["thread": route.thread, "host": route.host, "remoteName": route.remoteName,
                 "remoteSession": route.remoteSession, "remotePID": String(route.remotePID),
                 "remoteStart": route.remoteStart, "replyName": route.localName]
            })
        }
        if request.method == "GET", request.path == "/api/workspace/organization" {
            do { return try .jsonObject(workspace.workspaceOrganizationControlState()) }
            catch { return .text("Workspace organization is unavailable", status: 500, reason: "Internal Server Error") }
        }
        if request.method == "GET", request.path == "/api/workspace/migration-preview" {
            do { return try .jsonObject(workspace.workspaceMigrationControlState()) }
            catch { return .text("Workspace migration preview is unavailable", status: 500, reason: "Internal Server Error") }
        }
        // Migration writes share the layout grant. Stage only previews; apply
        // needs the exact open preview (ID and checksum); undo an exact record.
        if request.method == "POST", request.path.hasPrefix("/api/workspace/migration-") {
            guard mcpWorkspaceGrant.permits(.layout) else {
                return .text("MCP workspace layout capability is not granted", status: 403, reason: "Forbidden")
            }
            guard request.body.count <= WorkspaceMigrationPlanInbox.maximumBytes + 4096,
                  let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return .text("A JSON object is required", status: 400, reason: "Bad Request")
            }
            func uuid(_ key: String) -> UUID? { (body[key] as? String).flatMap(UUID.init(uuidString:)) }
            func conflict(_ error: Error) -> RelaySidePanelHTTPResponse {
                .text("Workspace migration refused: \(error.localizedDescription)", status: 409, reason: "Conflict")
            }
            switch request.path {
            case "/api/workspace/migration-stage":
                let name = body["name"] as? String, replace = body["replace"] as? Bool ?? false
                guard Set(body.keys).isSubset(of: ["plan", "path", "name", "replace"]), (body["plan"] == nil) != (body["path"] == nil),
                      body["name"] == nil || name != nil, body["replace"] == nil || body["replace"] is Bool else {
                    return .text("Supply exactly one of plan (object) or path (absolute .json file); name is a string, replace a boolean",
                                 status: 400, reason: "Bad Request")
                }
                let data: Data, planName: String?
                do {
                    if let plan = body["plan"] as? [String: Any] {
                        data = try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys])
                        planName = name
                    } else if let path = body["path"] as? String, path.hasPrefix("/"), path.hasSuffix(".json"), path.utf8.count <= 1024 {
                        let url = URL(fileURLWithPath: path)
                        data = try WorkspaceMigrationPlanInbox.read(url)
                        planName = name ?? WorkspaceMigrationPlanInbox.safeName(for: url)
                    } else {
                        return .text("plan must be an object, or path an absolute .json file", status: 400, reason: "Bad Request")
                    }
                } catch {
                    return .text("Migration plan rejected: \(error.localizedDescription)", status: 400, reason: "Bad Request")
                }
                do {
                    let (url, preview) = try workspace.stageWorkspaceMigrationPlan(data, name: planName, replace: replace)
                    return try .jsonObject(workspace.migrationPreviewSummary(preview, plan: url.lastPathComponent))
                } catch WorkspaceMigrationPlanInboxError.previewOpen {
                    return .text(WorkspaceMigrationPlanInboxError.previewOpen.localizedDescription, status: 409, reason: "Conflict")
                } catch {
                    return .text("Migration plan rejected: \(error.localizedDescription)", status: 400, reason: "Bad Request")
                }
            case "/api/workspace/migration-apply":
                guard body.count == 2, let id = uuid("preview_id"), let checksum = body["checksum"] as? String else {
                    return .text("preview_id and checksum of the open preview are required", status: 400, reason: "Bad Request")
                }
                do {
                    let migration = try workspace.applyWorkspaceMigration(previewID: id, checksum: checksum, caller: caller ?? "mcp")
                    return .json(["status": "applied", "migration_id": migration.uuidString.lowercased()])
                } catch { return conflict(error) }
            case "/api/workspace/migration-undo":
                guard body.count == 1, let id = uuid("migration_id") else {
                    return .text("migration_id is required", status: 400, reason: "Bad Request")
                }
                do {
                    try workspace.undoWorkspaceMigration(id, caller: caller ?? "mcp")
                    return .json(["status": "undone", "migration_id": id.uuidString.lowercased()])
                } catch { return conflict(error) }
            default:
                return .text("Unknown workspace migration route", status: 404, reason: "Not Found")
            }
        }
        if request.method == "POST", request.path == "/api/workspace/context" {
            guard let input = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let rawID = (input["tab_id"] ?? input["pane_id"]) as? String,
                  let suppliedID = UUID(uuidString: rawID),
                  !(input["tab_id"] != nil && input["pane_id"] != nil) else {
                return .text("Supply one exact existing tab_id or pane_id", status: 400, reason: "Bad Request")
            }
            let binding = input["action"] as? String == "bind"
            let explicitTab = input["pane_id"] == nil ? workspace.tabs.first(where: { $0.id == suppliedID }) : nil
            // Reading context may resolve a pane's existing tab. Binding still
            // requires the explicit tab identity and the layout grant.
            let resolvedID = explicitTab?.id ?? (binding ? nil : workspace.tabID(containingPane: suppliedID))
            guard let tabID = resolvedID, let tab = workspace.tabs.first(where: { $0.id == tabID }) else {
                return .text("Target is absent; binding requires tab_id. Use /api/state to discover current pane and tab IDs", status: 400, reason: "Bad Request")
            }
            if input["action"] as? String == "bind" {
                guard mcpWorkspaceGrant.permits(.layout) else { return .text("Workspace control is not granted", status: 403, reason: "Forbidden") }
                do {
                    if input["follow_active_pane"] as? Bool == true {
                        try workspace.bindExecutionContext(nil, tabID: tabID)
                    } else {
                        guard let host = input["host"] as? String, let profile = recoveryProfile(host: host),
                              let directory = input["directory"] as? String else { throw RelayHostRPCError.invalidRequest }
                        try workspace.bindExecutionContext(RelayExecutionContext(profile: profile, directory: directory), tabID: tabID)
                    }
                } catch { return .text(error.localizedDescription, status: 400, reason: "Bad Request") }
            }
            do {
                let context = try await workspace.captureExecutionContext(tabID: tabID)
                return .json(["tab_id": tabID.uuidString.lowercased(), "host": context.host, "directory": context.directory,
                              "binding": tab.executionContext == nil ? "follow_active_pane" : "explicit"])
            } catch {
                return .text("Workspace context capture failed: \(error.localizedDescription)", status: 409, reason: "Conflict")
            }
        }
        if request.method == "POST", request.path == "/api/workspace/host-request" || request.path == "/api/workspace/image" {
            guard var input = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let rawID = input.removeValue(forKey: "tab_id") as? String, let tabID = UUID(uuidString: rawID) else {
                return .text("Exact workspace context required", status: 400, reason: "Bad Request")
            }
            guard mcpWorkspaceGrant.permits(.input) else { return .text("Workspace host operations are not granted", status: 403, reason: "Forbidden") }
            do {
                let context = try await workspace.captureExecutionContext(tabID: tabID)
                let caller = try callerControl.identity(token: request.headers["x-relay-caller-token"])
                RelayHostRegistry.shared.register(context.profile, origin: "Workspace RPC client: \(caller)")
                if request.path == "/api/workspace/image" {
                    guard let path = input["path"] as? String else { throw RelayHostRPCError.invalidRequest }
                    let image = try await RelayHostFiles.image(context: context, path: path)
                    return try .jsonObject(["host": context.host, "path": path, "mime_type": "image/png", "data": image.base64EncodedString()])
                }
                guard let nested = input["request"] as? [String: Any] else { throw RelayHostRPCError.invalidRequest }
                // A malformed request is a caller error, not a refused grant:
                // say which field is wrong and what the tool may send.
                guard let operation = nested["operation"] as? String, !operation.isEmpty else {
                    return .text("request.operation is required; tools may use: \(Self.toolHostOperationList)", status: 400, reason: "Bad Request")
                }
                guard Self.toolHostOperations.contains(operation) else {
                    return .text("Host operation \"\(operation)\" is not available to tools; tools may use: \(Self.toolHostOperationList)", status: 400, reason: "Bad Request")
                }
                input = nested
                if ["process_signal", "account_force_commit"].contains(input["operation"] as? String ?? ""), !mcpWorkspaceGrant.permits(.terminate) {
                    return .text("MCP process termination is not granted", status: 403, reason: "Forbidden")
                }
                // Capture an unambiguous workspace owner before execution, even
                // if the response is lost. Host-only jobs have no pane attribution.
                let owners = workspace.tabs.first(where: { $0.id == tabID })?.allPaneIDs.compactMap { workspace.panes[$0] }.filter {
                    ($0.kind == .claude || $0.kind == .codex) && $0.profile == context.profile
                } ?? []
                if operation == "exec", owners.count == 1, let id = input["job_id"] as? String {
                    RelayMikoShepherdCoordinator.shared.track(id: id, owner: owners[0].id, profile: context.profile, workspace: workspace)
                }
                input["request_id"] = "rpc-" + UUID().uuidString.lowercased()
                input["cwd"] = context.directory
                let response = try await RelayNodeTransportPool.shared.request(profile: context.profile, payload: JSONSerialization.data(withJSONObject: input))
                guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw RelayHostRPCError.invalidRequest }
                return try .jsonObject(object)
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        }
        if request.method == "POST", request.path == "/api/host/relayd-update" {
            // Same grant as remote installs; it runs Manage relayd's Update.
            guard mcpWorkspaceGrant.permits(.input) else {
                return .text("Remote installs need Relay's terminal control grant", status: 403, reason: "Forbidden")
            }
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  Set(object.keys) == ["host", "request_id"],
                  let host = object["host"] as? String,
                  let id = (object["request_id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return .text("Exact host and a request_id UUID required", status: 400, reason: "Bad Request")
            }
            do {
                let caller = try callerControl.identity(token: request.headers["x-relay-caller-token"])
                if let profile = recoveryProfile(host: host), profile.kind == .ssh {
                    RelayHostRegistry.shared.register(profile, origin: "relayd update client: \(caller)")
                }
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
            // relay-mcp's HTTP client gives up after 60 seconds; a longer
            // update answers in_progress and the same request_id reads it.
            return .json(await relaydUpdates.run(host: host, requestID: id, wait: .seconds(45)))
        }
        if request.method == "POST", request.path == "/api/host/remote-install" {
            guard mcpWorkspaceGrant.permits(.input) else {
                return .text("Remote installs need Relay's terminal control grant", status: 403, reason: "Forbidden")
            }
            do {
                guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                    throw RelayHostRPCError.invalidRequest
                }
                let install = try RelayRemoteInstallRequest.parse(object)
                guard let profile = recoveryProfile(host: install.host), profile.kind == .ssh else {
                    return .text("Exact configured SSH host required", status: 400, reason: "Bad Request")
                }
                let caller = try callerControl.identity(token: request.headers["x-relay-caller-token"])
                RelayHostRegistry.shared.register(profile, origin: "Remote install client: \(caller)")
                let path = install.localPath
                let file = try await Task.detached { try path.map(RelayRemoteInstallRunner.inspect) }.value
                return .json(try remoteInstall.propose(install, file: file, send: { payload in
                    try await RelayNodeTransportPool.shared.request(profile: profile, payload: payload, timeoutSeconds: 60)
                }, direct: { script in
                    try await Task.detached { try RelaydRemoteClient.runDirect(profile: profile, script: script, timeout: 180) }.value
                }))
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        }
        if request.method == "GET", request.path.hasPrefix("/api/host/remote-install/") {
            guard let id = UUID(uuidString: String(request.path.dropFirst("/api/host/remote-install/".count))),
                  let receipt = remoteInstall.receipt(id) else {
                return .text("Unknown remote install request", status: 404, reason: "Not Found")
            }
            return .json(receipt)
        }
        if request.method == "POST", request.path == "/api/host/request" {
            guard var input = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let host = input.removeValue(forKey: "host") as? String,
                  let profile = recoveryProfile(host: host == "laptop" ? "This Mac" : host),
                  let operation = input["operation"] as? String,
                  Self.toolHostOperations.contains(operation) else {
                return .text("Exact configured host and valid operation required", status: 400, reason: "Bad Request")
            }
            if ["process_signal", "account_force_commit"].contains(operation), !mcpWorkspaceGrant.permits(.terminate) {
                return .text("MCP process termination is not granted", status: 403, reason: "Forbidden")
            }
            guard operation == "status" || mcpWorkspaceGrant.permits(.input) else {
                return .text("MCP terminal input is not granted", status: 403, reason: "Forbidden")
            }
            do {
                let caller = try callerControl.identity(token: request.headers["x-relay-caller-token"])
                RelayHostRegistry.shared.register(profile, origin: "Host RPC client: \(caller)")
                let payload = try JSONSerialization.data(withJSONObject: input)
                let response = try await RelayNodeTransportPool.shared.request(profile: profile, payload: payload)
                guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
                    throw RelayHostRPCError.invalidRequest
                }
                return try .jsonObject(object)
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        }
        if request.method == "POST", request.path == "/api/network/desktop-route/send" {
            struct Message: Decodable, Sendable {
                let replyName: String
                let thread: String
                let host: String
                let remoteSession: String
                let remotePID: Int
                let remoteStart: String
                let messageID: String
                let content: String
            }
            guard let message = try? JSONDecoder().decode(Message.self, from: request.body),
                  let route = DesktopPeerRoute.read().first(where: {
                      $0.localName == message.replyName && $0.thread == message.thread &&
                      $0.host == message.host && $0.remoteSession == message.remoteSession &&
                      $0.remotePID == message.remotePID && $0.remoteStart == message.remoteStart
                  }) else {
                return .text("Unknown exact route", status: 404, reason: "Not Found")
            }
            return await Task.detached(priority: .utility) {
                do { return RelaySidePanelHTTPResponse.json(try route.sendMessage(id: message.messageID, content: message.content)) }
                catch let error as DesktopPeerRoute.MessageSendFailure {
                    return .json(DesktopPeerRoute.MessageReceipt(id: message.messageID,
                        status: error.status, updatedAt: Date().timeIntervalSince1970))
                }
                catch { return .text("Message outcome is unknown. Check its receipt; do not retry with a new ID.", status: 409, reason: "Conflict") }
            }.value
        }
        if request.method == "POST", request.path == "/api/network/desktop-route/message-receipt" {
            struct Query: Decodable { let replyName: String; let messageID: String }
            guard let query = try? JSONDecoder().decode(Query.self, from: request.body),
                  query.replyName.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$"#, options: .regularExpression) != nil,
                  let route = DesktopPeerRoute.read().first(where: { $0.localName == query.replyName }) else {
                return .text("Unknown route", status: 404, reason: "Not Found")
            }
            do {
                guard let receipt = try route.messageReceipt(query.messageID) else {
                    return .text("Unknown message receipt", status: 404, reason: "Not Found")
                }
                return .json(receipt)
            } catch {
                return .text("Message receipt unavailable", status: 409, reason: "Conflict")
            }
        }
        if request.method == "POST", request.path == "/api/network/desktop-route/request" {
            do {
                let proposal = try JSONDecoder().decode(DesktopRouteProposal.self, from: request.body)
                return .json(try desktopRouteApprovals.propose(proposal, instance: agentInputRequests.instance))
            } catch {
                return .text("Desktop route approval unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
            }
        }
        if request.method == "POST", request.path == "/api/network/desktop-route/create" {
            do {
                let proposal = try JSONDecoder().decode(DesktopRouteProposal.self, from: request.body)
                return .json(try await desktopRouteDirect.create(proposal, instance: agentInputRequests.instance))
            } catch {
                return .text("Desktop route setup unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
            }
        }
        if request.method == "GET", request.path.hasPrefix("/api/network/desktop-route/receipts/") {
            guard let id = UUID(uuidString: String(request.path.dropFirst("/api/network/desktop-route/receipts/".count))),
                  let receipt = desktopRouteApprovals.receipt(id) ?? desktopRouteDirect.receipt(id) else {
                return .text("Unknown receipt; do not retry automatically", status: 404, reason: "Not Found")
            }
            return .json(receipt)
        }
        if request.method == "POST", request.path == "/api/network/remote-peers" {
            struct Request: Decodable { let host: String }
            guard !peerDiscoveryInFlight,
                  let body = try? JSONDecoder().decode(Request.self, from: request.body),
                  PeerDiscovery.remoteArgumentsIfValid(host: body.host) else {
                return .text("Remote discovery unavailable", status: 409, reason: "Conflict")
            }
            peerDiscoveryInFlight = true
            defer { peerDiscoveryInFlight = false }
            return await Task.detached(priority: .utility) {
                do {
                    return RelaySidePanelHTTPResponse.json(try PeerDiscovery.remote(
                        host: body.host, helper: ".local/share/relay/peer-network/relay-peer-link"))
                } catch { return .text("Remote discovery failed", status: 503, reason: "Service Unavailable") }
            }.value
        }
        if request.method == "POST", request.path == "/api/network/request" {
            do {
                let proposal = try JSONDecoder().decode(PeerNetworkProposal.self, from: request.body)
                return .json(try peerNetworkApprovals.propose(proposal, instance: agentInputRequests.instance,
                                                            controller: .shared))
            } catch {
                return .text("Network approval unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
            }
        }
        if request.method == "GET", request.path.hasPrefix("/api/network/receipts/") {
            guard let id = UUID(uuidString: String(request.path.dropFirst("/api/network/receipts/".count))),
                  let receipt = peerNetworkApprovals.receipt(id) else {
                return .text("Unknown receipt; do not retry automatically", status: 404, reason: "Not Found")
            }
            return .json(receipt)
        }
        if request.method == "GET", request.path == "/api/network/local-peers" {
            guard !peerDiscoveryInFlight else {
                return .text("Discovery already running", status: 429, reason: "Too Many Requests")
            }
            guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("relay-peer-link") else {
                return .text("Peer helper unavailable", status: 503, reason: "Service Unavailable")
            }
            peerDiscoveryInFlight = true
            defer { peerDiscoveryInFlight = false }
            return await Task.detached(priority: .utility) {
                do { return RelaySidePanelHTTPResponse.json(try PeerDiscovery.local(executable: executable)) }
                catch { return .text("Local discovery unavailable; check the bundled helper", status: 503, reason: "Service Unavailable") }
            }.value
        }
        if request.method == "GET", request.path.hasPrefix("/api/input-receipts/") {
            guard let id = UUID(uuidString: String(request.path.dropFirst("/api/input-receipts/".count))),
                  let receipt = agentInputRequests.receipt(id) else {
                return .text("Receipt unavailable; do not retry execution automatically", status: 404, reason: "Not Found")
            }
            return .json(receipt)
        }

        if request.path == "/api/rich-content", request.method == "POST" {
            guard mcpWorkspaceGrant.permits(.layout),
                  let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = body["pane_id"] as? String, let uuid = UUID(uuidString: id),
                  let pane = workspace.panes[uuid],
                  let name = body["kind"] as? String,
                  let source = body["source"] as? String, source.utf8.count <= 262144 else {
                return .text("Invalid content or missing layout grant", status: 403, reason: "Forbidden")
            }
            if ["pdf", "svg", "png", "jpeg", "jpg"].contains(name) {
                guard source.utf8.count <= 4096, !source.isEmpty,
                      TerminalPathSyntax.pathExtension(source) == name else {
                    return .text("Artifact format must match path", status: 422, reason: "Unprocessable Content")
                }
                let profile = pane.profile
                let path = TerminalPathSyntax.resolving(source, against: pane.directory ?? "/")
                do {
                    let bytes = try await RemoteArtifactLoader.load(path: path, profile: profile)
                    guard workspace.panes[uuid] === pane, pane.profile == profile else {
                        return .text("Pane changed during load", status: 409, reason: "Conflict")
                    }
                    let artifact = PaneArtifact(remotePath: path, data: bytes)
                    guard artifact.isPDF || artifact.image != nil else {
                        return .text("Unsupported image", status: 422, reason: "Unprocessable Content")
                    }
                    if RelayPreferences.shared.artifactPresentation == .inline {
                        guard pane.runtime.displayInlineArtifact(path: path, data: bytes) else {
                            return .text("Inline preview unavailable", status: 422, reason: "Unprocessable Content")
                        }
                    } else {
                        pane.receivedArtifact(path: path, data: bytes)
                        pane.richContentRequested = true
                    }
                    return .json(["status": "published", "pane_id": id, "kind": name])
                } catch { return .text("Artifact could not be loaded", status: 422, reason: "Unprocessable Content") }
            }
            guard let kind = RelaySurfaceContent.Kind(rawValue: name), [.diagram, .equation, .markdown].contains(kind) else {
                return .text("Unsupported format", status: 422, reason: "Unprocessable Content")
            }
            let content = RelaySurfaceContent(kind: kind, text: source)
            do { try content.validate() }
            catch { return .text("Unsupported content", status: 422, reason: "Unprocessable Content") }
            pane.richContents = [content]
            pane.richContentExplicit = true
            pane.richContentRequested = true
            return .json(["status": "published", "pane_id": id, "kind": name])
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
        case ("GET", "agent-binding"):
            // Background viewers can detach while their durable worker and
            // agent remain live. The host reader proves their native identity;
            // a renderer's connection flag is not an agent identity fence.
            guard let pane = workspace.panes[paneID], pane.contentKind == .terminal else {
                return .text("Exact terminal pane required", status: 409, reason: "Conflict")
            }
            let profile = pane.profile
            do {
                let command = RelayHostExecution.daemonCommand(profile: profile,
                    arguments: ["agent-binding", paneID.uuidString.lowercased()])
                let result = try await RelayHostExecution.capture(profile: profile, command: command,
                    timeout: 10, maximumBytes: 65_536)
                guard workspace.panes[paneID] === pane, pane.profile == profile else {
                    return .text("Pane or host changed during binding observation", status: 409, reason: "Conflict")
                }
                guard result.exitCode == 0 else {
                    let reason = String(String(decoding: result.stderr, as: UTF8.self).prefix(2_048))
                    return try .jsonObject(["pane_id": paneID.uuidString.lowercased(),
                        "status": "unavailable", "reason": reason, "binding": NSNull()])
                }
                guard let binding = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
                      binding["version"] as? Int == 1,
                      let producer = binding["producer"] as? [String: Any],
                      producer["pane_id"] as? String == paneID.uuidString.lowercased() else {
                    return .text("Binding reader returned mismatched evidence", status: 409, reason: "Conflict")
                }
                return try .jsonObject(["pane_id": paneID.uuidString.lowercased(),
                    "status": "bound", "binding": binding])
            } catch {
                return .text("Binding observation unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
            }
        case ("GET", "r-status"):
            do { return try .jsonObject(rAutomation.sessionStatus(paneID: paneID, workspace: workspace)) }
            catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        case ("POST", "editor-selection"), ("POST", "r-run-selection"), ("POST", "r-run-file"), ("POST", "r-run-project-file"),
             ("POST", "r-authorize"), ("POST", "r-run"), ("POST", "r-result"), ("POST", "r-pause"):
            do {
                guard let fields = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                      fields["instance"] as? String == agentInputRequests.instance.uuidString.lowercased() else {
                    throw PluginError.invalid("Rediscover the current Relay instance")
                }
                let operation = String(parts[3])
                if operation == "r-pause" { return .json(rAutomation.pause(paneID)) }
                guard let idText = fields["request_id"] as? String, let id = UUID(uuidString: idText) else {
                    throw PluginError.invalid("A request UUID is required")
                }
                if operation == "r-result" {
                    if let authorization = rAutomation.authorizationReceipt(id) { return .json(authorization) }
                    return try .jsonObject(await rAutomation.result(paneID: paneID, id: id, workspace: workspace))
                }
                if operation == "r-run-project-file" {
                    guard let expected = fields["expected_session"] as? String,
                          let path = fields["path"] as? String, let sha256 = fields["sha256"] as? String else {
                        throw PluginError.invalid("Exact project path, SHA-256 and R session are required")
                    }
                    return .json(try await rAutomation.executeProjectFile(paneID: paneID, expected: expected,
                        id: id, path: path, sha256: sha256, workspace: workspace))
                }
                if operation == "editor-selection" || operation == "r-run-selection" || operation == "r-run-file" {
                    guard let editor = workspace.panes[paneID], editor.contentKind == .editor,
                          let document = fields["document_id"] as? String,
                          let revision = fields["revision"] as? String,
                          let range = (fields["range"] as? [String: Int]) ?? (operation == "r-run-file" ? editor.editorRuntime.fullDocumentRange() : nil) else {
                        throw PluginError.invalid("Exact editor document, revision and range are required")
                    }
                    guard operation == "editor-selection" || !editor.editorRuntime.isDirty else {
                        throw PluginError.invalid("Agent execution cannot use the human's unsaved draft")
                    }
                    let selection = try await editor.editorRuntime.selectForMCP(document: document, revision: revision, range: range, verifyDisk: operation != "editor-selection")
                    if operation == "editor-selection" { return try .jsonObject(selection) }
                    guard workspace.panes[paneID] === editor,
                          let parent = editor.remoteParentSessionID.flatMap(UUID.init(uuidString:)),
                          let expected = fields["expected_session"] as? String,
                          let code = selection["code"] as? String else {
                        throw PluginError.invalid("The linked R console is unavailable")
                    }
                    let sourceData = try JSONSerialization.data(withJSONObject: selection["source"] as Any)
                    let source = try JSONDecoder().decode(RExecutionSource.self, from: sourceData)
                    return .json(try await rAutomation.execute(paneID: parent, expected: expected, id: id, code: code, workspace: workspace, direct: true, source: source))
                }
                guard let expected = fields["expected_session"] as? String else {
                    throw PluginError.invalid("Exact R session identity is required")
                }
                if operation == "r-authorize" {
                    return .json(try await rAutomation.authorize(paneID: paneID, expected: expected, id: id, workspace: workspace))
                }
                guard let code = fields["code"] as? String else { throw PluginError.invalid("R code is required") }
                return .json(try await rAutomation.execute(paneID: paneID, expected: expected, id: id, code: code, workspace: workspace, direct: true))
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        case ("POST", "editor-edit"), ("POST", "editor-save"), ("POST", "editor-receipt"):
            do {
                guard let fields = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                      fields["instance"] as? String == agentInputRequests.instance.uuidString.lowercased(),
                      let idText = fields["request_id"] as? String, let id = UUID(uuidString: idText),
                      let editor = workspace.panes[paneID], editor.contentKind == .editor else {
                    throw PluginError.invalid("Exact instance, editor and request identity required")
                }
                if String(parts[3]) == "editor-receipt" {
                    guard let receipt = editor.editorRuntime.mcpEdits.receipt(id) else {
                        throw PluginError.invalid("Unknown editor receipt; do not retry automatically")
                    }
                    return try .jsonObject(receipt)
                }
                guard let document = fields["document_id"] as? String,
                      let revision = fields["revision"] as? String else {
                    throw PluginError.invalid("Exact document and revision required")
                }
                return try .jsonObject(editor.editorRuntime.proposeMCPEdit(id: id, document: document,
                    revision: revision, range: fields["range"] as? [String: Int],
                    text: fields["text"] as? String, saving: String(parts[3]) == "editor-save"))
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        case ("GET", "editor"):
            guard let pane = workspace.panes[paneID], pane.contentKind == .editor else {
                return .text("Editor pane not found", status: 404, reason: "Not Found")
            }
            return .json(pane.editorRuntime.controlSnapshot())
        case ("POST", "r-snapshot"):
            guard let fields = try? JSONDecoder().decode([String: String].self, from: request.body),
                  Set(fields.keys) == Set(["relative_root", "request_id"]),
                  let root = fields["relative_root"], root.utf8.count <= 1024,
                  let id = fields["request_id"], id == "session" || UUID(uuidString: id) != nil,
                  let pane = workspace.panes[paneID], let directory = pane.directory else {
                return .text("Invalid R snapshot request", status: 400, reason: "Bad Request")
            }
            do {
                let scope = try PluginScope(paneID: paneID, profile: pane.profile, root: directory)
                let relative = root + "/" + (id == "session" ? "session.json" : id.lowercased() + "/result.json")
                _ = try scope.editorPath(relative)
                let snapshot = try await PluginOperationRunner.run(.artifacts, scope: scope, path: relative)
                guard workspace.panes[paneID] === pane, pane.profile == scope.profile,
                      let bytes = snapshot.verifiedBytes, bytes.count <= 2 << 20 else {
                    return .text("Snapshot unavailable", status: 409, reason: "Conflict")
                }
                return .json(["pane_id": paneID.uuidString.lowercased(), "snapshot": String(decoding: bytes, as: UTF8.self), "live": "false"])
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        case ("POST", "input-request"):
            guard let proposal = try? JSONDecoder().decode(AgentInputProposal.self, from: request.body),
                  let pane = workspace.panes[paneID], workspace.activePaneID == paneID else {
                return .text("Invalid request or missing pane", status: 400, reason: "Bad Request")
            }
            do {
                let receipt = try agentInputRequests.propose(proposal, pane: pane) { [weak workspace, weak pane] in
                    guard let pane else { return false }
                    return workspace?.panes[paneID] === pane && workspace?.activePaneID == paneID
                }
                return .json(receipt)
            } catch {
                return .text(error.localizedDescription, status: 409, reason: "Conflict")
            }
        case ("POST", "message"):
            guard mcpWorkspaceGrant.permits(.input) else {
                return .text("Pane messaging requires existing terminal input permission", status: 403, reason: "Forbidden")
            }
            do {
                let callerToken = request.headers["x-relay-caller-token"]
                // No source pane: only a registered, unpaused caller may send, as itself.
                // A legacy or unknown credential keeps the pane requirement below.
                if !RelayCallerSender.namesSourcePane(request.body) {
                    if RelayCallerSender.namesSession(request.body) {
                        return .text(RelayCallerSender.sessionRefusal, status: 409, reason: "Conflict")
                    }
                    guard let submission = RelayCallerSender.Submission.decode(request.body) else {
                        return .text("A pane-less message carries only messageID and text, and a registered caller credential", status: 409, reason: "Conflict")
                    }
                    let sender = try RelayCallerSender.resolve(token: callerToken, control: callerControl)
                    let target = workspace.panes[paneID]
                    let result = try await paneMessaging.sendAsCaller(messageID: submission.messageID, text: submission.text,
                        sender: sender, targetID: paneID, workspace: workspace)
                    if RelayPromptProvenanceLog.messageMayHaveReachedPane(result), workspace.panes[paneID] === target {
                        target?.promptProvenance.programmaticSubmit(source: "pane_message",
                            fingerprint: RelayPromptFingerprint(submission.text), messageID: submission.messageID.uuidString,
                            consumesInputLine: false)
                    }
                    return try .jsonObject(result)
                }
                let input = try JSONDecoder().decode(RelayPaneMessaging.Request.self, from: request.body)
                let submittingClientID = try callerControl.identity(token: callerToken)
                // A peer message is programmatic input to the target, never typing.
                // relayd writes it to the native inbox, not the input line, so desktop
                // counting keeps running: keys typed during the awaited send count.
                // The record is matched by message ID, not by timing.
                let target = workspace.panes[paneID]
                let result = try await paneMessaging.send(input, targetID: paneID, workspace: workspace,
                    submittingClientID: submittingClientID, callerToken: callerToken)
                if RelayPromptProvenanceLog.messageMayHaveReachedPane(result), workspace.panes[paneID] === target {
                    target?.promptProvenance.programmaticSubmit(source: "pane_message",
                        fingerprint: RelayPromptFingerprint(input.text), messageID: input.messageID.uuidString,
                        consumesInputLine: false)
                }
                return try .jsonObject(result)
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        case ("POST", "input-recover-shell"):
            guard mcpWorkspaceGrant.permits(.input) else {
                return .text("Shell recovery requires existing terminal input permission", status: 403, reason: "Forbidden")
            }
            guard let input = try? JSONDecoder().decode(RelayShellRecoveryInput.self, from: request.body),
                  input.instance == agentInputRequests.instance, input.isValid,
                  let pane = workspace.panes[paneID], pane.contentKind == .terminal else {
                return .text("Invalid shell recovery target", status: 409, reason: "Conflict")
            }
            if let prior = shellRecoveryRequests[input.requestID] {
                guard prior.0 == paneID, prior.1 == input, let result = shellRecoveryResults[input.requestID] else {
                    return .text("Conflicting shell recovery request", status: 409, reason: "Conflict")
                }
                return .json(result)
            }
            guard shellRecoveryRequests.count < 64 else {
                return .text("Shell recovery receipt limit reached", status: 409, reason: "Conflict")
            }
            shellRecoveryRequests[input.requestID] = (paneID, input)
            shellRecoveryResults[input.requestID] = ["status": "checking_owner", "paneID": paneID.uuidString.lowercased()]
            let sent = await pane.runtime.recoverCommandInRetainedShell(input)
            let result = ["status": sent ? "submitted_outcome_unknown" : "not_sent", "paneID": paneID.uuidString.lowercased()]
            shellRecoveryResults[input.requestID] = result
            return .json(result)
        case ("POST", "codex-resume"):
            guard mcpWorkspaceGrant.permits(.input), let caller,
                  let input = try? JSONDecoder().decode(RelayCodexPaneResumeRequest.self, from: request.body),
                  input.instance == agentInputRequests.instance,
                  let pane = workspace.panes[paneID] else {
                return .text("Invalid resume target, instance or input grant", status: 409, reason: "Conflict")
            }
            do {
                let receipt = try RelayCodexPaneResume.shared.start(input, pane: pane, workspace: workspace) { [weak self, weak workspace, weak pane] in
                    guard let self, let workspace, let pane else { return false }
                    return self.mcpWorkspaceGrant.permits(.input) && self.callerControl.permitted(caller) && workspace.panes[paneID] === pane
                }
                return try .jsonObject(receipt.object())
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        case ("POST", "codex-resume-receipt"):
            guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: String],
                  let text = body["requestID"], let id = UUID(uuidString: text),
                  let receipt = RelayCodexPaneResume.shared.receipt(id, paneID: paneID) else {
                return .json(["state": "unknown", "detail": "No original receipt found. Do not replay an uncertain resume."])
            }
            return (try? .jsonObject(receipt.object())) ?? .text("Receipt encoding failed", status: 500, reason: "Internal Server Error")
        case ("GET", "monitoring-usage"):
            guard let pane = workspace.panes[paneID], pane.profile.backend == .relay else {
                return .text("Host target unavailable", status: 409, reason: "Conflict")
            }
            do {
                let profile = pane.profile
                let request = RelayHostRotationTextRPC.Request(operation: .status)
                let data = try await RelayHostRotationTextRPC.sendHost(request, profile: profile)
                guard workspace.panes[paneID] === pane, pane.profile == profile,
                      let status = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .text("Host changed during usage read", status: 409, reason: "Conflict")
                }
                let allowed = Set(["day", "month", "requests_today", "charged_today_microusd", "charged_month_microusd", "purpose_usage", "cost_basis"])
                var result = status.filter { allowed.contains($0.key) }
                result["host"] = profile.kind == .local ? "This Mac" : profile.host
                result["observed_at"] = ISO8601DateFormatter().string(from: Date())
                result["cost_basis"] = "conservative_journal_charge_not_provider_invoice"
                return try .jsonObject(result)
            } catch { return .text(error.localizedDescription, status: 409, reason: "Conflict") }
        case ("GET", "terminal-edit-state"):
            guard let pane = workspace.panes[paneID] else { return .text("Pane not found", status: 404, reason: "Not Found") }
            var state = await pane.runtime.terminalEditState()
            state["instance"] = agentInputRequests.instance.uuidString
            return .json(state)
        case ("POST", "terminal-edit"):
            guard mcpWorkspaceGrant.permits(.input) else {
                return .text("Terminal editing requires the terminal input grant", status: 403, reason: "Forbidden")
            }
            guard let input = RelayTerminalEditRequest.decode(request.body),
                  input.instance == agentInputRequests.instance, input.isValid,
                  let pane = workspace.panes[paneID], let caller,
                  pane.contentKind == .terminal, pane.connectionState == .connected else {
                return .text("Invalid or stale terminal editing request", status: 409, reason: "Conflict")
            }
            switch terminalEditReceipts.begin(pane: paneID, request: input) {
            case .replay(let status): return .json(["status": status, "pane_id": paneID.uuidString.lowercased()])
            case .conflict: return .text("Conflicting terminal edit request ID", status: 409, reason: "Conflict")
            case .full: return .text("Terminal edit receipt limit reached", status: 409, reason: "Conflict")
            case .admitted: break
            }
            let status = await pane.runtime.sendTerminalEdit(input) { [weak self, weak workspace, weak pane] in
                guard let self, let workspace, let pane else { return false }
                return self.mcpWorkspaceGrant.permits(.input) && self.callerControl.permitted(caller) &&
                    workspace.panes[paneID] === pane
            }
            terminalEditReceipts.finish(input.requestID, status: status)
            return .json(["status": status, "pane_id": paneID.uuidString.lowercased(),
                "note": "input_submitted means transport submission, not command completion. Never retry uncertain input."])
        case ("POST", "input-direct"):
            guard mcpWorkspaceGrant.permits(.input) else {
                return .text("MCP terminal input is not granted", status: 403, reason: "Forbidden")
            }
            guard let proposal = try? JSONDecoder().decode(AgentInputProposal.self, from: request.body),
                  proposal.instance == agentInputRequests.instance, proposal.isValid,
                  let pane = workspace.panes[paneID], pane.contentKind == .terminal,
                  pane.connectionState == .connected else {
                return .text("Invalid or unavailable terminal input target", status: 409, reason: "Conflict")
            }
            if let old = directInputRequests[proposal.requestID] {
                guard old.0 == paneID, old.1 == proposal,
                      let result = directInputResults[proposal.requestID] else {
                    return .text("Conflicting terminal input request ID", status: 409, reason: "Conflict")
                }
                return .json(result)
            }
            guard directInputRequests.count < 256 else {
                return .text("Terminal input receipt limit reached", status: 409, reason: "Conflict")
            }
            directInputRequests[proposal.requestID] = (paneID, proposal)
            // Handle for relay_wait_for_command: command starts the shell had
            // reported before this input, so only a command started after it
            // (not one already running) can answer the wait. Read-only.
            let commandGeneration = String(pane.runtime.commandWaitContext.observation.executions)
            directInputResults[proposal.requestID] = ["status": "submitted_outcome_unknown", "paneID": paneID.uuidString.lowercased(),
                                                      "commandGeneration": commandGeneration]
            if let expected = proposal.expectedInputRevision {
                // Assistant-originated: fenced against a user draft or new input.
                let outcome = await pane.runtime.sendAssistantApprovedText(proposal.text, expectedInputRevision: expected)
                directInputResults[proposal.requestID] = ["status": outcome.rawValue, "paneID": paneID.uuidString.lowercased(),
                                                          "commandGeneration": commandGeneration]
                return .json(directInputResults[proposal.requestID]!)
            }
            if pane.runtime.sendSidePanelPrompt(proposal.text) {
                return .json(directInputResults[proposal.requestID]!)
            }
            directInputResults[proposal.requestID] = ["status": "unavailable", "paneID": paneID.uuidString.lowercased()]
            return .json(directInputResults[proposal.requestID]!)
        case ("POST", "capacity-action"):
            guard mcpWorkspaceGrant.permits(.input) else { return .text("MCP terminal input is not granted", status: 403, reason: "Forbidden") }
            guard let input = try? RelayCapacityActionRequest.decode(request.body), input.instance == agentInputRequests.instance,
                  let pane = workspace.panes[paneID], pane.contentKind == .terminal, pane.profile.backend == .relay, pane.connectionState == .connected else {
                return .text("Invalid capacity action or unavailable target", status: 409, reason: "Conflict")
            }
            switch capacityActionReceipts.begin(pane: paneID, request: input, expectedInstance: agentInputRequests.instance, inputGranted: mcpWorkspaceGrant.permits(.input)) {
            case .admitted: break
            case .result(let result): return .json(result)
            case .refused(let reason): return .text(reason, status: 409, reason: "Conflict")
            }
            do {
                let current = try await RelayCapacityManagementCoordinator.shared.read(pane)
                let operation = "capacity_" + input.action
                let value = try await RelayCapacityManagement.send(.init(operation: operation,
                    id: input.requestID.uuidString.replacingOccurrences(of: "-", with: "").lowercased(), expectedRevision: current.revision,
                    paneId: paneID.uuidString.lowercased(), targetAccount: input.targetAccount), profile: pane.profile)
                capacityActionReceipts.finish(pane: paneID, requestID: input.requestID, result: ["status": value.state, "reason": value.reason, "ready": String(value.ready), "paneID": paneID.uuidString.lowercased()])
            } catch { capacityActionReceipts.finish(pane: paneID, requestID: input.requestID, result: ["status": "held_or_outcome_unknown", "reason": String(error.localizedDescription.prefix(240)), "paneID": paneID.uuidString.lowercased()]) }
            return .json(capacityActionReceipts.result(for: input.requestID)!)
        case ("GET", "installed-update-receipt"):
            guard let input = try? RelayInstalledUpdateRequest.decode(request.body),
                  let result = installedUpdateReceipts.result(pane: paneID, request: input, instance: agentInputRequests.instance) else {
                return .text("Unknown receipt or stale app instance; do not replay", status: 409, reason: "Conflict")
            }
            return .json(result)
        case ("POST", "installed-update"):
            guard mcpWorkspaceGrant.permits(.input) else {
                return .text("MCP terminal input is not granted", status: 403, reason: "Forbidden")
            }
            guard let input = try? RelayInstalledUpdateRequest.decode(request.body),
                  input.instance == agentInputRequests.instance,
                  let pane = workspace.panes[paneID], pane.contentKind == .terminal,
                  pane.profile.backend == .relay, pane.connectionState == .connected else {
                return .text("Invalid or unavailable installed update target", status: 409, reason: "Conflict")
            }
            switch installedUpdateReceipts.begin(pane: paneID, request: input,
                instance: agentInputRequests.instance, granted: mcpWorkspaceGrant.permits(.input)) {
            case .existing(let result): return .json(result)
            case .refused: return .text("Conflicting request or receipt limit", status: 409, reason: "Conflict")
            case .admitted: break
            }
            Task { @MainActor [weak self, weak pane, weak workspace] in
                guard let self, let pane, let workspace else { return }
                let profile = pane.profile
                let result: RelayPaneHealthJSON
                var actionSubmitted = false
                do {
                    let proof = try await RelayAgentMaintenanceReader.inspect(pane)
                    guard workspace.panes[paneID] === pane, pane.profile == profile else {
                        throw RelayHostRotationRPC.Failure.changedConnection
                    }
                    if RelayInstalledUpdateScreenRefresh.admits(proof, paneID: paneID, pane: pane) {
                        // A hidden pane whose saved screen was cut short at
                        // restore gets one fresh screen, as if it were shown,
                        // before its prompt is read for this request.
                        _ = await pane.runtime.refreshHiddenScreenBaseForInstalledUpdate()
                        await pane.runtime.prepareAgentMaintenancePromptProof()
                        guard workspace.panes[paneID] === pane, pane.profile == profile else {
                            throw RelayHostRotationRPC.Failure.changedConnection
                        }
                    }
                    let facts = RelayPaneHealthFacts.read(pane, proof: proof)
                    if proof.valid(for: paneID), RelayAgentMaintenancePolicy.installedImageVerified(proof) {
                        result = .object(["state": .string("already_current"), "pane": facts.value])
                    } else if !facts.allowedActions.contains("apply_update") || RelayPreferences.shared.shepherd.enabled {
                        result = .object(["state": .string("held"), "message": .string("Fresh native evidence or the active coordinator holds this update."), "pane": facts.value])
                    } else {
                        actionSubmitted = true
                        let native = await RelayAgentMaintenance.shared.performHaikuTool("apply_installed_update",
                            pane: pane, workspace: workspace, evidenceID: facts.evidenceID,
                            operationID: input.requestID.uuidString.lowercased(), toolID: "mcp-installed-update")
                        if ["verified", "already_healthy"].contains(native["state"]?.string ?? "") {
                            let after = try await RelayAgentMaintenanceReader.inspect(pane)
                            if workspace.panes[paneID] === pane, pane.profile == profile,
                               RelayInstalledUpdatePostcondition.verified(before: proof, after: after, pane: paneID) {
                                result = .object(["state": .string("verified"),
                                    "pane": RelayPaneHealthFacts.read(pane, proof: after).value])
                            } else {
                                result = .object(["state": .string("verification_unknown"),
                                    "message": .string("The original conversation and current installed image could not both be verified; no retry was submitted.")])
                            }
                        } else { result = native }
                    }
                } catch {
                    result = .object(["state": .string(actionSubmitted ? "verification_unknown" : "held"),
                        "message": .string(actionSubmitted ?
                            "The native result could not be verified; do not replay the update." :
                            "Native identity inspection is unavailable; no update was submitted.")])
                }
                self.installedUpdateReceipts.finish(input.requestID, result: result)
            }
            return .json(installedUpdateReceipts.result(pane: paneID, request: input, instance: agentInputRequests.instance)!)
        case ("POST", "context-rotation"):
            // Same one-time terminal input grant as relay_send_command. Pausing is
            // always allowed; enabling never overrides a human takeover, which
            // only the user can lift from the Context management panel.
            guard mcpWorkspaceGrant.permits(.input) else {
                return .text("MCP terminal input is not granted", status: 403, reason: "Forbidden")
            }
            guard let input = try? JSONDecoder().decode(RelayContextRotationRequest.self, from: request.body),
                  input.instance == agentInputRequests.instance,
                  let pane = workspace.panes[paneID], pane.contentKind == .terminal,
                  pane.profile.backend == .relay, pane.connectionState == .connected else {
                return .text("Invalid or unavailable context rotation target", status: 409, reason: "Conflict")
            }
            if let old = contextRotationRequests[input.requestID] {
                guard old.0 == paneID, old.1 == input, let result = contextRotationResults[input.requestID] else {
                    return .text("Conflicting context rotation request ID", status: 409, reason: "Conflict")
                }
                return .json(result)
            }
            guard contextRotationRequests.count < 256 else {
                return .text("Context rotation receipt limit reached", status: 409, reason: "Conflict")
            }
            let target = paneID.uuidString.lowercased()
            contextRotationRequests[input.requestID] = (paneID, input)
            contextRotationResults[input.requestID] = ["status": "outcome_unknown", "paneID": target]
            var result = ["paneID": target]
            do {
                if input.enabled {
                    let current = try await pane.runtime.readHostRotationStatus()
                    guard current.state != "human_takeover" || input.permitsResumingHumanTakeover else {
                        result["status"] = "refused"
                        result["message"] = "Typing paused context rotation. An explicit user-requested resume_human_takeover is required to resume through MCP."
                        contextRotationResults[input.requestID] = result
                        return .json(result)
                    }
                }
                let status = try await pane.runtime.configureHostRotation(enabled: input.enabled)
                result["status"] = "applied"
                result["enabled"] = String(status.enabled == true)
                result["state"] = status.state
                if let generation = status.generation { result["generation"] = String(generation) }
                RelayDiagnostics.shared.record(category: "context-rotation", name: input.enabled ? "mcp-enable" : "mcp-pause",
                    details: ["pane_id": target, "state": status.state])
            } catch {
                result["status"] = "not_applied"
                result["message"] = String(error.localizedDescription.prefix(200))
            }
            contextRotationResults[input.requestID] = result
            return .json(result)
        case ("GET", "prompt-provenance"):
            // Read-only and content-free: counts, classes, lengths, hash prefixes.
            guard let pane = workspace.panes[paneID] else {
                return .text("Pane not found", status: 404, reason: "Not Found")
            }
            return .json(pane.promptProvenance.snapshot(paneID: paneID))
        case ("GET", "viewport"):
            guard let pane = workspace.panes[paneID], let text = await pane.runtime.backgroundViewportText(),
                  workspace.panes[paneID] === pane else {
                return .text("Viewport unavailable", status: 409, reason: "Conflict")
            }
            return .json(["pane_id": paneID.uuidString.lowercased(), "text": text, "scope": "visible_viewport_only"])
        case ("GET", "command-wait"):
            // Read-only, like the viewport: observes the shell's OSC 133
            // markers and never writes to the pane.
            guard let wait = TerminalCommandWait.Request.decode(request.body) else {
                return .text("Invalid command wait arguments", status: 400, reason: "Bad Request")
            }
            guard let pane = workspace.panes[paneID] else {
                return .text("Pane not found", status: 404, reason: "Not Found")
            }
            return await waitForCommand(pane, paneID: paneID, request: wait)
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
            guard let pane = workspace.panes[paneID], workspace.activePaneID == paneID else {
                return .text("Pane unavailable", status: 409, reason: "Conflict")
            }
            let proposal = AgentInputProposal(
                instance: prompt.instance ?? agentInputRequests.instance,
                requestID: prompt.requestID ?? UUID(), text: prompt.text
            )
            do {
                let receipt = try agentInputRequests.propose(proposal, pane: pane) { [weak workspace, weak pane] in
                    guard let pane else { return false }
                    return workspace?.panes[paneID] === pane && workspace?.activePaneID == paneID
                }
                return .json(receipt)
            } catch {
                return .text(error.localizedDescription, status: 409, reason: "Conflict")
            }
        default:
            return .text("Not found", status: 404, reason: "Not Found")
        }
    }

    /// Polls the pane's shell-reported command state until a final outcome or
    /// the request deadline. Never writes to the pane.
    private func waitForCommand(_ pane: PaneModel, paneID: UUID,
                                request: TerminalCommandWait.Request) async -> RelaySidePanelHTTPResponse {
        func paneState() -> TerminalCommandWait.PaneState {
            guard workspace?.panes[paneID] === pane else { return .unsupported("pane was closed or replaced") }
            guard pane.contentKind == .terminal else { return .unsupported("not a terminal pane") }
            guard pane.profile.backend == .relay else {
                return .unsupported("pane output does not pass through a Relay worker; command status is unavailable")
            }
            if pane.programExited { return .exited(code: pane.remoteExitCode) }
            // A lost transport is not a pane exit: the command may still run.
            return pane.connectionState == .connected && pane.phase != .exited ? .live : .disconnected
        }
        let start = pane.runtime.commandWaitContext
        let after = request.after ?? TerminalCommandWait.defaultAfter(start.observation)
        let deadline = ContinuousClock.now + .milliseconds(request.timeoutMilliseconds)
        while true {
            let current = pane.runtime.commandWaitContext
            let expired = ContinuousClock.now >= deadline || Task.isCancelled
            if let outcome = TerminalCommandWait.decide(current.observation, after: after, pane: paneState(),
                                                        producerChanged: current.producer != start.producer,
                                                        deadline: expired) {
                do { return try .jsonObject(TerminalCommandWait.json(outcome, paneID: paneID, after: after)) }
                catch { return .text("Command wait result unavailable", status: 500, reason: "Internal Server Error") }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}


/// The Relay assistant's Change actions enter exactly where an MCP request
/// authenticated with the installation credential does: `route()` applies the
/// caller pause, durable caller audit and every handler's own grant checks.
extension RelaySidePanelServer: RelayAssistantActionExecutor {
    var instance: UUID? { agentInputRequests.instance }

    func permits(_ capability: MCPWorkspaceCapability) -> Bool { mcpWorkspaceGrant.permits(capability) }

    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        let request = RelaySidePanelHTTPRequest(method: method, path: path,
            headers: ["x-relay-token": token, "content-type": "application/json"], body: body)
        let response = await route(request, assistantIdentity: true)
        return (response.status, response.body)
    }

    /// Called only after Miko policy admission (autonomous or a one-shot card).
    /// Network clients cannot set this flag; account-move route checks still run.
    func performMiko(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        let request = RelaySidePanelHTTPRequest(method: method, path: path,
            headers: ["x-relay-token": token, "content-type": "application/json"], body: body)
        let response = await route(request, assistantIdentity: true, assistantActionApproved: true)
        return (response.status, response.body)
    }
}
