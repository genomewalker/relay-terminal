import Foundation

/// A translated edit must be sent in full or discarded before dispatch.
struct RelayPromptControlBatch {
    let maximumBytes: Int
    private var bytes = Data()
    private(set) var overflowed = false

    init(maximumBytes: Int = 64 << 10) {
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        overflowed = false
    }

    @discardableResult
    mutating func append(_ data: Data) -> Bool {
        guard !overflowed else { return false }
        guard data.count <= maximumBytes - bytes.count else {
            bytes.removeAll(keepingCapacity: true)
            overflowed = true
            return false
        }
        bytes.append(data)
        return true
    }

    mutating func take() -> Data? {
        defer { reset() }
        guard !overflowed, !bytes.isEmpty else { return nil }
        return bytes
    }
}
