import Foundation
import Testing
@testable import Relay

struct RelayMikoShepherdPushTests {
    @Test func pushRefusesLegacyHelperProtocol() {
        #expect(RelayHostExecution.communicationVerb(["shepherd_report": true]) == "communication-shepherd", "SH44 old helpers must refuse before sending an unpinned report")
        #expect(RelayHostExecution.communicationVerb(["operation": "assistant_send"]) == "communication")
    }
    @Test func pushRecurringPromptOccurrenceAndRestart() throws { try RelayShepherdPushChecks.recurrence() }
    @Test func pushDecisionSmoke() throws { try RelayShepherdPushChecks.smoke() }
    @Test func pushOriginAuthorization() throws {
        let count = try RelayShepherdPushChecks.authorization()
        #expect(count == 42)
        print("SH2 authorization origins=6 target/cap mutations=7 cases=\(count)")
        for key in ["shepherd_report_target", "shepherd_messages_per_hour", "shepherd_push", "report_target", "shepherd_target"] {
            do { try RelaySettingsPolicy.validate([key: .string("anything")]); Issue.record("SH31 MCP changed a user-only push setting: \(key)") }
            catch { }
        }
    }
    @Test func pushBoundedSequences() throws {
        let count = try RelayShepherdPushChecks.bounded()
        #expect(count == 562_176)
        print("SH2 bounded depth=3 operations=16 initial_combinations=128 two_actor_schedules=6 visits=\(count)")
    }
    @Test func pushSeededWireFuzz() throws { try RelayShepherdPushChecks.fuzz() }
}

@MainActor private final class ShepherdFakePushTransport: RelayShepherdPushTransport {
    var packets: [RelayShepherdPushEnvelope] = []
    var stale = false
    var status = "accepted_by_provider"
    var fail = false
    var onRevalidate: (@MainActor () async throws -> Void)?
    var beforeSend: (@MainActor (RelayShepherdPushEnvelope) throws -> Void)?
    func revalidate(_ target: RelayShepherdPushTarget) async throws -> Bool {
        try await onRevalidate?(); return !stale
    }
    func send(_ envelope: RelayShepherdPushEnvelope, allowed: @escaping @MainActor () -> Bool) async throws -> Data {
        await Task.yield()
        guard allowed() else { throw RelayShepherdPushFailure.stale }
        try beforeSend?(envelope)
        packets.append(envelope)
        if fail { throw RelayShepherdChecks.Failure(description: "fake transport disconnected after admission") }
        return try RelayShepherdPushChecks.receipt(envelope, status: status)
    }
}

extension RelayMikoShepherdPushTests {
    @Test @MainActor func pushDurableReservationAndNoReplay() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SH2-reserve-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ledger.json")
        let fake = ShepherdFakePushTransport(); fake.fail = true
        let controller = RelayShepherdPushController(url: url, monitoring: { RelayShepherdChecks.settings }, paused: { false }, transport: fake)
        try controller.configure(RelayShepherdPushChecks.settings(), origin: .userSettings)
        fake.beforeSend = { envelope in
            let disk = try RelayShepherdPushLedger.decode(Data(contentsOf: url))
            #expect(disk.entries.contains { $0.messageID == envelope.messageID && $0.attempted }, "SH42 reserve UUID/cap before transport")
            #expect(disk.entries.filter(\.attempted).count == 1, "SH42 cap reservation durable")
        }
        controller.observe(RelayShepherdPushChecks.report(), now: Date(timeIntervalSince1970: 10))
        await controller.drain()
        #expect(fake.packets.count == 1)
        let uuid = try #require(fake.packets.first?.messageID)
        #expect(controller.ledger.blockedRegistration != nil, "SH32 failure stops registration")
        controller.observe(RelayShepherdPushChecks.report("later"), now: Date(timeIntervalSince1970: 11))
        await controller.drain()
        #expect(fake.packets.count == 1, "SH32 no retry storm on new source changes")
        let nextFake = ShepherdFakePushTransport()
        let restarted = RelayShepherdPushController(url: url, monitoring: { RelayShepherdChecks.settings }, paused: { false }, transport: nextFake)
        restarted.observe(RelayShepherdPushChecks.report(), now: Date(timeIntervalSince1970: 12))
        restarted.observe(RelayShepherdPushChecks.report("different"), now: Date(timeIntervalSince1970: 13))
        await restarted.drain()
        #expect(nextFake.packets.isEmpty, "SH33 restart never resumes an uncertain registration")
        #expect(restarted.ledger.entries.contains { $0.messageID == uuid }, "SH33 original uncertain UUID retained")
    }

    @Test @MainActor func pushTargetChangesAndPauseDuringWait() async throws {
        for change in 0..<3 {
            var monitoring = RelayShepherdChecks.settings; var paused = false
            let fake = ShepherdFakePushTransport()
            let controller = RelayShepherdPushController(url: nil, monitoring: { monitoring }, paused: { paused }, transport: fake)
            try controller.configure(RelayShepherdPushChecks.settings(), origin: .userSettings)
            fake.onRevalidate = {
                await Task.yield()
                if change == 0 { try controller.configure(RelayShepherdPushChecks.settings(RelayShepherdPushChecks.target(1)), origin: .userSettings) }
                if change == 1 { paused = true }
                if change == 2 { monitoring.excludedPanes.insert(RelayShepherdPushChecks.source) }
            }
            controller.observe(RelayShepherdPushChecks.report(), now: Date(timeIntervalSince1970: 0))
            await controller.drain()
            #expect(fake.packets.isEmpty, "SH30 target/pause/opt-out rechecked after asynchronous wait")
            #expect(controller.ledger.entries.count == 1)
            #expect(controller.ledger.entries[0].completed)
        }
    }

    @Test @MainActor func pushStaleTargetHasNoFallback() async throws {
        let fake = ShepherdFakePushTransport(); fake.stale = true
        let controller = RelayShepherdPushController(url: nil, monitoring: { RelayShepherdChecks.settings }, paused: { false }, transport: fake)
        try controller.configure(RelayShepherdPushChecks.settings(), origin: .userSettings)
        controller.observe(RelayShepherdPushChecks.report(), now: Date(timeIntervalSince1970: 0))
        await controller.drain()
        #expect(fake.packets.isEmpty, "SH37 stale target has no alternate pane")
        controller.observe(RelayShepherdPushChecks.report("new"), now: Date(timeIntervalSince1970: 1))
        await controller.drain()
        #expect(fake.packets.isEmpty, "SH37 stale registration remains stopped")
        #expect(controller.ledger.entries.filter { $0.attempted && $0.completed }.count == 1, "SH32 failure recorded once")
    }

    @Test @MainActor func pushCapAndUIAcrossRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SH2-cap-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ledger.json")
        let fake = ShepherdFakePushTransport()
        let controller = RelayShepherdPushController(url: url, monitoring: { RelayShepherdChecks.settings }, paused: { false }, transport: fake)
        try controller.configure(RelayShepherdPushChecks.settings(cap: 1), origin: .userSettings)
        controller.observe(RelayShepherdPushChecks.report(), now: Date(timeIntervalSince1970: 10)); await controller.drain()
        for i in 1...3 { controller.observe(RelayShepherdPushChecks.report("event\(i)"), now: Date(timeIntervalSince1970: 10 + Double(i))) }
        await controller.drain()
        #expect(fake.packets.count == 1, "SH35 per-hour cap holds")
        #expect(controller.ledger.capNoticeHours == [0], "SH39 only one cap notice in an hour")
        #expect(controller.ledger.uiReports == 4, "SH40 UI reports continue at cap")
        let next = ShepherdFakePushTransport()
        let restarted = RelayShepherdPushController(url: url, monitoring: { RelayShepherdChecks.settings }, paused: { false }, transport: next)
        restarted.observe(RelayShepherdPushChecks.report("afterRestart"), now: Date(timeIntervalSince1970: 100))
        await restarted.drain()
        #expect(next.packets.isEmpty, "SH35 cap ledger survives restart")
        #expect(restarted.ledger.uiReports == 5)
        restarted.observe(RelayShepherdPushChecks.report("newHour"), now: Date(timeIntervalSince1970: 3611))
        await restarted.drain()
        #expect(next.packets.count == 1, "new hour permits a new change")
    }

    @Test @MainActor func pushWriteFailureAndCorruptLedgerFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SH2-disk-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("store"); let file = folder.appendingPathComponent("ledger.json")
        let fake = ShepherdFakePushTransport()
        let controller = RelayShepherdPushController(url: file, monitoring: { RelayShepherdChecks.settings }, paused: { false }, transport: fake)
        try controller.configure(RelayShepherdPushChecks.settings(), origin: .userSettings)
        try FileManager.default.removeItem(at: folder); try Data("not a directory".utf8).write(to: folder)
        controller.observe(RelayShepherdPushChecks.report(), now: Date(timeIntervalSince1970: 0)); await controller.drain()
        #expect(fake.packets.isEmpty, "SH42 no send when durable reservation fails")
        #expect(controller.storageError != nil)
        try FileManager.default.removeItem(at: folder); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: file)
        let corrupt = RelayShepherdPushController(url: file, monitoring: { RelayShepherdChecks.settings }, paused: { false }, transport: fake)
        corrupt.observe(RelayShepherdPushChecks.report("another"), now: Date(timeIntervalSince1970: 2)); await corrupt.drain()
        #expect(fake.packets.isEmpty && corrupt.storageError != nil, "SH42 corrupted ledger cannot reset uncertainty")
    }

    @Test @MainActor func pushControllerAuthorizationAndActualHeartbeat() async throws {
        let fake = ShepherdFakePushTransport()
        var settings = RelayShepherdChecks.settings
        let controller = RelayShepherdPushController(url: nil, monitoring: { settings }, paused: { false }, transport: fake)
        for origin in RelayShepherdPushLedger.Origin.allCases where origin != .userSettings {
            do { try controller.configure(RelayShepherdPushChecks.settings(), origin: origin); Issue.record("SH31 untrusted target origin") } catch {}
        }
        #expect(controller.ledger.settings.target == nil)
        try controller.configure(RelayShepherdPushChecks.settings(), origin: .userSettings)
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        let pane = try #require(workspace.activePane)
        pane.receivedAgentEvent(Data(#"{"agent":"claude","event":{"hook_event_name":"UserPromptSubmit"}}"#.utf8))
        let monitor = RelayMikoShepherdCoordinator(testingHeartbeat: true, settings: { settings }, paused: { false }, push: controller)
        monitor.heartbeat(workspace, now: Date(timeIntervalSince1970: 0)); await controller.drain()
        #expect(fake.packets.count == 1)
        monitor.heartbeat(workspace, now: Date(timeIntervalSince1970: 31)); await controller.drain()
        #expect(fake.packets.count == 1, "SH34 actual unchanged heartbeat never pushes")
        #expect(monitor.reports.count == 1, "SH40 UI report remains independent of delivery")
        settings.excludedPanes.insert(pane.id)
        monitor.heartbeat(workspace, now: Date(timeIntervalSince1970: 62)); await controller.drain()
        #expect(fake.packets.count == 1)
    }
}
