import Foundation
import Testing
@testable import Relay

@Suite("OSC program status replay-safe attention")
struct RelayProgramStatusAttentionTests {
    private func record(_ state: String, id: String? = nil, kind: String? = nil,
                        message: String? = nil, progress: Int? = nil) -> RelayProgramStatusRecord {
        RelayProgramStatusRecord(id: id, state: state, kind: kind, app: "pretend-provider",
            title: "Fixture", message: message, progress: progress, revision: nil)
    }
    @Test func replayAndTextProgressChurnDoNotNotify() {
        var policy = RelayProgramStatusAttention()
        let epoch = UUID(), blocked = record("blocked", kind: "permission", message: "First")
        let replay = policy.consume(previous: [], current: [blocked], revision: 1,
            deliveryEpoch: epoch, replay: true, now: 0)
        #expect(replay.isEmpty)
        let changedText = record("blocked", kind: "permission", message: "Changed", progress: 50)
        let churn = policy.consume(previous: [blocked], current: [changedText], revision: 2,
            deliveryEpoch: epoch, replay: false, now: 10)
        #expect(churn.isEmpty)
        let done = policy.consume(previous: [changedText], current: [record("done")], revision: 3,
            deliveryEpoch: epoch, replay: false, now: 10)
        #expect(done.count == 1)
        #expect(done.first?.record.state == "done")
    }
    // The rate limit survives a reconnect. A transition inside the window is
    // no longer dropped: it is held as the pane's latest state and lands once
    // the window allows (rate limiting reduces alerts, never the record).
    @Test func rateLimitSurvivesReconnectAndCoalescesInsteadOfDropping() {
        var policy = RelayProgramStatusAttention()
        let epoch = UUID(), other = UUID(), blocked = record("blocked"), done = record("done")
        let initial = policy.consume(previous: [], current: [blocked], revision: 1,
            deliveryEpoch: epoch, replay: false, now: 1)
        #expect(initial.count == 1)
        let limited = policy.consume(previous: [blocked], current: [done], revision: 1,
            deliveryEpoch: other, replay: false, now: 2)
        #expect(limited.isEmpty)
        let coalesced = policy.consume(previous: [done], current: [done], revision: 2,
            deliveryEpoch: other, replay: false, now: 7)
        #expect(coalesced.map(\.record.state) == ["done"])
        // Delivered once: nothing is left to replay.
        #expect(policy.flush(now: 20, current: [done]).isEmpty)
        let newState = policy.consume(previous: [done], current: [blocked], revision: 3,
            deliveryEpoch: other, replay: false, now: 20)
        #expect(newState.count == 1)
    }

    // Several transitions inside one window collapse into the pane's latest
    // state, which a flush delivers once the window has passed.
    @Test func transitionsInsideTheWindowCollapseIntoTheLatestState() {
        var policy = RelayProgramStatusAttention()
        let epoch = UUID(), blocked = record("blocked"), done = record("done"), error = record("error")
        #expect(policy.consume(previous: [], current: [blocked], revision: 1,
            deliveryEpoch: epoch, replay: false, now: 1).count == 1)
        #expect(policy.consume(previous: [blocked], current: [done], revision: 2,
            deliveryEpoch: epoch, replay: false, now: 2).isEmpty)
        #expect(policy.consume(previous: [done], current: [error], revision: 3,
            deliveryEpoch: epoch, replay: false, now: 3).isEmpty)
        #expect(policy.hasPending)
        #expect(policy.flush(now: 4, current: [error]).isEmpty)
        let landed = policy.flush(now: 6, current: [error])
        #expect(landed.map(\.record.state) == ["error"])
        #expect(landed.first?.sourceID.hasSuffix(":3:") == true)
        #expect(!policy.hasPending && policy.flush(now: 30, current: [error]).isEmpty)
    }

    // bc08 F1: a held state the pane has already left must not land later.
    // error (emitted) → blocked (held) → running: nothing is delivered.
    @Test func aHeldStateThePaneHasLeftIsNotDelivered() {
        var policy = RelayProgramStatusAttention()
        let epoch = UUID(), error = record("error", id: "job"), blocked = record("blocked", id: "job"),
            running = record("running", id: "job")
        #expect(policy.consume(previous: [], current: [error], revision: 1,
            deliveryEpoch: epoch, replay: false, now: 0).map(\.record.state) == ["error"])
        #expect(policy.consume(previous: [error], current: [blocked], revision: 2,
            deliveryEpoch: epoch, replay: false, now: 1).isEmpty)
        #expect(policy.consume(previous: [blocked], current: [running], revision: 3,
            deliveryEpoch: epoch, replay: false, now: 2).isEmpty)
        #expect(!policy.hasPending)
        #expect(policy.flush(now: 5, current: [running]).isEmpty)
        #expect(policy.consume(previous: [running], current: [running], revision: 4,
            deliveryEpoch: epoch, replay: false, now: 6).isEmpty)
    }

    // The flush re-checks too: a held state whose record is gone, or whose
    // state or blocked kind changed, is discarded at window end.
    @Test func theFlushDiscardsAHeldStateThatNoLongerMatches() {
        let epoch = UUID(), error = record("error", id: "job")
        let blocked = record("blocked", id: "job", kind: "permission")
        for current in [[record("running", id: "job")], [], [record("blocked", id: "job", kind: "auth")],
                        [record("blocked", id: "other", kind: "permission")]] {
            var policy = RelayProgramStatusAttention()
            _ = policy.consume(previous: [], current: [error], revision: 1, deliveryEpoch: epoch, replay: false, now: 0)
            _ = policy.consume(previous: [error], current: [blocked], revision: 2, deliveryEpoch: epoch, replay: false, now: 1)
            #expect(policy.hasPending)
            #expect(policy.flush(now: 5, current: current).isEmpty, "\(current.map(\.state))")
            #expect(!policy.hasPending)
        }
    }

    // A held state still current at window end is delivered, even when only
    // its message or progress changed meanwhile.
    @Test func aHeldStateStillCurrentAtWindowEndIsDelivered() {
        var policy = RelayProgramStatusAttention()
        let epoch = UUID(), error = record("error", id: "job")
        let blocked = record("blocked", id: "job", kind: "permission")
        _ = policy.consume(previous: [], current: [error], revision: 1, deliveryEpoch: epoch, replay: false, now: 0)
        #expect(policy.consume(previous: [error], current: [blocked], revision: 2,
            deliveryEpoch: epoch, replay: false, now: 1).isEmpty)
        let later = record("blocked", id: "job", kind: "permission", message: "still waiting", progress: 40)
        #expect(policy.flush(now: 4, current: [later]).isEmpty)
        let landed = policy.flush(now: 5, current: [later])
        #expect(landed.map(\.record.state) == ["blocked"] && landed.first?.sourceID.hasSuffix(":2:job") == true)
    }

    // End to end: a pane that reports Waiting then Done within five seconds
    // ends with Done in the inbox, without another status message.
    @Test @MainActor func aPaneLandsItsCoalescedStateWithoutAnotherMessage() async throws {
        let pane = PaneModel(profile: .sshConfigHost("program-status-coalesce.invalid"))
        let store = AgentIntelligenceStore.shared
        defer { store.markPaneRead(pane.id) }
        let epoch = UUID()
        func deliver(_ records: [RelayProgramStatusRecord], _ revision: UInt64) {
            pane.applyProgramStatus(RelayStatus(state: "program_status", programStatus: records,
                programStatusRevision: revision, programStatusReplay: false), deliveryEpoch: epoch)
        }
        func titles() -> [String] { store.items.filter { $0.paneID == pane.id }.map(\.title) }
        deliver([record("blocked", id: "job")], 1)
        deliver([record("done", id: "job")], 2)
        #expect(titles().count == 1 && titles().first?.contains("Waiting") == true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(RelayProgramStatusAttention.minimumInterval + 3))
        while titles().count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(titles().count == 2 && titles().first?.contains("Done") == true, "\(titles())")
        #expect(store.marker(for: pane.id) == .needsInput)
    }
    @Test func simultaneousStatesChooseOneDeterministicPriority() {
        var policy = RelayProgramStatusAttention()
        let events = policy.consume(previous: [], current: [record("done", id: "a"),
            record("blocked", id: "b"), record("error", id: "c")], revision: 4,
            deliveryEpoch: UUID(), replay: false, now: 0)
        #expect(events.count == 1)
        #expect(events.first?.record.id == "c")
    }
    @Test @MainActor func reportsStayExactAndCannotClaimProviderIdentity() {
        var policy = RelayProgramStatusAttention()
        let transitions = policy.consume(previous: [], current: [record("blocked", kind: "auth",
            message: String(repeating: "display only ", count: 20))], revision: 1,
            deliveryEpoch: UUID(), replay: false, now: 0)
        let transition = transitions[0]
        let event = transition.inboxEvent(paneID: UUID(), host: "Fixture host",
            paneName: "Fixture pane", occurredAt: Date())
        let store = AgentIntelligenceStore(persistenceEnabled: false)
        let eventID = store.record(event)
        _ = store.record(event)
        #expect(store.items.count == 1)
        #expect(store.attentionCount == 1)
        #expect(store.item(eventID)?.provider == .shell)
        #expect(store.item(eventID)?.isProgramReported == true)
        #expect(store.item(eventID)?.title.contains("Fixture pane") == true)
        #expect(!AgentSummaryPolicy.shouldSummarize(store.items[0]))
    }
}
