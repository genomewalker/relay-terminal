import Foundation
import XCTest
@testable import Relay

/// F1-F3. Live wire rule (r2, option B): a reading without `five_hour` has
/// unknown 5-hour usage and authorizes neither a move nor a return. The engine
/// tests below cover the weekly-only model, which is NOT LIVE pending an
/// authoritative contract for a missing `five_hour`. Only the host's own
/// registry names accounts, and every unusable reading has a named reason.
final class RelayClaudeQuotaFiveHourTests: XCTestCase {
    typealias E = RelayClaudeQuotaEngine
    let w = RelayClaudeQuotaWeeklyTests()

    /// Engine-model only (not live): a quota without a 5-hour window. Its five
    /// fields are deliberately extreme so any use of them would show.
    func weeklyOnly(_ weekly: Double, at: Double = 1000, weeklyReset: Double = 1300) -> E.Quota {
        var quota = w.quota(100, weekly, at: at, fiveReset: 1, weeklyReset: weeklyReset)
        quota.fiveHourReported = false
        return quota
    }

    // MARK: - Weekly-only engine model (not live; see the file comment)

    func testWeeklyOnlyReadingTriggersAtWeeklyThresholdOnly() throws {
        for used in [89.0, 90, 91] {
            var engine = E()
            let move = try w.next(&engine, source: weeklyOnly(used))
            XCTAssertEqual(move != nil, used >= 90)
            if move != nil {
                XCTAssertEqual(engine.disk.records[0].triggerResets, ["seven_day": Date(timeIntervalSince1970: 1300)],
                               "an unreported 5-hour window never triggers")
            }
        }
        XCTAssertFalse(weeklyOnly(10).windows.keys.contains("five_hour"))
        XCTAssertTrue(weeklyOnly(10).below(.init()), "an unreported 5-hour window is not a high window")
    }

    func testWeeklyOnlyStaleFutureExpiredInvalidOrMissingNeverMoves() throws {
        for mode in 0..<6 {
            var source = weeklyOnly(98), engine = E()
            switch mode {
            case 0: source.weekly["seven_day"]!.observed = Date(timeIntervalSince1970: 879)
            case 1: source.weekly["seven_day"]!.observed = Date(timeIntervalSince1970: 1001)
            case 2: source.weekly["seven_day"]!.reset = Date(timeIntervalSince1970: 1000)
            case 3: source.weekly["seven_day"]!.used = .nan
            case 4: source.weekly = [:]
            default: source.weekly = ["unknown": source.weekly["seven_day"]!]
            }
            XCTAssertNil(try w.next(&engine, source: source), "mode \(mode)")
        }
    }

    func testReportedFiveHourWindowIsStillRequiredToBeValid() throws {
        // Present but stale or expired: the reading is unusable, it is never
        // treated as unreported.
        for mode in 0..<3 {
            var source = w.quota(95, 98), engine = E()
            switch mode {
            case 0: source.observed = Date(timeIntervalSince1970: 879)
            case 1: source.reset = Date(timeIntervalSince1970: 1000)
            default: source.used = 101
            }
            XCTAssertNil(try w.next(&engine, source: source), "mode \(mode)")
        }
    }

    func testTargetWithoutFiveHourIsJudgedOnItsWeeklyCeiling() throws {
        for weekly in [94.0, 95, 96] {
            var engine = E()
            let move = try w.next(&engine, source: w.quota(90, 10), target: weeklyOnly(weekly))
            XCTAssertEqual(move != nil, weekly < 95)
        }
        var target = weeklyOnly(20), engine = E()
        target.weekly["seven_day"]!.observed = Date(timeIntervalSince1970: 879)
        XCTAssertNil(try w.next(&engine, source: w.quota(90, 10), target: target), "a stale weekly target never admits a move")
    }

    func testReturnAfterAFiveHourTriggerWhoseWindowIsNoLongerReported() throws {
        var engine = E()
        let move = try XCTUnwrap(w.next(&engine, source: w.quota(90, 10)))
        XCTAssertEqual(Set(engine.disk.records[0].triggerResets.keys), ["five_hour"])
        try w.f.finish(&engine, move)
        // Before the recorded reset, no return.
        XCTAssertNil(try w.next(&engine, source: weeklyOnly(10, at: 1099, weeklyReset: 2300), at: 1099, returning: true))
        // After it, weekly evidence observed before the reset second cannot authorize.
        var early = weeklyOnly(10, at: 1100.5, weeklyReset: 2300)
        XCTAssertNil(try w.next(&engine, source: early, at: 1101, returning: true))
        // A high weekly window still blocks the return.
        XCTAssertNil(try w.next(&engine, source: weeklyOnly(90, at: 1101, weeklyReset: 2300), at: 1101, returning: true))
        early.weekly["seven_day"]!.observed = Date(timeIntervalSince1970: 1101)
        let back = try XCTUnwrap(w.next(&engine, source: early, at: 1101, returning: true))
        XCTAssertTrue(back.returning)
    }

    func testMissingWeeklyTriggerStillFencesReturn() throws {
        var engine = E()
        let move = try XCTUnwrap(w.next(&engine, source: weeklyOnly(98)))
        try w.f.finish(&engine, move)
        var other = weeklyOnly(10, at: 1301, weeklyReset: 2300)
        other.weekly = ["seven_day_opus": other.weekly["seven_day"]!]
        XCTAssertNil(try w.next(&engine, source: other, at: 1301, returning: true), "only the 5-hour window may be absent at return")
        XCTAssertNotNil(try w.next(&engine, source: weeklyOnly(10, at: 1301, weeklyReset: 2300), at: 1301, returning: true))
    }

    // MARK: - Reading the wire (F1, F3)

    let now = Date(timeIntervalSince1970: 1792770000)
    func usage(_ windows: [RelayAgentAccountUsage.Window], status: String = "ok", reason: String? = nil,
               age: Double = 0) -> RelayAgentAccountUsage {
        let formatter = ISO8601DateFormatter()
        return .init(provider: "claude", label: "business", status: status, reason: reason, source: "fake",
            readAt: formatter.string(from: now.addingTimeInterval(-age)), windows: windows)
    }
    var end: String { ISO8601DateFormatter().string(from: now.addingTimeInterval(1000)) }
    func window(_ name: String, _ used: Double, reset: String?? = nil) -> RelayAgentAccountUsage.Window {
        .init(name: name, usedPercent: used, resetsAt: reset ?? end, windowMinutes: name == "five_hour" ? 300 : 10080)
    }
    @MainActor func code(_ value: RelayAgentAccountUsage?, ceiling: Double? = nil) -> String? {
        if case .failure(let unusable) = RelayClaudeQuotaScheduler.reading(value, now: now, targetCeiling: ceiling) { return unusable.code }
        return nil
    }

    /// r2 (option B): an unknown 5-hour window, on the source or the target,
    /// never reaches the engine, so it cannot authorize a move or a return.
    @MainActor func testUnreportedFiveHourIsUnknownAndCannotAuthorizeMoveOrReturn() throws {
        for weekly in [10.0, 89, 90, 98] {
            let reading = usage([window("seven_day", weekly)])
            // Source: the scheduler defers on any failure before trigger or
            // return evaluation.
            XCTAssertEqual(code(reading), "no_five_hour", "source weekly \(weekly)")
            XCTAssertNil(RelayClaudeQuotaScheduler.quota(reading, now: now))
            // Target: headroom is never assumed for an unknown 5-hour window.
            XCTAssertEqual(code(reading, ceiling: 95), "no_five_hour", "target weekly \(weekly)")
            XCTAssertNil(RelayClaudeQuotaScheduler.quota(reading, now: now, targetCeiling: 95))
        }
        if case .failure(let unusable) = RelayClaudeQuotaScheduler.reading(usage([window("seven_day", 10)]), now: now) {
            XCTAssertTrue(unusable.text.contains("unknown"), "Settings says unknown, never 'no window running'")
            XCTAssertFalse(unusable.text.contains("running"))
        } else { XCTFail("a missing five_hour must be unusable") }
        // Settings still shows the weekly figures, with the 5-hour as unknown.
        let text = RelayClaudeQuotaScheduler.usageText(usage([window("seven_day", 77)]), label: "business", now: now)
        XCTAssertTrue(text.contains("business 5-hour: not reported (usage unknown; failover waits)"))
        XCTAssertTrue(text.joined().contains("weekly: 77%"))
        let both = try XCTUnwrap(RelayClaudeQuotaScheduler.quota(usage([window("five_hour", 10), window("seven_day", 77)]), now: now))
        XCTAssertTrue(both.fiveHourReported)
    }

    @MainActor func testEveryUnusableReadingHasANamedReason() {
        XCTAssertEqual(code(nil), "none")
        XCTAssertEqual(code(usage([], status: "unknown", reason: "Claude reports no plan limits for this account")), "status")
        if case .failure(let unusable) = RelayClaudeQuotaScheduler.reading(
            usage([], status: "unknown", reason: "Claude reports no plan limits for this account"), now: now) {
            XCTAssertTrue(unusable.text.contains("no plan limits"), "relayd's reason reaches Settings")
        } else { XCTFail("status unknown must be unusable") }
        XCTAssertEqual(code(usage([window("five_hour", 10)])), "no_weekly")
        XCTAssertEqual(code(usage([])), "no_weekly")
        XCTAssertEqual(code(usage([window("seven_day", 10), window("unknown", 10)])), "unknown_window")
        XCTAssertEqual(code(usage([window("seven_day", 10), window("seven_day", 10)])), "invalid")
        XCTAssertEqual(code(usage([window("seven_day", 10, reset: .some(nil))])), "invalid")
        XCTAssertEqual(code(usage([window("five_hour", 10, reset: .some(nil)), window("seven_day", 10)])), "invalid",
                       "a reported 5-hour window without a reset is never dropped")
        XCTAssertEqual(code(usage([window("five_hour", 10), window("seven_day", 10)], age: 121)), "stale")
        XCTAssertEqual(code(usage([window("five_hour", 10), window("seven_day", 10)], age: -1)), "stale")
        XCTAssertEqual(code(usage([window("five_hour", 10), window("seven_day", 95)]), ceiling: 95), "ceiling")
        XCTAssertEqual(code(usage([window("five_hour", 95), window("seven_day", 10)]), ceiling: 95), "ceiling")
        XCTAssertNil(code(usage([window("five_hour", 10), window("seven_day", 94)]), ceiling: 95))
        XCTAssertEqual(code(usage([window("seven_day", 10)])), "no_five_hour")
        // Audit events stay within the journal's 128-byte event bound.
        for suffix in ["none", "status", "invalid", "unknown_window", "no_weekly", "no_five_hour", "stale", "ceiling"] {
            XCTAssertLessThanOrEqual(("deferred_target_" + suffix).utf8.count, 128)
        }
    }

    // MARK: - Registry only (F2)

    @MainActor func testFailoverAccountsComeOnlyFromTheHostRegistry() throws {
        let directory = RelayAgentAccountDirectory()
        // Before the host's list is read, the display path still falls back to
        // the defaults, but the failover path has no accounts at all.
        XCTAssertFalse(directory.accounts(for: .local, provider: "claude").isEmpty)
        XCTAssertNil(directory.registeredAccounts(for: .local, provider: "claude"))
        let json = #"""
        [{"provider":"claude","label":"business","dir":"~/.claude-team","root":"/fixture/.claude-team","default":false,"exists":true,"logged_in":"yes"},
         {"provider":"claude","label":"personal","dir":"","root":"/fixture/.claude","default":true,"exists":true,"logged_in":"yes"},
         {"provider":"codex","label":"personal","dir":"~/.codex-personal","root":"/fixture/.codex-personal","default":false,"exists":true,"logged_in":"yes"}]
        """#
        let statuses = try JSONDecoder().decode([RelayAgentAccountStatus].self, from: Data(json.utf8))
        directory.record(statuses, executables: nil, fromHost: "local", probeRequested: false)
        let registry = try XCTUnwrap(directory.registeredAccounts(for: .local, provider: "claude"))
        XCTAssertEqual(registry.map(\.label), ["business", "personal"])
        XCTAssertEqual(registry.first { $0.label == "personal" }?.dir, "", "the host's personal, not the default ~/.claude-personal")
        XCTAssertNil(registry.first { $0.label == "work" }, "a default-only label is never resolved")
    }
}
