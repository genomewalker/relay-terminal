import AppKit
import SwiftUI

struct RelayNativeIdentity: Codable, Equatable, Sendable {
    let pane: String
    let instance: String
    let provider: String
}
struct RelayNativeItem: Codable, Identifiable, Sendable {
    let id: String
    let role: String
    let text: String
    let tool: String?
    let status: String?
    let sequence: UInt64
    let truncated: Bool?
}
struct RelayNativeQuestion: Codable, Identifiable, Sendable {
    struct Option: Codable, Identifiable, Sendable {
        let id: String
        let label: String
        let description: String?
    }
    let id: String
    let header: String?
    let text: String
    let options: [Option]?
    let multiple: Bool?
    let secret: Bool?
}
struct RelayNativeRequest: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    let turnId: String
    let title: String
    let detail: String
    let questions: [RelayNativeQuestion]?
    let responding: Bool
}
struct RelayNativeSnapshot: Codable, Sendable {
    struct Capabilities: Codable, Sendable {
        let send: Bool
        let steer: Bool
        let interrupt: Bool
        let interruptScope: String
        let respond: Bool
        let maintenance: Bool
        let scheduledTasks: String
        let maintenanceReason: String
    }
    let version: Int
    let identity: RelayNativeIdentity
    let sessionId: String
    let turnId: String
    let cwd: String
    let model: String
    let phase: String
    let revision: UInt64
    let items: [RelayNativeItem]
    let requests: [RelayNativeRequest]
    let capabilities: Capabilities
    let failure: String?
    let olderBefore: UInt64?
}
struct RelayNativeReceipt: Codable, Sendable {
    let id: String
    let digest: String
    let state: String
    let detail: String?
}
struct RelayNativeResponse: Codable, Sendable {
    let snapshot: RelayNativeSnapshot?
    let receipt: RelayNativeReceipt?
    let imagePath: String?
    let error: String?
}
struct RelayNativeBinding: Codable, Equatable, Sendable {
    let identity: RelayNativeIdentity
    let profile: ConnectionProfile
    let account: RelayAgentAccount
}

@MainActor final class RelayNativeRegistry: ObservableObject {
    static let shared = RelayNativeRegistry()
    @Published private var entries: [String: RelayNativeBinding]
    private static let key = "relay.native-conversation-locators.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = RelayStateProfile.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), data.count <= 1 << 20,
           let saved = try? JSONDecoder().decode([String: RelayNativeBinding].self, from: data) {
            entries = saved
        } else { entries = [:] }
    }
    func binding(for pane: PaneModel) -> RelayNativeBinding? {
        guard let binding = entries[pane.id.uuidString.lowercased()],
              binding.profile == pane.profile,
              binding.identity.pane == pane.id.uuidString.lowercased() else { return nil }
        return binding
    }
    func record(_ binding: RelayNativeBinding) throws {
        var next = entries
        next[binding.identity.pane] = binding
        let data = try JSONEncoder().encode(next)
        guard data.count <= 1 << 20 else { throw RelayNativeService.Failure.invalid }
        defaults.set(data, forKey: Self.key)
        entries = next
    }
}

@MainActor enum RelayNativeService {
    enum Failure: LocalizedError {
        case invalid
        case refused(String)
        var errorDescription: String? {
            switch self {
            case .invalid: return "Relay received an invalid native conversation response."
            case .refused(let message): return message
            }
        }
    }
    static func call(_ binding: RelayNativeBinding, body: [String: Any]) async throws -> RelayNativeResponse {
        var request = body
        request["identity"] = ["pane": binding.identity.pane, "instance": binding.identity.instance,
                               "provider": binding.identity.provider]
        let payload = try JSONSerialization.data(withJSONObject: [
            "request_id": "native-" + UUID().uuidString.lowercased(),
            "operation": "native_chat", "native_chat": request,
        ])
        guard payload.count <= 24 << 20 else { throw Failure.invalid }
        let data = try await RelayNodeTransportPool.shared.request(profile: binding.profile, payload: payload,
            requiredCapability: "native_chat_v1", timeoutSeconds: 30)
        guard data.count <= 24 << 20,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid }
        if let error = envelope["error"] as? String { throw Failure.refused(String(error.prefix(8192))) }
        guard let result = envelope["result"], JSONSerialization.isValidJSONObject(result) else { throw Failure.invalid }
        let response = try JSONDecoder().decode(RelayNativeResponse.self,
            from: JSONSerialization.data(withJSONObject: result))
        if let snapshot = response.snapshot {
            guard snapshot.version == 1, snapshot.identity == binding.identity,
                  snapshot.items.count <= 256, snapshot.requests.count <= 64 else { throw Failure.invalid }
        }
        if let error = response.error { throw Failure.refused(error) }
        return response
    }
}

@MainActor final class RelayNativeConversation: ObservableObject {
    let binding: RelayNativeBinding
    @Published var snapshot: RelayNativeSnapshot?
    @Published var failure: String?
    @Published var busy = false
    @Published var uncertainAction: String?
    @Published var receipts: [RelayNativeReceipt] = []
    @Published var older: [RelayNativeItem] = []
    private var pendingKey: String { "relay.native-pending." + binding.identity.pane + "." + binding.identity.instance }
    init(binding: RelayNativeBinding) {
        self.binding = binding
        self.uncertainAction = RelayStateProfile.defaults.string(forKey:
            "relay.native-pending." + binding.identity.pane + "." + binding.identity.instance)
    }
    private func markPending(_ id: String?) {
        if let id { RelayStateProfile.defaults.set(id, forKey: pendingKey) }
        else { RelayStateProfile.defaults.removeObject(forKey: pendingKey) }
        uncertainAction = id
    }

    func observe() async {
        failure = nil
        while !Task.isCancelled {
            do {
                let response = try await RelayNativeService.call(binding, body: [
                    "operation": "snapshot", "afterRevision": snapshot?.revision ?? 0,
                    "waitMillis": snapshot == nil ? 0 : 15000,
                ])
                try Task.checkCancellation()
                guard let next = response.snapshot else { throw RelayNativeService.Failure.invalid }
                snapshot = next
                if next.phase == "exited" { return }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
                return
            }
        }
    }
    func act(kind: String, text: String = "", images: [String] = [], request: RelayNativeRequest? = nil,
             decision: String = "", answers: [String: [String]] = [:]) async {
        guard !busy, uncertainAction == nil, failure == nil, let snapshot else { return }
        busy = true
        defer { busy = false }
        let id = UUID().uuidString.lowercased()
        var action: [String: Any] = [
            "id": id, "identity": ["pane": binding.identity.pane, "instance": binding.identity.instance,
                                  "provider": binding.identity.provider], "kind": kind,
        ]
        if kind != "send" { action["turnId"] = request?.turnId ?? snapshot.turnId }
        if !text.isEmpty { action["text"] = text }
        if !images.isEmpty { action["images"] = images }
        if let request { action["requestId"] = request.id }
        if !decision.isEmpty { action["decision"] = decision }
        if !answers.isEmpty { action["answers"] = answers }
        // Set before dispatch. Transport cancellation or timeout never enables replay.
        markPending(id)
        do {
            let response = try await RelayNativeService.call(binding, body: ["operation": "action", "action": action])
            guard let receipt = response.receipt, receipt.id == id else { throw RelayNativeService.Failure.invalid }
            receipts.append(receipt)
            if receipt.state == "sent" || receipt.state == "rejected" { markPending(nil) }
            if let next = response.snapshot { self.snapshot = next }
        } catch { failure = error.localizedDescription }
    }
    func inspectReceipt() async {
        guard let id = uncertainAction else { return }
        do {
            let response = try await RelayNativeService.call(binding, body: ["operation": "receipt", "receiptId": id])
            guard let receipt = response.receipt, receipt.id == id else { throw RelayNativeService.Failure.invalid }
            receipts.append(receipt)
            if receipt.state == "sent" || receipt.state == "rejected" { markPending(nil); failure = nil }
        } catch { failure = error.localizedDescription }
    }
    func loadOlder() async {
        guard let before = older.first?.sequence ?? snapshot?.olderBefore, before > 0 else { return }
        do {
            let response = try await RelayNativeService.call(binding, body: ["operation": "snapshot", "before": before])
            guard let next = response.snapshot else { throw RelayNativeService.Failure.invalid }
            let known = Set(older.map(\.id))
            older.insert(contentsOf: next.items.filter { !known.contains($0.id) }, at: 0)
        } catch { failure = error.localizedDescription }
    }
    func upload(_ data: Data) async throws -> String {
        guard data.count <= 4 << 20 else { throw RelayNativeService.Failure.refused("Images must be at most 4 MB.") }
        let response = try await RelayNativeService.call(binding, body: [
            "operation": "image", "imageData": data.base64EncodedString(),
        ])
        guard let path = response.imagePath else { throw RelayNativeService.Failure.invalid }
        return path
    }
}

extension WorkspaceModel {
    func startNativeAgentInNewTab(_ account: RelayAgentAccount, besidePane sourceID: UUID, launchID: UUID = UUID(),
                                 resuming: RelayNativeBinding? = nil,
                                 authorization: @escaping @MainActor () -> Bool = { true },
                                 capabilityProbe: (@MainActor (ConnectionProfile) async throws -> Void)? = nil,
                                 onSubmit: @escaping @MainActor () -> Void = {}) async -> String? {
        guard authorization(), !Task.isCancelled, account.isValid,
              let source = panes[sourceID], source.profile.backend == .relay else {
            return "Select a Relay workspace and a registered account."
        }
        do {
            if let capabilityProbe { try await capabilityProbe(source.profile) }
            else {
                let probe = try JSONSerialization.data(withJSONObject: [
                    "request_id": "native-capability-" + UUID().uuidString.lowercased(), "operation": "capabilities",
                ])
                _ = try await RelayNodeTransportPool.shared.request(profile: source.profile, payload: probe,
                    requiredCapability: "native_chat_v1", timeoutSeconds: 15)
            }
        } catch { return "This host does not currently provide native conversations: " + error.localizedDescription }
        guard !Task.isCancelled, panes[sourceID] === source, authorization() else {
            return "Native launch authorization or its source changed during the capability check. Nothing was launched."
        }
        let instance = launchID.uuidString.lowercased()
        var command = account.launchAssignment + " \"$HOME\"/.local/bin/relayd native-chat " + account.provider + " " + instance
        if let resume = resuming {
            guard resume.profile == source.profile, resume.account == account,
                  resume.identity.provider == account.provider,
                  RelayNativeRegistry.shared.binding(for: source) == resume,
                  let oldPane = UUID(uuidString: resume.identity.pane),
                  let oldInstance = UUID(uuidString: resume.identity.instance) else {
                return "The saved conversation binding or account changed. Nothing was launched."
            }
            command += " " + oldPane.uuidString.lowercased() + " " + oldInstance.uuidString.lowercased()
        }
        guard let pane = await openTab(running: command, profile: source.profile, besidePane: sourceID,
            authorization: authorization, onSubmit: onSubmit) else {
            return "The new pane did not accept a launch. Inspect it before starting another conversation."
        }
        let binding = RelayNativeBinding(identity: .init(pane: pane.id.uuidString.lowercased(),
            instance: instance, provider: account.provider), profile: pane.profile, account: account)
        do { try RelayNativeRegistry.shared.record(binding) }
        catch { return "The launch was submitted, but its conversation locator could not be saved. Do not repeat it." }
        pane.recordAgentAccount(account)
        pane.nativeConversationVisible = true
        return nil
    }
}
