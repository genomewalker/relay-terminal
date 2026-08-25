import Foundation

struct RelayStatus: Sendable {
    let state: String
    let exitCode: Int?
    let message: String?
}

struct RelayArtifact: Sendable {
    let path: String
    let data: Data
}

final class RelayRemoteTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var writer: RelayWireWriter?
    private var detached = false
    private var lastSequence: UInt64 = 0
    private var lastEventSequence: UInt64 = 0
    private var reconnectAttempt = 0
    private var reconnectScheduled = false
    private var inputBacklog = Data()
    private var latestResize: (UInt16, UInt16)?
    private let inputClientID = UUID()
    private var nextInputSequence: UInt64 = 0
    private var pendingInputs: [UInt64: Data] = [:]
    private var pendingInputBytes = 0
    private var inputOverflowed = false
    private var attached = false
    private var supportsInputAcknowledgements = false

    deinit {
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
        lock.unlock()
        connect(context)
    }

    private func connect(_ context: RelayConnectionContext) {
        let ssh = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            "-T",
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

        lock.lock()
        process = ssh
        writer = RelayWireWriter(input.fileHandleForWriting)
        detached = false
        attached = false
        lock.unlock()

        do {
            try ssh.run()
        } catch {
            scheduleReconnect(context, reason: error.localizedDescription)
            return
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
                            if decoded.state == "attached" { self?.didAttach(context: context, capabilities: decoded.capabilities ?? []) }
                            context.onStatus(RelayStatus(
                                state: decoded.state,
                                exitCode: decoded.exitCode,
                                message: decoded.message
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
                self?.lock.lock()
                let isCurrent = self?.process === ssh
                self?.lock.unlock()
                if isCurrent { self?.scheduleReconnect(context, reason: "SSH tunnel closed") }
            }
        }

        DispatchQueue.global(qos: .utility).async {
            var collected = Data()
            while let chunk = try? errors.fileHandleForReading.read(upToCount: 8 << 10), !chunk.isEmpty {
                collected.append(chunk)
            }
            // stderr is intentionally drained so SSH can never block. The
            // framed stream owns connection state and retry decisions.
            _ = collected
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

    private func scheduleReconnect(_ context: RelayConnectionContext, reason: String) {
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

        context.onStatus(RelayStatus(state: "reconnecting", exitCode: nil, message: reason))
        let milliseconds = min(3_000, 150 * (1 << min(attempt - 1, 4)))
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

    private func writeResize(columns: UInt16, rows: UInt16, using writer: RelayWireWriter?) {
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
        process?.terminate()
        process = nil
        writer = nil
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

private struct StatusWirePayload: Decodable {
    let state: String
    let exitCode: Int?
    let message: String?
    let capabilities: [String]?

    enum CodingKeys: String, CodingKey {
        case state
        case exitCode = "exit_code"
        case message, capabilities
    }
}

private struct EventWireEnvelope: Decodable {
    let sequence: UInt64?

    enum CodingKeys: String, CodingKey {
        case sequence = "relay_event_seq"
    }
}

private enum RelayWireType: UInt8 {
    case hello = 1, input, resize, output, status, detach, ping, pong, agentEvent, artifact, inputAck, inputV2
}

private struct RelayWireFrame {
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
}

private enum RelayWireError: Error { case invalidFrame, endOfStream }

private final class RelayWireWriter: @unchecked Sendable {
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
