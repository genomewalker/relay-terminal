import CryptoKit
import Foundation

/// A blocking Unix-domain stream socket whose every operation is bounded by
/// one absolute deadline. The deadline is measured on the monotonic clock and
/// checked on entry to every read and write and on every loop iteration, so
/// buffered or always-ready I/O cannot outlive it. `cancel()` may be called
/// from another thread to end a blocked or busy exchange.
final class RelayUnixStream: @unchecked Sendable {
    enum Failure: Error, Equatable { case connect(Int32), timedOut, closed }

    private(set) var descriptor: Int32
    private var buffered = Data()
    /// DispatchTime uptime (monotonic) nanoseconds at which the stream expires.
    private var expiry: UInt64 = 0
    private let state = NSLock()
    private var cancelled = false

    var deadline: Date {
        get {
            let now = DispatchTime.now().uptimeNanoseconds
            return Date(timeIntervalSinceNow: expiry > now ? Double(expiry - now) / 1e9 : 0)
        }
        set {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = newValue.timeIntervalSinceNow
            expiry = remaining > 0 ? now &+ UInt64(min(remaining, 1e9) * 1e9) : now
        }
    }

    init(path: String, deadline: Date) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        self.deadline = deadline
        guard descriptor >= 0 else { throw Failure.connect(errno) }
        do {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.connect(errno) }
            var noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard !bytes.isEmpty, bytes.count < capacity, !bytes.contains(0) else { throw Failure.connect(ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            try live()
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw Failure.connect(errno) }
                try wait(for: Int16(POLLOUT))
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
                guard error == 0 else { throw Failure.connect(error) }
            }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        state.lock(); defer { state.unlock() }
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    /// Ends the exchange from any thread: every later or blocked operation fails.
    func cancel() {
        state.lock(); defer { state.unlock() }
        cancelled = true
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
    }

    /// Throws once the stream is cancelled, closed or past its deadline.
    private func live() throws {
        state.lock()
        let stopped = cancelled || descriptor < 0
        state.unlock()
        guard !stopped else { throw Failure.closed }
        guard DispatchTime.now().uptimeNanoseconds < expiry else { throw Failure.timedOut }
    }

    /// The kernel's record of the connected peer: LOCAL_PEERPID and getpeereid.
    func peer() -> (pid: pid_t, uid: uid_t)? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getsockopt(descriptor, 0 /* SOL_LOCAL */, 2 /* LOCAL_PEERPID */, &pid, &length) == 0,
              getpeereid(descriptor, &uid, &gid) == 0 else { return nil }
        return (pid, uid)
    }

    /// Everything before `delimiter`, or nil once `limit` bytes hold none.
    func read(until delimiter: Data, limit: Int) throws -> Data? {
        try live()
        while buffered.range(of: delimiter) == nil {
            guard buffered.count <= limit else { return nil }
            try fill()
        }
        let end = buffered.range(of: delimiter)!
        let value = Data(buffered[buffered.startIndex..<end.lowerBound])
        buffered = Data(buffered[end.upperBound...])
        return value
    }

    func read(_ count: Int) throws -> Data {
        try live()
        while buffered.count < count { try fill() }
        let value = Data(buffered.prefix(count))
        buffered = Data(buffered.dropFirst(count))
        return value
    }

    func write(_ data: Data) throws {
        var offset = 0
        let bytes = [UInt8](data)
        repeat {
            try live()
            guard offset < bytes.count else { return }
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written > 0 { offset += written; continue }
            guard written < 0, errno == EAGAIN || errno == EINTR else { throw Failure.closed }
            try wait(for: Int16(POLLOUT))
        } while true
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            try live()
            let received = Darwin.read(descriptor, &chunk, chunk.count)
            if received > 0 { buffered.append(contentsOf: chunk[0..<received]); return }
            if received == 0 { throw Failure.closed }
            guard errno == EAGAIN || errno == EINTR else { throw Failure.closed }
            try wait(for: Int16(POLLIN))
        }
    }

    private func wait(for events: Int16) throws {
        while true {
            try live()
            // The clock may pass the expiry between live() and here.
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < expiry else { throw Failure.timedOut }
            let milliseconds = (expiry - now + 999_999) / 1_000_000
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&entry, 1, Int32(min(milliseconds, 60_000)))
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw Failure.closed }
        }
    }
}


/// A blocking RFC 6455 client over a Unix-domain stream socket, for the Codex
/// app-server control socket (the role `websockets.unix_connect(path,
/// compression=None, max_size=...)` had in the Python adapters). Text frames
/// only, no extensions; every operation is bounded by one absolute deadline.
final class RelayUnixWebSocket: @unchecked Sendable {
    enum Failure: Error, Equatable { case handshake, protocolViolation, tooLarge, closed }

    private let stream: RelayUnixStream
    private let maximumMessageBytes: Int

    /// Connects and completes the opening handshake. `host` is the Host header
    /// the Python client sent for a unix socket (`ws://localhost/`).
    init(path: String, deadline: Date, maximumMessageBytes: Int = 1 << 20, host: String = "localhost") throws {
        stream = try RelayUnixStream(path: path, deadline: deadline)
        self.maximumMessageBytes = maximumMessageBytes
        try handshake(host: host)
    }

    deinit { close() }

    /// Sends a close frame (best effort) and releases the socket.
    func close() {
        guard stream.descriptor >= 0 else { return }
        try? writeFrame(opcode: 0x8, payload: Data([0x03, 0xE8]))
        stream.close()
    }

    /// Ends the exchange from any thread (see `RelayUnixStream.cancel`).
    func cancel() { stream.cancel() }

    func send(_ text: String) throws { try writeFrame(opcode: 0x1, payload: Data(text.utf8)) }

    /// The next complete text (or binary) message; answers pings.
    func receive() throws -> Data {
        var message = Data()
        var started = false
        while true {
            let (fin, opcode, payload) = try readFrame()
            switch opcode {
            case 0x9: try writeFrame(opcode: 0xA, payload: payload); continue
            case 0xA: continue
            case 0x8: throw Failure.closed
            case 0x1, 0x2:
                guard !started else { throw Failure.protocolViolation }
                started = true
            case 0x0:
                guard started else { throw Failure.protocolViolation }
            default: throw Failure.protocolViolation
            }
            message += payload
            guard message.count <= maximumMessageBytes else { throw Failure.tooLarge }
            if fin { return message }
        }
    }

    private func handshake(host: String) throws {
        var nonce = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else { throw Failure.handshake }
        let key = Data(nonce).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try stream.write(Data(request.utf8))
        guard let response = try stream.read(until: Data("\r\n\r\n".utf8), limit: 16_384) else { throw Failure.handshake }
        let lines = String(decoding: response, as: UTF8.self).components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard status.count >= 2, status[0].hasPrefix("HTTP/1.1"), status[1] == "101" else { throw Failure.handshake }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.handshake }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",")
                .contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              headers["sec-websocket-accept"] == accept,
              headers["sec-websocket-extensions"] == nil else { throw Failure.handshake }
    }

    private func readFrame() throws -> (Bool, UInt8, Data) {
        let header = try stream.read(2)
        let fin = header[0] & 0x80 != 0
        guard header[0] & 0x70 == 0 else { throw Failure.protocolViolation }
        let opcode = header[0] & 0x0F
        guard header[1] & 0x80 == 0 else { throw Failure.protocolViolation }  // servers never mask
        var length = UInt64(header[1] & 0x7F)
        if length == 126 {
            length = try stream.read(2).reduce(0) { $0 << 8 | UInt64($1) }
        } else if length == 127 {
            length = try stream.read(8).reduce(0) { $0 << 8 | UInt64($1) }
        }
        if opcode >= 0x8 { guard fin, length <= 125 else { throw Failure.protocolViolation } }
        guard length <= UInt64(maximumMessageBytes) else { throw Failure.tooLarge }
        return (fin, opcode, try stream.read(Int(length)))
    }

    private func writeFrame(opcode: UInt8, payload: Data) throws {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(payload.count) >> (UInt64($0) * 8)) & 0xFF) })
        }
        var mask = [UInt8](repeating: 0, count: 4)
        guard SecRandomCopyBytes(kSecRandomDefault, 4, &mask) == errSecSuccess else { throw Failure.protocolViolation }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
        try stream.write(frame)
    }
}
