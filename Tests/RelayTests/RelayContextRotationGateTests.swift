import Foundation
import Testing
@testable import Relay

/// r3 (review d415f009, finding 1): a bounded, exhaustive two-actor check of the REAL
/// coordinator. Actor A is Relay: `advance` split at its suspension points. Actor B is the
/// user, whose operations change the state the real gate predicates read
/// (RelayStockRotationPolicy.blocker at observation, .sendBlocker at the live gate and the
/// send boundary). Every sequence of up to two user operations is applied at every
/// suspension point (bound 1), and at every pair of points within a window (bound 2).
///
/// Trusted, not checked here: the production gathering of the gate inputs (prompt screen,
/// composer state, approvals, relayd's proof), the fake agent and the fake Chitta ledger.
/// Lifecycle, background and subagent work are relayd's: Relay reads them with the
/// observation, so a change after the last observation is counted as `residual`, not hidden.
@MainActor
@Suite("Context rotation r3: two actors over the real gates", .serialized)
struct RelayContextRotationGateTests {
    typealias Fixture = RelayContextRotationLedgerTests.Fixture

    enum Op: String, CaseIterable {
        case draftOn, draftOff, promptText, promptEmpty, busy, quiet, approvalUp, approvalDown, takeover, settingOff
    }

    struct Outcome {
        var violations: [String] = []
        var final: RelayContextRotationMachine.State?
        var reason: String?
        var kinds: [RelayContextRotationInput] = []
        var pauses = 0
        var applied = 0
        var residual = 0
        var closedTicks = 0
        var ticks = 0
        var human = false
        var off = false
    }

    /// One run with the user's operations applied, in order, at the given suspension-call positions.
    static func run(ledger: Bool, _ schedule: [(Int, Op)], limit: Int = 80) async -> Outcome {
        let f = Fixture(knownToChitta: ledger)
        f.host.gates = .init()
        f.host.clock = { [unowned f] in f.clock }
        var out = Outcome()
        var position = 0

        func violate(_ what: String) { out.violations.append(what) }
        func apply(_ op: Op) {
            out.applied += 1
            let live = f.record.map { !$0.state.terminal } ?? false
            switch op {
            case .draftOn: f.host.gates!.draft = true
            case .draftOff: f.host.gates!.draft = false
            case .promptText: f.host.gates!.promptText = true
            case .promptEmpty: f.host.gates!.promptText = false
            case .busy:
                if !f.host.gates!.busy { f.host.nativeRevision += 1 }
                f.host.gates!.busy = true
            case .quiet:
                if f.host.gates!.busy { f.host.nativeRevision += 1 }
                f.host.gates!.busy = false
            case .approvalUp: f.host.gates!.approvals += 1
            case .approvalDown: f.host.gates!.approvals = max(0, f.host.gates!.approvals - 1)
            case .takeover:
                f.pane.userEnteredInput(); f.host.gates!.lastHumanInput = f.clock
                if live { out.human = true }
            case .settingOff:
                f.host.enabled = false
                if live { out.off = true }
            }
        }
        f.rotation.suspension = { _ in
            for (at, op) in schedule where at == position { apply(op) }
            position += 1
        }
        // The oracle, independent of the predicates under test: at every send attempt, before anything is typed.
        f.host.onSendAttempt = { [unowned f] kind, observation in
            let g = f.host.gates!
            if g.draft { violate("\(kind.rawValue) attempted with a composer draft") }
            if g.promptText { violate("\(kind.rawValue) attempted with text in the prompt") }
            if g.approvals > 0 { violate("\(kind.rawValue) attempted with a pending approval") }
            if out.human { violate("\(kind.rawValue) attempted after human input") }
            if !f.host.enabled { violate("\(kind.rawValue) attempted with the setting off") }
            if observation != f.host.lastObservation { violate("\(kind.rawValue) attempted on an older observation") }
            if f.host.roundTripsSinceObserve > 0 { violate("\(kind.rawValue) attempted after a host round trip since the observation") }
            if !observation.quiet || observation.fenceBlocker != nil { violate("\(kind.rawValue) attempted on a fenced observation") }
            if g.busy { out.residual += 1 }
        }
        for _ in 0..<limit {
            let g = f.host.gates!
            if g.draft || g.promptText || g.busy || g.approvals > 0 { out.closedTicks += 1 }
            await f.rotation.advance(f.pane, workspace: f.workspace)
            out.ticks += 1
            f.clock = f.clock.addingTimeInterval(20)
            if let r = f.record, r.state.terminal { break }
        }
        out.pauses = position
        out.final = f.record?.state
        out.reason = f.record?.reason
        out.kinds = f.kinds
        // Outcome properties.
        let label = schedule.map { "\($0.1.rawValue)@\($0.0)" }.joined(separator: ",")
        if out.final == .aborted {
            if out.kinds.contains(.clear) { violate("aborted after the clear was typed") }
            if let claim = f.epoch?.claim, claim["closed"] as? Bool != true { violate("aborted with the claim left live") }
        }
        // Every stop before the clear is an abort, on both paths (DESIGN.md: aborted, before clear).
        if out.final == .attention, !out.kinds.contains(.clear) {
            violate("attention before any clear was typed: \(out.reason ?? "")")
        }
        if out.human || out.off, let final = out.final, ![.aborted, .attention, .done].contains(final) {
            violate("human input or setting off left the rotation in \(final.rawValue)")
        }
        let open = !(f.host.gates!.draft || f.host.gates!.promptText || f.host.gates!.busy || f.host.gates!.approvals > 0)
        if !out.human, !out.off, f.host.enabled, open, out.closedTicks <= 3, out.final != .done {
            violate("liveness: every gate reopened within 3 ticks but the rotation ended \(String(describing: out.final))")
        }
        if !out.violations.isEmpty { out.violations = out.violations.map { "[\(ledger ? "ledger" : "file") \(label)] " + $0 } }
        // Break the closure cycles (suspension and oracle capture the fixture) so each run's fixture is freed.
        f.rotation.suspension = nil
        f.host.onSendAttempt = nil
        f.workspace.shutdown()
        // Let the main run loop turn so the run's autoreleased objects are drained. A long async
        // MainActor test otherwise never drains its pool (measured: ~0.6 MB a run, fatal at bound 2).
        await Task.yield()
        return out
    }

    struct Tally {
        var runs = 0, fired = 0, done = 0, aborted = 0, attention = 0, other = 0, residual = 0, violations: [String] = []
        mutating func add(_ o: Outcome, ops: Int) {
            runs += 1
            if o.applied == ops { fired += 1 }
            switch o.final {
            case .done: done += 1
            case .aborted: aborted += 1
            case .attention: attention += 1
            default: other += 1
            }
            residual += o.residual
            violations += o.violations
        }
    }

    @Test("Bound 1: every user operation at every suspension point of a full roll, both paths")
    func everyOperationEverywhere() async {
        for ledger in [true, false] {
            let base = await Self.run(ledger: ledger, [])
            #expect(base.violations.isEmpty && base.final == .done, "baseline \(ledger): \(base.violations) \(String(describing: base.final))")
            var t = Tally()
            for k in 0..<base.pauses {
                for op in Op.allCases { t.add(await Self.run(ledger: ledger, [(k, op)]), ops: 1) }
            }
            #expect(t.violations.isEmpty, "\(t.violations.prefix(8))")
            #expect(t.fired == t.runs && t.aborted > 0 && t.attention > 0 && t.done > 0)
            print("RelayContextRotation r3 gates bound=1 path=\(ledger ? "ledger" : "file") baselineTicks=\(base.ticks) limit=80 ops=\(Op.allCases.count) " +
                  "points=\(base.pauses) runs=\(t.runs) fired=\(t.fired) done=\(t.done) aborted=\(t.aborted) " +
                  "attention=\(t.attention) other=\(t.other) residualLifecycleSends=\(t.residual) violations=\(t.violations.count)")
        }
    }

    /// r3 (mutant G10): a lifecycle blip (busy, then quiet, at the same point) changes the native revision and
    /// leaves every gate open. A send at any later point must use an observation taken after the blip. This is the
    /// diagonal of bound 2 (k1 == k2) for the pair (busy, quiet), run in the mutant suite where bound 2 is skipped.
    @Test("Freshness: after a busy-then-quiet blip at any point, every send uses an observation taken after it")
    func lifecycleBlipEverywhere() async {
        for ledger in [true, false] {
            let base = await Self.run(ledger: ledger, [])
            var t = Tally()
            for k in 0..<base.pauses { t.add(await Self.run(ledger: ledger, [(k, .busy), (k, .quiet)]), ops: 2) }
            #expect(t.violations.isEmpty, "\(t.violations.prefix(8))")
            #expect(t.fired == t.runs && t.done > 0)
            print("RelayContextRotation r3 gates blip path=\(ledger ? "ledger" : "file") points=\(base.pauses) runs=\(t.runs) " +
                  "fired=\(t.fired) done=\(t.done) aborted=\(t.aborted) attention=\(t.attention) other=\(t.other) " +
                  "violations=\(t.violations.count)")
        }
    }

    /// The window after the first operation's point: the rest of that tick and the next ticks.
    static let window = 6

    @Test("Bound 2: every ordered pair of user operations at every pair of points within the window, both paths")
    func everyPairInWindow() async {
        for ledger in [true, false] {
            let base = await Self.run(ledger: ledger, [])
            var t = Tally()
            var skipped = 0
            for k1 in 0..<base.pauses {
                for op1 in Op.allCases {
                    // The second point must exist in the run the first operation produced.
                    let first = await Self.run(ledger: ledger, [(k1, op1)], limit: 50)
                    for k2 in k1..<(k1 + Self.window) {
                        guard k2 < first.pauses else { skipped += Op.allCases.count; continue }
                        for op2 in Op.allCases {
                            t.add(await Self.run(ledger: ledger, [(k1, op1), (k2, op2)], limit: 50), ops: 2)
                        }
                    }
                }
            }
            #expect(t.fired == t.runs, "every scheduled pair applied")
            #expect(t.violations.isEmpty, "\(t.violations.prefix(8))")
            print("RelayContextRotation r3 gates bound=2 window=\(Self.window) path=\(ledger ? "ledger" : "file") baselineTicks=\(base.ticks) limit=50 " +
                  "ops=\(Op.allCases.count) points=\(base.pauses) runs=\(t.runs) fired=\(t.fired) done=\(t.done) " +
                  "aborted=\(t.aborted) attention=\(t.attention) other=\(t.other) residualLifecycleSends=\(t.residual) " +
                  "pairsBeyondRunEnd=\(skipped) violations=\(t.violations.count)")
        }
    }

    // MARK: r3 fixes found after r2 was sent

    @Test("Release drain: a pending release runs only in its own pane's advance, on that pane's host")
    func releaseDrainPerPane() async {
        let f = Fixture()
        f.host.capsuleJSON = { _, _ in "not json" }
        let r = await f.run()
        #expect(r?.state == .aborted)
        let releases = { f.host.chitta.log.filter { $0.hasPrefix("rotation_release") }.count }
        let before = releases()
        #expect(before == 1, "\(f.host.chitta.log)")
        f.workspace.newTab(profile: .sshConfigHost("other-host.invalid"))
        guard let other = f.workspace.activePane, other !== f.pane, let transition = r?.transition else {
            Issue.record("no second pane"); return
        }
        f.rotation.pendingRelease.insert(transition)
        await f.rotation.advance(other, workspace: f.workspace)
        #expect(releases() == before, "another pane's advance released this pane's claim with its own host")
        #expect(f.rotation.pendingRelease.contains(transition))
        await f.rotation.advance(f.pane, workspace: f.workspace)
        #expect(releases() == before + 1)
        #expect(f.rotation.pendingRelease.isEmpty)
        f.workspace.shutdown()
    }

    @Test("Capsule: an empty optional text field is omitted; required fields, controls and types stay strict")
    func emptyOptionalFields() {
        let nonce = UUID().uuidString.lowercased()
        func doc(_ extra: [String: Any]) -> Data {
            var c: [String: Any] = ["objective": "o", "next_action": "n", "project_dir": "/w"]
            for (k, v) in extra { c[k] = v }
            return try! JSONSerialization.data(withJSONObject: ["capsule": c, "standing_rules": ["r"]], options: [.sortedKeys])
        }
        for key in ["branch", "code_head", "repository", "stream_id", "state"] {
            for value in ["", " ", "   "] {
                guard case .success(let parsed) = RelayRollCapsule.validate(doc([key: value]), nonce: nonce) else {
                    Issue.record("\(key)=\(value.debugDescription) refused"); continue
                }
                #expect(parsed.capsule[key] == nil, "\(key) kept")
            }
        }
        let refused: [(String, Any)] = [("objective", ""), ("next_action", " "), ("project_dir", ""), ("branch", "\n"),
            ("branch", "\t"), ("branch", " \u{2028}"), ("branch", 5), ("state", "bogus"), ("code_head", NSNull())]
        for (key, value) in refused {
            if case .success = RelayRollCapsule.validate(doc([key: value]), nonce: nonce) {
                Issue.record("\(key)=\(String(describing: value).debugDescription) accepted")
            }
        }
        #expect(RelayRollCapsule.request(transition: UUID(), nonce: nonce).contains("Leave out any optional key"))
        #expect(RelayStockRotationPolicy.admits(RelayRollCapsule.request(transition: UUID(), nonce: nonce), kind: .capsuleRequest))
    }

    @Test("Known limit: a failed abandon_intent after an abort is reported; the claim is still released")
    func failedAbandonIsReported() async {
        let f = Fixture()
        var did = false
        f.rotation.suspension = { [unowned f] index in
            if !did, index == 0, f.record?.state == .intentRecorded {
                did = true
                f.host.chitta.faults["rotation_abandon_intent"] = .refuse("invalid_request")
                f.pane.userEnteredInput()
            }
        }
        let r = await f.run()
        #expect(did && r?.state == .aborted)
        #expect(!f.kinds.contains(.clear))
        #expect(f.epoch?.claim?["closed"] as? Bool == true, "the claim is released even when the abandon fails")
        #expect(f.rotation.statuses[f.pane.id]?.contains("still holds its unbound intent") == true,
                "\(String(describing: f.rotation.statuses[f.pane.id]))")
        #expect(f.record?.ledger?.note?.contains("abandon_intent invalid_request") == true, "\(String(describing: f.record?.ledger?.note))")
        f.workspace.shutdown()
    }
}
