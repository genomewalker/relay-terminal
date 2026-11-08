import Foundation
import Testing
@testable import Relay

@MainActor private final class PolicyRecorder {
    var operations: [String] = []
    var incarnation = "transport-a/1"

    func install(_ control: RelayCallerControl) {
        control.policyTransport = { [unowned self] _, packet, _ in
            let operation = packet["operation"] as? String ?? ""
            self.operations.append(operation)
            return operation == "caller_list" ? ["authority": "relayd", "callers": []] : ["authority": "relayd"]
        }
        control.transportIncarnation = { [unowned self] _ in self.incarnation }
    }

    func count(_ operation: String) -> Int { operations.filter { $0 == operation }.count }
}

@MainActor private func callerFixture() -> (RelayCallerControl, PolicyRecorder, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-churn-" + UUID().uuidString)
    let control = RelayCallerControl(directory: directory)
    let recorder = PolicyRecorder()
    recorder.install(control)
    return (control, recorder, directory)
}

private let churnHost = ConnectionProfile(name: "churn", kind: .ssh, host: "dandy-07.invalid", backend: .relay)

@Test @MainActor func attachImportsOncePerTransportIncarnationAndPolicyRevision() async throws {
    let (control, recorder, directory) = callerFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await control.attachDaemon(profile: churnHost)
    #expect(recorder.operations == ["caller_policy_import", "caller_list"])
    for _ in 0..<10 { try await control.attachDaemon(profile: churnHost) }
    #expect(recorder.operations.count == 2)
    // A reconnect is a new incarnation: import and read again, once.
    recorder.incarnation = "transport-a/2"
    try await control.attachDaemon(profile: churnHost)
    try await control.attachDaemon(profile: churnHost)
    #expect(recorder.count("caller_policy_import") == 2 && recorder.count("caller_list") == 2)
    // A local policy change imports again on the next attach.
    let issued = try await control.register(label: "Fixture", thread: nil)
    #expect(recorder.count("caller_register") == 1)
    try await control.attachDaemon(profile: churnHost)
    #expect(recorder.count("caller_policy_import") == 3)
    let id = try #require(issued["caller_id"])
    try await control.setPaused(id: id, paused: true)
    #expect(recorder.count("caller_set_paused") == 1 && !control.permitted(id))
    // Pausing still refreshes every owner immediately, then re-imports once.
    #expect(recorder.count("caller_list") == 4)
    try await control.attachDaemon(profile: churnHost)
    try await control.attachDaemon(profile: churnHost)
    #expect(recorder.count("caller_policy_import") == 4)
}

@Test @MainActor func unknownTransportIncarnationNeverSkipsTheImport() async throws {
    let (control, recorder, directory) = callerFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    control.transportIncarnation = { _ in nil }
    try await control.attachDaemon(profile: churnHost)
    try await control.attachDaemon(profile: churnHost)
    #expect(recorder.count("caller_policy_import") == 2)
}

// The cache names the incarnation the import ran on. A transport created or
// replaced during the import is not cached, so the next attach imports on it.
@Test @MainActor func attachCachesOnlyTheIncarnationThatReceivedTheImport() async throws {
    let (control, recorder, directory) = callerFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    var current: String? = nil
    var imported: [String?] = []
    control.transportIncarnation = { _ in current }
    control.policyTransport = { _, packet, _ in
        let operation = packet["operation"] as? String ?? ""
        recorder.operations.append(operation)
        if operation == "caller_policy_import" {
            imported.append(current)
            // The first import creates the transport, the second reconnects it.
            if current == nil { current = "transport-b/1" } else if current == "transport-b/1" { current = "transport-b/2" }
        }
        return operation == "caller_list" ? ["authority": "relayd", "callers": []] : ["authority": "relayd"]
    }
    try await control.attachDaemon(profile: churnHost)
    try await control.attachDaemon(profile: churnHost)
    try await control.attachDaemon(profile: churnHost)
    #expect(imported == [nil, "transport-b/1", "transport-b/2"])
    for _ in 0..<5 { try await control.attachDaemon(profile: churnHost) }
    #expect(recorder.count("caller_policy_import") == 3)
}

@Test @MainActor func aFailedCallerListReadIsTrackedPerHostAndClearsOnSuccess() async throws {
    let (control, recorder, directory) = callerFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    var fail = true
    control.policyTransport = { _, packet, _ in
        let operation = packet["operation"] as? String ?? ""
        recorder.operations.append(operation)
        if operation == "caller_list" && fail { throw RelayHostRPCError.invalidRequest }
        return operation == "caller_list" ? ["authority": "relayd", "callers": []] : ["authority": "relayd"]
    }
    await #expect(throws: (any Error).self) { try await control.attachDaemon(profile: churnHost) }
    #expect(!control.available)
    fail = false
    try await control.attachDaemon(profile: churnHost)
    #expect(control.available)
}

/// Twelve question-notice pulls after the first attach: no caller import or list.
@Test @MainActor func questionNoticePullsNeverAttachOrRefresh() async throws {
    let (control, recorder, directory) = callerFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let messaging = RelayPaneMessaging()
    messaging.callerControl = control
    var transported: [String] = []
    messaging.communicationTransport = { _, packet in
        transported.append(packet["operation"] as? String ?? "")
        return (["notices": []], Data())
    }
    try await control.attachDaemon(profile: churnHost)
    #expect(recorder.operations == ["caller_policy_import", "caller_list"])
    for _ in 0..<12 {
        _ = try await messaging.pullQuestionNotices(profile: churnHost, paneIDs: [UUID()])
    }
    // A notice send still asks for attach, which the cache satisfies.
    _ = try await messaging.sendQuestionNotice(profile: churnHost, paneID: UUID(), messageID: "m-1")
    #expect(recorder.operations == ["caller_policy_import", "caller_list"])
    #expect(transported.filter { $0 == "question_notices" }.count == 12 && transported.last == "question_notice_send")
}

// MARK: Steady-state rate

@Test func questionNoticePullBacksOffAndWakes() {
    typealias Schedule = RelayQuestionNotices.Schedule
    let panes: Set<UUID> = [UUID()]
    let start = Date(timeIntervalSince1970: 1_000_000)
    var schedule = Schedule()
    #expect(schedule.due(panes: panes, activity: nil, now: start))
    // Bound panes, no notices: 5 s for three pulls, then 30 s.
    schedule.pulled(panes: panes, woken: true, notices: 0, bound: ["p"], at: start)
    #expect(schedule.interval == 5)
    for step in 1...3 { schedule.pulled(panes: panes, woken: false, notices: 0, bound: ["p"], at: start + Double(step * 5)) }
    #expect(schedule.interval == 30)
    #expect(!schedule.due(panes: panes, activity: nil, now: start + 20))
    // A notice returns to 5 s.
    schedule.pulled(panes: panes, woken: false, notices: 1, bound: ["p"], at: start + 50)
    #expect(schedule.interval == 5)
    // No bound pane: a 2 min recheck, unless this app sends, binds, or the panes change.
    schedule.pulled(panes: panes, woken: false, notices: 0, bound: [], at: start + 60)
    #expect(schedule.interval == 120 && !schedule.due(panes: panes, activity: nil, now: start + 100))
    #expect(schedule.due(panes: panes, activity: start + 70, now: start + 75))
    #expect(schedule.due(panes: panes.union([UUID()]), activity: nil, now: start + 75))
    schedule.pulled(panes: panes, woken: true, notices: 0, bound: ["p"], at: start + 75)
    #expect(schedule.interval == 5 && schedule.emptyPulls == 0)
    // A daemon that does not report bound panes is never idle; a failed pull
    // counts as empty, so an unavailable helper also slows to 30 s.
    schedule.pulled(panes: panes, woken: false, notices: 0, bound: nil, at: start + 80)
    #expect(!schedule.noBoundPanes)
    schedule.pulled(panes: panes, woken: false, notices: nil, bound: [], at: start + 85)
    schedule.pulled(panes: panes, woken: false, notices: nil, bound: [], at: start + 90)
    #expect(!schedule.noBoundPanes && schedule.interval == 30)
}

@Test func harnessPollIsFastOnlyForVisibleUnidentifiedOrChangingPanes() {
    let now = Date()
    let delay = { (active: Bool, identified: Set<String>, visible: Set<String>, hints: [String: Date], retry: Double) in
        RelayHostAgentMonitor.harnessDelay(active: active, panes: ["a", "b"], identified: identified, visible: visible,
                                           hints: hints, now: now, retryDelay: retry)
    }
    #expect(delay(true, ["a", "b"], ["a"], [:], 0) == 20)
    #expect(delay(true, ["a"], ["b"], [:], 0) == 3)
    #expect(delay(true, ["a"], ["c"], [:], 0) == 20)
    #expect(delay(true, ["a", "b"], [], ["b": now + 10], 0) == 3)
    #expect(delay(true, ["a", "b"], [], ["b": now - 1], 0) == 20)
    #expect(delay(false, [], ["a", "b"], ["a": now + 10], 0) == 20)
    // Failure backoff still applies on top.
    #expect(delay(true, [], ["a"], [:], 48) == 48)
}

/// Ten minutes on one host with four agent panes, every thread bound but
/// quiet, the app idle and attached: question pulls, harness polls and
/// maintenance probes together stay under 15 durable host jobs a minute.
@Test func steadyStateHostJobRateStaysUnderFifteenPerMinute() {
    let minutes = 10.0, panes = 4.0
    var schedule = RelayQuestionNotices.Schedule()
    let paneIDs: Set<UUID> = Set((0..<4).map { _ in UUID() })
    let start = Date(timeIntervalSince1970: 2_000_000)
    var pulls = 0
    var clock = 0.0
    while clock < minutes * 60 {
        let now = start + clock
        if schedule.due(panes: paneIDs, activity: nil, now: now) {
            let woken = schedule.woken(panes: paneIDs, activity: nil)
            schedule.pulled(panes: paneIDs, woken: woken, notices: 0, bound: ["bound"], at: now)
            pulls += 1
        }
        clock += 5
    }
    let harnessDelay = RelayHostAgentMonitor.harnessDelay(active: true, panes: ["a", "b", "c", "d"],
        identified: ["a", "b", "c", "d"], visible: ["a", "b"], hints: [:], now: start, retryDelay: 0)
    let harness = minutes * 60 / harnessDelay
    let maintenance = panes * minutes * 60 / 120
    let attaches = 0.0 // cached for the transport incarnation and policy revision
    let perMinute = (Double(pulls) + harness + maintenance + attaches) / minutes
    #expect(perMinute < 15, "\(pulls) pulls, \(harness) harness, \(maintenance) maintenance")
    // The unbound case is lower still: a 2 min recheck.
    var idle = RelayQuestionNotices.Schedule()
    idle.pulled(panes: paneIDs, woken: true, notices: 0, bound: [], at: start)
    #expect(idle.interval == 120)
}
