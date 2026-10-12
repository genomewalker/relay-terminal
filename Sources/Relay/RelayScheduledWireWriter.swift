import Foundation

/// Bounded logical-frame queue. Route heads preserve order; control traffic can
/// run between negotiated chunks. Failure is reported to the connection owner.
final class RelayScheduledWireWriter: RelayFrameWriting, @unchecked Sendable {
    private final class Item {
        let frame: RelayWireFrame
        let key: String
        let priority: Int
        let done = DispatchSemaphore(value: 0)
        var error: Error?
        var offset = 0
        var id: UInt64 = 0
        init(_ frame: RelayWireFrame) {
            self.frame = frame
            let inner = RelayWireFrame.parseHostEvent(frame)
            key = inner.map { "pane:" + $0.sessionID } ?? (frame.type == .ping || frame.type == .pong ? "heartbeat" : "connection")
            switch inner?.inner.type ?? frame.type {
            case .output: priority = 1
            case .agentEvent, .workspaceState: priority = 2
            case .artifact, .hostRequest, .hostResponse: priority = 3
            default: priority = 0
            }
        }
    }
    private let sink: RelayWireWriter
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.relay.node-scheduled", qos: .userInteractive)
    private let onError: @Sendable (String) -> Void
    private var pending: [Item] = []
    private var bytes = 0
    private var draining = false
    private var failure: Error?
    private var fragments = false
    private var nextID: UInt64 = 0
    private var burst = 0

    init(_ handle: FileHandle, onError: @escaping @Sendable (String) -> Void) {
        self.onError = onError
        sink = RelayWireWriter(handle, onError: onError)
    }
    func enableFragments() { lock.lock(); fragments = true; lock.unlock() }
    private func enqueue(_ frame: RelayWireFrame) throws -> Item {
        let item = Item(frame)
        lock.lock()
        if let failure { lock.unlock(); throw failure }
        guard frame.payload.count <= RelayWireFrame.maximumPayloadBytes,
              pending.count < 128, bytes + frame.payload.count <= 32 << 20 else {
            lock.unlock()
            throw RelayWireError.invalidFrame
        }
        pending.append(item); bytes += frame.payload.count
        if !draining { draining = true; queue.async { self.drain() } }
        lock.unlock()
        return item
    }
    func write(type: RelayWireType, payload: Data = Data()) throws {
        let item = try enqueue(.init(type: type, payload: payload))
        item.done.wait()
        if let error = item.error { throw error }
    }
    func writeAsync(type: RelayWireType, payload: Data = Data()) {
        do { _ = try enqueue(.init(type: type, payload: payload)) }
        catch { onError("Node queue rejected frame: \(error)") }
    }
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else { draining = false; lock.unlock(); return }
            var index = 0
            if burst < 8 {
                var seen: Set<String> = []
                for i in pending.indices where seen.insert(pending[i].key).inserted {
                    if pending[i].priority < pending[index].priority { index = i }
                }
            }
            burst = index == 0 ? 0 : burst + 1
            let item = pending[index]
            var frame = item.frame
            var final = true
            if fragments && frame.payload.count > RelayWireFragmentAssembler.chunkBytes {
                if item.id == 0 { nextID += 1; item.id = nextID }
                let end = min(frame.payload.count, item.offset + RelayWireFragmentAssembler.chunkBytes)
                frame = RelayWireFragmentAssembler.frame(id: item.id, kind: frame.type,
                    total: frame.payload.count, offset: item.offset,
                    chunk: frame.payload.subdata(in: item.offset..<end))
                item.offset = end; final = end == item.frame.payload.count
            }
            // Retain the in-flight item in the bound until the sink completes.
            lock.unlock()
            do { try sink.write(type: frame.type, payload: frame.payload) }
            catch {
                lock.lock(); failure = error
                let remaining = pending; pending = []; bytes = 0; draining = false
                lock.unlock()
                for next in remaining { next.error = error; next.done.signal() }
                return
            }
            if final {
                lock.lock()
                pending.removeAll { $0 === item }; bytes -= item.frame.payload.count
                lock.unlock()
                item.done.signal()
            }
        }
    }
}
