import Foundation

struct RelayStatus: Sendable {
    let state: String
    let exitCode: Int?
    let message: String?
    let outputReset: Bool
    let eventReset: Bool
    let capabilities: [String]

    init(
        state: String,
        exitCode: Int? = nil,
        message: String? = nil,
        outputReset: Bool = false,
        eventReset: Bool = false,
        capabilities: [String] = []
    ) {
        self.state = state
        self.exitCode = exitCode
        self.message = message
        self.outputReset = outputReset
        self.eventReset = eventReset
        self.capabilities = capabilities
    }
}

struct RelayArtifact: Sendable {
    let path: String
    let data: Data
}

enum SSHConnectionFailureKind: Equatable, Sendable {
    case networkRoute
    case interrupted
    case authentication
    case remoteConfiguration
}

struct SSHConnectionFailure: Equatable, Sendable {
    let kind: SSHConnectionFailureKind
    let detail: String

    var shouldRetry: Bool {
        kind == .networkRoute || kind == .interrupted
    }

    var userMessage: String {
        switch kind {
        case .networkRoute:
            "VPN or network route unavailable."
        case .interrupted:
            "Connection interrupted."
        case .authentication:
            detail.isEmpty ? "SSH authentication needs attention." : detail
        case .remoteConfiguration:
            detail.isEmpty ? "The remote Relay installation needs attention." : detail
        }
    }

    static func diagnose(_ diagnostic: String, terminationStatus: Int32? = nil) -> SSHConnectionFailure {
        let normalized = diagnostic.lowercased()
        let routeFailures = [
            "network is unreachable",
            "no route to host",
            "operation timed out",
            "connection timed out",
            "could not resolve hostname",
            "nodename nor servname provided",
            "temporary failure in name resolution",
            "connection refused",
        ]
        if routeFailures.contains(where: normalized.contains) {
            return SSHConnectionFailure(kind: .networkRoute, detail: conciseDetail(diagnostic))
        }

        let authenticationFailures = [
            "permission denied",
            "host key verification failed",
            "remote host identification has changed",
            "too many authentication failures",
        ]
        if authenticationFailures.contains(where: normalized.contains) {
            return SSHConnectionFailure(kind: .authentication, detail: conciseDetail(diagnostic))
        }

        let configurationFailures = [
            "relayd: command not found",
            ".local/bin/relayd: no such file",
            "unknown command \"attach\"",
            "unknown command: node",
        ]
        if configurationFailures.contains(where: normalized.contains) {
            return SSHConnectionFailure(kind: .remoteConfiguration, detail: conciseDetail(diagnostic))
        }

        // After known permanent failures have been removed, an SSH exit is
        // recoverable. This includes a cleanly closed multiplexed master and
        // a process Relay intentionally restarts to retransmit queued input.
        _ = terminationStatus
        return SSHConnectionFailure(kind: .interrupted, detail: conciseDetail(diagnostic))
    }

    private static func conciseDetail(_ diagnostic: String) -> String {
        let lines = diagnostic
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("** WARNING:") }
        return String((lines.last ?? "").prefix(220))
    }
}

final class RelayRemoteTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var writer: (any RelayFrameWriting)?
    private var nodeChannel: RelayNodeChannel?
    private var detached = false
    private var lastSequence: UInt64 = 0
    private var lastEventSequence: UInt64 = 0
    private var reconnectAttempt = 0
    private var reconnectScheduled = false
    private var inputBacklog = Data()
    private var latestResize: (UInt16, UInt16)?
    private let inputClientID = RelayClientIdentity.id
    private var nextInputSequence: UInt64 = 0
    private var pendingInputs: [UInt64: Data] = [:]
    private var pendingInputBytes = 0
    private var inputOverflowed = false
    private var attached = false
    private var supportsInputAcknowledgements = false
    private var sessionEnded = false

    deinit {
        nodeChannel?.close()
        process?.terminate()
    }

    func start(
        profile: ConnectionProfile,
        sessionID: String,
        parentSessionID: String?,
        workspaceSessionID: String?,
        tabID: String?,
        paneTitle: String,
        contentKind: String,
        onOutput: @escaping @Sendable (Data) -> Void,
        onStatus: @escaping @Sendable (RelayStatus) -> Void,
        onAgentEvent: @escaping @Sendable (Data) -> Void,
        onArtifact: @escaping @Sendable (RelayArtifact) -> Void,
        onDisconnect: @escaping @Sendable (String) -> Void,
        observeAgentsOnly: Bool = false
    ) {
        let context = RelayConnectionContext(
            profile: profile,
            sessionID: sessionID,
            parentSessionID: parentSessionID,
            workspaceSessionID: workspaceSessionID,
            tabID: tabID,
            paneTitle: paneTitle,
            contentKind: contentKind,
            onOutput: onOutput,
            onStatus: onStatus,
            onAgentEvent: onAgentEvent,
            onArtifact: onArtifact,
            onDisconnect: onDisconnect,
            observeAgentsOnly: observeAgentsOnly
        )
        lock.lock()
        detached = false
        lastSequence = 0
        lastEventSequence = 0
        reconnectAttempt = 0
        reconnectScheduled = false
        nextInputSequence = 0
        pendingInputs.removeAll(keepingCapacity: true)
        pendingInputBytes = 0
        inputOverflowed = false
        attached = false
        supportsInputAcknowledgements = false
        sessionEnded = false
        lock.unlock()
        connectMultiplexed(context)
    }

    private func connectMultiplexed(_ context: RelayConnectionContext) {
        let channel = RelayNodeTransportPool.shared.attach(
            profile: context.profile,
            sessionID: context.sessionID,
            onReady: { [weak self] channel in self?.openMultiplexed(context, channel: channel) },
            onFrame: { [weak self] frame in self?.receive(frame, context: context) },
            onDisconnect: { [weak self] failure in self?.nodeDisconnected(context, failure: failure) }
        )
        lock.lock()
        nodeChannel = channel
        writer = channel
        lock.unlock()
    }

    private func openMultiplexed(_ context: RelayConnectionContext, channel: RelayNodeChannel) {
        lock.lock()
        // RelayNodeConnection can already be ready when a second pane joins.
        // Its callback may therefore arrive before attach() returns and before
        // connectMultiplexed stores the channel. Adopt that same channel here
        // instead of dropping the only Hello handshake for this pane.
        if nodeChannel == nil {
            nodeChannel = channel
            writer = channel
        }
        guard !detached, nodeChannel === channel else {
            lock.unlock()
            return
        }
        let resumeSequence = lastSequence
        let resumeEventSequence = lastEventSequence
        attached = false
        writer = channel
        lock.unlock()
        var hello: [String: Any] = [
            "version": 1,
            "session_id": context.sessionID,
            "cols": 120,
            "rows": 36,
            "last_seq": resumeSequence,
            "last_event_seq": resumeEventSequence,
            "client_id": inputClientID.uuidString.lowercased(),
        ]
        if context.observeAgentsOnly {
            hello["observe_events"] = true
        } else {
            hello["parent_session_id"] = context.parentSessionID
            hello["workspace_id"] = context.workspaceSessionID
            hello["tab_id"] = context.tabID
            hello["pane_title"] = context.paneTitle
            hello["content_kind"] = context.contentKind
            if !context.profile.command.isEmpty { hello["command"] = context.profile.command }
        }
        let payload = (try? JSONSerialization.data(withJSONObject: hello.compactMapValues { $0 })) ?? Data()
        channel.writeAsync(type: .hello, payload: payload)
    }

    private func nodeDisconnected(_ context: RelayConnectionContext, failure: SSHConnectionFailure) {
        lock.lock()
        guard !detached, !sessionEnded else {
            lock.unlock()
            return
        }
        attached = false
        if failure.kind == .remoteConfiguration {
            let channel = nodeChannel
            nodeChannel = nil
            writer = nil
            lock.unlock()
            channel?.close()
            context.onStatus(RelayStatus(
                state: "compatibility_mode",
                message: "This host has an older relayd; using one SSH stream per pane until it is updated."
            ))
            connect(context)
            return
        }
        if !failure.shouldRetry {
            let channel = nodeChannel
            nodeChannel = nil
            writer = nil
            lock.unlock()
            channel?.close()
            context.onStatus(RelayStatus(state: "error", message: failure.userMessage))
            return
        }
        lock.unlock()
        let state = failure.kind == .networkRoute ? "waiting_for_network" : "reconnecting"
        context.onStatus(RelayStatus(
            state: state,
            message: failure.userMessage + " The shared node connection is retrying automatically."
        ))
    }

    private func receive(_ frame: RelayWireFrame, context: RelayConnectionContext) {
        switch frame.type {
        case .output:
            guard frame.payload.count >= 8 else { return }
            let sequence = frame.payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            lock.lock()
            lastSequence = max(lastSequence, sequence)
            lock.unlock()
            context.onOutput(Data(frame.payload.dropFirst(8)))
        case .status:
            guard let decoded = try? JSONDecoder().decode(StatusWirePayload.self, from: frame.payload) else { return }
            if decoded.outputReset == true || decoded.eventReset == true {
                lock.lock()
                if decoded.outputReset == true { lastSequence = 0 }
                if decoded.eventReset == true { lastEventSequence = 0 }
                lock.unlock()
            }
            if decoded.state == "attached" {
                let capabilities = decoded.capabilities ?? []
                let controlGranted = !capabilities.contains("input_lease_v1") || decoded.controlGranted == true
                if controlGranted {
                    didAttach(context: context, capabilities: capabilities)
                } else {
                    context.onStatus(RelayStatus(
                        state: "read_only",
                        message: "Another client currently controls input for this pane.",
                        outputReset: decoded.outputReset ?? false,
                        eventReset: decoded.eventReset ?? false,
                        capabilities: capabilities
                    ))
                    return
                }
            }
            if decoded.state == "exited" || decoded.state == "error" { markSessionEnded() }
            context.onStatus(RelayStatus(
                state: decoded.state, exitCode: decoded.exitCode, message: decoded.message,
                outputReset: decoded.outputReset ?? false, eventReset: decoded.eventReset ?? false,
                capabilities: decoded.capabilities ?? []
            ))
        case .ping:
            try? nodeChannel?.write(type: .pong)
        case .agentEvent:
            if let decoded = try? JSONDecoder().decode(EventWireEnvelope.self, from: frame.payload),
               let sequence = decoded.sequence {
                lock.lock()
                lastEventSequence = max(lastEventSequence, sequence)
                lock.unlock()
            }
            context.onAgentEvent(frame.payload)
        case .inputAck:
            if let acknowledgement = RelayWireFrame.parseInputAck(frame.payload), acknowledgement.clientID == inputClientID {
                lock.lock()
                if let removed = pendingInputs.removeValue(forKey: acknowledgement.sequence) {
                    pendingInputBytes = max(0, pendingInputBytes - removed.count)
                }
                lock.unlock()
            }
        case .artifact:
            if let artifact = RelayWireFrame.parseArtifact(frame.payload) { context.onArtifact(artifact) }
        default:
            return
        }
    }

    private func connect(_ context: RelayConnectionContext) {
        let ssh = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=~/.ssh/relay-%C",
        ]
        arguments += context.profile.sshConnectionArguments
        lock.lock()
        let resumeSequence = lastSequence
        let resumeEventSequence = lastEventSequence
        lock.unlock()
        if context.observeAgentsOnly {
            arguments += [
                "~/.local/bin/relayd", "observe",
                "--session", context.sessionID,
                "--last-seq", String(resumeSequence),
                "--last-event-seq", String(resumeEventSequence),
            ]
        } else {
            arguments += [
                "~/.local/bin/relayd", "attach",
                "--session", context.sessionID,
                "--cols", "120",
                "--rows", "36",
                "--last-seq", String(resumeSequence),
                "--last-event-seq", String(resumeEventSequence)
            ]
            if let parentSessionID = context.parentSessionID {
                arguments += ["--parent-session", parentSessionID]
            }
            if let workspaceSessionID = context.workspaceSessionID {
                arguments += ["--workspace", workspaceSessionID]
            }
            if let tabID = context.tabID {
                arguments += ["--tab", tabID]
            }
            arguments += ["--pane-title", context.paneTitle, "--content-kind", context.contentKind]
            if !context.profile.command.isEmpty {
                arguments += ["--command-b64", Data(context.profile.command.utf8).base64EncodedString()]
            }
        }
        ssh.arguments = arguments
        ssh.standardInput = input
        ssh.standardOutput = output
        ssh.standardError = errors

        let diagnostics = SSHDiagnosticBuffer()
        let stderrFinished = DispatchSemaphore(value: 0)
        ssh.terminationHandler = { [weak self] terminated in
            _ = stderrFinished.wait(timeout: .now() + .milliseconds(500))
            self?.connectionEnded(
                context,
                process: terminated,
                terminationStatus: terminated.terminationStatus,
                diagnostic: diagnostics.text
            )
        }

        lock.lock()
        process = ssh
        writer = RelayWireWriter(input.fileHandleForWriting)
        detached = false
        attached = false
        lock.unlock()

        do {
            try ssh.run()
        } catch {
            scheduleReconnect(context, failure: .diagnose(error.localizedDescription))
            return
        }

        DispatchQueue.global(qos: .utility).async {
            defer { stderrFinished.signal() }
            while let chunk = try? errors.fileHandleForReading.read(upToCount: 8 << 10), !chunk.isEmpty {
                diagnostics.append(chunk)
            }
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            do {
                while true {
                    let frame = try RelayWireFrame.read(from: output.fileHandleForReading)
                    switch frame.type {
                    case .output:
                        guard frame.payload.count >= 8 else { continue }
                        let sequence = frame.payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                        self?.lock.lock()
                        self?.lastSequence = max(self?.lastSequence ?? 0, sequence)
                        self?.lock.unlock()
                        context.onOutput(Data(frame.payload.dropFirst(8)))
                    case .status:
                        if let decoded = try? JSONDecoder().decode(StatusWirePayload.self, from: frame.payload) {
                            if decoded.outputReset == true || decoded.eventReset == true {
                                self?.lock.lock()
                                if decoded.outputReset == true { self?.lastSequence = 0 }
                                if decoded.eventReset == true { self?.lastEventSequence = 0 }
                                self?.lock.unlock()
                            }
                            if decoded.state == "attached" { self?.didAttach(context: context, capabilities: decoded.capabilities ?? []) }
                            if decoded.state == "exited" || decoded.state == "error" { self?.markSessionEnded() }
                            context.onStatus(RelayStatus(
                                state: decoded.state,
                                exitCode: decoded.exitCode,
                                message: decoded.message,
                                outputReset: decoded.outputReset ?? false,
                                eventReset: decoded.eventReset ?? false,
                                capabilities: decoded.capabilities ?? []
                            ))
                        }
                    case .ping:
                        try self?.writer?.write(type: .pong)
                    case .agentEvent:
                        if let decoded = try? JSONDecoder().decode(EventWireEnvelope.self, from: frame.payload),
                           let sequence = decoded.sequence {
                            self?.lock.lock()
                            self?.lastEventSequence = max(self?.lastEventSequence ?? 0, sequence)
                            self?.lock.unlock()
                        }
                        context.onAgentEvent(frame.payload)
                    case .inputAck:
                        if let acknowledgement = RelayWireFrame.parseInputAck(frame.payload),
                           acknowledgement.clientID == self?.inputClientID {
                            self?.lock.lock()
                            if let removed = self?.pendingInputs.removeValue(forKey: acknowledgement.sequence) {
                                self?.pendingInputBytes = max(0, (self?.pendingInputBytes ?? 0) - removed.count)
                            }
                            self?.lock.unlock()
                        }
                    case .artifact:
                        if let artifact = RelayWireFrame.parseArtifact(frame.payload) {
                            context.onArtifact(artifact)
                        }
                    default:
                        continue
                    }
                }
            } catch {
                // Process termination owns classification and retry. If the
                // framed stream itself becomes invalid, end SSH so its
                // termination handler can recover through the same path.
                if ssh.isRunning { ssh.terminate() }
            }
        }
    }

    private func markSessionEnded() {
        lock.lock()
        sessionEnded = true
        lock.unlock()
    }

    private func connectionEnded(
        _ context: RelayConnectionContext,
        process endedProcess: Process,
        terminationStatus: Int32,
        diagnostic: String
    ) {
        lock.lock()
        let isCurrent = process === endedProcess
        let shouldIgnore = detached || sessionEnded
        lock.unlock()
        guard isCurrent, !shouldIgnore else { return }

        let failure = SSHConnectionFailure.diagnose(diagnostic, terminationStatus: terminationStatus)
        if failure.shouldRetry {
            scheduleReconnect(context, failure: failure)
        } else {
            lock.lock()
            writer = nil
            process = nil
            attached = false
            lock.unlock()
            context.onStatus(RelayStatus(state: "error", exitCode: nil, message: failure.userMessage))
        }
    }

    private func didAttach(context: RelayConnectionContext, capabilities: [String]) {
        lock.lock()
        reconnectAttempt = 0
        reconnectScheduled = false
        attached = true
        supportsInputAcknowledgements = capabilities.contains("input_ack_v1")
        let backlog = inputBacklog
        inputBacklog.removeAll(keepingCapacity: true)
        let resize = latestResize
        let writer = self.writer
        var acknowledgedFrames = pendingInputs
        if supportsInputAcknowledgements, !backlog.isEmpty {
            nextInputSequence += 1
            pendingInputs[nextInputSequence] = backlog
            pendingInputBytes += backlog.count
            acknowledgedFrames[nextInputSequence] = backlog
        }
        let acknowledgementsEnabled = supportsInputAcknowledgements
        let overflowed = inputOverflowed
        inputOverflowed = false
        lock.unlock()
        if acknowledgementsEnabled {
            for (sequence, data) in acknowledgedFrames.sorted(by: { $0.key < $1.key }) {
                writer?.writeAsync(
                    type: .inputV2,
                    payload: RelayWireFrame.inputV2Payload(clientID: inputClientID, sequence: sequence, data: data)
                )
            }
        } else if !backlog.isEmpty {
            writer?.writeAsync(type: .input, payload: backlog)
        }
        if let (columns, rows) = resize { writeResize(columns: columns, rows: rows, using: writer) }
        if overflowed {
            context.onStatus(RelayStatus(
                state: "input_dropped",
                exitCode: nil,
                message: "Offline input reached 64 KiB; newer keystrokes were not queued."
            ))
        }
    }

    private func scheduleReconnect(_ context: RelayConnectionContext, failure: SSHConnectionFailure) {
        lock.lock()
        guard !detached, !reconnectScheduled else {
            lock.unlock()
            return
        }
        writer = nil
        process = nil
        attached = false
        reconnectScheduled = true
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        lock.unlock()

        let milliseconds = min(3_000, 150 * (1 << min(attempt - 1, 4)))
        let delay = milliseconds >= 1_000
            ? String(format: "%.1f", Double(milliseconds) / 1_000) + "s"
            : String(milliseconds) + "ms"
        let state = failure.kind == .networkRoute ? "waiting_for_network" : "reconnecting"
        context.onStatus(RelayStatus(
            state: state,
            exitCode: nil,
            message: failure.userMessage + " Retrying automatically in " + delay + "."
        ))
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.detached else {
                self.lock.unlock()
                return
            }
            self.reconnectScheduled = false
            self.lock.unlock()
            self.connect(context)
        }
    }

    func sendInput(_ data: Data) {
        lock.lock()
        let writer = self.writer
        let canSend = writer != nil && attached
        let acknowledged = supportsInputAcknowledgements
        var inputSequence: UInt64?
        var processToRestart: Process?
        if canSend && acknowledged && pendingInputBytes + data.count <= 64 << 10 {
            nextInputSequence += 1
            inputSequence = nextInputSequence
            pendingInputs[nextInputSequence] = data
            pendingInputBytes += data.count
        } else if canSend && acknowledged {
            if inputBacklog.count + data.count <= 64 << 10 {
                inputBacklog.append(data)
            } else {
                inputOverflowed = true
            }
            attached = false
            processToRestart = process
        } else if !canSend {
            if inputBacklog.count + data.count <= 64 << 10 {
                inputBacklog.append(data)
            } else {
                inputOverflowed = true
            }
        }
        lock.unlock()
        processToRestart?.terminate()
        if processToRestart != nil { return }
        guard canSend, let writer else { return }
        if let inputSequence {
            writer.writeAsync(
                type: .inputV2,
                payload: RelayWireFrame.inputV2Payload(clientID: inputClientID, sequence: inputSequence, data: data)
            )
        } else {
            writer.writeAsync(type: .input, payload: data)
        }
    }

    func sendResize(columns: UInt16, rows: UInt16) {
        lock.lock()
        latestResize = (columns, rows)
        let writer = self.writer
        lock.unlock()
        writeResize(columns: columns, rows: rows, using: writer)
    }

    private func writeResize(columns: UInt16, rows: UInt16, using writer: (any RelayFrameWriting)?) {
        var payload = Data()
        var cols = columns.bigEndian
        var lines = rows.bigEndian
        withUnsafeBytes(of: &cols) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &lines) { payload.append(contentsOf: $0) }
        writer?.writeAsync(type: .resize, payload: payload)
    }

    func detach() {
        lock.lock()
        detached = true
        attached = false
        lock.unlock()
        try? writer?.write(type: .detach)
        nodeChannel?.close()
        nodeChannel = nil
        process?.terminate()
        process = nil
        writer = nil
    }
}

final class SSHDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        if data.count < 64 << 10 {
            data.append(chunk.prefix((64 << 10) - data.count))
        }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}

private struct RelayConnectionContext: Sendable {
    let profile: ConnectionProfile
    let sessionID: String
    let parentSessionID: String?
    let workspaceSessionID: String?
    let tabID: String?
    let paneTitle: String
    let contentKind: String
    let onOutput: @Sendable (Data) -> Void
    let onStatus: @Sendable (RelayStatus) -> Void
    let onAgentEvent: @Sendable (Data) -> Void
    let onArtifact: @Sendable (RelayArtifact) -> Void
    let onDisconnect: @Sendable (String) -> Void
    let observeAgentsOnly: Bool
}

struct StatusWirePayload: Decodable {
    let state: String
    let exitCode: Int?
    let message: String?
    let capabilities: [String]?
    let outputReset: Bool?
    let eventReset: Bool?
    let controlGranted: Bool?

    enum CodingKeys: String, CodingKey {
        case state
        case exitCode = "exit_code"
        case message, capabilities
        case outputReset = "output_reset"
        case eventReset = "event_reset"
        case controlGranted = "control_granted"
    }
}

private struct EventWireEnvelope: Decodable {
    let sequence: UInt64?

    enum CodingKeys: String, CodingKey {
        case sequence = "relay_event_seq"
    }
}

enum RelayWireType: UInt8 {
    case hello = 1, input, resize, output, status, detach, ping, pong, agentEvent, artifact, inputAck, inputV2, hostEvent, workspaceState
}

struct RelayWireFrame {
    let type: RelayWireType
    let payload: Data

    static func read(from handle: FileHandle) throws -> RelayWireFrame {
        let header = try readExactly(5, from: handle)
        guard let type = RelayWireType(rawValue: header[0]) else { throw RelayWireError.invalidFrame }
        let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= 16 << 20 else { throw RelayWireError.invalidFrame }
        return RelayWireFrame(type: type, payload: try readExactly(Int(length), from: handle))
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        if count == 0 { return Data() }
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw RelayWireError.endOfStream
            }
            data.append(chunk)
        }
        return data
    }

    static func parseArtifact(_ payload: Data) -> RelayArtifact? {
        guard payload.count >= 4 else { return nil }
        let pathLength = payload.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard pathLength > 0, Int(pathLength) <= payload.count - 4 else { return nil }
        let pathData = payload.subdata(in: 4..<(4 + Int(pathLength)))
        guard let path = String(data: pathData, encoding: .utf8) else { return nil }
        return RelayArtifact(path: path, data: payload.subdata(in: (4 + Int(pathLength))..<payload.count))
    }

    static func inputV2Payload(clientID: UUID, sequence: UInt64, data: Data) -> Data {
        var payload = Data()
        var uuid = clientID.uuid
        withUnsafeBytes(of: &uuid) { payload.append(contentsOf: $0) }
        var bigEndianSequence = sequence.bigEndian
        withUnsafeBytes(of: &bigEndianSequence) { payload.append(contentsOf: $0) }
        payload.append(data)
        return payload
    }

    static func parseInputAck(_ payload: Data) -> (clientID: UUID, sequence: UInt64)? {
        guard payload.count == 24 else { return nil }
        let uuidBytes = payload.prefix(16)
        let uuid = uuidBytes.withUnsafeBytes { bytes -> uuid_t in
            let pointer = bytes.bindMemory(to: UInt8.self)
            return (
                pointer[0], pointer[1], pointer[2], pointer[3],
                pointer[4], pointer[5], pointer[6], pointer[7],
                pointer[8], pointer[9], pointer[10], pointer[11],
                pointer[12], pointer[13], pointer[14], pointer[15]
            )
        }
        let sequence = payload.dropFirst(16).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return (UUID(uuid: uuid), sequence)
    }

    static func hostEvent(sessionID: String, inner: RelayWireFrame) -> RelayWireFrame? {
        let session = Data(sessionID.utf8)
        guard !session.isEmpty, session.count <= Int(UInt16.max) else { return nil }
        var payload = Data()
        var length = UInt16(session.count).bigEndian
        withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
        payload.append(inner.type.rawValue)
        payload.append(session)
        payload.append(inner.payload)
        return RelayWireFrame(type: .hostEvent, payload: payload)
    }

    static func parseHostEvent(_ frame: RelayWireFrame) -> (sessionID: String, inner: RelayWireFrame)? {
        guard frame.type == .hostEvent, frame.payload.count >= 3 else { return nil }
        let length = frame.payload.prefix(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        guard length > 0, 3 + Int(length) <= frame.payload.count,
              let type = RelayWireType(rawValue: frame.payload[2]),
              let sessionID = String(data: frame.payload.subdata(in: 3..<(3 + Int(length))), encoding: .utf8) else {
            return nil
        }
        return (sessionID, RelayWireFrame(type: type, payload: frame.payload.subdata(in: (3 + Int(length))..<frame.payload.count)))
    }
}

private enum RelayWireError: Error { case invalidFrame, endOfStream }

protocol RelayFrameWriting: AnyObject, Sendable {
    func write(type: RelayWireType, payload: Data) throws
    func writeAsync(type: RelayWireType, payload: Data)
}

extension RelayFrameWriting {
    func write(type: RelayWireType) throws { try write(type: type, payload: Data()) }
    func writeAsync(type: RelayWireType) { writeAsync(type: type, payload: Data()) }
}

final class RelayWireWriter: RelayFrameWriting, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.relay.terminal-wire", qos: .userInteractive)

    init(_ handle: FileHandle) { self.handle = handle }

    func write(type: RelayWireType, payload: Data = Data()) throws {
        var header = Data([type.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: header)
        if !payload.isEmpty { try handle.write(contentsOf: payload) }
    }

    func writeAsync(type: RelayWireType, payload: Data = Data()) {
        queue.async { [weak self] in
            try? self?.write(type: type, payload: payload)
        }
    }
}
