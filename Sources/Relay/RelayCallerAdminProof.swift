import Foundation
import CryptoKit
import Security

/// Signs caller-policy mutations (register, set_paused, policy_import) so
/// relayd can tell the Relay app from another process of the same remote user.
/// The Ed25519 private key lives only in this Mac's Keychain; each host pins the
/// public key on the first valid proof. The signed bytes mirror
/// remote/relayd/internal/daemon/communication_caller_admin.go.
enum RelayCallerAdminProof {
    static let domain = "relay-caller-admin-v1\u{0}"
    static let lifetime: TimeInterval = 120
    static let mutating: Set<String> = ["caller_register", "caller_set_paused", "caller_policy_import"]

    private static let service = "app.relay.caller-admin-key"
    private static let account = "ed25519-v1"

    /// The app's key, created on first use. Not synchronized and not
    /// migratable: it stays on this Mac, unlocked-only.
    static func loadOrCreateKey() throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return try Curve25519.Signing.PrivateKey(rawRepresentation: data) }
        guard status == errSecItemNotFound else { throw RelayHostRPCError.invalidRequest }
        let key = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: key.rawRepresentation,
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw RelayHostRPCError.invalidRequest }
        return key
    }

    /// Reads the key off the main actor and keeps it for the app's lifetime.
    /// The item's partition list pins each build's cdhash (the signing
    /// certificate is not Apple-issued), so the first read after an update
    /// shows a Keychain prompt; on the main actor that froze every Relay API
    /// call until it was answered. The actor also keeps concurrent first
    /// attaches from raising more than one prompt.
    static let adminKey = AdminKeyStore(load: loadOrCreateKey)

    /// How long a request waits for the key. An unanswered Keychain prompt
    /// must not hold request handlers (0.5.30: Miko supervisor calls hung with
    /// no reply); the load itself keeps waiting for the user. HTTP, agent and
    /// MCP paths use it; an action the user starts in Relay's UI waits
    /// without it, because that user is the one answering the prompt (U-K1).
    static let keyWait: Duration = .seconds(3)

    /// How a mutation waits for the key.
    enum KeyWait: Sendable {
        /// HTTP, agent and MCP paths: refuse after the bound.
        case bounded(Duration)
        /// An action the user started: wait until approval or cancellation,
        /// reporting the wait on that action's own status.
        case user(KeychainApprovalStatus)

        static var request: KeyWait { .bounded(RelayCallerAdminProof.keyWait) }
        var bound: Duration? {
            if case .bounded(let bound) = self { return bound }
            return nil
        }
    }

    /// Whether one user-started action is waiting on the Keychain prompt.
    /// Each action (or the view running it) owns its own; the key load and
    /// its single prompt stay shared.
    @MainActor final class KeychainApprovalStatus: ObservableObject {
        static let waitingText = "Waiting for Keychain approval…"
        @Published private(set) var waiting = 0
        var pending: Bool { waiting > 0 }
        func begin() { waiting += 1 }
        func end() { waiting = max(0, waiting - 1) }
    }

    /// The key for an action the user started: no bound, only cancellation
    /// ends the wait. Once it outlasts `grace` (when a request would have
    /// failed) the action is shown as waiting for Keychain approval.
    @MainActor static func userKey(store: AdminKeyStore = adminKey, status: KeychainApprovalStatus,
                                   grace: Duration = keyWait) async throws -> Curve25519.Signing.PrivateKey {
        do { return try await store.key(within: grace) }
        catch is KeychainApprovalPending {
            status.begin()
            defer { status.end() }
            return try await store.key(within: nil)
        }
    }

    /// The key load is still waiting on the user's Keychain approval.
    struct KeychainApprovalPending: LocalizedError, Equatable {
        static let message = "Keychain approval pending: approve Relay's caller-admin key in the macOS Keychain prompt, then retry with a fresh request."
        var errorDescription: String? { Self.message }
    }

    actor AdminKeyStore {
        typealias Key = Curve25519.Signing.PrivateKey
        private let load: @Sendable () throws -> Key
        private var cached: Key?
        /// The one load in flight; it raises at most one Keychain prompt.
        private var loading: Task<Data, Error>?
        private(set) var loads = 0
        init(load: @escaping @Sendable () throws -> Key) { self.load = load }

        /// Returns the key, waiting at most `bound` (nil: until the load ends)
        /// for the load in progress. A timeout leaves that load running and
        /// throws KeychainApprovalPending; a later request picks up its result.
        /// A failed load is reported and not cached, so the next request loads
        /// (and prompts) again, as before.
        func key(within bound: Duration? = nil) async throws -> Key {
            if let cached { return cached }
            let task: Task<Data, Error>
            if let loading { task = loading } else {
                loads += 1
                let load = self.load
                task = Task.detached {
                    try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(with: Result { try load().rawRepresentation })
                        }
                    }
                }
                loading = task
            }
            do {
                let key = try Key(rawRepresentation: try await Self.value(of: task, within: bound))
                cached = key
                if loading == task { loading = nil }
                return key
            } catch let pending as KeychainApprovalPending {
                throw pending
            } catch is CancellationError {
                // Only this caller stopped waiting; the load (and its one
                // prompt) stays in flight for the next request.
                throw CancellationError()
            } catch {
                if loading == task { loading = nil }
                throw error
            }
        }

        /// Awaiting a Task's value ignores cancellation, so a task group could
        /// not stop waiting; the first of the load, the bound (if any) or the
        /// waiter's cancellation resumes once.
        private static func value(of task: Task<Data, Error>, within bound: Duration?) async throws -> Data {
            let once = ResumeOnce()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    once.set(continuation)
                    Task.detached { once.resume(with: await task.result) }
                    if let bound {
                        Task.detached {
                            try? await Task.sleep(for: bound)
                            once.resume(with: .failure(KeychainApprovalPending()))
                        }
                    }
                }
            } onCancel: {
                once.resume(with: .failure(CancellationError()))
            }
        }

        /// Resumes its continuation once. A result that arrives before the
        /// continuation (cancellation before the wait began) is kept for it.
        private final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Data, Error>?
            private var early: Result<Data, Error>?
            private var done = false
            func set(_ continuation: CheckedContinuation<Data, Error>) {
                lock.lock()
                if let early { done = true; self.early = nil; lock.unlock(); continuation.resume(with: early); return }
                self.continuation = continuation; lock.unlock()
            }
            func resume(with result: Result<Data, Error>) {
                lock.lock()
                guard !done else { lock.unlock(); return }
                guard let continuation else { if early == nil { early = result }; lock.unlock(); return }
                done = true; self.continuation = nil; lock.unlock()
                continuation.resume(with: result)
            }
        }
    }

    private static func lp(_ s: String) -> String { "\(s.utf8.count):\(s)" }
    private static func flag(_ v: Bool) -> String { v ? "1" : "0" }

    /// Length-prefixed arguments, identical to communicationCallerAdminArguments.
    static func arguments(_ packet: [String: Any]) -> String {
        var out = lp((packet["caller_id"] as? String ?? "").lowercased())
        out += lp((packet["paused"] as? Bool).map(flag) ?? "-")
        guard let policy = packet["policy"] as? [String: Any] else { return out + lp("-") }
        out += lp(flag(policy["legacyPaused"] as? Bool ?? false))
        let callers = policy["callers"] as? [[String: Any]] ?? []
        out += lp(String(callers.count))
        for c in callers {
            out += lp((c["id"] as? String ?? "").lowercased())
            out += lp(c["label"] as? String ?? "")
            out += lp((c["thread"] as? String).map { "+" + $0 } ?? "-")
            out += lp(c["tokenHash"] as? String ?? "")
            out += lp(flag(c["paused"] as? Bool ?? false))
        }
        return out
    }

    static func message(node: String, operation: String, nonce: String, expires: Int64, packet: [String: Any]) -> Data {
        Data((domain + lp(node) + lp(operation) + lp(nonce) + lp(String(expires)) + lp(arguments(packet))).utf8)
    }

    /// The `admin_proof` object to attach to a mutating packet bound for `node`.
    static func proof(for packet: [String: Any], node: String, key: Curve25519.Signing.PrivateKey,
                      now: Date = Date(), nonce: Data? = nil) throws -> [String: Any] {
        let nonceData = nonce ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let nonceText = nonceData.base64EncodedString()
        let expires = Int64(now.timeIntervalSince1970 + lifetime)
        let signature = try key.signature(for: message(node: node, operation: packet["operation"] as? String ?? "",
                                                       nonce: nonceText, expires: expires, packet: packet))
        return ["public_key": key.publicKey.rawRepresentation.base64EncodedString(), "nonce": nonceText,
                "expires": expires, "signature": signature.base64EncodedString()]
    }

    /// Default policy transport: signs mutations after asking the host for its
    /// node ID (readable without proof), then sends the packet. `keyWait`
    /// says how long to wait for the key (`.user` for UI actions only).
    @MainActor static func send(profile: ConnectionProfile, packet: [String: Any],
                                keyWait: KeyWait = .request) async throws -> [String: Any] {
        var packet = packet
        if let operation = packet["operation"] as? String, mutating.contains(operation) {
            let info = try await RelayHostExecution.communicationRequest(profile: profile, packet: ["operation": "caller_admin_info"])
            guard let node = info.value?["node_id"] as? String, !node.isEmpty else { throw RelayHostRPCError.invalidRequest }
            let key: Curve25519.Signing.PrivateKey
            switch keyWait {
            case .bounded(let bound): key = try await adminKey.key(within: bound)
            case .user(let status): key = try await userKey(status: status)
            }
            // A host pinned to a different key is not ours to administer.
            if let pinned = info.value?["admin_key_sha256"] as? String, !pinned.isEmpty,
               pinned != SHA256.hash(data: key.publicKey.rawRepresentation).map({ String(format: "%02x", $0) }).joined() {
                throw RelayHostRPCError.invalidRequest
            }
            packet["admin_proof"] = try proof(for: packet, node: node, key: key)
        }
        let result = try await RelayHostExecution.communicationRequest(profile: profile, packet: packet)
        guard let value = result.value else { throw RelayHostRPCError.invalidRequest }
        return value
    }
}
