import Foundation
import XCTest
@testable import Relay

final class RelayClaudeQuotaFailoverTests: XCTestCase {
    typealias Engine = RelayClaudeQuotaEngine
    let now = Date(timeIntervalSince1970: 1000)
    let reset = Date(timeIntervalSince1970: 1100)
    let id = UUID(uuidString: "a561ece8-0000-4000-8000-000000000001")!
    func pane(_ n: Int = 0, label: String = "business", idle: Bool = true) -> Engine.Pane {
        .init(id: UUID(uuidString: String(format: "a561ece8-0000-4000-8000-%012d", n + 1))!,
            host: "dandy-07", label: label, session: "same-session", process: "2311512:99", idle: idle)
    }
    func quota(_ used: Double = 90, reset end: Date? = nil, observed: Date? = nil) -> Engine.Quota {
        .init(used: used, reset: end ?? reset, observed: observed ?? now,
            weekly: ["seven_day": .init(used: 10, reset: end ?? reset, observed: observed ?? now)])
    }
    func next(_ e: inout Engine, panes: [Engine.Pane]? = nil, source: Engine.Quota? = nil,
              target: Engine.Quota? = nil, paused: Bool = false, at: Date? = nil) throws -> Engine.Move? {
        try e.next(settings: .init(), host: "dandy-07", source: source ?? quota(), target: target ?? quota(20),
            panes: panes ?? [pane()], paused: paused, now: at ?? now, sourceDir: "~/.claude-team", targetDir: "~/.claude-max",
            save: { _ in }, audit: { _, _ in })
    }
    func finish(_ e: inout Engine, _ move: Engine.Move) throws {
        try e.finish(move, success: true, process: "2311512:99", detail: "same conversation", save: { _ in }, audit: { _, _ in })
    }
    func away() throws -> Engine {
        var e = Engine(); let move = try XCTUnwrap(next(&e)); try finish(&e, move); return e
    }

    func testSerialThresholdAndDeferral() throws {
        var e = Engine()
        XCTAssertNil(try next(&e, source: quota(89)))
        XCTAssertNil(try next(&e, panes: [pane(idle: false)]))
        XCTAssertNil(try next(&e, target: quota(95)))
        XCTAssertNil(try next(&e, paused: true))
        let move = try XCTUnwrap(next(&e, panes: [pane(), pane(1)]))
        XCTAssertEqual(move.pane.id, id)
        XCTAssertNil(try next(&e, panes: [pane(1)]))
        try finish(&e, move)
        XCTAssertEqual(try next(&e, panes: [pane(1)])?.pane.id, pane(1).id)
    }

    func testReturnRequiresResetAndFreshLowerUsage() throws {
        var e = try away()
        XCTAssertNil(try next(&e, panes: [pane(label: "personal")], source: quota(10)))
        let fraction = Date(timeIntervalSince1970: 1100.5)
        XCTAssertNil(try next(&e, panes: [pane(label: "personal")],
            source: quota(10, reset: Date(timeIntervalSince1970: 1200), observed: fraction), at: fraction))
        let after = Date(timeIntervalSince1970: 1101)
        var source = quota(90, reset: Date(timeIntervalSince1970: 1200), observed: after)
        XCTAssertNil(try next(&e, panes: [pane(label: "personal")], source: source, at: after))
        source.used = 10; source.observed = now
        XCTAssertNil(try next(&e, panes: [pane(label: "personal")], source: source, at: after))
        source.observed = after
        let move = try XCTUnwrap(next(&e, panes: [pane(label: "personal")], source: source, at: after))
        XCTAssertTrue(move.returning)
        try finish(&e, move)
        // The completed old failover cannot be repeated in that old window.
        XCTAssertNil(try next(&e, source: quota(99)))
    }

    func testStalePastResetAndFutureObservationsNeverMove() throws {
        for q in [quota(99, reset: reset, observed: now.addingTimeInterval(-121)),
                  quota(99, reset: now, observed: now), quota(99, reset: reset, observed: reset)] {
            var e = Engine(); XCTAssertNil(try next(&e, source: q))
        }
    }

    func testUserMoveWinsEveryInterleavingAndRestart() throws {
        for order in 0..<3 {
            var e = Engine()
            if order == 0 { try e.userMoved(pane(), source: "business", target: "personal", save: { _ in }) }
            let move = try next(&e)
            if order == 1 { try e.userMoved(pane(), source: "business", target: "personal", save: { _ in }) }
            if let move { try finish(&e, move) }
            if order == 2 { try e.userMoved(pane(), source: "business", target: "personal", save: { _ in }) }
            e = Engine(disk: try Engine.Disk.decode(JSONEncoder().encode(e.disk)))
            let after = Date(timeIntervalSince1970: 1101)
            XCTAssertNil(try next(&e, panes: [pane(label: "personal")],
                source: quota(10, reset: Date(timeIntervalSince1970: 1200), observed: after), at: after))
            XCTAssertEqual(e.disk.records.first?.state, .user)
        }
    }

    func testWriteAheadAndAuditFailuresFailClosed() throws {
        enum Failure: Error { case disk }
        var e = Engine()
        var audit = 0
        XCTAssertThrowsError(try e.next(settings: .init(), host: "dandy-07", source: quota(), target: quota(20),
            panes: [pane()], paused: false, now: now, sourceDir: "", targetDir: "~/.claude-max",
            save: { _ in throw Failure.disk }, audit: { _, _ in audit += 1 }))
        XCTAssertEqual(audit, 1); XCTAssertNil(e.inFlight); XCTAssertTrue(e.disk.records.isEmpty)
        XCTAssertThrowsError(try e.next(settings: .init(), host: "dandy-07", source: quota(), target: quota(20),
            panes: [pane()], paused: false, now: now, sourceDir: "", targetDir: "~/.claude-max",
            save: { _ in XCTFail("audit must precede save") }, audit: { _, _ in throw Failure.disk }))
        XCTAssertNil(e.inFlight)
        var budgetEvents: [String] = []
        XCTAssertNil(try e.next(settings: .init(), host: "dandy-07", source: quota(), target: quota(20),
            panes: [pane()], paused: false, now: now, sourceDir: "", targetDir: "~/.claude-max",
            save: { _ in XCTFail("budget must precede save") }, audit: { _, event in budgetEvents.append(event) }, admit: { _ in false }))
        XCTAssertEqual(budgetEvents, ["deferred_budget"])
    }

    func testJournalSurvivesRestartAndPendingIntentIsNotReplayed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("quota.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = RelayClaudeQuotaJournal(url: url)
        var e = try away()
        try journal.save(e.disk)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertNotEqual(attributes[.protectionKey] as? FileProtectionType, .completeUnlessOpen,
            "background journal must remain reopenable after its atomic write")
        let otherWriter = RelayClaudeQuotaJournal(url: url)
        XCTAssertThrowsError(try otherWriter.load(), "one journal writer across app processes")
        e = Engine(disk: try journal.load())
        XCTAssertEqual(e.disk.records.count, 1) // QF10
        let after = Date(timeIntervalSince1970: 1101)
        XCTAssertNotNil(try next(&e, panes: [pane(label: "personal")],
            source: quota(10, reset: Date(timeIntervalSince1970: 1200), observed: after), at: after))
        try journal.save(e.disk)
        e = Engine(disk: try journal.load())
        XCTAssertNil(try next(&e, panes: [pane(label: "personal")],
            source: quota(10, reset: Date(timeIntervalSince1970: 1200), observed: after), at: after))
        try Data("corrupt".utf8).write(to: url)
        XCTAssertThrowsError(try journal.load())
    }

    func testSettingsAreNotRemoteWritable() {
        XCTAssertThrowsError(try RelaySettingsPolicy.validate(["claude_quota_failover": .bool(false)]))
        XCTAssertTrue(RelayClaudeQuotaSettings().enabled)
        XCTAssertEqual(RelayClaudeQuotaSettings().threshold, 90)
        XCTAssertEqual(RelayClaudeQuotaSettings().targetCeiling, 95)
        XCTAssertFalse(RelayAgentAccountMovePolicy.preparesTarget(.quotaFailover))
        XCTAssertTrue(RelayAgentAccountMovePolicy.preparesTarget(.user))
    }
}

extension RelayClaudeQuotaFailoverTests {
    func testInvalidSettingsCannotResurrectEnabledStateAfterRestart() throws {
        for enabled in [false, true] {
            var editing = RelayClaudeQuotaSettings()
            editing.enabled = enabled
            editing.source = "" // partially edited native label
            let restarted = RelayClaudeQuotaSettings.restored(try JSONEncoder().encode(editing))
            XCTAssertFalse(restarted.enabled)
            var e = Engine()
            XCTAssertNil(try e.next(settings: restarted, host: "dandy-07", source: quota(), target: quota(20),
                panes: [pane()], paused: false, now: now, sourceDir: "~/.claude-team", targetDir: "~/.claude-max",
                save: { _ in }, audit: { _, _ in }))
        }
        XCTAssertFalse(RelayClaudeQuotaSettings.restored(Data("invalid".utf8)).enabled)
        XCTAssertTrue(RelayClaudeQuotaSettings.restored(nil).enabled)
    }
    func testAllGlobalAndHostEnableCombinations() throws {
        for enabled in [false, true] {
            for hostEnabled in [false, true] {
                var settings = RelayClaudeQuotaSettings()
                settings.enabled = enabled
                settings.hosts["dandy-07"] = hostEnabled
                var e = Engine()
                let move = try e.next(settings: settings, host: "dandy-07", source: quota(), target: quota(20),
                    panes: [pane()], paused: false, now: now, sourceDir: "~/.claude-team", targetDir: "~/.claude-max",
                    save: { _ in }, audit: { _, _ in })
                XCTAssertEqual(move != nil, enabled && hostEnabled, "user host/global opt-outs must stop moves")
            }
        }
    }
    func testQuotaPollCadenceIsSeparateFromMovesAndNeverOverlaps() {
        var polls = RelayClaudeQuotaPollSchedule()
        XCTAssertTrue(polls.begin(host: "dandy-07", now: now))
        XCTAssertFalse(polls.begin(host: "dandy-07", now: now.addingTimeInterval(120)))
        XCTAssertTrue(polls.begin(host: "local", now: now))
        polls.finish(host: "dandy-07")
        XCTAssertFalse(polls.begin(host: "dandy-07", now: now.addingTimeInterval(59)))
        XCTAssertTrue(polls.begin(host: "dandy-07", now: now.addingTimeInterval(60)))
    }
    func testBusyRaceDefersButPermanentRefusalDoesNotRetry() throws {
        var e = Engine()
        let move = try XCTUnwrap(next(&e))
        try e.finish(move, success: false, process: move.pane.process, detail: "turn began before the first exit attempt",
            deferred: true, save: { _ in }, audit: { _, _ in })
        XCTAssertEqual(e.disk.records.first?.state, .queued)
        e = Engine(disk: e.disk)
        XCTAssertNil(try next(&e, panes: [pane(idle: false)]))
        let retry = try XCTUnwrap(next(&e))
        try e.finish(retry, success: false, process: retry.pane.process, detail: "shared history unavailable",
            save: { _ in }, audit: { _, _ in })
        XCTAssertEqual(e.disk.records.first?.state, .refused)
        XCTAssertNil(try next(&e))
    }
}
