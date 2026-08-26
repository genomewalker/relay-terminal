import Darwin
import Dispatch
import Foundation

struct BridgeArguments {
    var host = ""
    var user = ""
    var port = 22
    var session = ""
    var parentSession = ""
    var command = ""

    static func parse() -> BridgeArguments? {
        var result = BridgeArguments()
        var index = 1
        let arguments = CommandLine.arguments
        while index < arguments.count {
            guard index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--host": result.host = value
            case "--user": result.user = value
            case "--port": result.port = Int(value) ?? 22
            case "--session": result.session = value
            case "--parent-session": result.parentSession = value
            case "--command": result.command = value
            default: return nil
            }
            index += 2
        }
        return result.host.isEmpty || result.session.isEmpty ? nil : result
    }

    var destination: String { user.isEmpty ? host : "\(user)@\(host)" }
}

enum RelayBridge {
    static func run() {
        guard let arguments = BridgeArguments.parse() else {
            message("relay-bridge: invalid connection arguments\r\n")
            exit(64)
        }

        let initialSize = terminalSize()
        let ssh = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var remoteArguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=2",
            "-o", "ServerAliveCountMax=2",
            // The application already multiplexes logical terminal channels.
            // Reusing an OpenSSH control master here can retain a dead TCP path
            // across VPN changes and make a reconnect look alive while no
            // protocol data moves.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-p", String(arguments.port),
            arguments.destination,
            "~/.local/bin/relayd", "attach",
            "--session", arguments.session,
            "--cols", String(initialSize.cols),
            "--rows", String(initialSize.rows)
        ]
        if !arguments.command.isEmpty {
            remoteArguments += ["--command-b64", Data(arguments.command.utf8).base64EncodedString()]
        }
        if !arguments.parentSession.isEmpty {
            remoteArguments += ["--parent-session", arguments.parentSession]
        }
        ssh.arguments = remoteArguments
        ssh.standardInput = inputPipe
        ssh.standardOutput = outputPipe
        ssh.standardError = errorPipe

        do {
            try ssh.run()
        } catch {
            message("relay-bridge: could not start SSH: \(error.localizedDescription)\r\n")
            exit(69)
        }

        let writer = WireWriter(inputPipe.fileHandleForWriting)
        let resizeSource = makeResizeSource(writer: writer)
        _ = resizeSource

        DispatchQueue.global(qos: .userInteractive).async {
            let input = FileHandle.standardInput
            while true {
                do {
                    guard let data = try input.read(upToCount: 32 << 10), !data.isEmpty else { break }
                    try writer.write(type: .input, payload: data)
                } catch {
                    break
                }
            }
            try? writer.write(type: .detach)
        }

        DispatchQueue.global(qos: .utility).async {
            let errors = errorPipe.fileHandleForReading
            while let data = try? errors.read(upToCount: 8 << 10), !data.isEmpty {
                if let text = String(data: data, encoding: .utf8) {
                    message("\r\n\u{001B}[38;2;255;139;120m\(text)\u{001B}[0m")
                }
            }
        }

        var exitCode: Int32 = 0
        do {
            while true {
                let frame = try readFrame(from: outputPipe.fileHandleForReading)
                switch frame.type {
                case .output:
                    if let output = outputPayload(frame) {
                        try FileHandle.standardOutput.write(contentsOf: output.data)
                    }
                case .status:
                    if let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                       let state = object["state"] as? String {
                        if state == "error" {
                            let detail = object["message"] as? String ?? "remote session error"
                            message("\r\n\u{001B}[38;2;255;139;120mRelay: \(detail)\u{001B}[0m\r\n")
                            exitCode = 70
                        }
                    }
                case .ping:
                    try writer.write(type: .pong)
                case .agentEvent:
                    if let json = String(data: frame.payload, encoding: .utf8) {
                        message("\r\n\u{001B}[38;2;103;214;173m[Relay agent event] \(json)\u{001B}[0m\r\n")
                    }
                default:
                    continue
                }
            }
        } catch {
            ssh.waitUntilExit()
            if exitCode == 0 { exitCode = ssh.terminationStatus }
        }
        resizeSource.cancel()
        exit(exitCode)
    }

    private static func makeResizeSource(writer: WireWriter) -> DispatchSourceSignal {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .userInteractive))
        source.setEventHandler {
            let size = terminalSize()
            try? writer.write(type: .resize, payload: resizePayload(cols: size.cols, rows: size.rows))
        }
        source.resume()
        return source
    }

    private static func terminalSize() -> (cols: UInt16, rows: UInt16) {
        var size = winsize()
        guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 else { return (120, 36) }
        return (max(size.ws_col, 1), max(size.ws_row, 1))
    }

    private static func message(_ text: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    }
}

RelayBridge.run()
