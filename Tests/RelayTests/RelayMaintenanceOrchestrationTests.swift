import Foundation
import Testing
@testable import Relay

/// The maintenance call site's orchestration after native admission, driven
/// through the real `orchestrate`, `readmissionHold`, journal and draft store.
/// Native inspection, the editor, the clock, the grant and the preference are
/// injected so an authority change can land at every suspension.
@MainActor @Suite("Maintenance restart orchestration")
struct RelayMaintenanceOrchestrationTests {
    typealias Admission = RelayAgentMaintenanceRestartAdmission
    typealias Outcome = TerminalRuntime.AgentMaintenanceSendOutcome
    typealias Grant = RelayAgentMaintenancePolicy.ModelGrant

    static let paneID = UUID(uuidString: "7d85fd72-64ec-46a4-8591-567bf64f7c93")!
    static let host = "exact-host"
    static let evidence = "evidence-1"
    static let draftText = Data("keep this draft".utf8)

    static func probe() throws -> RelayAgentMaintenanceProbe {
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","bound":false,"lifecycle":"quiet","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"resume_command":"/home/test/.local/bin/claude --resume exact-session"}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
    }

    /// Suspension points, in the order the orchestration reaches them.
    enum Point: CaseIterable { case capture, readPrompt, prepare, firstReadmit, sleep1, sleep2 }
    /// Authority or native changes an operator, the model or the agent can make.
    enum Change: CaseIterable { case none, preferenceOff, grantRevoked, grantExpired, inputChanged, ownerChanged, notQuiet }

    /// The mutable world the injected dependencies read.
    @MainActor final class World {
        let original: RelayAgentMaintenanceProbe
        var native: RelayAgentMaintenanceProbe
        var preference = true
        var inputRevision: UInt64 = 7
        let startRevision: UInt64 = 7
        let grantAtStart: Grant?
        var grant: Grant?
        var now = Date(timeIntervalSince1970: 1_000_000)
        var prompt: Data
        let journal: RelayAgentMaintenanceJournal
        let drafts: RelayAgentMaintenanceDraftStore
        let directory: URL
        var change: Change = .none
        var changeAt: Point?
        var changed = false
        var script: [Outcome] = []
        var attempts: [(probe: RelayAgentMaintenanceProbe, changed: Bool)] = []
        var readmits = 0

        init(draft: Bool, grant: Bool) throws {
            original = try RelayMaintenanceOrchestrationTests.probe()
            native = original
            prompt = draft ? RelayMaintenanceOrchestrationTests.draftText : Data()
            let g = grant ? Grant(operationID: "op", toolID: "tool", action: "repair_agent_link",
                evidenceID: RelayMaintenanceOrchestrationTests.evidence,
                expires: Date(timeIntervalSince1970: 1_000_060)) : nil
            grantAtStart = g; self.grant = g
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-orchestration-" + UUID().uuidString)
            journal = RelayAgentMaintenanceJournal(url: directory.appendingPathComponent("journal.json"))
            drafts = RelayAgentMaintenanceDraftStore(directory: directory.appendingPathComponent("drafts"))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        /// Applies the scheduled change when the orchestration reaches `point`.
        func reach(_ point: Point) {
            guard point == changeAt, !changed else { return }
            changed = true
            switch change {
            case .none: changed = false
            case .preferenceOff: preference = false
            case .grantRevoked: grant = nil
            case .grantExpired: now = Date(timeIntervalSince1970: 1_000_120)
            case .inputChanged: inputRevision += 1
            case .ownerChanged: native.processID = 43
            case .notQuiet: native.lifecycle = "busy"
            }
        }

        /// Whether the change, once applied, revokes authority. Grant changes
        /// do nothing to an operator-authorized action that had no grant.
        var authorityLost: Bool {
            guard changed else { return false }
            switch change {
            case .grantRevoked, .grantExpired: return grantAtStart != nil
            default: return true
            }
        }

        func orchestration() -> Admission.Orchestration {
            .init(
                promptIsEmpty: { self.prompt.isEmpty },
                promptHasTypedText: { !self.prompt.isEmpty },
                promptBlocker: { nil },
                provider: original.provider,
                captureDraft: { beforeApply in
                    self.reach(.capture)
                    try beforeApply(self.prompt)
                    self.prompt = Data()
                },
                readPrompt: { self.reach(.readPrompt); return self.prompt },
                preparePrompt: { self.reach(.prepare) },
                claim: {
                    try self.journal.claim(pane: RelayMaintenanceOrchestrationTests.paneID,
                        host: RelayMaintenanceOrchestrationTests.host, proof: self.original, reason: .binding,
                        modelOperationID: self.grantAtStart?.operationID, modelToolID: self.grantAtStart?.toolID)
                },
                saveDraft: { id, text in
                    try Admission.saveCapturedDraft(actionID: id, text: text,
                        paneID: RelayMaintenanceOrchestrationTests.paneID,
                        host: RelayMaintenanceOrchestrationTests.host, proof: self.original,
                        drafts: self.drafts, journal: self.journal)
                },
                mark: { id, state in try self.journal.mark(id, state) },
                readmit: {
                    self.readmits += 1
                    if self.readmits == 1 { self.reach(.firstReadmit) }
                    let refreshed = self.native
                    if let hold = Admission.readmissionHold(paneID: RelayMaintenanceOrchestrationTests.paneID,
                        original: self.original, refreshed: refreshed, paneCurrent: true,
                        automaticMaintenance: self.preference,
                        inputUnchanged: self.inputRevision == self.startRevision,
                        grantAtStart: self.grantAtStart, grantNow: self.grant, reason: .binding,
                        evidenceID: RelayMaintenanceOrchestrationTests.evidence, now: self.now) {
                        return .hold(hold)
                    }
                    return .admit(refreshed)
                },
                attempt: { probe in
                    self.attempts.append((probe, self.authorityLost))
                    return self.script[min(self.attempts.count - 1, self.script.count - 1)]
                },
                sleep: { self.reach(self.readmits == 1 ? .sleep1 : .sleep2) })
        }
    }

    enum Kind: Equatable { case held, busy, unknown, submitted }

    struct Expected: Equatable { let kind: Kind; let attempts: Int }

    /// Independent oracle: walk the suspensions in order; a readmission after
    /// a lost authority holds; only an open output phase is retried.
    static func oracle(draft: Bool, change: Change, at point: Point, grant: Bool,
                       script: [Outcome], limit: Int) -> Expected {
        let effective = change != .none &&
            !((change == .grantRevoked || change == .grantExpired) && !grant)
        var lost = false
        func reach(_ p: Point) { if p == point && effective { lost = true } }
        if draft { reach(.capture); reach(.readPrompt); reach(.prepare) }
        reach(.firstReadmit)
        if lost { return Expected(kind: .held, attempts: 0) }
        var attempts = 1
        var outcome = script[0]
        var sleeps = 0
        while outcome == .outputPhaseOpen, sleeps < limit {
            sleeps += 1
            reach(sleeps == 1 ? .sleep1 : .sleep2)
            if lost { return Expected(kind: .held, attempts: attempts) }
            outcome = script[min(attempts, script.count - 1)]
            attempts += 1
        }
        switch outcome {
        case .outputPhaseOpen: return Expected(kind: .busy, attempts: attempts)
        case .refused: return Expected(kind: .unknown, attempts: attempts)
        case .sent: return Expected(kind: .submitted, attempts: attempts)
        }
    }

    static func kind(_ d: Admission.Decision) -> (Kind, String)? {
        switch d {
        case .held(let id, _): return (.held, id)
        case .busy(let id): return (.busy, id)
        case .unknown(let id): return (.unknown, id)
        case .submitted(let id, _): return (.submitted, id)
        default: return nil
        }
    }

    static let journalState: [Kind: String] = [.held: "restart_held_changed", .busy: "restart_held_busy",
        .unknown: "restart_admission_unknown", .submitted: "restart_submitted"]

    @Test("Bounded: every authority change at every suspension, against an oracle")
    func boundedAuthorityTransitions() async throws {
        let outcomes: [Outcome] = [.sent, .outputPhaseOpen, .refused]
        var scripts: [[Outcome]] = []
        for a in outcomes { for b in outcomes { for c in outcomes { scripts.append([a, b, c]) } } }
        let limit = 2
        var cases = 0, held = 0, heldWithDraft = 0, attemptsSeen = 0
        for draft in [false, true] {
            for grant in [false, true] {
                for change in Change.allCases {
                    for point in Point.allCases {
                        for script in scripts {
                            let world = try World(draft: draft, grant: grant)
                            defer { world.cleanUp() }
                            world.change = change; world.changeAt = point; world.script = script
                            let decision = try await Admission.orchestrate(world.orchestration(), limit: limit)
                            let expected = Self.oracle(draft: draft, change: change, at: point, grant: grant,
                                script: script, limit: limit)
                            let label = "draft=\(draft) grant=\(grant) change=\(change) at=\(point) script=\(script)"
                            let got = try #require(Self.kind(decision), "\(label): \(decision)")
                            // O1: the decision and attempt count match the oracle.
                            #expect(got.0 == expected.kind && world.attempts.count == expected.attempts,
                                "\(label): got \(got.0)/\(world.attempts.count), expected \(expected)")
                            // S1: no exit is typed after authority was lost.
                            #expect(!world.attempts.contains { $0.changed }, "\(label): typed after authority was lost")
                            // S2: no second write after a sent or uncertain one.
                            let writes = world.attempts.indices.filter { script[min($0, script.count - 1)] != .outputPhaseOpen }
                            #expect(writes.count <= 1, "\(label): a second write followed \(writes.count) writes")
                            // S3: every attempt is against an exact-source, quiet probe.
                            #expect(world.attempts.allSatisfy { $0.probe.sameSource(as: world.original) && $0.probe.lifecycle == "quiet" },
                                "\(label): attempt against changed evidence")
                            // S4: the journal records the decision.
                            #expect(world.journal.entries[got.1]?.state == Self.journalState[got.0], "\(label): journal state")
                            // S5: a captured draft is saved before any exit, and a held
                            // action leaves it for the same-conversation restore flow.
                            if draft {
                                let saved = try world.drafts.load(got.1)
                                #expect(saved.text == Self.draftText, "\(label): draft backup")
                                #expect(world.journal.entries[got.1]?.draftDigest == saved.digest, "\(label): digest")
                                if got.0 == .held {
                                    heldWithDraft += 1
                                    #expect(Admission.pendingDraftRestore(world.journal, paneID: Self.paneID,
                                        host: Self.host, sessionID: "exact-session")?.id == got.1, "\(label): restore pending")
                                }
                            }
                            if got.0 == .held { held += 1 }
                            attemptsSeen += world.attempts.count
                            cases += 1
                        }
                    }
                }
            }
        }
        print("maintenance orchestration bounded check: \(cases) cases (2 draft x 2 grant x \(Change.allCases.count) changes x \(Point.allCases.count) points x \(scripts.count) scripts, retry limit \(limit)), \(held) held (\(heldWithDraft) with a saved draft), \(attemptsSeen) attempts")
        #expect(cases == 2 * 2 * Change.allCases.count * Point.allCases.count * scripts.count)
    }

    @Test("Preference turned off during draft capture: held, nothing typed, draft kept")
    func preferenceOffDuringCapture() async throws {
        let world = try World(draft: true, grant: false)
        defer { world.cleanUp() }
        world.change = .preferenceOff; world.changeAt = .capture; world.script = [.sent]
        let decision = try await Admission.orchestrate(world.orchestration())
        guard case .held(let id, let reason) = decision else { Issue.record("\(decision)"); return }
        #expect(reason == "automatic maintenance was turned off")
        #expect(world.attempts.isEmpty)
        #expect(world.journal.entries[id]?.state == "restart_held_changed")
        #expect(try world.drafts.load(id).text == Self.draftText)
    }

    @Test("Grant expiry and revocation while the prompt is read back: held before the first exit")
    func grantChangeDuringReadBack() async throws {
        for change in [Change.grantExpired, .grantRevoked] {
            let world = try World(draft: true, grant: true)
            defer { world.cleanUp() }
            world.change = change; world.changeAt = .readPrompt; world.script = [.sent]
            let decision = try await Admission.orchestrate(world.orchestration())
            guard case .held(_, let reason) = decision else { Issue.record("\(change): \(decision)"); continue }
            #expect(reason == "the model repair grant expired or changed")
            #expect(world.attempts.isEmpty, "\(change)")
        }
    }

    @Test("Unchanged authority: the first exit is sent once, against the readmitted probe")
    func unchangedFirstSend() async throws {
        let world = try World(draft: true, grant: true)
        defer { world.cleanUp() }
        world.script = [.sent]
        let decision = try await Admission.orchestrate(world.orchestration())
        guard case .submitted(let id, let probe) = decision else { Issue.record("\(decision)"); return }
        #expect(world.readmits == 1, "the first exit passed one readmission")
        #expect(world.attempts.count == 1 && probe.sameSource(as: world.original))
        #expect(world.journal.entries[id]?.state == "restart_submitted")
    }

    @Test("A later retry is held when authority changes during its wait")
    func retryHeldAfterWait() async throws {
        let world = try World(draft: false, grant: false)
        defer { world.cleanUp() }
        world.change = .inputChanged; world.changeAt = .sleep1; world.script = [.outputPhaseOpen, .sent]
        let decision = try await Admission.orchestrate(world.orchestration())
        guard case .held(let id, let reason) = decision else { Issue.record("\(decision)"); return }
        #expect(reason == "you entered input")
        #expect(world.attempts.count == 1)
        #expect(world.journal.entries[id]?.state == "restart_held_changed")
    }

    @Test("An uncertain write is never retried")
    func noSecondWriteAfterUncertainDispatch() async throws {
        let world = try World(draft: false, grant: false)
        defer { world.cleanUp() }
        world.script = [.refused, .sent]
        let decision = try await Admission.orchestrate(world.orchestration())
        guard case .unknown(let id) = decision else { Issue.record("\(decision)"); return }
        #expect(world.attempts.count == 1)
        #expect(world.readmits == 1, "no readmission after an uncertain write")
        #expect(world.journal.entries[id]?.state == "restart_admission_unknown")
    }

    @Test("A held draft is restored only through the same-conversation flow, once")
    func heldDraftRestoreSelection() async throws {
        let world = try World(draft: true, grant: false)
        defer { world.cleanUp() }
        world.change = .ownerChanged; world.changeAt = .prepare; world.script = [.sent]
        let decision = try await Admission.orchestrate(world.orchestration())
        guard case .held(let id, _) = decision else { Issue.record("\(decision)"); return }
        #expect(Admission.pendingDraftRestore(world.journal, paneID: Self.paneID, host: Self.host,
            sessionID: "exact-session")?.id == id)
        #expect(Admission.pendingDraftRestore(world.journal, paneID: Self.paneID, host: Self.host,
            sessionID: "other-session") == nil, "another conversation never receives the draft")
        #expect(Admission.pendingDraftRestore(world.journal, paneID: Self.paneID, host: "other-host",
            sessionID: "exact-session") == nil)
        try world.journal.restoredDraft(id)
        #expect(Admission.pendingDraftRestore(world.journal, paneID: Self.paneID, host: Self.host,
            sessionID: "exact-session") == nil, "a restored draft is not restored again")
        // A new action stays blocked while the held one is recent.
        #expect(try world.journal.claim(pane: Self.paneID, host: Self.host, proof: world.original, reason: .binding) == nil)
    }
}
