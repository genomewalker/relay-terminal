import Foundation
import CryptoKit

enum RelayPrivateSecretProofPolicy {
    static let inbox = "a5515700-0000-4000-8000-00000000b0c6"
    static func canonical(tool: String, arguments: String) -> String? {
        guard ["relay_request_secret", "relay_secret_receipt"].contains(tool), arguments.utf8.count <= 4096 else { return nil }
        let digest = SHA256.hash(data: Data(arguments.utf8)).map { String(format: "%02x", $0) }.joined()
        return "relay-private-secret/v1\n" + tool + "\n" + digest
    }
    static func verifies(_ reply: [String: Any], attestation: String, paneID: UUID, sessionID: String) -> Bool {
        guard reply["authority"] as? String == "relayd", let source = reply["source"] as? [String: Any] else { return false }
        return source["authentication"] as? String == "source_host_attested" &&
            source["attestationID"] as? String == attestation &&
            source["paneID"] as? String == paneID.uuidString.lowercased() &&
            source["sessionID"] as? String == sessionID && source["socketPath"] == nil
    }
}
