import Foundation
import CryptoKit
import Testing
@testable import Relay

@Suite struct RelayCallerAdminProofTests {
    // Same vectors as TestCallerAdminSwiftVectors in relayd's daemon package.
    @Test func argumentsMatchRelaydCanonicalForm() {
        let packet: [String: Any] = ["operation": "caller_policy_import", "policy": ["legacyPaused": true, "callers": [
            ["id": "ABC-1", "label": "L", "thread": "t", "tokenHash": "ff", "paused": false],
            ["id": "x", "label": "M", "tokenHash": "aa", "paused": true]]]]
        #expect(RelayCallerAdminProof.arguments(packet) == "0:1:-1:11:25:abc-11:L2:+t2:ff1:01:x1:M1:-2:aa1:1")
    }

    @Test func proofSignsTheExactMessageRelaydVerifies() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let proof = try RelayCallerAdminProof.proof(
            for: ["operation": "caller_set_paused", "caller_id": "Legacy-Unattributed", "paused": true],
            node: "n1", key: key, now: Date(timeIntervalSince1970: 1000), nonce: Data(repeating: 1, count: 16))
        #expect(proof["public_key"] as? String == "6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=")
        #expect(proof["nonce"] as? String == "AQEBAQEBAQEBAQEBAQEBAQ==")
        #expect(proof["expires"] as? Int64 == 1120)
        // CryptoKit Ed25519 signatures are randomized, so check validity over
        // the exact message relayd verifies rather than comparing bytes.
        let signatureText = try #require(proof["signature"] as? String)
        let signature = try #require(Data(base64Encoded: signatureText))
        let message = RelayCallerAdminProof.message(node: "n1", operation: "caller_set_paused",
            nonce: "AQEBAQEBAQEBAQEBAQEBAQ==", expires: 1120,
            packet: ["operation": "caller_set_paused", "caller_id": "Legacy-Unattributed", "paused": true])
        #expect(key.publicKey.isValidSignature(signature, for: message))
        #expect(!key.publicKey.isValidSignature(signature, for: RelayCallerAdminProof.message(node: "n2",
            operation: "caller_set_paused", nonce: "AQEBAQEBAQEBAQEBAQEBAQ==", expires: 1120,
            packet: ["operation": "caller_set_paused", "caller_id": "Legacy-Unattributed", "paused": true])))
    }
}
