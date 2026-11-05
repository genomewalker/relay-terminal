import Foundation
import Testing
@testable import Relay

// Written against the fake confirmer; NOT compiled in this session (build hold).

@MainActor
private final class FakeConfirmer: RelayPaneLinkConfirming {
    private(set) var prompts: [RelayPaneLinkPrompt] = []
    var decision: RelayPaneLinkDecision = .deny
    /// When set, confirm suspends until `release` is called, so a proposal stays pending.
    var hold = false
    private var waiting: CheckedContinuation<Void, Never>?
    var beforeAnswer: (() -> Void)?

    func confirm(_ prompt: RelayPaneLinkPrompt, timeout: TimeInterval) async -> RelayPaneLinkDecision {
        prompts.append(prompt)
        if hold { await withCheckedContinuation { waiting = $0 } }
        beforeAnswer?()
        return decision
    }

    /// Latches `hold` off before resuming, so a release that comes before the queued resolve
    /// reaches `confirm` is not lost: that later `confirm` then answers without waiting.
    func release() { hold = false; waiting?.resume(); waiting = nil }
}

@MainActor
private final class Fixture {
    let remote = ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07", backend: .relay)
    let mac = ConnectionProfile(name: "This Mac", kind: .local, host: "", backend: .relay)
    let confirmer = FakeConfirmer()
    var panes: [UUID: RelayPaneLinkPane] = [:]
    let sourceID = UUID(), targetID = UUID(), otherID = UUID()
    var clock = Date(timeIntervalSince1970: 1_000_000)
    /// What the source host's relayd says the attestation proved.
    var provenPane: UUID?
    var redeemed: [[String: Any]] = []
    var connected: [[UUID]] = []
    var policy = true
    var connectFails = false
    var proposals: RelayPaneLinkProposals!

    init() {
        panes[sourceID] = RelayPaneLinkPane(id: sourceID, displayName: "claude-A", profile: remote, instance: 1)
        panes[targetID] = RelayPaneLinkPane(id: targetID, displayName: "codex-B", profile: mac, instance: 2)
        panes[otherID] = RelayPaneLinkPane(id: otherID, displayName: "claude-C", profile: mac, instance: 3)
        provenPane = sourceID
        proposals = RelayPaneLinkProposals(
            confirmer: confirmer,
            lookup: { [unowned self] in self.panes[$0] },
            redeem: { [unowned self] _, packet in
                self.redeemed.append(packet)
                guard let proven = self.provenPane else { throw RelayPaneLinkProposals.Refusal(status: 403, message: "spent") }
                return ["authority": "relayd", "source": ["authentication": "source_host_attested",
                    "attestationID": packet["attestation_id"] as? String ?? "", "paneID": proven.uuidString.lowercased()]]
            },
            connect: { [unowned self] s, t, commitGuard in
                if self.connectFails { throw RemoteCatalogError.failed("no") }
                guard commitGuard() else { throw RemoteCatalogError.failed("changed") }
                self.connected.append([s, t])
            },
            policyPermits: { [unowned self] _ in self.policy },
            now: { [unowned self] in self.clock })
    }

    static let attestation = "0123456789abcdef0123456789abcdef"

    func body(op: String = "propose", id: UUID, source: UUID? = nil, target: UUID? = nil) -> Data {
        var object: [String: Any] = ["op": op, "proposal_id": id.uuidString.lowercased(), "attestation_id": Self.attestation,
                                     "source_pane_id": (source ?? sourceID).uuidString.lowercased()]
        if op == "propose" { object["target_pane_id"] = (target ?? targetID).uuidString.lowercased() }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// Every proposal id sent through `propose`, so `drain` can await its resolution task.
    private(set) var proposed: [UUID] = []

    func propose(_ id: UUID = UUID(), source: UUID? = nil, target: UUID? = nil, caller: String = "caller-a") async -> (status: Int, value: [String: Any]) {
        proposed.append(id)
        return await proposals.handle(body: body(id: id, source: source, target: target), caller: caller)
    }

    /// The fixture's closures capture it unowned, and a proposal's resolution task can outlive a
    /// test body that stops awaiting it. Every test ends here: stop holding, answer any held prompt,
    /// and await every queued resolution while the fixture is still alive.
    func drain() async {
        confirmer.hold = false
        confirmer.release()
        for id in proposed { await proposals.resolution(of: id) }
    }

    func status(_ id: UUID, caller: String = "caller-a") async -> String? {
        let r = await proposals.handle(body: body(op: "status", id: id), caller: caller)
        return r.value["status"] as? String
    }
}

@MainActor
@Suite struct RelayPaneLinkProposalTests {
    @Test func allowCreatesTheLinkExactlyOnce() async {
        let f = Fixture(); f.confirmer.decision = .allow
        let id = UUID()
        let r = await f.propose(id)
        #expect(r.status == 200 && r.value["status"] as? String == "pending")
        await f.proposals.resolution(of: id)
        #expect(await f.status(id) == "approved")
        #expect(f.connected == [[f.sourceID, f.targetID]])
        _ = await f.propose(id)            // an identical retry must not link again
        _ = await f.status(id)
        #expect(f.connected.count == 1 && f.confirmer.prompts.count == 1)
        await f.drain()
    }

    @Test func denyNeverLinks() async {
        let f = Fixture(); f.confirmer.decision = .deny
        let id = UUID(); _ = await f.propose(id)
        await f.proposals.resolution(of: id)
        #expect(await f.status(id) == "denied" && f.connected.isEmpty)
        await f.drain()
    }

    @Test func noConfirmationWindowIsDeniedNotApproved() async {
        let f = Fixture(); f.confirmer.decision = .unavailable
        let id = UUID(); _ = await f.propose(id)
        await f.proposals.resolution(of: id)
        #expect(await f.status(id) == "denied" && f.connected.isEmpty)
        await f.drain()
    }

    @Test func timeoutExpiresAndNeverLinks() async {
        let f = Fixture(); f.confirmer.decision = .timedOut
        let id = UUID(); _ = await f.propose(id)
        await f.proposals.resolution(of: id)
        #expect(await f.status(id) == "expired" && f.connected.isEmpty)
        await f.drain()
    }

    @Test func pendingProposalExpiresByTheClockEvenIfNobodyAnswers() async {
        let f = Fixture(); f.confirmer.hold = true
        let id = UUID(); _ = await f.propose(id)
        #expect(await f.status(id) == "pending")
        f.clock = f.clock.addingTimeInterval(RelayPaneLinkProposals.expiry + 1)
        #expect(await f.status(id) == "expired")
        f.confirmer.decision = .allow          // a late Allow after expiry must not link
        f.confirmer.release()
        await f.proposals.resolution(of: id)
        #expect(await f.status(id) == "expired" && f.connected.isEmpty)
        await f.drain()
    }

    @Test func allowAfterDeadlineIsExpiredNotApproved() async {
        let f = Fixture(); f.confirmer.decision = .allow
        f.confirmer.beforeAnswer = { f.clock = f.clock.addingTimeInterval(RelayPaneLinkProposals.expiry + 1) }
        let id = UUID(); _ = await f.propose(id)
        await f.proposals.resolution(of: id)
        #expect(await f.status(id) == "expired" && f.connected.isEmpty)
        await f.drain()
    }

    @Test func attestationForAnotherPaneIsRejectedBeforeAnything() async {
        let f = Fixture()
        f.provenPane = f.otherID                    // the proof proves another pane than the claimed source
        let r = await f.propose()
        #expect(r.status == 403)
        #expect(f.confirmer.prompts.isEmpty && f.proposals.entries.isEmpty && f.connected.isEmpty)
        await f.drain()
    }

    @Test func spentOrUnverifiableAttestationIsRejected() async {
        let f = Fixture(); f.provenPane = nil
        #expect(await f.propose().status == 403)
        #expect(f.confirmer.prompts.isEmpty)
        await f.drain()
    }

    @Test func attestationIsBoundToTheOperationBothPanesAndTheProposalId() async {
        let f = Fixture(); f.confirmer.decision = .deny
        let id = UUID(); _ = await f.propose(id)
        let packet = f.redeemed[0]
        #expect(packet["operation"] as? String == "attest_consume")
        #expect(packet["pane_id"] as? String == f.targetID.uuidString.lowercased())
        #expect(packet["message_id"] as? String == id.uuidString.lowercased())
        #expect(packet["text"] as? String == RelayPaneLinkProposals.canonicalText(op: "propose", source: f.sourceID, target: f.targetID, proposal: id))
        #expect(!(packet["text"] as! String).hasPrefix(RelayMikoSupervisorChannel.prefix))
        // A status read spends a proof bound to "status", not to a target.
        _ = await f.status(id)
        #expect(f.redeemed[1]["pane_id"] as? String == RelayPaneLinkProposals.statusInboxID)
        await f.drain()
    }

    @Test func unknownTargetAndNonTerminalTargetAreRefused() async {
        let f = Fixture()
        #expect(await f.propose(target: UUID()).status == 404)
        f.panes[f.targetID] = RelayPaneLinkPane(id: f.targetID, displayName: "editor", profile: f.mac, instance: 2, isAgentTerminal: false)
        #expect(await f.propose().status == 404)
        #expect(f.confirmer.prompts.isEmpty)
        await f.drain()
    }

    @Test func malformedAndUnknownSourceAreRefused() async {
        let f = Fixture()
        #expect(await f.proposals.handle(body: Data("{}".utf8), caller: "c").status == 400)
        #expect(await f.propose(source: UUID()).status == 403)
        #expect(await f.propose(target: f.sourceID).status == 400)
        #expect(await f.proposals.handle(body: f.body(id: UUID()), caller: RelayCallerControl.assistantCaller).status == 403)
        f.policy = false
        #expect(await f.propose().status == 403)
        await f.drain()
    }

    @Test func duplicatePairWhilePendingIsRefusedAndPromptsOnce() async {
        let f = Fixture(); f.confirmer.hold = true
        let first = UUID(); _ = await f.propose(first)
        let second = await f.propose(UUID())
        #expect(second.status == 409)
        // The reverse direction is the same pair.
        f.provenPane = f.targetID
        let reverse = await f.proposals.handle(body: f.body(id: UUID(), source: f.targetID, target: f.sourceID), caller: "caller-a")
        #expect(reverse.status == 409)
        f.confirmer.release()
        await f.proposals.resolution(of: first)
        #expect(f.confirmer.prompts.count == 1)
        await f.drain()
    }

    @Test func sameIdSameContentReturnsTheSameProposalAndDifferentContentConflicts() async {
        let f = Fixture(); f.confirmer.hold = true
        let id = UUID(); _ = await f.propose(id)
        let again = await f.propose(id)
        #expect(again.status == 200 && again.value["proposal_id"] as? String == id.uuidString.lowercased())
        #expect(await f.propose(id, target: f.otherID).status == 409)
        #expect(await f.propose(id, caller: "caller-b").status == 403)
        #expect(f.proposals.entries.count == 1)
        await f.drain()
    }

    @Test func statusIsReadableOnlyByTheProposer() async {
        let f = Fixture(); f.confirmer.hold = true
        let id = UUID(); _ = await f.propose(id)
        #expect(await f.status(id) == "pending")
        #expect(await f.status(id, caller: "caller-b") == nil)
        f.provenPane = f.otherID
        #expect(await f.status(id) == nil)       // a proof for another pane cannot read it
        await f.drain()
    }

    @Test func rateLimitPerSourcePane() async {
        let f = Fixture(); f.confirmer.decision = .deny
        for _ in 0..<RelayPaneLinkProposals.rateLimit {
            let id = UUID()
            #expect(await f.propose(id).status == 200)
            await f.proposals.resolution(of: id)
        }
        #expect(await f.propose().status == 429)
        f.clock = f.clock.addingTimeInterval(RelayPaneLinkProposals.rateWindow + 1)
        #expect(await f.propose().status == 200)
        await f.drain()
    }

    @Test func forgedSourceDoesNotConsumeTheRealPanesRateLimit() async {
        let f = Fixture(); f.confirmer.decision = .deny
        f.provenPane = f.otherID
        for _ in 0..<(RelayPaneLinkProposals.rateLimit + 2) { _ = await f.propose() }
        f.provenPane = f.sourceID
        #expect(await f.propose().status == 200)
        await f.drain()
    }

    @Test func allowAfterAPaneWasReboundOrClosedIsDeniedAndNeverLinks() async {
        for mutation in ["rebound", "closed", "host", "policy"] {
            let f = Fixture(); f.confirmer.decision = .allow
            f.confirmer.beforeAnswer = {
                switch mutation {
                case "rebound": f.panes[f.targetID] = RelayPaneLinkPane(id: f.targetID, displayName: "codex-B", profile: f.mac, instance: 99)
                case "closed": f.panes[f.sourceID] = nil
                case "host": f.panes[f.targetID] = RelayPaneLinkPane(id: f.targetID, displayName: "codex-B", profile: f.remote, instance: 2)
                default: f.policy = false
                }
            }
            let id = UUID(); _ = await f.propose(id)
            await f.proposals.resolution(of: id)
            #expect(f.proposals.entries[id]?.status == .denied, "\(mutation)")
            #expect(f.connected.isEmpty, "\(mutation)")
            await f.drain()
        }
    }

    @Test func connectFailureIsDeniedNotApproved() async {
        let f = Fixture(); f.confirmer.decision = .allow; f.connectFails = true
        let id = UUID(); _ = await f.propose(id)
        await f.proposals.resolution(of: id)
        #expect(f.proposals.entries[id]?.status == .denied)
        await f.drain()
    }

    @Test func tableIsBounded() async {
        let f = Fixture(); f.confirmer.hold = true
        for i in 0..<RelayPaneLinkProposals.tableLimit {
            let target = UUID(); f.panes[target] = RelayPaneLinkPane(id: target, displayName: "t\(i)", profile: f.mac, instance: 100 + i)
            let source = UUID(); f.panes[source] = RelayPaneLinkPane(id: source, displayName: "s\(i)", profile: f.remote, instance: 1000 + i)
            f.provenPane = source
            #expect(await f.propose(UUID(), source: source, target: target).status == 200)
        }
        let target = UUID(); f.panes[target] = RelayPaneLinkPane(id: target, displayName: "x", profile: f.mac, instance: 7)
        f.provenPane = f.sourceID
        #expect(await f.propose(UUID(), target: target).status == 429)
        await f.drain()
    }

    @Test func confirmationNamesBothPanesBothHostsAndWhatTheLinkAllows() async {
        let f = Fixture(); f.confirmer.hold = true
        _ = await f.propose()
        for _ in 0..<20 { await Task.yield() }
        let text = f.confirmer.prompts.first?.text ?? ""
        for needle in ["claude-A", "codex-B", "dandy-07", "This Mac", "send messages to each other", "Deny is the default"] {
            #expect(text.contains(needle), "\(needle)")
        }
        await f.drain()
    }
}

// MARK: Production commit boundary
//
// The real RelayPaneMessaging.connect (with its endpoint-discovery awaits and its local link
// store in a temporary directory) runs behind the real commit guard built by
// RelayPaneLinkProposals. Only the host round trip of endpoint discovery is replaced.

@MainActor
private final class BoundaryFixture {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-link-boundary-" + UUID().uuidString)
    let messaging: RelayPaneMessaging
    let confirmer = FakeConfirmer()
    var proposals: RelayPaneLinkProposals!
    let source: PaneModel
    let target: PaneModel
    var endpointCalls = 0
    var connectCalls = 0
    /// Runs inside the first endpoint await of connect.
    var duringFirstEndpoint: (() -> Void)?
    /// When set, the proposal layer sees the target as a different pane (replaced, or on another host).
    var targetSwapped = false

    init() throws {
        // The link store refuses a group- or world-accessible directory, as the production store does.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        messaging = RelayPaneMessaging(linksDirectory: directory)
        workspace.newTab(profile: .sshConfigHost("boundary-source.invalid"))
        source = try #require(workspace.activePane)
        workspace.newTab(profile: ConnectionProfile(name: "Boundary Mac", kind: .local, backend: .relay))
        target = try #require(workspace.activePane)
        messaging.nativeRequestOverride = { [unowned self] pane, _ in
            self.endpointCalls += 1
            if self.endpointCalls == 1 {
                self.duringFirstEndpoint?()
                await Task.yield()     // the await a real host round trip would be
            }
            let n = abs(pane.id.hashValue % 100_000) + 10
            return ["endpoint": ["pid": n, "start": "start-\(n)", "provider": "claude", "sessionID": "session-\(n)",
                "rootPID": n + 1, "rootStart": "root-\(n)", "socketPath": "/tmp/boundary-\(n).sock",
                "socketIdentity": "id-\(n)", "socketPID": n, "socketStart": "start-\(n)", "transport": "unix"]]
        }
        proposals = RelayPaneLinkProposals(
            confirmer: confirmer,
            lookup: { [unowned self] id in
                if self.targetSwapped, id == self.target.id {
                    return RelayPaneLinkPane(id: id, displayName: self.target.displayName,
                        profile: ConnectionProfile(name: "Elsewhere", kind: .ssh, host: "elsewhere.invalid", backend: .relay), instance: 777)
                }
                return RelayPaneLinkPane(self.workspace.panes[id])
            },
            redeem: { _, packet in
                ["authority": "relayd", "source": ["authentication": "source_host_attested",
                    "attestationID": packet["attestation_id"] as? String ?? "",
                    "paneID": packet["source_pane_id"] as? String ?? ""]]
            },
            connect: { [unowned self] s, t, commitGuard in
                self.connectCalls += 1
                _ = try await self.messaging.connect(panes: [s, t], workspace: self.workspace, commitGuard: commitGuard)
            },
            policyPermits: { _ in true })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func savedLinkFiles() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }

    func propose(_ id: UUID) async -> Int {
        let body = try! JSONSerialization.data(withJSONObject: ["op": "propose", "proposal_id": id.uuidString.lowercased(),
            "attestation_id": "0123456789abcdef0123456789abcdef", "source_pane_id": source.id.uuidString.lowercased(),
            "target_pane_id": target.id.uuidString.lowercased()])
        return await proposals.handle(body: body, caller: "caller-a").status
    }
}

@MainActor
@Suite struct RelayPaneLinkCommitBoundaryTests {
    @Test func targetSwappedDuringTheFirstEndpointAwaitWritesNothingAndIsDenied() async throws {
        let f = try BoundaryFixture(); f.confirmer.decision = .allow
        f.duringFirstEndpoint = { f.targetSwapped = true }   // after the pre-connect revalidation passed
        let id = UUID()
        #expect(await f.propose(id) == 200)
        await f.proposals.resolution(of: id)
        #expect(f.endpointCalls >= 1 && f.connectCalls == 1)
        #expect(f.savedLinkFiles() == 0)
        #expect(f.proposals.entries[id]?.status == .denied)
        #expect(f.proposals.entries[id]?.reason == "panes_changed_or_policy_revoked")
    }

    @Test func unchangedPanesWriteTheLinkExactlyOnce() async throws {
        let f = try BoundaryFixture(); f.confirmer.decision = .allow
        let id = UUID()
        #expect(await f.propose(id) == 200)
        await f.proposals.resolution(of: id)
        #expect(f.proposals.entries[id]?.status == .approved)
        #expect(f.connectCalls == 1)
        let written = f.savedLinkFiles()
        #expect(written >= 1)
        #expect(await f.propose(id) == 200)         // an identical retry neither prompts nor links again
        #expect(f.connectCalls == 1 && f.savedLinkFiles() == written && f.confirmer.prompts.count == 1)
    }

    @Test func connectKeepsItsDefaultBehaviourWithoutAGuard() async throws {
        let f = try BoundaryFixture()
        _ = try await f.messaging.connect(panes: [f.source.id, f.target.id], workspace: f.workspace)
        #expect(f.savedLinkFiles() >= 1)
    }

    @Test func aGuardThatRefusesStopsTheWriteInsideConnect() async throws {
        let f = try BoundaryFixture()
        await #expect(throws: (any Error).self) {
            _ = try await f.messaging.connect(panes: [f.source.id, f.target.id], workspace: f.workspace, commitGuard: { false })
        }
        #expect(f.savedLinkFiles() == 0)
    }
}
