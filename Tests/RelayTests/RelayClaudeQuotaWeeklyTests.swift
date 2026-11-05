import Foundation
import XCTest
@testable import Relay

final class RelayClaudeQuotaWeeklyTests: XCTestCase {
    typealias E = RelayClaudeQuotaEngine
    let f = RelayClaudeQuotaFailoverTests()
    func quota(_ five: Double = 10, _ weekly: Double = 90, at: Double = 1000,
               fiveReset: Double = 1100, weeklyReset: Double = 1300) -> E.Quota {
        .init(used: five, reset: Date(timeIntervalSince1970: fiveReset), observed: Date(timeIntervalSince1970: at),
            weekly: ["seven_day": .init(used: weekly, reset: Date(timeIntervalSince1970: weeklyReset), observed: Date(timeIntervalSince1970: at))])
    }
    func next(_ engine: inout E, source: E.Quota, target: E.Quota? = nil, at: Double = 1000,
              returning: Bool = false, settings: RelayClaudeQuotaSettings = .init()) throws -> E.Move? {
        try engine.next(settings: settings, host: "dandy-07", source: source, target: target ?? quota(20, 20),
            panes: [f.pane(label: returning ? "personal" : "business")], paused: false,
            now: Date(timeIntervalSince1970: at), sourceDir: "~/.claude-team", targetDir: "~/.claude-max",
            save: { _ in }, audit: { _, _ in })
    }
    func testWeeklyAloneTriggersAtThresholdAndHasIndependentSetting() throws {
        for name in E.weeklyNames.sorted() {
            for used in [89.0, 90, 91] {
                var engine = E(), source = quota(10, used)
                source.weekly = [name: source.weekly["seven_day"]!]
                let move = try next(&engine, source: source)
                XCTAssertEqual(move != nil, used >= 90)
                if move != nil { XCTAssertEqual(engine.disk.records[0].triggerResets, [name: Date(timeIntervalSince1970: 1300)]) }
            }
        }
        var settings = RelayClaudeQuotaSettings(), engine = E()
        settings.weeklyThreshold = 91
        XCTAssertNil(try next(&engine, source: quota(10, 90), settings: settings))
        XCTAssertNotNil(try next(&engine, source: quota(90, 90), settings: settings), "5-hour threshold remains independent")
    }
    func testReturnWaitsForEveryTriggerAndAllSourceWindowsBelow() throws {
        var engine = E()
        let move = try XCTUnwrap(next(&engine, source: quota(90, 98)))
        XCTAssertEqual(Set(engine.disk.records[0].triggerResets.keys), ["five_hour", "seven_day"])
        try f.finish(&engine, move)
        engine = E(disk: try E.Disk.decode(JSONEncoder().encode(engine.disk)))
        // 5h has reset, and both fresh usages are low, but weekly has not reset.
        XCTAssertNil(try next(&engine, source: quota(10, 10, at: 1101, fiveReset: 1500), at: 1101, returning: true))
        // Exact and fractional weekly-reset boundaries remain fenced.
        for time in [1300.0, 1300.5] {
            XCTAssertNil(try next(&engine, source: quota(10, 10, at: time, fiveReset: 1500, weeklyReset: 2300), at: time, returning: true))
        }
        // Every source window, including a window that did not trigger, must be below its own threshold.
        for pair in [(90.0, 10.0), (10.0, 90.0)] {
            XCTAssertNil(try next(&engine, source: quota(pair.0, pair.1, at: 1301, fiveReset: 1500, weeklyReset: 2300), at: 1301, returning: true))
        }
        var missing = quota(10, 10, at: 1301, fiveReset: 1500, weeklyReset: 2300)
        missing.weekly = ["seven_day_opus": missing.weekly["seven_day"]!]
        XCTAssertNil(try next(&engine, source: missing, at: 1301, returning: true), "a missing triggering window cannot authorize return")
        let back = try XCTUnwrap(next(&engine, source: quota(10, 10, at: 1301, fiveReset: 1500, weeklyReset: 2300), at: 1301, returning: true))
        XCTAssertTrue(back.returning)
        try f.finish(&engine, back)
        XCTAssertNil(try next(&engine, source: quota(90, 98)), "recorded window fences survive completion")
    }
    func testWeeklyOnlyReturnDoesNotWaitForUntriggeredFiveHourReset() throws {
        var engine = E()
        let move = try XCTUnwrap(next(&engine, source: quota(10, 98, fiveReset: 1500, weeklyReset: 1100)))
        try f.finish(&engine, move)
        XCTAssertNotNil(try next(&engine, source: quota(10, 10, at: 1101, fiveReset: 1500, weeklyReset: 2300), at: 1101, returning: true))
    }
    func testWeeklyStaleFutureExpiredInvalidOrMissingNeverMoves() throws {
        for mode in 0..<7 {
            var source = quota(10, 98), engine = E()
            switch mode {
            case 0: source.weekly["seven_day"]!.observed = Date(timeIntervalSince1970: 879)
            case 1: source.weekly["seven_day"]!.observed = Date(timeIntervalSince1970: 1001)
            case 2: source.weekly["seven_day"]!.reset = f.now
            case 3: source.weekly["seven_day"]!.used = 101
            case 4: source.weekly["seven_day"]!.used = .nan
            case 5: source.weekly = [:]
            default: source.weekly = ["unknown": source.weekly["seven_day"]!]
            }
            XCTAssertNil(try next(&engine, source: source))
        }
    }
    func testBothTargetCeilingsAndWeeklyFreshnessAreRequired() throws {
        for pair in [(94.0, 94.0), (95.0, 94.0), (94.0, 95.0)] {
            var engine = E()
            XCTAssertEqual(try next(&engine, source: quota(), target: quota(pair.0, pair.1)) != nil, pair.0 < 95 && pair.1 < 95)
        }
        var target = quota(20, 20), engine = E()
        target.weekly["seven_day"]!.observed = Date(timeIntervalSince1970: 879)
        XCTAssertNil(try next(&engine, source: quota(), target: target))
    }
    func testSettingsAndJournalWeeklyStrictnessAndLegacyMigration() throws {
        XCTAssertEqual(RelayClaudeQuotaSettings().weeklyThreshold, 90)
        for invalid in [0.0, -1, 101, .infinity, .nan] {
            var settings = RelayClaudeQuotaSettings(); settings.weeklyThreshold = invalid
            XCTAssertFalse(settings.valid)
        }
        var engine = E()
        _ = try XCTUnwrap(next(&engine, source: quota(90, 98)))
        let data = try JSONEncoder().encode(engine.disk)
        XCTAssertEqual(try E.Disk.decode(data), engine.disk)
        var top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(top["records"] as? [[String: Any]])
        rows[0]["triggerResets"] = ["unknown": 100.0]; top["records"] = rows
        XCTAssertThrowsError(try E.Disk.decode(JSONSerialization.data(withJSONObject: top)))
        rows[0].removeValue(forKey: "triggerResets"); top["records"] = rows; top["version"] = 1
        let legacy = try E.Disk.decode(JSONSerialization.data(withJSONObject: top))
        XCTAssertEqual(legacy.version, 2)
        XCTAssertEqual(legacy.records[0].triggerResets, ["five_hour": legacy.records[0].reset])
        var invalidVersion = top
        invalidVersion["version"] = true
        XCTAssertThrowsError(try E.Disk.decode(JSONSerialization.data(withJSONObject: invalidVersion)))
        rows[0]["unknown"] = true; top["records"] = rows
        XCTAssertThrowsError(try E.Disk.decode(JSONSerialization.data(withJSONObject: top)))
    }
    @MainActor func testNormalizedWeeklyWindowsAndSettingsUsageText() throws {
        let formatter = ISO8601DateFormatter()
        let now = Date(timeIntervalSince1970: 1792770000)
        let end = formatter.string(from: now.addingTimeInterval(1000))
        func usage(_ windows: [RelayAgentAccountUsage.Window], age: Double = 0) -> RelayAgentAccountUsage {
            .init(provider: "claude", label: "business", status: "ok", reason: nil, source: "fake",
                readAt: formatter.string(from: now.addingTimeInterval(-age)), windows: windows)
        }
        let five = RelayAgentAccountUsage.Window(name: "five_hour", usedPercent: 10, resetsAt: end, windowMinutes: 300)
        for name in E.weeklyNames.sorted() {
            let weekly = RelayAgentAccountUsage.Window(name: name, usedPercent: 98, resetsAt: end, windowMinutes: 10080)
            let value = usage([five, weekly])
            XCTAssertNotNil(RelayClaudeQuotaScheduler.quota(value, now: now))
            XCTAssertNil(RelayClaudeQuotaScheduler.quota(value, now: now, targetCeiling: 95))
            XCTAssertNil(RelayClaudeQuotaScheduler.quota(usage([five, weekly], age: 121), now: now))
            XCTAssertNil(RelayClaudeQuotaScheduler.quota(usage([five, weekly], age: -1), now: now))
            let text = RelayClaudeQuotaScheduler.usageText(value, label: "business", now: now).joined(separator: " ")
            XCTAssertTrue(text.contains("5-hour")); XCTAssertTrue(text.contains("weekly")); XCTAssertTrue(text.contains("98%")); XCTAssertTrue(text.contains("resets"))
            XCTAssertNil(RelayClaudeQuotaScheduler.quota(usage([five, weekly, weekly]), now: now))
        }
        XCTAssertNil(RelayClaudeQuotaScheduler.quota(usage([five]), now: now))
        XCTAssertNil(RelayClaudeQuotaScheduler.quota(usage([five, .init(name: "unknown", usedPercent: 98, resetsAt: end, windowMinutes: 10080)]), now: now))
    }
    func testRandomizedAuditFramingIsBoundedAndRejectsPartialTails() {
        var random = RelayClaudeQuotaRandomizedTests.Random()
        for i in 0..<10_000 {
            let size = Int64(truncatingIfNeeded: random.next())
            let last = UInt8(truncatingIfNeeded: random.next() >> 32)
            XCTAssertEqual(RelayQuotaWire.auditAppendable(size: size, last: last), size >= 0 && size <= 32 << 20 && (size == 0 || last == 10))
            if i % 100 == 0 {
                let lengths: [Int64] = [-1, 0, 1, 32 << 20, (32 << 20) + 1]
                for length in lengths {
                    for byte in UInt8.min...UInt8.max {
                        XCTAssertEqual(RelayQuotaWire.auditAppendable(size: length, last: byte), length >= 0 && length <= 32 << 20 && (length == 0 || byte == 10))
                    }
                }
            }
        }
        XCTAssertFalse(RelayQuotaWire.auditAppendable(size: 1, last: nil))
    }
    func testStandaloneAuditIsAppendOnlyBoundedPrivateAndLocked() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("quota.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = RelayClaudeQuotaJournal(url: url)
        let log = URL(fileURLWithPath: url.path + ".audit.jsonl")
        try journal.appendAudit(f.id, "failover_intent")
        let first = try Data(contentsOf: log)
        try journal.appendAudit(f.id, "move_completed")
        let second = try Data(contentsOf: log)
        XCTAssertTrue(second.starts(with: first)); XCTAssertEqual(second.split(separator: 10).count, 2)
        XCTAssertTrue(String(decoding: second, as: UTF8.self).contains("failover_intent"))
        let attrs = try FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try RelayClaudeQuotaJournal(url: url).appendAudit(f.id, "other_writer"))
        try second.dropLast().write(to: log)
        XCTAssertThrowsError(try journal.appendAudit(f.id, "interrupted_tail"), "an uncertain partial append must not be joined or replayed")
        XCTAssertEqual(try Data(contentsOf: log), second.dropLast(), "partial evidence is preserved")
        try second.write(to: log)
        let handle = try FileHandle(forWritingTo: log); try handle.truncate(atOffset: 32 << 20); try handle.close()
        XCTAssertThrowsError(try journal.appendAudit(f.id, "full_log"), "a full log must stop moves, not discard evidence")
        try FileManager.default.removeItem(at: log)
        let victim = url.deletingLastPathComponent().appendingPathComponent("victim")
        // Keep the incomplete-tail victim and add a complete frame so the
        // symlink oracle cannot be satisfied by the independent framing gate.
        for contents in ["unchanged", "unchanged\n"] {
            try Data(contents.utf8).write(to: victim)
            try FileManager.default.createSymbolicLink(at: log, withDestinationURL: victim)
            XCTAssertThrowsError(try journal.appendAudit(f.id, "symlink"))
            XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), contents)
            try FileManager.default.removeItem(at: log)
        }
    }
}
