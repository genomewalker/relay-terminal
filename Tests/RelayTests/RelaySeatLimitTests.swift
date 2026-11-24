import Foundation
import Testing
@testable import Relay

/// Seat-limit (HTTP 429) notifications and moves. Event fields are exactly
/// what relayd's status line sends for real Claude Code refusal rows
/// (2026-10-27 five-hour, 2026-11-03 weekly; the Fable text from the brief).
@MainActor
@Suite("Seat-limit notification and move")
struct RelaySeatLimitTests {
    static let pane = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let business = RelayAgentAccount(provider: "claude", label: "business", dir: "~/.claude-business")
    static let personal = RelayAgentAccount(provider: "claude", label: "personal", dir: "~/.claude-personal")

    static func raw(kind: String, reset: Double?, row: String = "row-1", model: String? = nil,
                    occurredAt: String = ISO8601DateFormatter().string(from: Date()),
                    text: String = "You've hit your weekly limit · resets Nov 22, 9am (Europe/Copenhagen)") -> [String: Any] {
        var event: [String: Any] = ["hook_event_name": "SeatLimit", "limit_kind": kind, "seat_limit_id": row,
            "message": text, "session_id": "s-1", "occurred_at": occurredAt]
        if let reset { event["resets_at"] = NSNumber(value: reset) }
        if let model { event["limit_model"] = model }
        return event
    }

    static let now = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18
    static let weeklyReset = 1_795_334_400.0                   // Nov 22 09:00 CET

    static func event(_ raw: [String: Any], account: String? = "business") -> RelaySeatLimitEvent {
        RelaySeatLimitEvent.parse(raw, paneID: pane, host: "dandy-07", account: account)!
    }

    @Test("The three real refusal kinds parse with their window and reset")
    func parsesKinds() throws {
        let five = Self.event(Self.raw(kind: "five_hour", reset: 1_795_003_800,
            text: "You've hit your 5-hour limit · resets 3:10pm (Europe/Copenhagen)"))
        #expect(five.limitName == "5-hour" && five.resetsAt == Date(timeIntervalSince1970: 1_795_003_800))
        let weekly = Self.event(Self.raw(kind: "seven_day", reset: Self.weeklyReset))
        #expect(weekly.limitName == "weekly" && weekly.sessionID == "s-1" && weekly.rowID == "row-1")
        let fable = Self.event(Self.raw(kind: "model", reset: nil, model: "Fable",
            text: "You've reached your Fable limit. Run /usage-credits to continue or switch models with /model."))
        #expect(fable.limitName == "Fable" && fable.resetsAt == nil)
        #expect(RelaySeatLimitText.headline(weekly, pane: "api-work").hasPrefix("Claude in api-work hit the business weekly limit (resets "))
        #expect(RelaySeatLimitEvent.parse(["hook_event_name": "Stop"], paneID: Self.pane, host: "h", account: nil) == nil)
        #expect(RelaySeatLimitEvent.parse(Self.raw(kind: "Bad Kind", reset: nil), paneID: Self.pane, host: "h", account: nil) == nil)
    }

    @Test("A pane worker older than SeatLimit keeps only the message: the window and reset come from its text")
    func parsesTextOnlyEvent() throws {
        let weekly = try #require(RelaySeatLimitEvent.parse(["hook_event_name": "SeatLimit", "session_id": "s",
            "occurred_at": "2026-11-18T08:00:00.000Z",
            "message": "You've hit your weekly limit · resets Nov 22, 9am (Europe/Copenhagen)"], paneID: Self.pane, host: "h", account: "business"))
        #expect(weekly.kind == "seven_day" && weekly.resetsAt == Date(timeIntervalSince1970: Self.weeklyReset))
        let five = try #require(RelaySeatLimitEvent.parse(["hook_event_name": "SeatLimit", "occurred_at": "2026-11-20T12:00:00Z",
            "message": "You've hit your 5-hour limit · resets 3:10pm (Europe/Copenhagen)"], paneID: Self.pane, host: "h", account: nil))
        #expect(five.kind == "five_hour" && five.resetsAt == Date(timeIntervalSince1970: 1_795_183_800))
        let fable = try #require(RelaySeatLimitEvent.parse(["hook_event_name": "SeatLimit", "occurred_at": "2026-11-20T12:00:00Z",
            "message": "You've reached your Fable limit. Run /usage-credits to continue or switch models with /model."],
            paneID: Self.pane, host: "h", account: nil))
        #expect(fable.kind == "model" && fable.model == "Fable" && fable.resetsAt == nil)
        #expect(RelaySeatLimitEvent.parse(["hook_event_name": "SeatLimit", "occurred_at": "2026-11-20T12:00:00Z",
            "message": "something else"], paneID: Self.pane, host: "h", account: nil) == nil)
    }

    @Test("A refusal first seen long after Claude wrote it (a resumed conversation's history) is not news")
    func oldRowIgnored() {
        var ledger = RelaySeatLimitLedger()
        var old = Self.event(Self.raw(kind: "seven_day", reset: Self.weeklyReset))
        old.occurredAt = Self.now.addingTimeInterval(-3600)
        let admitted = ledger.admit(old, now: Self.now)
        #expect(!admitted && ledger.limits.isEmpty)
    }

    @Test("Simultaneous limits on two panes each get their own automatic move")
    func twoPanesMoveIndependently() async throws {
        let (coordinator, workspace, first, box) = try harness(automatic: true, decision: .init(target: Self.personal, autoMove: true))
        workspace.newTab(profile: .sshConfigHost("seat-limit-2.invalid"))
        let second = try #require(workspace.activePane)
        second.recordAgentAccount(Self.business)
        coordinator.mover = { pane, _, target, origin in
            box.moves.append((target.label, origin))
            // Both lanes are inside move() at once; each intent is its own.
            try? await Task.sleep(nanoseconds: 30_000_000)
            #expect(coordinator.authorizes(pane.id, target: target))
            return .init(state: "verified", message: "Moved")
        }
        let reset = Date().timeIntervalSince1970 + 86_400
        coordinator.observe(Self.raw(kind: "seven_day", reset: reset, row: "a"), pane: first)
        coordinator.observe(Self.raw(kind: "seven_day", reset: reset, row: "b"), pane: second)
        await settle { box.moves.count == 2 && coordinator.offers.isEmpty }
        #expect(box.moves.count == 2 && box.moves.allSatisfy { $0.1 == .seatLimit } && coordinator.offers.isEmpty)
        withExtendedLifetime(workspace) {}
    }

    @Test("A deferred automatic move is tried again; a lane that cannot finish posts why")
    func deferredThenStopped() async throws {
        let (coordinator, workspace, pane, box) = try harness(automatic: true, decision: .init(target: Self.personal, autoMove: true))
        coordinator.autoRetryInterval = 0.01
        coordinator.autoAttempts = 3
        coordinator.mover = { _, _, target, origin in
            box.moves.append((target.label, origin))
            return .init(state: "deferred", message: "Waiting for the current turn to finish")
        }
        coordinator.observe(Self.raw(kind: "five_hour", reset: Date().timeIntervalSince1970 + 3600), pane: pane)
        await settle { box.notices.count >= 2 }
        #expect(box.moves.count == 3)
        #expect(box.notices.last?.title.contains("was not moved") == true)
        #expect(box.notices.last?.detail.contains("Waiting for the current turn to finish") == true)
        withExtendedLifetime(workspace) {}
    }

    @Test("Once per limit occurrence: retries, replays and old rows do not repeat")
    func dedup() {
        var ledger = RelaySeatLimitLedger()
        let first = Self.event(Self.raw(kind: "seven_day", reset: Self.weeklyReset, row: "row-1"))
        do { let admitted = ledger.admit(first, now: Self.now); #expect(admitted) }
        // Claude writes a new row for each retry inside the same window.
        do { let admitted = ledger.admit(Self.event(Self.raw(kind: "seven_day", reset: Self.weeklyReset, row: "row-2")), now: Self.now); #expect(!admitted) }
        // The observer replays the same event after a reconnect.
        do { let admitted = ledger.admit(first, now: Self.now.addingTimeInterval(600)); #expect(!admitted) }
        // A refusal whose reset passed is not a current limit.
        do { let admitted = ledger.admit(Self.event(Self.raw(kind: "five_hour", reset: Self.now.timeIntervalSince1970 - 60)), now: Self.now); #expect(!admitted) }
        // The next window's limit is a new occurrence.
        do { let admitted = ledger.admit(Self.event(Self.raw(kind: "five_hour", reset: Self.now.timeIntervalSince1970 + 3600, row: "row-3")), now: Self.now); #expect(admitted) }
        // The account is recorded as limited until its reset.
        #expect(ledger.limit(host: "dandy-07", label: "business", now: Self.now)?.name == "5-hour")
        // Persisted form round-trips.
        let data = try! JSONEncoder().encode(ledger)
        #expect(try! JSONDecoder().decode(RelaySeatLimitLedger.self, from: data) == ledger)
    }

    @Test("Protected panes are never moved automatically, and the offer says so")
    func protectedRefusal() {
        // Mythos pane: must stay personal; a move to business is refused.
        let mythos = UUID(uuidString: "19b7955f-0000-4000-8000-000000000000")!
        let pinned = RelaySeatLimitPolicy.decide(target: .success(Self.business), health: .available,
            pinned: RelaySeatLimitPolicy.pinnedAccount(mythos), protection: RelaySeatLimitPolicy.protection(mythos, protectedList: []),
            ruleHold: nil, automatic: true)
        #expect(!pinned.autoMove && pinned.moveRefusal?.contains("must stay on personal") == true)
        // Sapropel and the maintenance list: offered to the user, never automatic.
        for (id, list) in [(UUID(uuidString: "767dc718-0000-4000-8000-000000000000")!, [String]()),
                           (Self.pane, [Self.pane.uuidString.lowercased()])] {
            for automatic in [true, false] {
                let decision = RelaySeatLimitPolicy.decide(target: .success(Self.personal), health: .available,
                    pinned: RelaySeatLimitPolicy.pinnedAccount(id), protection: RelaySeatLimitPolicy.protection(id, protectedList: list),
                    ruleHold: nil, automatic: automatic)
                #expect(!decision.autoMove && decision.moveRefusal == nil && decision.target == Self.personal)
                #expect(decision.autoHold?.contains("never moved automatically") == true)
            }
        }
        // A workspace rule naming the current account holds automatic moves.
        var rules = RelayAgentAccountRules()
        let workspace = UUID()
        rules.workspaces[RelayAgentAccountRules.workspaceKey(workspace)] = ["claude": "business"]
        let hold = RelaySeatLimitPolicy.ruleHold(rules: rules, host: "dandy-07", workspace: workspace, current: "business")
        let ruled = RelaySeatLimitPolicy.decide(target: .success(Self.personal), health: .available, pinned: nil,
                                                protection: nil, ruleHold: hold, automatic: true)
        #expect(!ruled.autoMove && ruled.autoHold?.contains("agent_account_rules") == true)
    }

    @Test("Automatic off: an offer only; on: a move; the other account limited: refused with its reason")
    func decisions() {
        let off = RelaySeatLimitPolicy.decide(target: .success(Self.personal), health: .available, pinned: nil,
                                              protection: nil, ruleHold: nil, automatic: false)
        #expect(off.target == Self.personal && !off.autoMove && off.autoHold == nil && off.moveRefusal == nil)
        let on = RelaySeatLimitPolicy.decide(target: .success(Self.personal), health: .available, pinned: nil,
                                             protection: nil, ruleHold: nil, automatic: true)
        #expect(on.autoMove)
        // Known limited from an earlier refusal of that account.
        var ledger = RelaySeatLimitLedger()
        _ = ledger.admit(RelaySeatLimitEvent.parse(Self.raw(kind: "seven_day", reset: Self.weeklyReset, row: "p"),
            paneID: UUID(), host: "dandy-07", account: "personal")!, now: Self.now)
        let health = RelaySeatLimitPolicy.health(usage: nil, knownLimit: ledger.limit(host: "dandy-07", label: "personal", now: Self.now),
                                                 label: "personal", now: Self.now)
        let limited = RelaySeatLimitPolicy.decide(target: .success(Self.personal), health: health, pinned: nil,
                                                  protection: nil, ruleHold: nil, automatic: true)
        #expect(!limited.autoMove && limited.moveRefusal?.hasPrefix("personal is also at its weekly limit until") == true)
        // Unknown usage: the user may still move it; Relay does not.
        let unknown = RelaySeatLimitPolicy.decide(target: .success(Self.personal),
            health: RelaySeatLimitPolicy.health(usage: nil, knownLimit: nil, label: "personal", now: Self.now),
            pinned: nil, protection: nil, ruleHold: nil, automatic: true)
        #expect(!unknown.autoMove && unknown.moveRefusal == nil && unknown.autoHold?.contains("usage is unknown") == true)
        // No other account: refused with the reason.
        let none = RelaySeatLimitPolicy.decide(target: RelaySeatLimitPolicy.otherAccount(current: "business", registry: nil,
            settings: .init()), health: .available, pinned: nil, protection: nil, ruleHold: nil, automatic: true)
        #expect(none.moveRefusal == "this host's Claude account list has not been read yet" && none.target == nil)
        #expect(try! RelaySeatLimitPolicy.otherAccount(current: "business", registry: [Self.business, Self.personal],
                                                        settings: .init()).get() == Self.personal)
    }

    /// A real workspace and pane; the move, usage refresh and host facts are fakes.
    func harness(automatic: Bool, decision: RelaySeatLimitPolicy.Decision)
        throws -> (RelaySeatLimitCoordinator, WorkspaceModel, PaneModel, Box) {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        workspace.newTab(profile: .sshConfigHost("seat-limit.invalid"))
        let pane = try #require(workspace.activePane)
        pane.recordAgentAccount(Self.business)
        let coordinator = RelaySeatLimitCoordinator(url: nil)
        coordinator.install(workspace: workspace)
        let box = Box()
        coordinator.automaticEnabled = { automatic }
        coordinator.refreshUsage = { _ in }
        coordinator.decider = { _, _, _ in decision }
        coordinator.notify = { event in box.notices.append(event); return "inbox-\(box.notices.count)" }
        coordinator.mover = { _, _, target, origin in
            box.moves.append((target.label, origin))
            return .init(state: "verified", message: "Moved")
        }
        return (coordinator, workspace, pane, box)
    }

    final class Box { var notices: [AgentInboxEvent] = []; var moves: [(String, RelayAgentAccountMoveOrigin)] = [] }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test("Automatic off: one notification with the offer, no move, no repeat")
    func coordinatorOffersOnly() async throws {
        let (coordinator, workspace, pane, box) = try harness(automatic: false,
            decision: .init(target: Self.personal))
        let raw = Self.raw(kind: "seven_day", reset: Date().timeIntervalSince1970 + 86_400)
        coordinator.observe(raw, pane: pane)
        coordinator.observe(raw, pane: pane)
        await settle { !box.notices.isEmpty }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(box.notices.count == 1 && box.moves.isEmpty)
        #expect(box.notices.first?.detail.contains("Move to personal?") == true)
        #expect(box.notices.first?.alert == .needsInput)
        #expect(coordinator.offers[pane.id]?.decision.target == Self.personal)
        withExtendedLifetime(workspace) {}
    }

    @Test("Automatic on: the move is requested with the seat-limit origin, then reported")
    func coordinatorMovesAutomatically() async throws {
        let (coordinator, workspace, pane, box) = try harness(automatic: true,
            decision: .init(target: Self.personal, autoMove: true))
        coordinator.observe(Self.raw(kind: "five_hour", reset: Date().timeIntervalSince1970 + 3600), pane: pane)
        await settle { box.notices.count >= 2 }
        #expect(box.moves.count == 1 && box.moves.first?.0 == "personal" && box.moves.first?.1 == .seatLimit)
        #expect(box.notices.last?.title.contains("Relay moved") == true && coordinator.offers[pane.id] == nil)
        withExtendedLifetime(workspace) {}
    }

    @Test("The other account is limited: no move, the entry says why")
    func coordinatorRefusesLimitedTarget() async throws {
        let (coordinator, workspace, pane, box) = try harness(automatic: true,
            decision: .init(target: Self.personal, moveRefusal: "personal is also at its weekly limit until Nov 22 09:00"))
        coordinator.observe(Self.raw(kind: "seven_day", reset: Date().timeIntervalSince1970 + 86_400), pane: pane)
        await settle { !box.notices.isEmpty }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(box.moves.isEmpty)
        #expect(box.notices.first?.detail.contains("Relay cannot move it: personal is also at its weekly limit") == true)
        withExtendedLifetime(workspace) {}
    }

    @Test("Seat-limit moves are automatic: no target preparation, and only the coordinator's intent authorizes them")
    func originPolicy() {
        #expect(RelayAgentAccountMovePolicy.automatic(.seatLimit) && !RelayAgentAccountMovePolicy.preparesTarget(.seatLimit))
        #expect(!RelayAgentAccountMovePolicy.automatic(.user))
        let coordinator = RelaySeatLimitCoordinator(url: nil)
        coordinator.automaticEnabled = { true }
        #expect(!coordinator.authorizes(Self.pane, target: Self.personal))
        coordinator.setIntentForTesting(pane: Self.pane, target: Self.personal)
        #expect(coordinator.authorizes(Self.pane, target: Self.personal))
        #expect(!coordinator.authorizes(Self.pane, target: Self.business))
        coordinator.automaticEnabled = { false }
        #expect(!coordinator.authorizes(Self.pane, target: Self.personal))
    }
}
