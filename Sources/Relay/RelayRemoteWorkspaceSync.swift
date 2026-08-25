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
