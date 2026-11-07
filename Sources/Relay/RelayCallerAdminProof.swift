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
    /// node ID (readable without proof), then sends the packet.
    @MainActor static func send(profile: ConnectionProfile, packet: [String: Any]) async throws -> [String: Any] {
        var packet = packet
        if let operation = packet["operation"] as? String, mutating.contains(operation) {
            let info = try await RelayHostExecution.communicationRequest(profile: profile, packet: ["operation": "caller_admin_info"])
            guard let node = info.value?["node_id"] as? String, !node.isEmpty else { throw RelayHostRPCError.invalidRequest }
            let key = try loadOrCreateKey()
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
