import Foundation

/// Negotiated logical-frame assembly. Partial frames never reach terminal,
/// job, or receipt handlers. The assembler is local to one connection generation.
struct RelayWireFragmentAssembler {
    static let chunkBytes = 32 << 10
    private struct Partial {
        let kind: RelayWireType
        let total: Int
        var bytes: Data
    }
    var enabled = false
    private var partial: [UInt64: Partial] = [:]
    private var reserved = 0
    private var completed: Set<UInt64> = []
    private var history: [UInt64] = []

    mutating func accept(_ frame: RelayWireFrame) throws -> RelayWireFrame? {
        guard frame.type == .fragment else { return frame }
        let data = frame.payload
        guard enabled, data.count > 18, data.count <= 18 + Self.chunkBytes, data[0] == 1,
              let kind = RelayWireType(rawValue: data[1]), kind != .fragment,
              kind != .capabilities, kind != .unsupported else { throw RelayWireError.invalidFrame }
        let id = data[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let total = Int(data[10..<14].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let offset = Int(data[14..<18].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let chunk = data.dropFirst(18)
        guard id > 0, total > 0, total <= RelayWireFrame.maximumPayloadBytes,
              offset <= total, chunk.count <= total - offset, !completed.contains(id) else {
            throw RelayWireError.invalidFrame
        }
        if partial[id] == nil {
            guard offset == 0, partial.count < 64, reserved + total <= 32 << 20 else {
                throw RelayWireError.invalidFrame
            }
            partial[id] = .init(kind: kind, total: total, bytes: Data())
            reserved += total
        }
        guard var item = partial[id], item.kind == kind, item.total == total,
              item.bytes.count == offset else { throw RelayWireError.invalidFrame }
        item.bytes.append(contentsOf: chunk)
        if item.bytes.count == total {
            partial.removeValue(forKey: id); reserved -= total
            completed.insert(id); history.append(id)
            if history.count > 512 { completed.remove(history.removeFirst()) }
            return RelayWireFrame(type: kind, payload: item.bytes)
        }
        partial[id] = item
        return nil
    }

    static func frame(id: UInt64, kind: RelayWireType, total: Int, offset: Int, chunk: Data) -> RelayWireFrame {
        var data = Data([1, kind.rawValue])
        var messageID = id.bigEndian, count = UInt32(total).bigEndian, position = UInt32(offset).bigEndian
        withUnsafeBytes(of: &messageID) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &position) { data.append(contentsOf: $0) }
        data.append(chunk)
        return .init(type: .fragment, payload: data)
    }
}
