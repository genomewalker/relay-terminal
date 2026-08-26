import Foundation

enum RelayClientIdentity {
    static let id: UUID = {
        let key = "relay.workspace-controller-id.v1"
        if let existing = UserDefaults.standard.string(forKey: key),
           let parsed = UUID(uuidString: existing) {
            return parsed
        }
        let created = UUID()
        UserDefaults.standard.set(created.uuidString.lowercased(), forKey: key)
        return created
    }()
}

enum RelayInputClientIdentity {
    static let id: UUID = {
        let key = "relay.input-client-id.v2"
        if let existing = UserDefaults.standard.string(forKey: key),
           let parsed = UUID(uuidString: existing) {
            return parsed
        }
        let created = UUID()
        UserDefaults.standard.set(created.uuidString.lowercased(), forKey: key)
        return created
    }()
}

/// Reserves input sequence numbers in large durable blocks. A crash may leave
/// a harmless gap, but a new process can never reuse a sequence that a remote
/// worker has already applied. This lets a restart reclaim its five-second
/// input lease immediately without risking duplicate keystrokes.
final class RelayInputSequenceAllocator: @unchecked Sendable {
    static let shared = RelayInputSequenceAllocator()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key: String
    private let blockSize: UInt64
    private var nextValue: UInt64
    private var reservedUpperBound: UInt64

    init(
        defaults: UserDefaults = .standard,
        key: String = "relay.input-sequence-high-water.v2",
        blockSize: UInt64 = 1 << 20
    ) {
        self.defaults = defaults
        self.key = key
        self.blockSize = max(1, blockSize)
        let previous = (defaults.object(forKey: key) as? NSNumber)?.uint64Value ?? 0
        nextValue = previous
        reservedUpperBound = previous
        reserveBlock()
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if nextValue >= reservedUpperBound { reserveBlock() }
        nextValue &+= 1
        return nextValue
    }

    private func reserveBlock() {
        let upper = reservedUpperBound > UInt64.max - blockSize
            ? UInt64.max
            : reservedUpperBound + blockSize
        precondition(upper > reservedUpperBound, "Relay input sequence space exhausted")
        reservedUpperBound = upper
        defaults.set(NSNumber(value: upper), forKey: key)
    }
}

final class RelayRemoteWorkspaceSync: @unchecked Sendable {
    static let shared = RelayRemoteWorkspaceSync()
    private let clientID = RelayClientIdentity.id.uuidString.lowercased()

    private init() {}

    func put(profile: ConnectionProfile, workspaceID: UUID, state: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: state),
              JSONSerialization.isValidJSONObject(object),
              let payload = try? JSONSerialization.data(withJSONObject: [
                "operation": "put", "client_id": clientID, "state": object,
              ]) else { return }
        WorkspaceStateRequest(
            profile: profile,
            workspaceID: workspaceID.uuidString.lowercased(),
            payload: payload
        ).start()
    }
}

private final class WorkspaceStateRequest: @unchecked Sendable {
    let profile: ConnectionProfile
    let workspaceID: String
    let payload: Data
    private let lock = NSLock()
    private var channel: RelayNodeChannel?
    private var finished = false

    init(profile: ConnectionProfile, workspaceID: String, payload: Data) {
        self.profile = profile
        self.workspaceID = workspaceID
        self.payload = payload
    }

    func start() {
        let created = RelayNodeTransportPool.shared.attach(
            profile: profile,
            sessionID: workspaceID,
            onReady: { [self] channel in
                channel.writeAsync(type: .workspaceState, payload: payload)
            },
            onFrame: { [self] frame in
                guard frame.type == .workspaceState else { return }
                finish()
            },
            onDisconnect: { [self] failure in
                if !failure.shouldRetry { finish() }
            }
        )
        lock.lock()
        if finished {
            lock.unlock()
            created.close()
        } else {
            channel = created
            lock.unlock()
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let channel = self.channel
        self.channel = nil
        lock.unlock()
        channel?.close()
    }
}
