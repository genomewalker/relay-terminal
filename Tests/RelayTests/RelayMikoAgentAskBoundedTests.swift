import Foundation
import Testing
@testable import Relay

// Bounded checks for relay_ask_miko against the real channel and harness:
// an exhaustive enumeration of the ask/approval state machine (R4) and a
// seeded random generator over the channel's request decoding (R3).
//
// Trusted fakes, each bounded:
// - MikoCheckModel: a new turn proposes one reversible tab rename under
//   cards_for_writes (so it parks on an action card) or, for the fuzz, answers at
//   once; a turn carrying tool results answers. No real model.
// - MikoCheckExecutor: permits every capability and records each dispatch.
// - The redeemer: returns a relayd source_host_attested proof naming the
//   packet's own source pane (or a forged pane when asked), after running an
//   optional injected operation at the channel's only await point.
// - MikoCheckClock: a frozen clock moved only by the expire operation.

/// SplitMix64: a fixed seed reproduces every generated input.
struct MikoSplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
}

final class MikoCheckClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_900_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@MainActor
final class MikoCheckModel: RelayAssistantModel {
    let answerAtOnce: Bool
    let tabID: UUID
    private(set) var turnsStarted = 0
    private(set) var lastUserText: String?
    init(answerAtOnce: Bool, tabID: UUID) { self.answerAtOnce = answerAtOnce; self.tabID = tabID }

    func step(_ request: RelayAssistantModelRequest) async throws -> RelayAssistantModelStep {
        if let text = request.messages.last?["content"]?.string {
            turnsStarted += 1
            lastUserText = text
            if !answerAtOnce {
                let input: [String: RelayPaneHealthJSON] = ["tab_id": .string(tabID.uuidString.lowercased()), "action": .string("rename"), "name": .string("Check")]
                let call = RelayPaneHealthToolCall(type: "tool_use", id: "toolu_check", name: "tab_action", input: .object(input))
                return RelayAssistantModelStep(stopReason: "tool_use", content: [.object(["type": .string("tool_use"),
                    "id": .string(call.id), "name": .string(call.name), "input": .object(input)])], toolCalls: [call], chargedMicrousd: 1)
            }
        }
        return RelayAssistantModelStep(stopReason: "end_turn", content: [.object(["type": .string("text"), "text": .string("done")])],
                                       toolCalls: [], chargedMicrousd: 1)
    }
}

@MainActor
final class MikoCheckExecutor: RelayAssistantActionExecutor {
    var instance: UUID? = UUID()
    private(set) var dispatched: [String] = []
    func permits(_ capability: MCPWorkspaceCapability) -> Bool { true }
    func perform(method: String, path: String, body: Data) async -> (status: Int, body: Data) {
        dispatched.append(path)
        return (200, Data("{}".utf8))
    }
}

/// One Relay window shared by many fixtures: each fixture gets its own
/// harness, channel, supervision, model, executor and a fresh pane B.
@MainActor
final class MikoCheckWorld {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let audit: RelayCallerControl
    let paneA: PaneModel
    /// Pane B lives across fixtures; only a sequence that closes it gets a new one.
    private(set) var paneB: PaneModel
    private(set) var tabB: UUID
    private(set) var bOpen = true
    private(set) var panesOpened = 1

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-miko-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audit = RelayCallerControl(directory: directory)
        paneA = try #require(workspace.activePane)
        (paneB, tabB) = try Self.openPane(workspace, like: paneA)
    }

    /// A new tab without touching the remembered navigation state.
    private static func openPane(_ workspace: WorkspaceModel, like pane: PaneModel) throws -> (PaneModel, UUID) {
        let before = Set(workspace.panes.keys)
        workspace.withoutNavigationEffects { workspace.newTab(profile: pane.profile) }
        let id = try #require(Set(workspace.panes.keys).subtracting(before).first)
        let opened = try #require(workspace.panes[id])
        return (opened, try #require(workspace.tabID(containingPane: id)))
    }

    func ensureB() throws {
        guard !bOpen else { return }
        (paneB, tabB) = try Self.openPane(workspace, like: paneA)
        bOpen = true
        panesOpened += 1
    }

    func closeB() {
        guard bOpen else { return }
        bOpen = false
        workspace.withoutNavigationEffects { workspace.closeTab(tabB) }
    }
}

@MainActor
final class MikoCheckFixture {
    let world: MikoCheckWorld
    let supervision: RelayMikoSupervision
    let model: MikoCheckModel
    let executor: MikoCheckExecutor
    let clock: MikoCheckClock
    let instance = UUID()
    let harness: RelayAssistantHarness
    var channel: RelayMikoSupervisorChannel!
    var paneB: PaneModel { world.paneB }
    var bOpen: Bool { world.bOpen }
    var granted = true
    var redeemed = 0
    /// The pane the next proof names instead of the caller's (a forged proof).
    var forgeAs: String?
    /// Runs once inside the next proof round trip, before it returns.
    var during: (@MainActor () async -> Void)?

    init(_ world: MikoCheckWorld, answerAtOnce: Bool) throws {
        let supervision = RelayMikoSupervision(url: nil)
        let model = MikoCheckModel(answerAtOnce: answerAtOnce, tabID: try #require(world.workspace.selectedTabID))
        let executor = MikoCheckExecutor()
        let clock = MikoCheckClock()
        try world.ensureB()
        self.world = world
        self.supervision = supervision
        self.model = model
        self.executor = executor
        self.clock = clock
        harness = RelayAssistantHarness(policy: { .init(autonomy: .cardsForWrites) }, budget: RelayMikoActionBudget(), workspace: world.workspace, facts: RelayAssistantFacts(
            health: { _ in .object([:]) }, holdReason: { _ in nil }, rotation: { _ in .object([:]) }),
            model: { [model] _ in (model, "h-check") }, audit: world.audit, executor: { [executor] in executor },
            promptProof: { _ in nil }, cardTimeout: RelayAssistantHarness.cardLifetime, supervision: supervision,
            now: { clock.now })
        world.workspace.haikuAssistantStorage = harness
        try supervision.register(paneID: world.paneA.id, label: "Agent A")
        try supervision.setMayApproveCards(world.paneA.id, true)
        channel = RelayMikoSupervisorChannel(supervision: supervision, audit: world.audit, redeem: { [unowned self] _, packet in
            self.redeemed += 1
            if let hook = self.during {
                self.during = nil
                await hook()
            }
            let source = self.forgeAs ?? (packet["source_pane_id"] as? String ?? "")
            self.forgeAs = nil
            return ["authority": "relayd", "source": ["authentication": "source_host_attested",
                "attestationID": packet["attestation_id"] as? String ?? "", "paneID": source]]
        }, now: { clock.now }, inputGranted: { [unowned self] in self.granted }, instance: { [unowned self] in self.instance })
    }

    func id(_ pane: PaneModel) -> String { pane.id.uuidString.lowercased() }

    /// One verified call as `pane`. Returns the status, reply and transport id.
    func call(_ tool: String, _ arguments: [String: Any], as pane: PaneModel) async throws -> (Int, [String: Any], String) {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys), as: UTF8.self)
        return await send(tool, arguments: encoded, as: id(pane))
    }

    func send(_ tool: String, arguments: String, as pane: String, transport: String = UUID().uuidString.lowercased(),
              attestation: String = "0123456789abcdef0123456789abcdef") async -> (Int, [String: Any], String) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["tool": tool, "request_id": transport,
            "attestation_id": attestation, "supervisor_pane_id": pane, "arguments": arguments]) else { return (0, [:], transport) }
        let (status, value) = await channel.handle(body: body, caller: "caller-check", workspace: world.workspace)
        return (status, value, transport)
    }

    func ask(_ text: String, id request: String, as pane: PaneModel) async throws -> (Int, [String: Any], String) {
        try await call("relay_ask_miko", ["instance": instance.uuidString.lowercased(), "request_id": request, "text": text], as: pane)
    }

    func receipt(_ request: String, as pane: PaneModel) async throws -> (Int, [String: Any], String) {
        try await call("relay_miko_receipt", ["instance": instance.uuidString.lowercased(), "request_id": request], as: pane)
    }

    func closeB() { world.closeB() }

    /// Waits until the harness is parked on a card or idle with every ask finished.
    func settle() async -> Bool {
        for turn in 0..<20_000 {
            if harness.pendingCard != nil || (!harness.isBusy && channel.asks.values.allSatisfy(\.finished)) { return true }
            if turn % 50 == 49 { try? await Task.sleep(nanoseconds: 200_000) } else { await Task.yield() }
        }
        return false
    }

    func tearDown() async {
        harness.cancel()
        for turn in 0..<20_000 where harness.isBusy {
            if turn % 50 == 49 { try? await Task.sleep(nanoseconds: 200_000) } else { await Task.yield() }
        }
    }
}

// MARK: - The specification the real code is checked against

/// The abstract state: what the user and agents may observe.
struct MikoAskSpec: Hashable {
    enum Phase: Hashable { case waiting, completed, stopped }
    struct Ask: Hashable { let owner: String; let text: String; var phase: Phase }
    var granted = true
    var bOpen = true
    var asks: [String: Ask] = [:]
    var cardFor: String?
    var dispatched = 0
}

enum MikoAskOp: CaseIterable {
    case grantOff, grantOn
    case askA1, askA1Other, askB1, askA2
    case receiptA1, receiptB1
    case userRun, userDeny, expire, userStop
    case supervisorRouteRunA
    case askA2RevokedDuringProof
    case askA1RacedByAskB1
    case askB1RacedByAskA2
    case askA2RacedByUserRun, askA2RacedByUserDeny, askA2RacedByExpire, askA2RacedByUserStop
    case askB2PaneClosedDuringProof
    case askA1ForgedAsB
}

@MainActor
final class MikoSpecBox {
    var spec: MikoAskSpec
    var hookRan = false
    init(_ spec: MikoAskSpec) { self.spec = spec }
}

/// Exhaustive bounded check. Every sequence of `depth` operations over the
/// whole alphabet runs against a fresh harness and channel; the named
/// invariants are checked after every operation (so every shorter sequence
/// is checked as a prefix).
@MainActor
final class MikoAskModelChecker {
    static let r1 = "7e108132-5073-4b10-abd2-df3a0ee8a14d"
    static let r2 = "c0c9f125-0d3b-4728-9a10-08e4a3e0080c"
    static let t1 = "Tidy my tabs on dandy-07"
    static let t2 = "Something else entirely"

    let world: MikoCheckWorld
    var states: Set<MikoAskSpec> = []
    var sequences = 0
    var steps = 0
    var dispatchedSequences = 0
    var violations: [String] = []

    init(world: MikoCheckWorld) { self.world = world }

    func fail(_ invariant: String, _ trace: [MikoAskOp], _ detail: String) {
        if violations.count < 20 { violations.append("\(invariant) after \(trace): \(detail)") }
    }

    func run(_ sequence: [MikoAskOp]) async throws {
        let f = try MikoCheckFixture(world, answerAtOnce: false)
        var spec = MikoAskSpec()
        states.insert(spec)
        var trace: [MikoAskOp] = []
        for op in sequence {
            trace.append(op)
            try await apply(op, f, &spec, trace)
            steps += 1
            guard await f.settle() else { fail("SETTLES", trace, "harness never settled"); break }
            check(f, spec, trace)
            states.insert(spec)
        }
        if spec.dispatched > 0 { dispatchedSequences += 1 }
        sequences += 1
        await f.tearDown()
    }

    // MARK: Spec transitions paired with the real calls

    private func pane(_ owner: String, _ f: MikoCheckFixture) -> PaneModel { owner == "A" ? world.paneA : f.paneB }

    /// Applies a user/card operation to the real harness and the spec.
    private func userOp(_ op: MikoAskOp, _ f: MikoCheckFixture, _ spec: inout MikoAskSpec) {
        switch op {
        case .userRun:
            f.harness.runCard()
            if let key = spec.cardFor { spec.asks[key]?.phase = .completed; spec.dispatched += 1; spec.cardFor = nil }
        case .userDeny:
            f.harness.cancelCard()
            if let key = spec.cardFor { spec.asks[key]?.phase = .completed; spec.cardFor = nil }
        case .expire:
            f.clock.advance(RelayAssistantHarness.cardLifetime + 1)
            f.harness.runCard()
            if let key = spec.cardFor { spec.asks[key]?.phase = .completed; spec.cardFor = nil }
        case .userStop:
            f.harness.cancel()
            if let key = spec.cardFor { spec.asks[key]?.phase = .stopped; spec.cardFor = nil }
        case .grantOff: f.granted = false; spec.granted = false
        case .grantOn: f.granted = true; spec.granted = true
        default: break
        }
    }

    /// One relay_ask_miko through handle(); `during` runs inside its proof
    /// round trip and updates the spec exactly when it runs.
    private func ask(_ owner: String, _ key: String, _ text: String, _ f: MikoCheckFixture, _ spec: inout MikoAskSpec,
                     _ trace: [MikoAskOp], forged: Bool = false,
                     during: (@MainActor (MikoSpecBox) async -> Void)? = nil) async throws {
        let before = (redeemed: f.redeemed, asks: f.channel.asks.count, exchanges: f.harness.exchanges.count)
        let preRefused = !spec.granted || (owner == "B" && !spec.bOpen)
        let box = MikoSpecBox(spec)
        if !preRefused, let during {
            f.during = {
                await during(box)
                box.hookRan = true
            }
        }
        if forged { f.forgeAs = f.id(owner == "A" ? f.paneB : world.paneA) }
        let (status, value, transport) = try await f.ask(text, id: key, as: pane(owner, f))
        f.during = nil
        f.forgeAs = nil
        if !preRefused, during != nil, !box.hookRan { fail("HARNESS", trace, "the injected operation never ran inside the proof") }
        spec = box.spec
        let expected: Int
        if preRefused {
            expected = 403
            if f.redeemed != before.redeemed { fail("GRANT-AND-PANE-BEFORE-PROOF", trace, "a refused ask spent a proof") }
        } else if forged || !spec.granted || (owner == "B" && !spec.bOpen) {
            expected = 403
        } else if let prior = spec.asks[key] {
            expected = prior.owner == owner && prior.text == text ? 200 : 409
            if expected == 200, value["status"] as? String != "replayed" { fail("REPLAY-NO-RERUN", trace, "replay status \(value)") }
        } else if spec.cardFor != nil {
            expected = 409
            if value["status"] as? String != "busy" { fail("BUSY-NOT-RECORDED", trace, "expected busy, got \(value)") }
        } else {
            expected = 200
            if value["status"] as? String != "accepted" { fail("OUTCOME", trace, "expected accepted, got \(value)") }
            spec.asks[key] = .init(owner: owner, text: text, phase: .waiting)
            spec.cardFor = key
        }
        if status != expected { fail("OUTCOME", trace, "ask \(owner) \(key.prefix(8)) status \(status), expected \(expected): \(value)") }
        if expected == 403 {
            if value["request_id"] != nil { fail("LOGICAL-ID", trace, "a refusal carried a request_id") }
        } else {
            if value["request_id"] as? String != key { fail("LOGICAL-ID", trace, "request_id \(value["request_id"] ?? "nil") != \(key)") }
            if value["call_id"] as? String != transport { fail("LOGICAL-ID", trace, "call_id is not the transport id") }
        }
        // REFUSED-CHANGES-NOTHING: only an accepted ask (here or in an injected
        // operation) adds a record or an exchange.
        let added = spec.asks.count - before.asks
        if f.channel.asks.count != before.asks + added || f.harness.exchanges.count > before.exchanges + added {
            fail("REFUSED-CHANGES-NOTHING", trace, "records \(before.asks)->\(f.channel.asks.count), spec added \(added)")
        }
    }

    private func apply(_ op: MikoAskOp, _ f: MikoCheckFixture, _ spec: inout MikoAskSpec, _ trace: [MikoAskOp]) async throws {
        let r1 = Self.r1, r2 = Self.r2, t1 = Self.t1, t2 = Self.t2
        switch op {
        case .grantOff, .grantOn, .userRun, .userDeny, .expire, .userStop:
            let dispatched = f.executor.dispatched.count
            userOp(op, f, &spec)
            if op != .userRun, f.executor.dispatched.count != dispatched { fail("DISPATCH-ONLY-ON-USER-RUN", trace, "\(op) dispatched") }
        case .askA1: try await ask("A", r1, t1, f, &spec, trace)
        case .askA1Other: try await ask("A", r1, t2, f, &spec, trace)
        case .askB1: try await ask("B", r1, t1, f, &spec, trace)
        case .askA2: try await ask("A", r2, t1, f, &spec, trace)
        case .receiptA1, .receiptB1:
            let owner = op == .receiptA1 ? "A" : "B"
            let before = f.redeemed
            let (status, value, transport) = try await f.receipt(r1, as: pane(owner, f))
            let expected: Int
            if owner == "B" && !spec.bOpen {
                expected = 403
                if f.redeemed != before { fail("GRANT-AND-PANE-BEFORE-PROOF", trace, "a closed pane spent a proof") }
            } else if let prior = spec.asks[r1], prior.owner == owner {
                expected = 200
                let state: String = switch prior.phase {
                case .waiting: "waiting_for_approval"
                case .completed: "completed"
                case .stopped: "stopped"
                }
                if value["state"] as? String != state { fail("RECEIPT-STATE", trace, "state \(value["state"] ?? "nil") != \(state)") }
                if prior.phase == .waiting, (value["pending_card"] as? [String: Any])?["origin"] as? [String: Any] == nil {
                    fail("RECEIPT-STATE", trace, "waiting receipt lacks the card summary")
                }
            } else {
                expected = 404
            }
            if status != expected { fail("OWNER-ONLY-RECEIPT", trace, "receipt \(owner) status \(status), expected \(expected)") }
            if expected != 403 {
                if value["request_id"] as? String != r1 { fail("LOGICAL-ID", trace, "receipt request_id \(value["request_id"] ?? "nil")") }
                if value["call_id"] as? String != transport { fail("LOGICAL-ID", trace, "receipt call_id is not the transport id") }
            }
            if expected != 200, value["answer"] != nil || value["exchange"] != nil {
                fail("OWNER-ONLY-RECEIPT", trace, "a refused receipt leaked an answer")
            }
        case .supervisorRouteRunA:
            let card = f.harness.pendingCard
            let dispatched = f.executor.dispatched.count
            let (status, _, _) = try await f.call("relay_miko_card", ["card_id": (card?.id ?? UUID()).uuidString.lowercased(),
                                                                      "decision": "run"], as: world.paneA)
            let expected = card == nil ? 409 : 403
            if status != expected { fail("AGENT-CARD-NOT-SUPERVISOR-RUNNABLE", trace, "card route status \(status), expected \(expected)") }
            if f.harness.pendingCard?.id != card?.id || f.executor.dispatched.count != dispatched {
                fail("AGENT-CARD-NOT-SUPERVISOR-RUNNABLE", trace, "the supervisor route changed the card")
            }
        case .askA2RevokedDuringProof:
            try await ask("A", r2, t1, f, &spec, trace) { box in
                f.granted = false
                box.spec.granted = false
            }
        case .askA1RacedByAskB1:
            try await ask("A", r1, t1, f, &spec, trace) { [unowned self] box in
                var inner = box.spec
                try? await self.ask("B", r1, t1, f, &inner, trace + [.askB1])
                _ = await f.settle()
                box.spec = inner
            }
        case .askB1RacedByAskA2:
            try await ask("B", r1, t1, f, &spec, trace) { [unowned self] box in
                var inner = box.spec
                try? await self.ask("A", r2, t1, f, &inner, trace + [.askA2])
                _ = await f.settle()
                box.spec = inner
            }
        case .askA2RacedByUserRun, .askA2RacedByUserDeny, .askA2RacedByExpire, .askA2RacedByUserStop:
            let user: MikoAskOp = switch op {
            case .askA2RacedByUserRun: .userRun
            case .askA2RacedByUserDeny: .userDeny
            case .askA2RacedByExpire: .expire
            default: .userStop
            }
            try await ask("A", r2, t1, f, &spec, trace) { [unowned self] box in
                var inner = box.spec
                self.userOp(user, f, &inner)
                _ = await f.settle()
                box.spec = inner
            }
        case .askB2PaneClosedDuringProof:
            try await ask("B", r2, t1, f, &spec, trace) { box in
                f.closeB()
                box.spec.bOpen = false
            }
        case .askA1ForgedAsB:
            try await ask("A", r1, t1, f, &spec, trace, forged: true)
        }
    }

    // MARK: Invariants, checked after every step

    private func check(_ f: MikoCheckFixture, _ spec: MikoAskSpec, _ trace: [MikoAskOp]) {
        let asks = f.channel.asks
        // ONE-RECORD-PER-REQUEST and OWNER-FIXED: the channel's records are exactly the spec's.
        if Set(asks.keys) != Set(spec.asks.keys) { fail("ONE-RECORD-PER-REQUEST", trace, "asks \(asks.keys.sorted()) != spec \(spec.asks.keys.sorted())") }
        for (key, want) in spec.asks {
            guard let have = asks[key] else { continue }
            if have.paneID != pane(want.owner, f).id { fail("OWNER-FIXED", trace, "\(key) owner changed") }
            if have.finished != (want.phase != .waiting) { fail("PHASE", trace, "\(key) finished=\(have.finished) spec \(want.phase)") }
            // ONE-RUN-PER-REQUEST and AGENT-ORIGIN: exactly one exchange, labelled with the owner.
            let runs = f.harness.exchanges.filter { $0.requestID == have.exchangeID }
            if runs.count != 1 { fail("ONE-RUN-PER-REQUEST", trace, "\(key) has \(runs.count) exchanges") }
            if let exchange = runs.first {
                guard case .agent(let paneID, _) = exchange.origin, paneID == have.paneID else {
                    fail("AGENT-ORIGIN", trace, "\(key) origin \(exchange.origin)"); continue
                }
                // NO-CLIP: the agent's text reaches the model whole.
                if !exchange.request.hasSuffix(want.text) { fail("NO-CLIP", trace, "\(key) request was cut") }
                switch want.phase {
                case .waiting: if !exchange.reply.isEmpty && exchange.failed { fail("PHASE", trace, "\(key) failed while waiting") }
                case .completed: if exchange.failed { fail("PHASE", trace, "\(key) failed: \(exchange.reply)") }
                case .stopped: if exchange.reply != "Cancelled." { fail("PHASE", trace, "\(key) not cancelled: \(exchange.reply)") }
                }
            }
        }
        if f.harness.exchanges.count != spec.asks.count { fail("ONE-RUN-PER-REQUEST", trace, "\(f.harness.exchanges.count) exchanges for \(spec.asks.count) asks") }
        if f.model.turnsStarted != spec.asks.count { fail("ONE-RUN-PER-REQUEST", trace, "\(f.model.turnsStarted) model turns for \(spec.asks.count) asks") }
        // CARD-WAITS-FOR-USER: a card is pending exactly while the spec says, and it is the owner's agent card.
        if (f.harness.pendingCard != nil) != (spec.cardFor != nil) { fail("CARD-WAITS-FOR-USER", trace, "pending card \(f.harness.pendingCard != nil), spec \(spec.cardFor ?? "none")") }
        if let key = spec.cardFor, let owner = spec.asks[key]?.owner {
            guard case .agent(let paneID, _)? = f.harness.pendingCardOrigin, paneID == pane(owner, f).id else {
                fail("CARD-WAITS-FOR-USER", trace, "pending card origin \(String(describing: f.harness.pendingCardOrigin))"); return
            }
        }
        // DISPATCH-ONLY-ON-USER-RUN: every dispatch is one user Run on an unexpired card.
        if f.executor.dispatched.count != spec.dispatched { fail("DISPATCH-ONLY-ON-USER-RUN", trace, "\(f.executor.dispatched.count) dispatched, spec \(spec.dispatched)") }
        // GRANT-GATE: the grant flag is exactly the spec's; asks only exist from granted calls (by OUTCOME).
        if f.granted != spec.granted || f.bOpen != spec.bOpen { fail("ENVIRONMENT", trace, "fixture and spec diverged") }
    }
}

@Suite("Miko agent ask bounded checks", .serialized)
@MainActor
struct RelayMikoAgentAskBoundedTests {
    static let depth = 3

    @Test func everyAskApprovalSequenceUpToTheBoundKeepsTheSafetyInvariants() async throws {
        let world = try MikoCheckWorld()
        defer { world.workspace.shutdown() }
        let checker = MikoAskModelChecker(world: world)
        let alphabet = MikoAskOp.allCases
        var counter = [Int](repeating: 0, count: Self.depth)
        let total = Int(pow(Double(alphabet.count), Double(Self.depth)))
        let started = Date()
        for _ in 0..<total {
            try await checker.run(counter.map { alphabet[$0] })
            if !checker.violations.isEmpty { break }
            var position = Self.depth - 1
            while position >= 0 {
                counter[position] += 1
                if counter[position] < alphabet.count { break }
                counter[position] = 0
                position -= 1
            }
        }
        print("MIKO-ASK-MODEL-CHECK alphabet=\(alphabet.count) depth=\(Self.depth) sequences=\(checker.sequences) " +
              "steps=\(checker.steps) distinct_states=\(checker.states.count) sequences_with_dispatch=\(checker.dispatchedSequences) " +
              "seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))")
        #expect(checker.violations.isEmpty, "\(checker.violations.joined(separator: "\n"))")
        #expect(checker.sequences == total)
        // Non-vacuity: the bound reaches dispatch, replay, conflict, busy and both card endings.
        #expect(checker.dispatchedSequences > 0)
        #expect(checker.states.contains { $0.asks.count == 2 })
        #expect(checker.states.contains { $0.asks.values.contains { $0.phase == .stopped } })
        #expect(checker.states.contains { !$0.bOpen })
    }
}

// MARK: - Seeded random generator over the channel's decoding (R3)

/// An independent reading of the ask argument contract.
enum MikoAskOracle {
    static func isUUID(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 36 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if [8, 13, 18, 23].contains(index) { if scalar != "-" { return false }; continue }
            guard scalar.isASCII, "0123456789abcdefABCDEF".unicodeScalars.contains(scalar) else { return false }
        }
        return true
    }
}

@MainActor
struct MikoAskFuzzer {
    /// Committed seeds; a failure prints the seed and iteration to replay. A seed
    /// fixes every generator decision and generated value; only the fixture's own
    /// pane and instance UUIDs are fresh per run (they never steer generation).
    static let seeds: [UInt64] = [0x5EED_0001, 0xA5C0_FFEE_1631, 0xDEAD_BEEF_0B0B]
    static let iterations = 300
    static let pieces = ["a", "Z", " ", "\n", "\t", "é", "e\u{301}", "😀", "👨‍👩‍👧", "\u{0}", "\u{7}", "中", "\u{200B}",
                         "\"", "\\", "\u{00A0}", "\u{2028}"]

    var random: MikoSplitMix
    var counts: [String: Int] = [:]

    mutating func text() -> String {
        let target: Int = switch random.below(8) {
        case 0: 0
        case 1: 1 + random.below(3)
        case 2, 3, 4, 5: random.below(200)
        default: 4096 + random.below(9) - 4
        }
        var value = ""
        if random.chance(10) { return String(repeating: random.pick([" ", "\n", "\t", "\u{00A0}"]), count: 1 + random.below(5)) }
        while value.utf8.count < target { value += random.pick(Self.pieces) }
        if random.chance(30), !value.isEmpty { value.removeLast() }
        return value
    }

    /// A UUID string drawn from the seed, so a seed reproduces every generated value.
    mutating func uuidString() -> String {
        let hex = Array(String(format: "%016llx%016llx", random.next(), random.next()))
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }.joined(separator: "-")
    }

    mutating func uuid(_ fixed: String? = nil) -> Any {
        switch random.below(8) {
        case 0: return uuidString().uppercased()
        case 1: return String(uuidString().dropLast())
        case 2: return 7
        case 3: return "not-a-uuid"
        default: return fixed ?? uuidString()
        }
    }
}

extension RelayMikoAgentAskBoundedTests {
    @Test func seededRandomAskBodiesMatchTheContractAndKeepTextWhole() async throws {
        let world = try MikoCheckWorld()
        defer { world.workspace.shutdown() }
        var fuzzer = MikoAskFuzzer(random: MikoSplitMix(state: 0))
        var executed = 0
        for seed in MikoAskFuzzer.seeds {
            fuzzer.random = MikoSplitMix(state: seed)
            var f = try MikoCheckFixture(world, answerAtOnce: true)
            var used: [String: (text: String, context: String)] = [:]
            for iteration in 0..<MikoAskFuzzer.iterations {
                if f.channel.asks.count >= RelayMikoSupervisorChannel.askLimit - 8 {
                    await f.tearDown()
                    f = try MikoCheckFixture(world, answerAtOnce: true)
                    used = [:]
                }
                let label = "seed \(String(seed, radix: 16)) iteration \(iteration)"
                try await fuzzOne(f, &fuzzer, &used, label)
                executed += 1
            }
            await f.tearDown()
        }
        print("MIKO-ASK-SWIFT-FUZZ seeds=\(MikoAskFuzzer.seeds.count) executions=\(executed) " +
              fuzzer.counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        #expect(executed == MikoAskFuzzer.seeds.count * MikoAskFuzzer.iterations)
        // Non-vacuity: every outcome class was generated.
        for kind in ["accepted", "replayed", "conflict", "invalid-arguments", "stale-instance", "truncated", "bad-envelope", "oversized"] {
            #expect((fuzzer.counts[kind] ?? 0) > 0, "no \(kind) case was generated")
        }
    }

    private func fuzzOne(_ f: MikoCheckFixture, _ fuzzer: inout MikoAskFuzzer,
                         _ used: inout [String: (text: String, context: String)], _ label: String) async throws {
        let before = (redeemed: f.redeemed, asks: f.channel.asks.count, exchanges: f.harness.exchanges.count)
        let shape = fuzzer.random.below(100)
        // Envelope-level damage: refused before any proof is spent.
        if shape < 6 {
            let upper = fuzzer.uuidString().uppercased(), short = String(fuzzer.uuidString().dropLast())
            let transport = fuzzer.random.pick([upper, "x", short])
            let attestation = fuzzer.random.pick(["0123456789abcdef0123456789abcdef", "0123456789ABCDEF0123456789ABCDEF", "short"])
            let pane = fuzzer.random.chance(50) ? f.id(f.world.paneA).uppercased() : f.id(f.world.paneA)
            let (status, value, _) = await f.send("relay_ask_miko", arguments: "{}", as: pane, transport: transport, attestation: attestation)
            let saneEnvelope = transport == transport.lowercased() && MikoAskOracle.isUUID(transport) &&
                attestation == "0123456789abcdef0123456789abcdef" && pane == pane.lowercased()
            fuzzer.counts["bad-envelope", default: 0] += 1
            if !saneEnvelope {
                #expect(status == 400 && f.redeemed == before.redeemed, "\(label): bad envelope \(status) \(value)")
            }
            #expect(f.channel.asks.count == before.asks, "\(label): an envelope case recorded an ask")
            return
        }
        if shape < 9 {
            // Oversized body: over 32 KB is refused before decoding.
            let padding = String(repeating: "x", count: 33 << 10)
            let (status, _, _) = await f.send("relay_ask_miko", arguments: "{\"pad\":\"\(padding)\"}", as: f.id(f.world.paneA))
            fuzzer.counts["oversized", default: 0] += 1
            #expect(status == 400 && f.redeemed == before.redeemed, "\(label): oversized body \(status)")
            return
        }
        // Arguments.
        var arguments: [String: Any] = [:]
        let instance = f.instance.uuidString.lowercased()
        let stale = fuzzer.uuidString()
        if fuzzer.random.chance(95) { arguments["instance"] = fuzzer.random.chance(85) ? instance : fuzzer.uuid(stale) }
        var requestID: Any = fuzzer.uuid()
        if let prior = used.keys.sorted().first, fuzzer.random.chance(25) { requestID = fuzzer.random.chance(50) ? prior : prior.uppercased() }
        if fuzzer.random.chance(95) { arguments["request_id"] = requestID }
        var text: Any = fuzzer.text()
        if let id = requestID as? String, let prior = used[id.lowercased()], fuzzer.random.chance(60) { text = prior.text }
        if fuzzer.random.chance(4) { text = fuzzer.random.pick([5, NSNull(), ["a"]] as [Any]) }
        if fuzzer.random.chance(96) { arguments["text"] = text }
        if fuzzer.random.chance(30) {
            let unknown = fuzzer.uuidString()
            arguments["pane_id"] = fuzzer.random.chance(80) ? fuzzer.random.pick([f.id(f.world.paneA), f.id(f.paneB), unknown])
                : fuzzer.uuid()
        }
        if fuzzer.random.chance(4) { arguments[fuzzer.random.pick(["card_id", "decision", "Text", "budget"])] = "x" }
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys) else { return }
        var encoded = String(decoding: data, as: UTF8.self)
        let truncated = fuzzer.random.chance(10) && encoded.utf8.count > 1
        if truncated {
            let bytes = Array(encoded.utf8)
            encoded = String(decoding: bytes[0..<(1 + fuzzer.random.below(bytes.count - 1))], as: UTF8.self)
        }
        let callID = fuzzer.uuidString()
        let (status, value, transport) = await f.send("relay_ask_miko", arguments: encoded, as: f.id(f.world.paneA), transport: callID)
        if truncated {
            fuzzer.counts["truncated", default: 0] += 1
            #expect(status == 400 && f.redeemed == before.redeemed, "\(label): truncated arguments \(status) spent=\(f.redeemed - before.redeemed)")
            #expect(f.channel.asks.count == before.asks && f.harness.exchanges.count == before.exchanges, "\(label): truncated input changed state")
            return
        }
        // The oracle's expected outcome.
        #expect(f.redeemed == before.redeemed + 1, "\(label): a well-formed call did not spend exactly one proof")
        let allowed: Set<String> = ["instance", "request_id", "text", "pane_id"]
        let id = arguments["request_id"] as? String
        let body = arguments["text"] as? String
        let context = arguments["pane_id"]
        let contractOK = Set(arguments.keys).isSubset(of: allowed) && id.map(MikoAskOracle.isUUID) == true &&
            body.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4096 } == true &&
            (context == nil || (context as? String).map(MikoAskOracle.isUUID) == true)
        let expected: Int
        var kind: String
        let contextKey = (context as? String)?.lowercased() ?? ""
        if !contractOK { expected = 400; kind = "invalid-arguments" }
        else if (arguments["instance"] as? String).map({ MikoAskOracle.isUUID($0) && UUID(uuidString: $0) == f.instance }) != true {
            expected = 409; kind = "stale-instance"
        } else if let prior = used[id!.lowercased()] {
            // Byte equality: the channel digests UTF-8, so canonically equal spellings differ.
            let same = Array(prior.text.utf8) == Array(body!.utf8) && prior.context == contextKey
            expected = same ? 200 : 409; kind = same ? "replayed" : "conflict"
        } else { expected = 200; kind = "accepted" }
        fuzzer.counts[kind, default: 0] += 1
        #expect(status == expected, "\(label): \(kind) expected \(expected), got \(status) \(value)")
        // Round trip: every answer after the proof names the caller's own request_id, exactly as sent.
        if let id, MikoAskOracle.isUUID(id) {
            #expect(value["request_id"] as? String == id, "\(label): request_id \(value["request_id"] ?? "nil") != \(id)")
        } else {
            #expect(value["request_id"] == nil, "\(label): a non-UUID request_id was echoed as one")
        }
        #expect(value["call_id"] as? String == transport, "\(label): call_id is not the transport id")
        guard status == 200, kind == "accepted", let id, let body else {
            #expect(f.channel.asks.count == before.asks && f.harness.exchanges.count == before.exchanges,
                    "\(label): a \(kind) call changed state")
            return
        }
        used[id.lowercased()] = (body, contextKey)
        #expect(await f.settle(), "\(label): never settled")
        let key = id.lowercased()
        let exchange = f.harness.exchanges.first { $0.requestID == f.channel.asks[key]?.exchangeID }
        // Bounded and whole: the request is the header (if any) plus the text, trimmed only at the ends as every turn is.
        var composed = body
        if let pane = context as? String, let uuid = UUID(uuidString: pane) {
            let name = f.world.workspace.panes[uuid]?.displayName ?? "unknown pane"
            composed = "Context pane: “\(RelayMikoSupervisorChannel.boundedName(name))” (\(pane.lowercased())).\n" + body
        }
        let want = composed.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(exchange?.request == want, "\(label): the model request differs from the composed ask")
        #expect((exchange?.request.utf8.count ?? .max) <= RelayMikoSupervisorChannel.askComposedLimit, "\(label): unbounded request")
        #expect(f.model.lastUserText?.hasSuffix(want) == true, "\(label): the model turn does not end with the whole request")
        let receipt = try await f.receipt(id, as: f.world.paneA)
        #expect(receipt.0 == 200 && receipt.1["request_id"] as? String == id && receipt.1["state"] as? String == "completed",
                "\(label): receipt by the returned id \(receipt.0) \(receipt.1["state"] ?? "nil")")
    }
}
