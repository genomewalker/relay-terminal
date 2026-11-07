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

    // After each update the first Keychain read raises a prompt (the partition
    // list pins each build's cdhash). On the main actor that froze every Relay
    // API call until the user answered; concurrent first attaches could also
    // raise it more than once.
    @MainActor @Test func adminKeyLoadsOnceAndOffTheMainThread() async throws {
        let seen = OSAllocatedUnfairLockBox()
        let fixed = Curve25519.Signing.PrivateKey()
        let store = RelayCallerAdminProof.AdminKeyStore(load: {
            seen.record(main: Thread.isMainThread)
            return fixed
        })
        // First call from the main actor, as RelayCallerAdminProof.send makes it.
        let first = try await store.key().rawRepresentation
        let tasks = (0..<8).map { _ in Task.detached { try await store.key().rawRepresentation } }
        var keys = [first]
        for task in tasks { keys.append(try await task.value) }
        #expect(keys.count == 9 && Set(keys) == [fixed.rawRepresentation])
        #expect(await store.loads == 1)
        #expect(seen.calls == 1 && seen.onMain == 0)
    }
}

private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0, _onMain = 0
    func record(main: Bool) { lock.lock(); _calls += 1; if main { _onMain += 1 }; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var onMain: Int { lock.lock(); defer { lock.unlock() }; return _onMain }
}
