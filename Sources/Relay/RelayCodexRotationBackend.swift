import CryptoKit
import Foundation

/// The desktop socket check every app-server client applies (formerly
/// codex-desktop-deliver.py `check_socket`): a socket owned by this user with
/// mode 0600, reached at most through one link inside a private directory.
enum RelayDesktopSocket {
    struct Unsafe: Error {}

    static func check(_ path: String) throws -> String {
        var path = absolutePath(path)
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Unsafe() }
        if info.st_mode & S_IFMT == S_IFLNK {
            var parent = stat()
            guard info.st_uid == getuid(), lstat(directory(of: path), &parent) == 0,
                  parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == getuid(), parent.st_mode & 0o7777 == 0o700,
                  let linked = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { throw Unsafe() }
            path = absolutePath(linked.hasPrefix("/") ? linked : directory(of: path) + "/" + linked)
            var targetParent = stat()
            guard lstat(directory(of: path), &targetParent) == 0, targetParent.st_mode & S_IFMT == S_IFDIR,
                  targetParent.st_uid == getuid(), targetParent.st_mode & 0o7777 == 0o700,
                  lstat(path, &info) == 0 else { throw Unsafe() }
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600 else {
            throw Unsafe()
        }
        return path
    }

    /// `os.path.abspath`: lexical normalization; symlinks are not resolved.
    static func absolutePath(_ path: String) -> String {
        let joined = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        let leading = joined.hasPrefix("//") && !joined.hasPrefix("///") ? "//" : "/"
        var parts: [Substring] = []
        for part in joined.split(separator: "/") where part != "." {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(part) }
        }
        return leading + parts.joined(separator: "/")
    }

    /// `os.path.dirname` of an absolute normalized path.
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        let head = String(path[..<slash])
        return head.isEmpty || head.allSatisfy({ $0 == "/" }) ? String(path[...slash]) : head
    }
}

/// One-shot Codex app-server lifecycle adapter for a trusted Relay parent
/// (formerly relay-codex-rotation-backend.py). No backend launch, implicit
/// source resume, retries, terminal input, or deletion. Any failure is
/// `reconciliationRequired`: the durable rotation journal must reconcile it.
enum RelayCodexRotationBackend {
    struct ReconciliationRequired: Error {}
    static let limit = 65_536

    /// The bound on one whole operation, independent of the socket deadline:
    /// the role of the 120 s ProcessCapture timeout around the Python adapter.
    static let overallBound: TimeInterval = 120

    /// The operation's socket, so an expired caller can end it from outside.
    private final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var socket: RelayUnixWebSocket?
        private var abandoned = false
        var result: Result<Data, Error>?

        func attach(_ socket: RelayUnixWebSocket) {
            lock.lock(); defer { lock.unlock() }
            self.socket = socket
            if abandoned { socket.cancel() }
        }

        func abandon() {
            lock.lock(); defer { lock.unlock() }
            abandoned = true
            socket?.cancel()
        }
    }

    static func perform(operation: String, socketPath: String, device: UInt64, inode: UInt64,
                        request: Data, timeout: TimeInterval = 110,
                        overallBound: TimeInterval = overallBound) throws -> Data {
        let exchange = Exchange()
        let done = DispatchSemaphore(value: 0)
        Thread {
            exchange.result = Result {
                guard request.count <= limit,
                      let arguments = try JSONSerialization.jsonObject(with: request) as? [String: Any] else {
                    throw ReconciliationRequired()
                }
                return try JSONSerialization.data(withJSONObject: try run(operation: operation, socketPath: socketPath,
                    device: device, inode: inode, arguments: arguments, timeout: timeout, exchange: exchange))
            }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + overallBound) == .success, case .success(let data)? = exchange.result else {
            exchange.abandon()
            throw ReconciliationRequired()
        }
        return data
    }

    static func identifier(_ value: Any?) throws -> String {
        guard let value = value as? String, (1...110).contains(value.unicodeScalars.count),
              value.unicodeScalars.allSatisfy({ $0.value >= 33 }) else { throw ReconciliationRequired() }
        return value
    }

    private static func sameIncarnation(_ path: String, device: UInt64, inode: UInt64) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && UInt64(bitPattern: Int64(info.st_dev)) == device && UInt64(info.st_ino) == inode
    }

    private static func run(operation: String, socketPath: String, device: UInt64, inode: UInt64,
                            arguments: [String: Any], timeout: TimeInterval, exchange: Exchange) throws -> [String: Any] {
        guard ["inspect", "start", "load", "archive"].contains(operation) else { throw ReconciliationRequired() }
        let path = try RelayDesktopSocket.check(socketPath)
        guard sameIncarnation(path, device: device, inode: inode) else { throw ReconciliationRequired() }
        guard let cwd = arguments["cwd"] as? String, cwd.hasPrefix("/") else { throw ReconciliationRequired() }
        if arguments.keys.contains("code_head") {
            guard try headOfRepository(cwd) == arguments["code_head"] as? String else { throw ReconciliationRequired() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        let socket = try RelayUnixWebSocket(path: path, deadline: deadline, maximumMessageBytes: limit)
        exchange.attach(socket)
        defer { socket.close() }
        guard sameIncarnation(path, device: device, inode: inode) else { throw ReconciliationRequired() }
        let backend = Session(socket: socket)
        _ = try backend.rpc("initialize", ["clientInfo": ["name": "relay_rotation", "version": "1"],
                                           "capabilities": ["experimentalApi": true]])
        try socket.send(String(decoding: try JSONSerialization.data(withJSONObject:
            ["method": "initialized", "params": [String: Any]()]), as: UTF8.self))
        switch operation {
        case "inspect":
            return try backend.inspect(identifier(arguments["thread_id"]), cwd: cwd)
        case "start":
            _ = try backend.inspect(identifier(arguments["source_thread_id"]), cwd: cwd)
            guard let start = arguments["start_parameters"] as? [String: Any], start["cwd"] as? String == cwd else {
                throw ReconciliationRequired()
            }
            guard let started = try backend.rpc("thread/start", start) as? [String: Any],
                  let thread = started["thread"] as? [String: Any] else {
                throw ReconciliationRequired()
            }
            let id = try identifier(thread["id"])
            guard thread["sessionId"] as? String == id else { throw ReconciliationRequired() }
            return ["thread_id": id, "session_id": id]
        case "load":
            return try backend.load(identifier(arguments["thread_id"]), arguments: arguments, cwd: cwd)
        default:
            let thread = try identifier(arguments["thread_id"])
            _ = try backend.inspect(thread, cwd: cwd)
            _ = try backend.rpc("thread/archive", ["threadId": thread])
            return ["thread_id": thread, "archived": true]
        }
    }

    private static func headOfRepository(_ directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory, "rev-parse", "HEAD"]
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        let result = try ProcessCapture.run(process, output: output, errors: errors, timeout: 10, maximumBytesPerStream: 4_096)
        guard process.terminationStatus == 0 else { throw ReconciliationRequired() }
        return pythonStrip(String(decoding: result.standardOutput, as: UTF8.self))
    }

    /// `str.strip()` with Python's whitespace set.
    static func pythonStrip(_ text: String) -> String {
        func space(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
            default: false
            }
        }
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !space($0) }),
              let last = scalars.lastIndex(where: { !space($0) }) else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[first...last])
        return String(view)
    }

    /// `x in container` for the shapes a JSON reply can take.
    private static func contains(_ container: Any?, _ value: String) throws -> Bool {
        switch container {
        case let list as [Any]: return list.contains { $0 as? String == value }
        case let text as String: return text.contains(value)
        case let object as [String: Any]: return object[value] != nil
        default: throw ReconciliationRequired()
        }
    }

    final class Session {
        let socket: RelayUnixWebSocket
        var sequence = 0
        var events: [[String: Any]] = []

        init(socket: RelayUnixWebSocket) { self.socket = socket }

        func message() throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: socket.receive(), options: .fragmentsAllowed)
                    as? [String: Any] else { throw ReconciliationRequired() }
            return value
        }

        /// The reply `result` (any JSON value); other messages queue as events.
        func rpc(_ method: String, _ params: [String: Any]) throws -> Any {
            sequence += 1
            try socket.send(String(decoding: try JSONSerialization.data(withJSONObject:
                ["id": sequence, "method": method, "params": params]), as: UTF8.self))
            while true {
                let value = try message()
                // Python ==: 1.0 and true also match id 1.
                if let id = value["id"] as? NSNumber, id.doubleValue == Double(sequence) {
                    guard value["error"] == nil, let result = value["result"] else {
                        throw ReconciliationRequired()
                    }
                    return result
                }
                events.append(value)
                guard events.count <= 256 else { throw ReconciliationRequired() }
            }
        }

        func inspect(_ thread: String, cwd: String, descendants: Bool = true) throws -> [String: Any] {
            guard let loaded = try rpc("thread/loaded/list", [:]) as? [String: Any],
                  try RelayCodexRotationBackend.contains(loaded["data"] ?? [Any](), thread),
                  let read = try rpc("thread/read", ["threadId": thread, "includeTurns": false]) as? [String: Any],
                  let result = read["thread"] as? [String: Any],
                  result["id"] as? String == thread, result["sessionId"] as? String == thread,
                  result["cwd"] as? String == cwd, result["forkedFromId"] == nil || result["forkedFromId"] is NSNull,
                  ((result["status"] ?? [String: Any]()) as? [String: Any])?["type"] as? String == "idle" else {
                throw ReconciliationRequired()
            }
            if descendants {
                // Archive includes descendants. Refuse the entire operation if any
                // exist; Relay does not infer authorization for them.
                for archived in [false, true] {
                    guard let children = try rpc("thread/list", ["parentThreadId": thread, "archived": archived, "limit": 1])
                            as? [String: Any] else { throw ReconciliationRequired() }
                    let data = children["data"]
                    let present = switch data {
                    case nil, is NSNull: false
                    case let list as [Any]: !list.isEmpty
                    case let object as [String: Any]: !object.isEmpty
                    case let text as String: !text.isEmpty
                    case let number as NSNumber: number.doubleValue != 0
                    default: true
                    }
                    guard !present, children["nextCursor"] == nil || children["nextCursor"] is NSNull else {
                        throw ReconciliationRequired()
                    }
                }
            }
            return ["idle": true, "root": true, "no_descendants": descendants]
        }

        func load(_ thread: String, arguments: [String: Any], cwd: String) throws -> [String: Any] {
            guard let capsule = arguments["capsule"] as? String else { throw ReconciliationRequired() }
            let digest = SHA256.hash(data: Data(capsule.utf8)).map { String(format: "%02x", $0) }.joined()
            guard arguments["sha256"] as? String == digest else { throw ReconciliationRequired() }
            // Fresh threads may unload after the creating client disconnects.
            // Only the exact newly bound destination is allowed to resume here.
            _ = try rpc("thread/resume", ["threadId": thread])
            _ = try inspect(thread, cwd: cwd, descendants: false)
            let marker = "Relay-Capsule-Loaded: " + digest
            let turn = try rpc("turn/start", [
                "threadId": thread,
                "input": [["type": "text", "text": "Receive the saved handoff capsule supplied as Relay tool output. Read it, then reply with exactly " + marker + ". Do not execute tools or begin the saved work in this receipt turn."]],
                "toolOutput": ["namespace": "relay", "name": "rotation_capsule", "output": capsule],
            ])
            guard let started = (turn as? [String: Any])?["turn"] as? [String: Any], let turnID = started["id"] else { throw ReconciliationRequired() }
            func same(_ value: Any?) -> Bool {
                guard let value else { return false }
                return (value as AnyObject).isEqual(turnID)
            }
            var text: [String] = []
            while true {
                let value = events.isEmpty ? try message() : events.removeFirst()
                let method = value["method"] as? String
                guard let params = (value["params"] ?? [String: Any]()) as? [String: Any] else { throw ReconciliationRequired() }
                guard params["threadId"] as? String == thread else { continue }
                if method == "item/completed", same(params["turnId"]) {
                    guard let item = (params["item"] ?? [String: Any]()) as? [String: Any] else { throw ReconciliationRequired() }
                    if item["type"] as? String == "agentMessage" {
                        guard let line = (item["text"] ?? "") as? String else { throw ReconciliationRequired() }
                        text.append(line)
                    } else if !["userMessage", "reasoning", "contextCompaction"].contains(item["type"] as? String ?? "") {
                        throw ReconciliationRequired()
                    }
                }
                guard method == "turn/completed" else { continue }
                guard let completed = (params["turn"] ?? [String: Any]()) as? [String: Any] else { throw ReconciliationRequired() }
                if same(completed["id"]) {
                    guard completed["status"] as? String == "completed",
                          RelayCodexRotationBackend.pythonStrip(text.joined(separator: "\n")) == marker else {
                        throw ReconciliationRequired()
                    }
                    return ["thread_id": thread, "completed": true, "sha256": digest, "turn_id": turnID]
                }
            }
        }
    }
}
