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
    private var reconnectAttempt = 0
    private var reconnectScheduled = false
    private var inputBacklog = Data()
    private var latestResize: (UInt16, UInt16)?

    func start(
        profile: ConnectionProfile,
        sessionID: String,
        parentSessionID: String?,
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
        reconnectAttempt = 0
        reconnectScheduled = false
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
        lock.unlock()
        if context.observeAgentsOnly {
            arguments += [
                "~/.local/bin/relayd", "observe",
                "--session", context.sessionID,
                "--last-seq", String(resumeSequence),
            ]
        } else {
            arguments += [
                "~/.local/bin/relayd", "attach",
                "--session", context.sessionID,
                "--cols", "120",
                "--rows", "36",
                "--last-seq", String(resumeSequence)
            ]
            if let parentSessionID = context.parentSessionID {
                arguments += ["--parent-session", parentSessionID]
            }
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
                            if decoded.state == "attached" { self?.didAttach() }
                            context.onStatus(RelayStatus(
                                state: decoded.state,
                                exitCode: decoded.exitCode,
                                message: decoded.message
                            ))
                        }
                    case .ping:
                        try self?.writer?.write(type: .pong)
                    case .agentEvent:
                        context.onAgentEvent(frame.payload)
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

    private func didAttach() {
        lock.lock()
        reconnectAttempt = 0
        reconnectScheduled = false
        let backlog = inputBacklog
        inputBacklog.removeAll(keepingCapacity: true)
        let resize = latestResize
        let writer = self.writer
        lock.unlock()
        if !backlog.isEmpty { try? writer?.write(type: .input, payload: backlog) }
        if let (columns, rows) = resize { writeResize(columns: columns, rows: rows, using: writer) }
    }

    private func scheduleReconnect(_ context: RelayConnectionContext, reason: String) {
        lock.lock()
        guard !detached, !reconnectScheduled else {
            lock.unlock()
            return
        }
        writer = nil
        process = nil
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
        if writer == nil {
            inputBacklog.append(data)
            if inputBacklog.count > 64 << 10 { inputBacklog.removeFirst(inputBacklog.count - (64 << 10)) }
        }
        lock.unlock()
        guard let writer else { return }
        do {
            try writer.write(type: .input, payload: data)
        } catch {
            lock.lock()
            inputBacklog.append(data)
            lock.unlock()
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
        try? writer?.write(type: .resize, payload: payload)
    }

    func detach() {
        lock.lock()
        detached = true
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

    enum CodingKeys: String, CodingKey {
        case state
        case exitCode = "exit_code"
        case message
    }
}

private enum RelayWireType: UInt8 {
    case hello = 1, input, resize, output, status, detach, ping, pong, agentEvent, artifact
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
}

private enum RelayWireError: Error { case invalidFrame, endOfStream }

private final class RelayWireWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

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
}
