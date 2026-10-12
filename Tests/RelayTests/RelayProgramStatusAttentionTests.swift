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
    @Test func rateLimitSurvivesReconnectAndNeverQueues() {
        var policy = RelayProgramStatusAttention()
        let epoch = UUID(), other = UUID(), blocked = record("blocked"), done = record("done")
        let initial = policy.consume(previous: [], current: [blocked], revision: 1,
            deliveryEpoch: epoch, replay: false, now: 1)
        #expect(initial.count == 1)
        let limited = policy.consume(previous: [blocked], current: [done], revision: 1,
            deliveryEpoch: other, replay: false, now: 2)
        #expect(limited.isEmpty)
        let notQueued = policy.consume(previous: [done], current: [done], revision: 2,
            deliveryEpoch: other, replay: false, now: 7)
        #expect(notQueued.isEmpty)
        let newState = policy.consume(previous: [done], current: [blocked], revision: 3,
            deliveryEpoch: other, replay: false, now: 7)
        #expect(newState.count == 1)
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
