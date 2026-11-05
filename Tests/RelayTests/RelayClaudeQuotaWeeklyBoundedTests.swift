import XCTest
@testable import Relay

/// Extends (and retains) the original unpruned depth-three checker. This
/// checker merges only identical logical states at the same remaining depth;
/// UUID operation names are alpha-renamed, retaining their equality relation.
final class RelayClaudeQuotaWeeklyBoundedTests: XCTestCase {
    typealias E = RelayClaudeQuotaEngine
    struct State {
        var engine: E
        var panes: [E.Pane]
        var source: E.Quota
        var target: E.Quota
        var enabled: Bool
        var paused: Bool
        var now: Date
        var users: Set<UUID>
        var consumed: [UUID: Int]
    }
    struct Key: Hashable { var depth: Int; var values: [Int] }
    enum Failure: Error { case safetyProperty }
    func mask(_ resets: [String: Date]) -> Int {
        resets.reduce(0) { result, pair in
            let bit = pair.key == "five_hour" ? (pair.value.timeIntervalSince1970 == 1100 ? 1 : 2) : (pair.value.timeIntervalSince1970 == 1300 ? 4 : 8)
            return result | bit
        }
    }
    func key(_ state: State, depth: Int) -> Key {
        var values = [Int(state.now.timeIntervalSince1970), state.enabled ? 1 : 0, state.paused ? 1 : 0,
                      state.engine.disk.version, state.panes.count]
        for quota in [state.source, state.target] {
            values.append(quota.fiveHourReported ? 1 : 0)
            for window in [E.Window(used: quota.used, reset: quota.reset, observed: quota.observed), quota.weekly["seven_day"]!] {
                values += [Int(window.used), Int(window.reset.timeIntervalSince1970), Int(window.observed.timeIntervalSince1970)]
            }
        }
        let states: [E.Record.State] = [.moving, .queued, .away, .returning, .returned, .refused, .user]
        for pane in state.panes {
            values += [pane.idle ? 1 : 0, pane.label == "business" ? 0 : 1, pane.process == "manual:99" ? 1 : 0,
                       state.users.contains(pane.id) ? 1 : 0, state.consumed[pane.id, default: 0]]
            if let record = state.engine.disk.records.first(where: { $0.pane == pane.id }) {
                values += [1, states.firstIndex(of: record.state)!, Int(record.reset.timeIntervalSince1970), mask(record.triggerResets),
                           record.process == "manual:99" ? 1 : 0, record.operation == state.engine.inFlight?.operation ? 1 : 0]
            } else { values += [0, 0, 0, 0, 0, 0] }
        }
        if let move = state.engine.inFlight {
            values += [1, state.panes.firstIndex(where: { $0.id == move.pane.id })!, move.returning ? 1 : 0,
                       move.pane.label == "business" ? 0 : 1, move.pane.process == "manual:99" ? 1 : 0]
        } else { values += [0, 0, 0, 0, 0] }
        return .init(depth: depth, values: values)
    }
    func testWeeklyCartesianThreePaneThreeStepInterleavings() throws {
        let f = RelayClaudeQuotaFailoverTests(), w = RelayClaudeQuotaWeeklyTests()
        let idle = try (0..<3).map { try RelayClaudeQuotaIdleTests.idle($0) }
        XCTAssertEqual(idle, [true, false, true])
        var visited: Set<Key> = []
        var initials = 0, unique = 0, visits = 0, transitions = 0, merged = 0
        func walk(_ state: State, _ depth: Int) throws {
            visits += 1
            guard depth > 0 else { return }
            guard visited.insert(key(state, depth: depth)).inserted else { merged += 1; return }
            unique += 1
            for action in 0..<(9 + state.panes.count) {
                var s = state
                transitions += 1
                switch action {
                case 0:
                    var settings = RelayClaudeQuotaSettings(); settings.enabled = s.enabled
                    var events: [(UUID, String)] = []; var persisted: E.Disk?
                    let previous = s.engine.inFlight, records = s.engine.disk.records
                    let move = try s.engine.next(settings: settings, host: "dandy-07", source: s.source, target: s.target,
                        panes: s.panes, paused: s.paused, now: s.now, sourceDir: "~/.claude-team", targetDir: "~/.claude-max",
                        save: { persisted = $0 }, audit: { events.append(($0, $1)) })
                    if let move {
                        XCTAssertNil(previous, "at most one move in flight")
                        XCTAssertTrue(move.pane.idle, "no busy move")
                        XCTAssertFalse(s.users.contains(move.pane.id), "user-moved panes never touched")
                        XCTAssertTrue(s.enabled && !s.paused, "disabled or paused stops new moves")
                        XCTAssertTrue(s.source.current(s.now), "fresh observations for every source window")
                        XCTAssertEqual(events.filter { $0.1.hasSuffix("intent") }.count, 1, "every move audited")
                        let durable = try XCTUnwrap(persisted?.records.first(where: { $0.pane == move.pane.id }))
                        XCTAssertEqual(durable.operation, move.operation, "every move journaled before effect")
                        if move.returning {
                            let old = try XCTUnwrap(records.first(where: { $0.pane == move.pane.id }))
                            XCTAssertEqual(old.state, .away)
                            for (name, reset) in old.triggerResets {
                                XCTAssertGreaterThan(s.now, reset, "no return before every triggering reset")
                                if let window = s.source.windows[name] {
                                    XCTAssertGreaterThan(window.observed, reset, "post-reset evidence for every trigger")
                                } else {
                                    // Only a 5-hour window Claude stopped reporting may be absent;
                                    // every weekly window is then post-reset evidence.
                                    XCTAssertTrue(name == "five_hour" && !s.source.fiveHourReported, "a missing weekly trigger never returns")
                                    XCTAssertTrue(s.source.weekly.values.allSatisfy { $0.observed > reset }, "post-reset weekly evidence")
                                }
                            }
                            if s.source.fiveHourReported { XCTAssertLessThan(s.source.used, 90) }
                            XCTAssertTrue(s.source.weekly.values.allSatisfy { $0.used < 90 }, "no return with any high source window")
                            XCTAssertEqual(durable.triggerResets, old.triggerResets, "return retains every trigger")
                        } else {
                            let expected = s.source.triggers(settings)
                            XCTAssertFalse(expected.isEmpty, "either source window can trigger")
                            XCTAssertTrue(s.source.fiveHourReported || expected["five_hour"] == nil, "an unreported 5-hour window never triggers")
                            XCTAssertEqual(durable.triggerResets, expected, "every triggering reset recorded")
                            XCTAssertTrue(s.target.current(s.now), "both target windows fresh")
                            XCTAssertTrue(s.target.windows.values.allSatisfy { $0.used < 95 }, "both target ceilings")
                            XCTAssertEqual(s.consumed[move.pane.id, default: 0] & mask(expected), 0, "no oscillation or retry within a consumed window")
                        }
                    }
                case 1, 5, 6:
                    if let move = s.engine.inFlight {
                        if action == 1, !s.users.contains(move.pane.id), let i = s.panes.firstIndex(where: { $0.id == move.pane.id }) {
                            s.panes[i].label = move.target
                        }
                        // A permanent refusal consumes its window too; an idle deferral does not.
                        if action != 6, !move.returning, let record = s.engine.disk.records.first(where: { $0.operation == move.operation }) {
                            s.consumed[move.pane.id, default: 0] |= mask(record.triggerResets)
                        }
                        var audited = false
                        try s.engine.finish(move, success: action == 1, process: move.pane.process, detail: "bounded effect",
                            deferred: action == 6, save: { _ in }, audit: { _, _ in audited = true })
                        XCTAssertTrue(audited, "every completion, refusal and deferral audited")
                    }
                case 2: s.paused.toggle()
                case 3, 4:
                    let next = Date(timeIntervalSince1970: action == 3 ? 1101 : 1301)
                    if next > s.now {
                        s.now = next
                        s.source.observed = next; s.source.used = 10; s.source.reset = Date(timeIntervalSince1970: 1500)
                        s.source.weekly["seven_day"]!.observed = next
                        if action == 4 { s.source.weekly["seven_day"]!.used = 10; s.source.weekly["seven_day"]!.reset = Date(timeIntervalSince1970: 2300) }
                        s.target.observed = next; s.target.reset = Date(timeIntervalSince1970: 1500)
                        s.target.weekly["seven_day"]!.observed = next; s.target.weekly["seven_day"]!.reset = Date(timeIntervalSince1970: 2300)
                    }
                case 7: s.engine = E(disk: s.engine.disk)
                case 8: s.enabled.toggle()
                default:
                    let i = action - 9, pane = s.panes[i]
                    s.users.insert(pane.id)
                    try s.engine.userMoved(pane, source: "business", target: "personal", save: { _ in })
                    s.panes[i].label = pane.label == "business" ? "personal" : "business"; s.panes[i].process = "manual:99"
                }
                for user in s.users {
                    XCTAssertEqual(s.engine.disk.records.first(where: { $0.pane == user })?.state, .user, "user ownership wins every interleaving")
                }
                if let run = self.testRun, run.failureCount > 0 { throw Failure.safetyProperty }
                try walk(s, depth - 1)
            }
        }
        // Full product, no sampling. Fresh/stale/expired/future are varied
        // independently for 5h and weekly; target ceilings independently too.
        for five in [89.0, 90, 91] { for weekly in [89.0, 90, 91] {
            // targetFive -1: the target reports no 5-hour window.
            for targetFive in [94.0, 95, -1] { for targetWeekly in [94.0, 95] {
                // Share reset/refreshed successors across freshness classes.
                // Exact pre-refresh timestamps remain part of the cache key.
                visited.removeAll(keepingCapacity: true)
                // freshFive 4: the source reports no 5-hour window.
                for freshFive in 0..<5 { for freshWeekly in 0..<4 {
                    for count in 0...3 {
                        for assignment in 0..<Int(pow(9.0, Double(count))) {
                            var panes: [E.Pane] = [], records: [E.Record] = [], users: Set<UUID> = [], consumed: [UUID: Int] = [:]
                            var digits = assignment
                            for i in 0..<count {
                                let digit = digits % 9; digits /= 9
                                let mode = digit % 3, owner = digit / 3
                                let pane = f.pane(i, label: owner == 0 ? "business" : "personal", idle: idle[mode]); panes.append(pane)
                                if owner != 0 {
                                    let triggers = ["five_hour": Date(timeIntervalSince1970: 1100), "seven_day": Date(timeIntervalSince1970: 1300)]
                                    records.append(.init(pane: pane.id, host: pane.host, session: pane.session, process: pane.process,
                                        source: "business", target: "personal", sourceDir: "~/.claude-team", targetDir: "~/.claude-max",
                                        reset: Date(timeIntervalSince1970: 1300), state: owner == 1 ? .away : .user, operation: UUID(), detail: "initial", triggerResets: triggers))
                                    if owner == 2 { users.insert(pane.id) } else { consumed[pane.id] = mask(triggers) }
                                }
                            }
                            for enabled in [false, true] { for paused in [false, true] {
                                var source = w.quota(five, weekly)
                                switch freshFive { case 1: source.observed = Date(timeIntervalSince1970: 879); case 2: source.reset = f.now; case 3: source.observed = Date(timeIntervalSince1970: 1001); case 4: source.fiveHourReported = false; default: break }
                                switch freshWeekly { case 1: source.weekly["seven_day"]!.observed = Date(timeIntervalSince1970: 879); case 2: source.weekly["seven_day"]!.reset = f.now; case 3: source.weekly["seven_day"]!.observed = Date(timeIntervalSince1970: 1001); default: break }
                                initials += 1
                                var target = w.quota(max(targetFive, 0), targetWeekly)
                                target.fiveHourReported = targetFive >= 0
                                try walk(.init(engine: E(disk: .init(records: records)), panes: panes, source: source,
                                    target: target, enabled: enabled, paused: paused, now: f.now, users: users, consumed: consumed), 3)
                            } }
                        }
                    }
                } }
            } }
            print("QF2 weekly bounded progress: five=\(five); weekly=\(weekly); initial=\(initials); visits=\(visits); unique=\(unique); transitions=\(transitions); equivalent=\(merged)")
        } }
        print("QF2 weekly bounded: panes=0...3; depth=3; initials=\(initials); visits=\(visits); unique=\(unique); transitions=\(transitions); equivalent=\(merged)")
        XCTAssertEqual(initials, 3_542_400, "original 1,889,280 initials plus unreported 5-hour source and target")
        XCTAssertGreaterThan(transitions, 31_722_624, "weekly extension retains and exceeds original transition bound")
    }
}
