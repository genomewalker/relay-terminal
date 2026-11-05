import CryptoKit
import Foundation
import Testing
@testable import Relay

/// A one-connection fake Codex app-server on a private unix socket.
final class FakeAppServer: @unchecked Sendable {
    enum Reply { case message([String: Any]), ping, fragmented([String: Any]), raw(Data) }
    let directory: URL
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    private var accepted = false
    private var finished = false
    var badAccept = false

    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return received }
    var wasConnected: Bool { lock.lock(); defer { lock.unlock() }; return accepted }
    var hasFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    init(mode: mode_t = 0o600, handler: @escaping ([String: Any]) -> [Reply]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("as-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("s.sock").path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0, chmod(path, mode) == 0 else { throw POSIXError(.EIO) }
        let descriptor = listener
        nonisolated(unsafe) let serveHandler = handler
        Thread.detachNewThread { [self] in
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            self.lock.lock(); self.accepted = true; self.lock.unlock()
            defer { Darwin.close(client) }
            self.serve(client, handler: serveHandler)
            self.lock.lock(); self.finished = true; self.lock.unlock()
        }
    }

    deinit {
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: directory)
    }

    var identity: (UInt64, UInt64) {
        var info = stat()
        stat(path, &info)
        return (UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino))
    }

    /// One best-effort write that never raises SIGPIPE. Setting SO_NOSIGPIPE
    /// after accept is not enough: it fails once a hasty client has gone.
    static func put(_ socket: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
    }

    private func readExactly(_ client: Int32, _ count: Int) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: max(count, 1))
        while data.count < count {
            let got = Darwin.read(client, &chunk, count - data.count)
            guard got > 0 else { return nil }
            data.append(contentsOf: chunk[0..<got])
        }
        return data
    }

    private func frame(_ opcode: UInt8, _ payload: Data, fin: Bool = true) -> Data {
        var out = Data([(fin ? 0x80 : 0) | opcode])
        if payload.count < 126 { out.append(UInt8(payload.count)) }
        else { out.append(126); out.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]) }
        return out + payload
    }

    private func serve(_ client: Int32, handler: ([String: Any]) -> [Reply]) {
        var head = Data()
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard let byte = readExactly(client, 1) else { return }
            head += byte
        }
        let text = String(decoding: head, as: UTF8.self)
        guard let line = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else { return }
        let key = line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        var accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        if badAccept { accept = "AAAA" + accept.dropFirst(4) }
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        FakeAppServer.put(client, Data(response.utf8))
        while true {
            guard let header = readExactly(client, 2) else { return }
            var length = Int(header[1] & 0x7F)
            if length == 126, let extended = readExactly(client, 2) { length = Int(extended[0]) << 8 | Int(extended[1]) }
            guard header[1] & 0x80 != 0, let mask = readExactly(client, 4),
                  let masked = readExactly(client, length) else { return }
            let payload = Data(masked.enumerated().map { $0.element ^ mask[$0.offset & 3] })
            if header[0] & 0x0F == 0x8 { return }
            if header[0] & 0x0F == 0xA { continue }
            guard let request = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
            lock.lock(); received.append(request); lock.unlock()
            for reply in handler(request) {
                var out = Data()
                switch reply {
                case .message(let value): out = frame(0x1, try! JSONSerialization.data(withJSONObject: value))
                case .ping: out = frame(0x9, Data("p".utf8))
                case .fragmented(let value):
                    let data = try! JSONSerialization.data(withJSONObject: value)
                    let middle = data.count / 2
                    out = frame(0x1, data.prefix(middle), fin: false) + frame(0x0, data.dropFirst(middle))
                case .raw(let data): out = data
                }
                FakeAppServer.put(client, out)
            }
        }
    }
}

@Suite struct RelayCodexRotationBackendTests {
    static let thread = "019a0000-0000-7000-8000-000000000001"
    static let cwd = "/work/project"

    /// A healthy idle root thread with no descendants.
    static func appServer(start: [String: Any]? = nil, children: [String: Any] = ["data": [Any]()],
                          completion: [[String: Any]] = [], status: String = "idle",
                          extra: @escaping ([String: Any]) -> [FakeAppServer.Reply]? = { _ in nil })
        -> ([String: Any]) -> [FakeAppServer.Reply] {
        return { request in
            if let custom = extra(request) { return custom }
            guard let id = request["id"] as? Int, let method = request["method"] as? String else { return [] }
            func reply(_ result: Any) -> [FakeAppServer.Reply] { [.message(["id": id, "result": result])] }
            switch method {
            case "initialize": return [.ping, .message(["method": "noise", "params": [:]])] + reply(["userAgent": "fake"])
            case "thread/loaded/list": return [.fragmented(["id": id, "result": ["data": ["other", thread]]])]
            case "thread/read":
                return reply(["thread": ["id": thread, "sessionId": thread, "cwd": cwd, "status": ["type": status]]])
            case "thread/list": return reply(children)
            case "thread/start": return reply(start ?? [:])
            case "thread/archive", "thread/resume": return reply([:])
            case "turn/start":
                return reply(["turn": ["id": "turn-1"]]) + completion.map { .message($0) }
            default: return [.message(["id": id, "error": ["message": "unknown"]])]
            }
        }
    }

    static func perform(_ server: FakeAppServer, _ operation: String, _ arguments: [String: Any],
                        identity: (UInt64, UInt64)? = nil, timeout: TimeInterval = 10,
                        overallBound: TimeInterval = RelayCodexRotationBackend.overallBound) throws -> [String: Any] {
        let (device, inode) = identity ?? server.identity
        let data = try RelayCodexRotationBackend.perform(operation: operation, socketPath: server.path,
            device: device, inode: inode, request: JSONSerialization.data(withJSONObject: arguments), timeout: timeout,
            overallBound: overallBound)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func inspectsAnIdleRootOverTheWebSocket() throws {
        let server = try FakeAppServer(handler: Self.appServer())
        let result = try Self.perform(server, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd])
        #expect(result["idle"] as? Bool == true && result["root"] as? Bool == true && result["no_descendants"] as? Bool == true)
        let methods = server.requests.compactMap { $0["method"] as? String }
        #expect(methods == ["initialize", "initialized", "thread/loaded/list", "thread/read", "thread/list", "thread/list"])
        #expect(server.requests.filter { $0["method"] as? String == "thread/list" }.map { $0["params"] as? [String: Any] }
            .map { $0?["archived"] as? Bool } == [false, true])
        #expect(server.requests.first?["params"].flatMap { ($0 as? [String: Any])?["clientInfo"] as? [String: String] }
            == ["name": "relay_rotation", "version": "1"])
    }

    @Test func refusesUnsafeOrChangedBackends() throws {
        let descendants = try FakeAppServer(handler: Self.appServer(children: ["data": ["child"]]))
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(descendants, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd])
        }
        let cursor = try FakeAppServer(handler: Self.appServer(children: ["data": [Any](), "nextCursor": "c"]))
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(cursor, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd])
        }
        let busy = try FakeAppServer(handler: Self.appServer(status: "active"))
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(busy, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd])
        }
        let moved = try FakeAppServer(handler: Self.appServer())
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(moved, "inspect", ["thread_id": Self.thread, "cwd": "/elsewhere"])
        }
        let replaced = try FakeAppServer(handler: Self.appServer())
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(replaced, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd],
                             identity: (replaced.identity.0, replaced.identity.1 + 1))
        }
        #expect(!replaced.wasConnected, "a changed incarnation is refused before connecting")
        let shared = try FakeAppServer(mode: 0o644, handler: Self.appServer())
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(shared, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd])
        }
        let forged = try FakeAppServer(handler: Self.appServer())
        forged.badAccept = true
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(forged, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd])
        }
        let unknown = try FakeAppServer(handler: Self.appServer())
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(unknown, "delete", ["thread_id": Self.thread, "cwd": Self.cwd])
        }
        let rejected = try FakeAppServer(handler: Self.appServer(extra: { request in
            request["method"] as? String == "thread/read" ? [.message(["id": request["id"]!, "error": NSNull()])] : nil
        }))
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(rejected, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd])
        }
    }

    @Test func startsOnlyAFreshRoot() throws {
        let fresh = "019a0000-0000-7000-8000-000000000002"
        let server = try FakeAppServer(handler: Self.appServer(start: ["thread": ["id": fresh, "sessionId": fresh]]))
        let result = try Self.perform(server, "start", ["source_thread_id": Self.thread, "cwd": Self.cwd,
                                                        "start_parameters": ["cwd": Self.cwd, "model": "m"]])
        #expect(result as NSDictionary == ["thread_id": fresh, "session_id": fresh] as NSDictionary)
        #expect(server.requests.last?["params"] as? NSDictionary == ["cwd": Self.cwd, "model": "m"] as NSDictionary)
        let fork = try FakeAppServer(handler: Self.appServer(start: ["thread": ["id": fresh, "sessionId": Self.thread]]))
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(fork, "start", ["source_thread_id": Self.thread, "cwd": Self.cwd,
                                             "start_parameters": ["cwd": Self.cwd]])
        }
        let elsewhere = try FakeAppServer(handler: Self.appServer(start: ["thread": ["id": fresh, "sessionId": fresh]]))
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(elsewhere, "start", ["source_thread_id": Self.thread, "cwd": Self.cwd,
                                                  "start_parameters": ["cwd": "/other"]])
        }
    }

    @Test func loadsACapsuleOnlyWithItsExactReceipt() throws {
        let capsule = "saved handoff"
        let digest = SHA256.hash(data: Data(capsule.utf8)).map { String(format: "%02x", $0) }.joined()
        func completion(_ text: String, status: String = "completed", item: String = "agentMessage") -> [[String: Any]] {
            [["method": "item/completed", "params": ["threadId": "other", "turnId": "turn-1", "item": ["type": "commandExecution"]]],
             ["method": "item/completed", "params": ["threadId": Self.thread, "turnId": "turn-1", "item": ["type": "reasoning"]]],
             ["method": "item/completed", "params": ["threadId": Self.thread, "turnId": "turn-1", "item": ["type": item, "text": text]]],
             ["method": "turn/completed", "params": ["threadId": Self.thread, "turn": ["id": "turn-1", "status": status]]]]
        }
        let arguments: [String: Any] = ["thread_id": Self.thread, "cwd": Self.cwd, "capsule": capsule, "sha256": digest]
        let server = try FakeAppServer(handler: Self.appServer(completion: completion(" Relay-Capsule-Loaded: \(digest)\n")))
        let result = try Self.perform(server, "load", arguments)
        #expect(result as NSDictionary == ["thread_id": Self.thread, "completed": true, "sha256": digest,
                                           "turn_id": "turn-1"] as NSDictionary)
        let turn = try #require(server.requests.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        #expect((turn["toolOutput"] as? [String: String])?["output"] == capsule)
        for (name, events) in [("wrong text", completion("done")), ("failed", completion("Relay-Capsule-Loaded: \(digest)", status: "failed")),
                               ("tool use", completion("x", item: "commandExecution"))] {
            let failing = try FakeAppServer(handler: Self.appServer(completion: events))
            #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self, "\(name)") { try Self.perform(failing, "load", arguments) }
        }
        let mismatch = try FakeAppServer(handler: Self.appServer())
        var tampered = arguments
        tampered["sha256"] = String(repeating: "0", count: 64)
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) { try Self.perform(mismatch, "load", tampered) }
        #expect(mismatch.requests.allSatisfy { $0["method"] as? String != "thread/resume" })
    }

    @Test func archivesAfterInspection() throws {
        let server = try FakeAppServer(handler: Self.appServer())
        let result = try Self.perform(server, "archive", ["thread_id": Self.thread, "cwd": Self.cwd])
        #expect(result as NSDictionary == ["thread_id": Self.thread, "archived": true] as NSDictionary)
        #expect(server.requests.last?["method"] as? String == "thread/archive")
    }

    @Test func pythonStripAndPaths() {
        #expect(RelayCodexRotationBackend.pythonStrip("\u{1C} a b\u{3000}\n") == "a b")
        #expect(RelayDesktopSocket.absolutePath("/a/./b/../c//d/") == "/a/c/d")
        #expect(RelayDesktopSocket.absolutePath("//a/../b") == "//b")
        #expect(RelayDesktopSocket.directory(of: "/a/b") == "/a" && RelayDesktopSocket.directory(of: "/a") == "/")
    }

    /// Expiry holds on the fast paths too: buffered bytes, ready bytes and writes.
    @Test func expiredStreamRefusesBufferedReadyAndWrittenBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("st-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)); $0[path.utf8.count] = 0 }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(listener, 1) == 0)
        let stream = try RelayUnixStream(path: path, deadline: Date().addingTimeInterval(30))
        let peer = accept(listener, nil, nil)
        try #require(peer >= 0)
        defer { Darwin.close(peer) }
        func send(_ text: String) { FakeAppServer.put(peer, Data(text.utf8)) }

        send("ab")
        #expect(try stream.read(1) == Data("a".utf8))
        stream.deadline = Date(timeIntervalSinceNow: -1)
        #expect(throws: RelayUnixStream.Failure.timedOut) { try stream.read(1) }
        send("c\r\n\r\n")
        #expect(throws: RelayUnixStream.Failure.timedOut) { try stream.read(until: Data("\r\n\r\n".utf8), limit: 64) }
        #expect(throws: RelayUnixStream.Failure.timedOut) { try stream.write(Data("late".utf8)) }
        _ = fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) | O_NONBLOCK)
        var byte: UInt8 = 0
        #expect(Darwin.read(peer, &byte, 1) == -1 && errno == EAGAIN, "an expired write reached the peer")

        // A live deadline sees the same bytes; cancel then ends the stream.
        stream.deadline = Date().addingTimeInterval(30)
        #expect(try stream.read(1) == Data("b".utf8))
        stream.cancel()
        #expect(throws: RelayUnixStream.Failure.closed) { try stream.read(1) }

        // A whole delimited record already buffered is refused after expiry too.
        let framed = try RelayUnixStream(path: path, deadline: Date().addingTimeInterval(30))
        let framer = accept(listener, nil, nil)
        try #require(framer >= 0)
        defer { Darwin.close(framer) }
        FakeAppServer.put(framer, Data("one\r\n\r\ntwo\r\n\r\n".utf8))
        #expect(try framed.read(until: Data("\r\n\r\n".utf8), limit: 64) == Data("one".utf8))
        framed.deadline = Date(timeIntervalSinceNow: -1)
        #expect(throws: RelayUnixStream.Failure.timedOut) { try framed.read(until: Data("\r\n\r\n".utf8), limit: 64) }

        // Writing to a departed peer is an error, never a SIGPIPE.
        let orphan = try RelayUnixStream(path: path, deadline: Date().addingTimeInterval(30))
        let departed = accept(listener, nil, nil)
        try #require(departed >= 0)
        Darwin.close(departed)
        #expect(throws: RelayUnixStream.Failure.closed) {
            for _ in 0..<64 { try orphan.write(Data(count: 65_536)) }
        }
    }

    /// Root's control: a valid inspect behind 500 queued pings must not finish
    /// after its exchange deadline; with time to spare it succeeds.
    @Test func pingFloodCannotOutliveTheDeadline() throws {
        let flood = Self.appServer(extra: { request in
            guard request["method"] as? String == "initialize", let id = request["id"] else { return nil }
            return Array(repeating: .ping, count: 500) + [.message(["id": id, "result": ["userAgent": "fake"]])]
        })
        let late = try FakeAppServer(handler: flood)
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(late, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd], timeout: 0.001)
        }
        let control = try FakeAppServer(handler: flood)
        let result = try Self.perform(control, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd], timeout: 30)
        #expect(result["idle"] as? Bool == true)
    }

    /// The overall bound holds even while the socket deadline is far away, and
    /// it ends the abandoned exchange instead of leaving it connected.
    @Test func overallBoundEndsASilentExchange() throws {
        let silent = try FakeAppServer(handler: { _ in [] })
        let started = Date()
        #expect(throws: RelayCodexRotationBackend.ReconciliationRequired.self) {
            try Self.perform(silent, "inspect", ["thread_id": Self.thread, "cwd": Self.cwd],
                             timeout: 30, overallBound: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 15, "the 30 s socket deadline, not the bound, ended it")
        let limit = Date().addingTimeInterval(15)
        while !silent.hasFinished && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
        #expect(silent.hasFinished, "the abandoned exchange still holds its connection")
    }

    /// The fake server outlives a client that leaves before the reply: its
    /// writes fail quietly instead of killing the test process with SIGPIPE.
    @Test func fakeServerSurvivesAClientThatLeftEarly() throws {
        let server = try FakeAppServer(handler: Self.appServer())
        let stream = try RelayUnixStream(path: server.path, deadline: Date().addingTimeInterval(30))
        try stream.write(Data("GET / HTTP/1.1\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n\r\n".utf8))
        stream.close()
        let limit = Date().addingTimeInterval(15)
        while !server.hasFinished && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
        #expect(server.hasFinished)
    }
}
