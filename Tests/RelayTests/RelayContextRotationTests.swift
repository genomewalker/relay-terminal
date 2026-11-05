import Foundation
import Testing
@testable import Relay

/// Automatic context rotation on stock CLIs (work/context-clear-20261101/DESIGN.md).
/// SSH hosts are .invalid and every host read goes through a fake environment,
/// so no connection, provider or file outside the test is touched.
@Suite("Context rotation", .serialized)
@MainActor
struct RelayContextRotationTests {
    // MARK: measurement

    static func claudeLine(_ input: Int, _ created: Int, _ read: Int, sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"message":{"model":"m","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(created),"cache_read_input_tokens":\#(read),"output_tokens":5}}}"#
    }
    static func codexLine(_ input: Int, window: Int? = 475_000) -> String {
        let w = window.map { #","model_context_window":\#($0)"# } ?? ""
        return #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":1}\#(w)}}}"#
    }

    @Test("Usage: the last complete provider record, cached and uncached, sidechains and partial lines ignored")
    func usage() {
        let claude = [Self.claudeLine(1, 2, 3), Self.claudeLine(2, 8451, 275_905), Self.claudeLine(9, 9, 9, sidechain: true)].joined(separator: "\n")
        #expect(RelayContextUsage.measure(tail: claude, provider: "claude", startsMidFile: false)?.contextTokens == 284_358)
        // A partial first line is never parsed, even when it happens to be valid JSON.
        #expect(RelayContextUsage.measure(tail: Self.claudeLine(1, 1, 1), provider: "claude", startsMidFile: true) == nil)
        let codex = [Self.codexLine(10), #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{}}}"#].joined(separator: "\n")
        let m = RelayContextUsage.measure(tail: codex, provider: "codex", startsMidFile: false)
        #expect(m?.contextTokens == 10 && m?.window == 475_000)
        // Inconsistent or non-integer counters abstain instead of being guessed.
        for bad in [#"{"type":"assistant","message":{"usage":{"input_tokens":true}}}"#,
                    #"{"type":"assistant","message":{"usage":{"input_tokens":1.5}}}"#,
                    #"{"type":"assistant","message":{"usage":{"input_tokens":-1}}}"#,
                    #"{"type":"assistant","message":{"usage":{"input_tokens":0}}}"#] {
            #expect(RelayContextUsage.measure(tail: bad, provider: "claude", startsMidFile: false) == nil, "\(bad)")
        }
        #expect(RelayContextUsage.measure(tail: Self.codexLine(10), provider: "claude", startsMidFile: false) == nil)
        #expect(RelayContextUsage.measure(tail: Self.codexLine(10), provider: "other", startsMidFile: false) == nil)
        #expect(RelayStockRotationPolicy.over(.init(provider: "codex", contextTokens: 427_500, window: 475_000), budget: 10_000_000))
        #expect(!RelayStockRotationPolicy.over(.init(provider: "codex", contextTokens: 427_499, window: 475_000), budget: 10_000_000))
        #expect(RelayStockRotationPolicy.over(.init(provider: "claude", contextTokens: 160_000, window: nil), budget: 160_000))
        #expect(!RelayStockRotationPolicy.over(.init(provider: "claude", contextTokens: 159_999, window: nil), budget: 160_000))
    }

    @Test("Capsule: exact header, size bound, no history marker, valid UTF-8")
    func capsule() {
        let t = UUID(), nonce = "n-1"
        let header = RelayContextCapsule.header(t)
        func check(_ text: String) -> RelayContextCapsule.Refusal? {
            if case .failure(let r) = RelayContextCapsule.validate(Data(text.utf8), transition: t, nonce: nonce) { return r }
            return nil
        }
        #expect(check(header + "\nGoal: x") == nil)
        #expect(check(RelayContextCapsule.header(UUID()) + "\nGoal") == .header)
        #expect(check(header + "\n" + String(repeating: "x", count: 6000)) == .oversize)
        #expect(check(header + "\nmarker n-1") == .historyMarker)
        #expect(check(header + "\n   \n") == .empty)
        #expect(check("") == .empty)
        if case .failure(let r) = RelayContextCapsule.validate(Data([0xFF, 0xFE]), transition: t, nonce: nonce) { #expect(r == .encoding) }
        #expect(RelayStockRotationPolicy.admits("/clear", kind: .clear))
        #expect(!RelayStockRotationPolicy.admits("/clear\r/exit", kind: .clear))
        #expect(!RelayStockRotationPolicy.admits("/exit", kind: .clear))
        #expect(RelayStockRotationPolicy.admits(RelayContextCapsule.request(transition: t, nonce: nonce), kind: .capsuleRequest))
        #expect(!RelayStockRotationPolicy.admits(RelayContextCapsule.request(transition: t, nonce: nonce), kind: .restore))
        #expect(RelayStockRotationPolicy.admits(RelayContextCapsule.restore(transition: t, capsule: header + "\nG"), kind: .restore))
        #expect(!RelayStockRotationPolicy.admits("relay-capsule-restore " + String(repeating: "x", count: 9000), kind: .restore))
    }

    // MARK: exhaustive state graph

    @Test("Machine: every reachable state under every event keeps S1-S6, the graph is acyclic and L1 holds")
    func machineExhaustive() {
        typealias M = RelayContextRotationMachine
        var seen: Set<M.State> = [.idle], queue: [M.State] = [.idle], edges = 0
        var graph: [M.State: Set<M.State>] = [:]
        while let state = queue.popLast() {
            for event in M.Event.allCases {
                let (next, action) = M.step(state, event)
                edges += 1
                // S1-S2 and each typing action's single source state.
                switch action {
                case .typeCapsuleRequest: #expect(state == .armed && next == .sendingCapsuleRequest)
                case .typeClear: #expect(state == .capsuleVerified && next == .sendingClear, "S1 clear without a verified capsule")
                case .typeRestore: #expect(state == .clearVerified && next == .sendingRestore, "S2 restore without a verified clear")
                case .readCapsule, .readBinding, .readAck: #expect(next == state)
                case .signal, .claim, .saveCapsule, .recordIntent, .bind, .ack, .release:
                    Issue.record("r2: the file path emitted ledger action \(action!) from \(state) on \(event)")
                case nil: break
                }
                // r2: Chitta outcomes never move a file-path transition.
                if M.ledgerOutcomes.contains(event) { #expect(next == state && action == nil) }
                // S4 nothing after terminal states or an unconfirmed send.
                if state.terminal { #expect(next == state && action == nil) }
                if event == .sendUnconfirmed, M.isSending(state) { #expect(next == .attention) }
                // S5 input before the clear stops with no typing; after it, attention.
                if event == .humanInput, state != .idle, !state.terminal {
                    #expect(action == nil && next == (state.beforeClear && !M.isSending(state) ? .aborted : .attention))
                }
                // S6 a restart while sending is never resumed as a send.
                if event == .appRestart { #expect(action == nil && next == (M.isSending(state) ? .attention : state)) }
                if next != state { graph[state, default: []].insert(next) }
                if seen.insert(next).inserted { queue.append(next) }
            }
        }
        // Acyclic apart from self-loops: each typing action happens at most once per transition (S3).
        func cyclic(_ s: M.State, _ path: Set<M.State>) -> Bool {
            guard !path.contains(s) else { return true }
            return (graph[s] ?? []).contains { cyclic($0, path.union([s])) }
        }
        #expect(!cyclic(.idle, []))
        // L1: the clean sequence reaches done with exactly the three typing actions in order.
        let clean: [M.Event] = [.measuredOver, .fenceOpen, .sendOK, .turnCompleted, .capsuleOK, .fenceOpen, .sendOK,
                                .turnCompleted, .bindingNew, .fenceOpen, .sendOK, .turnCompleted, .ackSeen]
        var state = M.State.idle, actions: [M.Action] = []
        for e in clean { let (n, a) = M.step(state, e); state = n; if let a { actions.append(a) } }
        #expect(state == .done)
        #expect(actions.filter { [.typeCapsuleRequest, .typeClear, .typeRestore].contains($0) } == [.typeCapsuleRequest, .typeClear, .typeRestore])
        // r2: exactly the r1 states; the five Chitta-only states are unreachable on the file path.
        let ledgerOnly: Set<M.State> = [.signaled, .claimed, .intentRecorded, .clearSeen, .acknowledging]
        #expect(seen == Set(M.State.allCases).subtracting(ledgerOnly), "file path states: \(seen)")
        print("RelayContextRotationMachine exhaustive: states=\(seen.count) events=\(M.Event.allCases.count) edges=\(edges)")
    }

    // MARK: coordinator with a fake host

    @MainActor final class FakeHost: RelayContextRotationEnvironment {
        var enabled = true
        var enrollment: RelayContextRotationEnrollment?
        var budget = 100
        var provider = "claude"
        var pid = 4242
        var start: UInt64 = 77
        var session = "old-session"
        var transcript = "/h/old.jsonl"
        var quiet = true
        var blocker: String? = nil
        var files: [String: String] = [:]
        var sent: [(RelayContextRotationInput, String)] = []
        var sendResult = true
        /// What the fake agent does after each input.
        var writesCapsule = true
        var capsuleOverride: ((UUID, String) -> String)?
        var clearKeepsNonce = false
        var acknowledges = true
        var unreachable: Set<String> = []
        weak var pane: PaneModel?
        /// r2: these r1 tests exercise the file path, which runs when chitta is absent on the host.
        var ledgerCalls: [String] = []

        func ledger(_ profile: ConnectionProfile, op: String, args: [String: Any]) async -> RelayRotationLedgerReply {
            ledgerCalls.append(op)
            return .missing
        }

        func observe(_ pane: PaneModel) async -> RelayContextRotationObservation? {
            .init(provider: provider, processID: pid, processStart: start, sessionID: session, transcriptPath: transcript,
                  quiet: quiet, fenceBlocker: blocker)
        }
        func tail(_ profile: ConnectionProfile, path: String, maxBytes: Int) async -> (text: String, partial: Bool)? {
            guard !unreachable.contains(path), let text = files[path] else { return nil }
            let data = Data(text.utf8)
            return data.count > maxBytes ? (String(decoding: data.suffix(maxBytes), as: UTF8.self), true) : (text, false)
        }
        func liveBlocker(_ pane: PaneModel, _ text: String, kind: RelayContextRotationInput,
                         observation: RelayContextRotationObservation, inputRevision: UInt64) -> String? {
            RelayStockRotationPolicy.admits(text, kind: kind) && pane.agentInputRevision == inputRevision ? nil : "changed"
        }
        func send(_ pane: PaneModel, _ text: String, kind: RelayContextRotationInput,
                  observation: RelayContextRotationObservation, inputRevision: UInt64) -> Bool {
            guard RelayStockRotationPolicy.admits(text, kind: kind), pane.agentInputRevision == inputRevision else { return false }
            sent.append((kind, text))
            guard sendResult else { return false }
            pane.userEnteredInput()
            let id = text.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, options: .regularExpression)
                .map { String(text[$0]) }
            switch kind {
            case .capsuleRequest:
                guard writesCapsule, let id, let t = UUID(uuidString: id) else { break }
                let nonce = text.range(of: #"relay-history-marker [0-9a-f-]{36}"#, options: .regularExpression).map { String(text[$0]).components(separatedBy: " ")[1] } ?? ""
                files[RelayContextCapsule.path(t)] = capsuleOverride?(t, nonce) ?? RelayContextCapsule.header(t) + "\nGoal: finish\nNext step: test"
                // The whole request, marker included, is now part of the old history.
                let line = try! JSONSerialization.data(withJSONObject: ["type": "user", "message": ["content": text]])
                files[transcript, default: ""] += "\n" + String(decoding: line, as: UTF8.self)
            case .clear:
                let old = files[transcript] ?? ""
                session = "new-session"; transcript = "/h/new.jsonl"
                files[transcript] = clearKeepsNonce ? old : ""
            case .restore:
                guard let id else { break }
                files[transcript, default: ""] += "\n" + #"{"type":"user","message":{"content":"relay-capsule-restore \#(id)"}}"#
                    + "\n" + #"{"type":"user","message":{"content":"\#(RelayContextCapsule.header(UUID(uuidString: id)!))"}}"#
                if acknowledges {
                    files[transcript]! += "\n" + #"{"type":"assistant","message":{"content":[{"type":"text","text":"ACK \#(id)"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":4,"cache_read_input_tokens":5}}}"#
                }
            }
            return true
        }
    }

    @MainActor final class Fixture {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let host = FakeHost()
        let journalURL = FileManager.default.temporaryDirectory.appendingPathComponent("relay-rotation-\(UUID().uuidString).json")
        var rotation: RelayContextRotation
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let pane: PaneModel

        init() {
            workspace.newTab(profile: .sshConfigHost("rotation-host.invalid"))
            pane = workspace.activePane!
            rotation = RelayContextRotation(journal: RelayContextRotationJournal(url: journalURL), environment: host)
            host.enrollment = .init(paneID: pane.id, provider: host.provider, processID: host.pid, processStart: host.start)
            host.files[host.transcript] = [RelayContextRotationTests.claudeLine(50, 50, 50)].joined(separator: "\n")
            rotation.now = { [unowned self] in self.clock }
        }

        func restart() {
            rotation = RelayContextRotation(journal: RelayContextRotationJournal(url: journalURL), environment: host)
            rotation.now = { [unowned self] in self.clock }
        }

        /// r3: arming types nothing in its own tick; the next tick observes again and types the capsule request.
        /// Brings a fresh fixture to "capsule request typed", the point r1/r2 reached with one advance.
        func armAndRequest() async {
            await rotation.advance(pane, workspace: workspace)
            #expect(host.sent.isEmpty && record?.state == .armed, "arming types nothing in its own tick")
            clock = clock.addingTimeInterval(20)
            await rotation.advance(pane, workspace: workspace)
        }

        /// Advances until terminal (or `limit` steps), letting time pass between steps.
        func run(_ limit: Int = 40) async -> RelayContextRotationRecord? {
            for _ in 0..<limit {
                await rotation.advance(pane, workspace: workspace)
                clock = clock.addingTimeInterval(20)
                if let r = record, r.state.terminal { return r }
            }
            return record
        }

        var record: RelayContextRotationRecord? { rotation.journal.records.values.max { $0.createdAt < $1.createdAt } }
        var kinds: [RelayContextRotationInput] { host.sent.map(\.0) }
        deinit { try? FileManager.default.removeItem(at: journalURL) }
    }

    @Test("L1: a measured-over pane rotates once: capsule request, /clear, restore, ACK, with the archive kept")
    func cleanRotation() async {
        let f = Fixture()
        defer { f.workspace.shutdown() }
        let r = await f.run()
        #expect(r?.state == .done)
        #expect(f.kinds == [.capsuleRequest, .clear, .restore])
        #expect(f.host.sent[1].1 == "/clear")
        #expect(r?.sourceSession == "old-session" && r?.sourceTranscript == "/h/old.jsonl", "the archive reference is kept")
        #expect(r?.newSession == "new-session" && r?.measuredTokens == 150 && r?.newMeasuredTokens == 12)
        #expect(f.host.sent[2].1.contains(RelayContextCapsule.header(r!.transition)), "the exact capsule is restored")
        // r2: chitta absent -> the file path, decided once at arming, with the reason kept.
        #expect(r?.ledger == nil && r?.pathNote?.contains("not installed") == true)
        #expect(f.host.ledgerCalls == ["rotation_status"])
        // Cooldown: no second rotation right away.
        await f.rotation.advance(f.pane, workspace: f.workspace)
        #expect(f.kinds.count == 3)
    }

    @Test("Enrollment: only the exact enrolled pane and provider process incarnation is ever typed into")
    func enrollment() async {
        let other = { (f: Fixture) -> RelayContextRotationEnrollment in f.host.enrollment! }
        for (name, change) in [("none", { (f: Fixture) in f.host.enrollment = nil }),
                               ("other pane", { f in let e = other(f); f.host.enrollment = .init(paneID: UUID(), provider: e.provider, processID: e.processID, processStart: e.processStart) }),
                               ("other provider", { f in let e = other(f); f.host.enrollment = .init(paneID: e.paneID, provider: "codex", processID: e.processID, processStart: e.processStart) }),
                               ("other pid", { f in let e = other(f); f.host.enrollment = .init(paneID: e.paneID, provider: e.provider, processID: e.processID + 1, processStart: e.processStart) }),
                               ("restarted agent", { f in let e = other(f); f.host.enrollment = .init(paneID: e.paneID, provider: e.provider, processID: e.processID, processStart: e.processStart + 1) })] {
            let f = Fixture()
            change(f)
            _ = await f.run(6)
            #expect(f.host.sent.isEmpty, "\(name): nothing typed")
            #expect(f.record == nil, "\(name): nothing armed")
            f.workspace.shutdown()
        }
        // Unenrolled mid-rotation, before the clear: stops with the conversation intact.
        let f = Fixture()
        await f.armAndRequest()
        #expect(f.kinds == [.capsuleRequest])
        f.host.enrollment = nil
        f.clock = f.clock.addingTimeInterval(20)
        #expect(await f.run()?.state == .aborted)
        #expect(f.kinds == [.capsuleRequest])
        f.workspace.shutdown()
        // The persisted form round-trips exactly.
        let e = RelayContextRotationEnrollment(paneID: UUID(), provider: "codex", processID: 9, processStart: 1 << 40)
        #expect(try! JSONDecoder().decode(RelayContextRotationEnrollment.self, from: JSONEncoder().encode(e)) == e)
    }

    @Test("Below budget, unmeasured, disabled or fenced panes are never typed into")
    func noRotation() async {
        for setup in [{ (h: FakeHost) in h.budget = 1_000 }, { $0.files = [:] }, { $0.enabled = false },
                      { $0.blocker = "Waiting for the prompt to be confirmed empty" }, { $0.quiet = false }] {
            let f = Fixture()
            setup(f.host)
            _ = await f.run(6)
            #expect(f.host.sent.isEmpty)
            f.workspace.shutdown()
        }
    }

    @Test("Two actors: human input at every suspension point before the clear aborts with nothing more typed")
    func humanInputInterleavings() async {
        var firedCases = 0, abortedCases = 0
        for point in 0...6 {
            for afterSends in 0...2 {
                let f = Fixture()
                var fired = false
                f.rotation.suspension = { index in
                    // Only while a transition exists; input before one only delays measurement (asserted below).
                if !fired, index == point, f.host.sent.count == afterSends, let r = f.record, !r.state.terminal {
                    fired = true; f.pane.userEnteredInput()
                }
                }
                let r = await f.run()
                let sentAfter = f.host.sent.count
                if fired {
                    firedCases += 1
                    if r?.state == .aborted { abortedCases += 1 }
                    #expect(r?.state == .aborted || r?.state == .attention, "point \(point) after \(afterSends): \(String(describing: r?.state))")
                    #expect(sentAfter <= afterSends + 1, "typed after human input at point \(point)")
                    if afterSends < 2 { #expect(!f.kinds.contains(.restore)) }
                    if afterSends == 0 { #expect(!f.kinds.contains(.clear), "cleared after human input before the clear") }
                    if r?.state == .aborted { #expect(!f.kinds.contains(.clear)) }
                }
                f.workspace.shutdown()
            }
        }
        // Liveness of the check itself: the interleavings really happened, both outcomes.
        #expect(abortedCases >= 3 && firedCases - abortedCases >= 3, "fired=\(firedCases) aborted=\(abortedCases)")
        print("RelayContextRotation interleavings: points=7 sendDepths=3 fired=\(firedCases) aborted=\(abortedCases)")
    }

    @Test("Human input before any transition exists is never typed over in that tick")
    func humanInputBeforeArming() async {
        for point in 0...2 {
            let f = Fixture()
            var fired = false
            f.rotation.suspension = { index in if !fired, index == point { fired = true; f.pane.userEnteredInput() } }
            await f.rotation.advance(f.pane, workspace: f.workspace)
            #expect(fired && f.host.sent.isEmpty && f.record == nil, "point \(point)")
            f.workspace.shutdown()
        }
    }

    @Test("Faults: bad capsule aborts before clear; an unconfirmed send, old history after clear and a missing ACK need attention")
    func faults() async {
        var f = Fixture()
        f.host.capsuleOverride = { t, _ in "wrong header\n" + RelayContextCapsule.header(t) }
        #expect(await f.run()?.state == .aborted)
        #expect(f.kinds == [.capsuleRequest])
        f.workspace.shutdown()

        f = Fixture()
        f.host.capsuleOverride = { t, nonce in RelayContextCapsule.header(t) + "\ncopied " + nonce }
        #expect(await f.run()?.state == .aborted)
        #expect(!f.kinds.contains(.clear))
        f.workspace.shutdown()

        f = Fixture()
        f.host.writesCapsule = false
        #expect(await f.run(60)?.state == .aborted, "no capsule by the deadline")
        #expect(f.kinds == [.capsuleRequest])
        f.workspace.shutdown()

        f = Fixture()
        f.host.sendResult = false
        #expect(await f.run()?.state == .attention)
        #expect(f.host.sent.count == 1, "an unconfirmed send is never repeated")
        f.workspace.shutdown()

        f = Fixture()
        f.host.clearKeepsNonce = true
        #expect(await f.run()?.state == .attention)
        #expect(!f.kinds.contains(.restore))
        f.workspace.shutdown()

        f = Fixture()
        f.host.acknowledges = false
        #expect(await f.run(80)?.state == .attention)
        #expect(f.kinds == [.capsuleRequest, .clear, .restore])
        f.workspace.shutdown()

        f = Fixture()
        // The capsule changes between verification and restore: never restored.
        await f.armAndRequest()
        f.clock = f.clock.addingTimeInterval(20)
        await f.rotation.advance(f.pane, workspace: f.workspace)
        if let t = f.record?.transition, f.record?.state == .capsuleVerified {
            f.host.files[RelayContextCapsule.path(t)]! += "\nedited later"
        }
        f.clock = f.clock.addingTimeInterval(20)
        #expect(await f.run()?.state == .attention)
        #expect(f.kinds == [.capsuleRequest, .clear], "a changed capsule is not restored")
        f.workspace.shutdown()

        f = Fixture()
        f.rotation.journal.failWrites = true
        _ = await f.run(6)
        #expect(f.host.sent.isEmpty, "nothing is typed when the record cannot be saved")
        f.workspace.shutdown()
    }

    @Test("Restart: a persisted send in flight becomes attention and is not repeated; settled steps resume")
    func restart() async throws {
        let f = Fixture()
        defer { f.workspace.shutdown() }
        // Stop exactly between persisting sendingClear and the send's outcome.
        await f.armAndRequest()  // arm, then capsule request
        f.clock = f.clock.addingTimeInterval(20)
        await f.rotation.advance(f.pane, workspace: f.workspace)  // capsule verified
        var r = try #require(f.record)
        #expect(r.state == .capsuleVerified)
        r.state = .sendingClear
        #expect(f.rotation.journal.put(r))
        f.restart()
        #expect(f.record?.state == .attention)
        _ = await f.run(4)
        #expect(f.kinds == [.capsuleRequest], "the clear is not typed after a restart in flight")

        // A restart in a settled state resumes it.
        let g = Fixture()
        await g.armAndRequest()
        g.restart()
        g.clock = g.clock.addingTimeInterval(20)
        #expect(await g.run()?.state == .done)
        #expect(g.kinds == [.capsuleRequest, .clear, .restore])
        g.workspace.shutdown()
    }

    @Test("Identity: another provider process or conversation stops the rotation; turning it off mid-way never clears")
    func identityAndSetting() async {
        var f = Fixture()
        await f.armAndRequest()
        f.host.pid = 9999
        f.clock = f.clock.addingTimeInterval(20)
        #expect(await f.run()?.state == .aborted)
        #expect(f.kinds == [.capsuleRequest])
        f.workspace.shutdown()

        f = Fixture()
        await f.armAndRequest()
        f.host.session = "someone-else"
        f.clock = f.clock.addingTimeInterval(20)
        #expect(await f.run()?.state == .aborted)
        #expect(!f.kinds.contains(.clear))
        f.workspace.shutdown()

        f = Fixture()
        await f.armAndRequest()
        f.host.enabled = false
        f.clock = f.clock.addingTimeInterval(20)
        #expect(await f.run()?.state == .aborted)
        #expect(!f.kinds.contains(.clear))
        f.workspace.shutdown()
    }

    // MARK: fuzz

    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    }

    @Test("Fuzz: usage parser results equal an independent oracle; capsule acceptance implies every bound")
    func fuzz() {
        var rng = SplitMix64(state: 20_261_102)
        let atoms = [Self.claudeLine(1, 2, 3), Self.claudeLine(7, 0, 0, sidechain: true), Self.codexLine(5), Self.codexLine(6, window: nil),
                     #"{"type":"assistant","message":{"usage":{"input_tokens":"3"}}}"#, #"{"type":"user"}"#, "not json", "{", "",
                     #"{"type":"event_msg","payload":{"type":"token_count"}}"#, #"{"type":"assistant","message":{"usage":{"input_tokens":1e300}}}"#,
                     #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":4},"model_context_window":0}}}"#]
        var measured = 0, refused = 0, accepted = 0
        for _ in 0..<20_000 {
            var lines = (0..<Int(rng.next() % 6)).map { _ in rng.pick(atoms) }
            if rng.next() % 4 == 0, !lines.isEmpty {
                let i = Int(rng.next() % UInt64(lines.count))
                lines[i] = String(lines[i].prefix(Int(rng.next() % UInt64(max(1, lines[i].count)))))
            }
            let provider = rng.pick(["claude", "codex"])
            let mid = rng.next() % 3 == 0
            let tail = lines.joined(separator: "\n")
            let got = RelayContextUsage.measure(tail: tail, provider: provider, startsMidFile: mid)
            // Oracle: walk the same lines with JSONSerialization independently.
            var oracle: Int?? = .none
            var considered = tail.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if mid, !considered.isEmpty { considered.removeFirst() }
            for line in considered.reversed() {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if provider == "claude", o["type"] as? String == "assistant", o["isSidechain"] as? Bool != true,
                   let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    let parts = [u["input_tokens"], u["cache_creation_input_tokens"] ?? 0, u["cache_read_input_tokens"] ?? 0]
                    let ints = parts.compactMap { RelayContextUsage.count($0) }
                    oracle = .some(ints.count == 3 && ints.reduce(0, +) > 0 ? ints.reduce(0, +) : nil); break
                }
                if provider == "codex", o["type"] as? String == "event_msg", let p = o["payload"] as? [String: Any],
                   p["type"] as? String == "token_count", let info = p["info"] as? [String: Any] {
                    let input = ((info["last_token_usage"] as? [String: Any])?["input_tokens"]).flatMap(RelayContextUsage.count)
                    let window = info["model_context_window"].flatMap(RelayContextUsage.count)
                    oracle = .some(input.flatMap { $0 > 0 && (window ?? 1) > 0 ? $0 : nil }); break
                }
            }
            #expect(got?.contextTokens == (oracle ?? nil), "tail=\(tail) provider=\(provider) mid=\(mid)")
            if got != nil { measured += 1 } else { refused += 1 }
        }
        let t = UUID(), nonce = "nonce-xyz", header = RelayContextCapsule.header(t)
        let pieces = [header, "\n", "Goal", nonce, "é", "\u{0}", String(repeating: "x", count: 3000), "relay-capsule", " ", "\r\n"]
        for _ in 0..<20_000 {
            let body = (0..<Int(rng.next() % 5)).map { _ in rng.pick(pieces) }.joined()
            var bytes = Data(((rng.next() % 2 == 0 ? header + "\n" : "") + body).utf8)
            if rng.next() % 5 == 0, !bytes.isEmpty { bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next()) }
            if case .success(let v) = RelayContextCapsule.validate(bytes, transition: t, nonce: nonce) {
                accepted += 1
                #expect(bytes.count <= RelayContextCapsule.maximumBytes && v.text.hasPrefix(header) && !v.text.contains(nonce))
                #expect(String(data: bytes, encoding: .utf8) == v.text && v.sha256.count == 64)
            }
        }
        #expect(measured >= 1_000 && refused >= 1_000 && accepted >= 100, "liveness: measured=\(measured) refused=\(refused) accepted=\(accepted)")
        print("RelayContextRotation fuzz seed=20261102 usage=20000 measured=\(measured) refused=\(refused) capsule=20000 accepted=\(accepted)")
    }
}
