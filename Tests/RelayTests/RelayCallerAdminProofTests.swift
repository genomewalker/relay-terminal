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

    // 0.5.30: while the post-update Keychain prompt stayed unanswered, every
    // Miko supervisor call hung in attachDaemon with no HTTP reply. A bounded
    // request now refuses promptly; the single load keeps waiting for the user.
    @Test func boundedKeyRequestsRefuseWhileTheKeychainPromptIsOpen() async throws {
        let gate = DispatchSemaphore(value: 0)
        let seen = OSAllocatedUnfairLockBox()
        let fixed = Curve25519.Signing.PrivateKey()
        let store = RelayCallerAdminProof.AdminKeyStore(load: {
            seen.record(main: Thread.isMainThread)
            gate.wait()
            return fixed
        })
        let clock = ContinuousClock(), begun = clock.now
        await #expect(throws: RelayCallerAdminProof.KeychainApprovalPending.self) {
            _ = try await store.key(within: .milliseconds(50))
        }
        #expect(clock.now - begun < .seconds(2))
        // Concurrent bounded requests share the one load (one prompt).
        let waiting = (0..<6).map { _ in Task.detached { try? await store.key(within: .milliseconds(30)) } }
        for task in waiting { #expect(await task.value == nil) }
        #expect(await store.loads == 1 && seen.calls == 1)
        // An unbounded request waits for the same load; approval releases it.
        let patient = Task.detached { try await store.key().rawRepresentation }
        try await Task.sleep(for: .milliseconds(20))
        gate.signal()
        #expect(try await patient.value == fixed.rawRepresentation)
        // Cached: later requests succeed at once without loading again.
        #expect(try await store.key(within: .milliseconds(1)).rawRepresentation == fixed.rawRepresentation)
        #expect(await store.loads == 1 && seen.calls == 1)
    }

    // A denied prompt is reported, not cached: the next request loads (and
    // prompts) again, as before.
    @Test func aDeniedKeychainLoadIsReportedAndRetriedOnTheNextRequest() async throws {
        let seen = OSAllocatedUnfairLockBox()
        let fixed = Curve25519.Signing.PrivateKey()
        let store = RelayCallerAdminProof.AdminKeyStore(load: {
            seen.record(main: false)
            if seen.calls == 1 { throw RelayHostRPCError.invalidRequest }
            return fixed
        })
        await #expect(throws: RelayHostRPCError.self) { _ = try await store.key(within: .seconds(2)) }
        #expect(try await store.key(within: .seconds(2)).rawRepresentation == fixed.rawRepresentation)
        #expect(await store.loads == 2 && seen.calls == 2)
    }

    // U-K1: the user who clicked Register/Pause is the one answering the
    // Keychain prompt. Their action waits for it; an agent/HTTP request on the
    // same load still refuses after keyWait with the 0.5.31 message.
    @Test func userActionsOutwaitTheKeychainPromptWhileRequestsFailFast() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixed = Curve25519.Signing.PrivateKey()
        let store = RelayCallerAdminProof.AdminKeyStore(load: { gate.wait(); return fixed })
        let clock = ContinuousClock(), begun = clock.now
        let user = Task.detached { try await store.key(within: nil).rawRepresentation }
        let request = Task.detached { () -> (Error?, Duration) in
            do { _ = try await store.key(within: RelayCallerAdminProof.keyWait); return (nil, clock.now - begun) }
            catch { return (error, clock.now - begun) }
        }
        let (error, elapsed) = await request.value
        #expect(error is RelayCallerAdminProof.KeychainApprovalPending)
        #expect(error?.localizedDescription == "Keychain approval pending: approve Relay's caller-admin key in the macOS Keychain prompt, then retry with a fresh request.")
        #expect(elapsed >= RelayCallerAdminProof.keyWait && elapsed < .seconds(5))
        // The user's wait is still open past the agent bound; approval ends it.
        try await Task.sleep(for: .milliseconds(300))
        gate.signal()
        #expect(try await user.value == fixed.rawRepresentation)
        #expect(clock.now - begun > .seconds(3))
        #expect(await store.loads == 1)
    }

    // Closing the Clients sheet cancels the user's wait; the Keychain load
    // itself stays in flight so a retry does not raise a second prompt.
    @Test func cancellingTheUsersWaitEndsItWithoutASecondPrompt() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixed = Curve25519.Signing.PrivateKey()
        let store = RelayCallerAdminProof.AdminKeyStore(load: { gate.wait(); return fixed })
        let waiting = Task.detached { try await store.key(within: nil) }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock(), begun = clock.now
        waiting.cancel()
        let outcome = await waiting.result
        #expect(clock.now - begun < .seconds(1))
        #expect(throws: CancellationError.self) { try outcome.get() }
        let retry = Task.detached { try await store.key(within: nil).rawRepresentation }
        try await Task.sleep(for: .milliseconds(20))
        gate.signal()
        #expect(try await retry.value == fixed.rawRepresentation)
        #expect(await store.loads == 1)
    }

    // A task cancelled before it reaches the wait still ends promptly.
    @Test func anAlreadyCancelledUserWaitEndsAtOnce() async throws {
        let gate = DispatchSemaphore(value: 0)
        let store = RelayCallerAdminProof.AdminKeyStore(load: { gate.wait(); return Curve25519.Signing.PrivateKey() })
        let waiting = Task.detached { () -> Result<Curve25519.Signing.PrivateKey, Error> in
            withUnsafeCurrentTask { $0?.cancel() }
            return await Result { try await store.key(within: nil) }
        }
        let outcome = await waiting.value
        #expect(throws: CancellationError.self) { try outcome.get() }
        gate.signal()
    }

    // The pending state shows only once the user's action has outlasted the
    // grace (keyWait in the app), then clears when the key arrives.
    @MainActor @Test func theUsersWaitShowsAPendingKeychainState() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fixed = Curve25519.Signing.PrivateKey()
        let store = RelayCallerAdminProof.AdminKeyStore(load: { gate.wait(); return fixed })
        let status = RelayCallerAdminProof.KeychainApprovalStatus()
        let user = Task { try await RelayCallerAdminProof.userKey(store: store, status: status, grace: .milliseconds(50)).rawRepresentation }
        #expect(!status.pending)
        try await Task.sleep(for: .milliseconds(400))
        #expect(status.pending)
        #expect(RelayCallerAdminProof.KeychainApprovalStatus.waitingText == "Waiting for Keychain approval…")
        gate.signal()
        #expect(try await user.value == fixed.rawRepresentation)
        #expect(!status.pending)
    }

    // Only the Settings entry points (origin: .hardware) wait for the user;
    // daemon attach and the request paths keep the 3 s bound.
    @MainActor @Test func onlyUserEntryPointsWaitUnbounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-caller-wait-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = RelayCallerControl(directory: directory)
        var waits: [String: [Duration?]] = [:]
        control.transportIncarnation = { _ in nil }
        control.policyTransport = { _, packet, wait in
            let operation = packet["operation"] as? String ?? ""
            waits[operation, default: []].append(wait)
            return operation == "caller_list" ? ["authority": "relayd", "callers": []] : ["authority": "relayd"]
        }
        try await control.attachDaemon(profile: .sshConfigHost("caller-wait.invalid"))
        let issued = try await control.register(label: "Fixture", thread: nil, origin: .hardware)
        let id = try #require(issued["caller_id"])
        try await control.setPaused(id: id, paused: true, origin: .hardware)
        _ = try await control.register(label: "Request", thread: nil)
        try await control.setPaused(id: id, paused: false)
        #expect(waits["caller_policy_import"] == [RelayCallerAdminProof.keyWait])
        #expect(waits["caller_register"] == [nil, RelayCallerAdminProof.keyWait])
        #expect(waits["caller_set_paused"] == [nil, RelayCallerAdminProof.keyWait])
    }
}

private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0, _onMain = 0
    func record(main: Bool) { lock.lock(); _calls += 1; if main { _onMain += 1 }; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var onMain: Int { lock.lock(); defer { lock.unlock() }; return _onMain }
}
