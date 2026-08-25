import Foundation

enum WireType: UInt8 {
    case hello = 1
    case input = 2
    case resize = 3
    case output = 4
    case status = 5
    case detach = 6
    case ping = 7
    case pong = 8
    case agentEvent = 9
}

struct WireFrame {
    let type: WireType
    let payload: Data
}

enum WireError: Error {
    case endOfStream
    case invalidType(UInt8)
    case oversizedFrame(Int)
}

final class WireWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(type: WireType, payload: Data = Data()) throws {
        guard payload.count <= 16 << 20 else { throw WireError.oversizedFrame(payload.count) }
        var header = Data([type.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: header)
        if !payload.isEmpty { try handle.write(contentsOf: payload) }
    }
}

func readFrame(from handle: FileHandle) throws -> WireFrame {
    let header = try readExactly(5, from: handle)
    guard let type = WireType(rawValue: header[0]) else { throw WireError.invalidType(header[0]) }
    let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length <= 16 << 20 else { throw WireError.oversizedFrame(Int(length)) }
    return WireFrame(type: type, payload: try readExactly(Int(length), from: handle))
}

private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
    if count == 0 { return Data() }
    var result = Data()
    while result.count < count {
        guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
            throw WireError.endOfStream
        }
        result.append(chunk)
    }
    return result
}

func outputPayload(_ frame: WireFrame) -> (sequence: UInt64, data: Data)? {
    guard frame.type == .output, frame.payload.count >= 8 else { return nil }
    let sequence = frame.payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    return (sequence, frame.payload.dropFirst(8))
}

func resizePayload(cols: UInt16, rows: UInt16) -> Data {
    var data = Data()
    var bigCols = cols.bigEndian
    var bigRows = rows.bigEndian
    withUnsafeBytes(of: &bigCols) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: &bigRows) { data.append(contentsOf: $0) }
    return data
}
