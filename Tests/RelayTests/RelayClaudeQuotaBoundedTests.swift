import XCTest
@testable import Relay

final class RelayClaudeQuotaBoundedTests: XCTestCase {
    typealias E = RelayClaudeQuotaEngine
    struct State {
        var engine: E
        var panes: [E.Pane]
        var source: E.Quota
        var target: E.Quota
        var paused: Bool
        var now: Date
        var users: Set<UUID>
        var starts: [UUID: Set<Date>]
    }
    func testExhaustiveThreePaneThreeStepInterleavings() throws {
        let fixtures = RelayClaudeQuotaFailoverTests()
        // These are decisions of the REAL idle gate, not test-only booleans.
        let idle = try (0..<3).map { try RelayClaudeQuotaIdleTests.idle($0) }
        XCTAssertEqual(idle, [true, false, true])
        var explored = 0
        var transitions = 0
        func walk(_ state: State, _ depth: Int) throws {
            explored += 1
            guard depth > 0 else { return }
            // Scheduler: poll/finish. User: move each pane, pause, advance
            // clock and publish the post-reset quota. Every ordering is run.
            for action in 0..<(7 + state.panes.count) {
                var s = state
                transitions += 1
                switch action {
                case 0:
                    var events: [(UUID, String)] = []
                    var persisted: E.Disk?
                    let before = s.engine.inFlight
                    let records = s.engine.disk.records
                    let move = try s.engine.next(settings: .init(), host: "dandy-07", source: s.source, target: s.target,
                        panes: s.panes, paused: s.paused, now: s.now, sourceDir: "~/.claude-team", targetDir: "~/.claude-max",
                        save: { persisted = $0 }, audit: { events.append(($0, $1)) })
                    if let move {
                        // Named safety properties, after every real transition.
                        XCTAssertNil(before, "at most one move in flight")
                        XCTAssertTrue(move.pane.idle, "no busy pane moved")
                        XCTAssertFalse(s.users.contains(move.pane.id), "user-moved panes never touched")
                        XCTAssertFalse(s.paused, "pause stops new moves")
                        XCTAssertTrue(s.source.current(s.now), "stale quota never current")
                        XCTAssertEqual(events.filter { $0.1.hasSuffix("intent") }.count, 1, "every move audited")
                        XCTAssertEqual(persisted?.records.first(where: { $0.pane == move.pane.id })?.operation, move.operation,
                            "intent durable before effect")
                        if move.returning {
                            let record = try XCTUnwrap(records.first(where: { $0.pane == move.pane.id }))
                            XCTAssertGreaterThan(s.now, record.reset, "nothing returns before reset")
                            XCTAssertGreaterThan(s.source.observed, record.reset, "return needs a post-reset observation")
                            XCTAssertLessThan(s.source.used, 90, "no return at or above threshold")
                            XCTAssertEqual(record.state, .away, "only scheduler-owned panes return")
                        } else {
                            XCTAssertGreaterThanOrEqual(s.source.used, 90, "failover threshold")
                            XCTAssertTrue(s.target.current(s.now), "target must be usable")
                            XCTAssertLessThan(s.target.used, 95, "target ceiling")
                            XCTAssertFalse(s.starts[move.pane.id, default: []].contains(s.source.reset), "no oscillation within window")
                            // Completion, not an idle deferral, consumes the window.
                        }
                    }
                case 1:
                    if let move = s.engine.inFlight {
                        if let i = s.panes.firstIndex(where: { $0.id == move.pane.id }), !s.users.contains(move.pane.id) {
                            s.panes[i].label = move.target
                            if !move.returning, let record = s.engine.disk.records.first(where: { $0.operation == move.operation }) {
                                s.starts[move.pane.id, default: []].insert(record.reset)
                            }
                        }
                        var audited = false
                        try s.engine.finish(move, success: true, process: move.pane.process, detail: "completed",
                            save: { _ in }, audit: { _, event in audited = event == "move_completed" })
                        XCTAssertTrue(audited, "completion audited")
                    }
                case 2:
                    s.paused.toggle()
                case 3:
                    s.now = Date(timeIntervalSince1970: 1101)
                    s.source.reset = Date(timeIntervalSince1970: 1200)
                    s.source.observed = s.now
                    s.source.weekly["seven_day"] = .init(used: 10, reset: s.source.reset, observed: s.now)
                    s.target.reset = s.source.reset
                    s.target.observed = s.now
                    s.target.weekly["seven_day"] = .init(used: 10, reset: s.target.reset, observed: s.now)
                case 4, 5:
                    if let move = s.engine.inFlight {
                        try s.engine.finish(move, success: false, process: move.pane.process, detail: "fake refusal or idle deferral",
                            deferred: action == 5, save: { _ in }, audit: { _, _ in })
                    }
                case 6:
                    s.engine = E(disk: s.engine.disk)
                default:
                    let i = action - 7
                    let id = s.panes[i].id
                    s.users.insert(id)
                    try s.engine.userMoved(s.panes[i], source: "business", target: "personal", save: { _ in })
                    s.panes[i].label = s.panes[i].label == "personal" ? "business" : "personal"
                    s.panes[i].process = "manual:99"
                }
                for user in s.users {
                    XCTAssertEqual(s.engine.disk.records.first(where: { $0.pane == user })?.state, .user,
                        "user ownership wins every two-actor interleaving")
                }
                try walk(s, depth - 1)
            }
        }
        // 0...3 panes, 3 idle states x 3 ownership states per pane, and
        // all source/observation/target/pause combinations. No sampling.
        for count in 0...3 {
            let assignments = Int(pow(9.0, Double(count)))
            for assignment in 0..<assignments {
                var panes: [E.Pane] = []
                var records: [E.Record] = []
                var users: Set<UUID> = []
                var starts: [UUID: Set<Date>] = [:]
                var digits = assignment
                for i in 0..<count {
                    let digit = digits % 9; digits /= 9
                    let mode = digit % 3, owner = digit / 3
                    let pane = fixtures.pane(i, label: owner == 0 ? "business" : "personal", idle: idle[mode])
                    panes.append(pane)
                    if owner != 0 {
                        records.append(.init(pane: pane.id, host: pane.host, session: pane.session, process: pane.process,
                            source: "business", target: "personal", sourceDir: "~/.claude-team", targetDir: "~/.claude-max",
                            reset: fixtures.reset, state: owner == 1 ? .away : .user, operation: UUID(), detail: "initial", triggerResets: ["five_hour": fixtures.reset]))
                        if owner == 2 { users.insert(pane.id) }
                        else { starts[pane.id] = [fixtures.reset] }
                    }
                }
                for used in [89.0, 90, 91] {
                    for observation in 0..<3 {
                        for target in [94.0, 95] {
                            for paused in [false, true] {
                                var quota = fixtures.quota(used)
                                if observation == 1 { quota.observed = fixtures.now.addingTimeInterval(-121) }
                                if observation == 2 { quota.reset = fixtures.now.addingTimeInterval(-1) }
                                try walk(.init(engine: E(disk: .init(records: records)), panes: panes, source: quota,
                                    target: fixtures.quota(target), paused: paused, now: fixtures.now, users: users, starts: starts), 3)
                            }
                        }
                    }
                }
            }
        }
        print("QF bounded: panes=0...3; action depth=3; initial states=29520; states=\(explored); transitions=\(transitions)")
        XCTAssertGreaterThan(explored, 10_000_000)
    }
}
