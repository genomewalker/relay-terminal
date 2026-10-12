import Foundation
import Testing
@testable import Relay

private final class EventReceiptWriter: RelayFrameWriting, @unchecked Sendable {
    func write(type: RelayWireType, payload: Data) throws {}
    func writeAsync(type: RelayWireType, payload: Data) {}
}

struct RelayAgentEventReceiptTests {
    private func event(_ sequence: UInt64) -> RelayWireFrame {
        .init(type: .agentEvent, payload: Data("{\"relay_event_seq\":\(sequence),\"agent\":\"relay\",\"event\":{\"type\":\"test\"}}".utf8))
    }

    @Test func receiptsCommitReceivedPrefixWithSequenceGaps() {
        var receipts = RelayAgentEventReceipts()
        receipts.received(10)
        receipts.received(20)
        #expect(receipts.acknowledge(20) == nil)
        #expect(receipts.acknowledge(10) == 20)
        #expect(receipts.acknowledge(20) == nil)
    }

    @Test func overflowCannotSkipUntrackedEvent() {
        var receipts = RelayAgentEventReceipts(maximumPending: 2)
        receipts.received(10)
        receipts.received(20)
        receipts.received(30)
        #expect(receipts.overflowed)
        #expect(receipts.acknowledge(10) == 10)
        #expect(receipts.acknowledge(20) == 20)
        receipts.received(40)
        #expect(receipts.acknowledge(30) == nil)
        #expect(receipts.acknowledge(40) == nil)
        receipts.reset()
        receipts.received(30)
        #expect(receipts.acknowledge(30) == 30)
    }

    @Test func actualReaderKeepsRejectedUITasksEligibleForReplay() throws {
        let writer = EventReceiptWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: .init(name: "Owned event receipt", host: "owned-peer.invalid"), paneID: UUID(),
            capabilities: [], controlGranted: true)
        let old = Process(), current = Process()
        defer { transport.detach() }
        #expect(transport.installDedicatedProcess(old, writer: writer))
        let oldEpoch = transport.deliveryEpochSnapshot()
        try transport.receiveAttachedDedicatedFrame(event(10), sourceProcess: old)
        try transport.receiveAttachedDedicatedFrame(event(20), sourceProcess: old)
        #expect(transport.committedAgentEventSequence == 0)
        transport.acknowledgeAgentEvent(event(20).payload, deliveryEpoch: oldEpoch)
        #expect(transport.committedAgentEventSequence == 0)
        transport.acknowledgeAgentEvent(event(10).payload, deliveryEpoch: oldEpoch)
        #expect(transport.committedAgentEventSequence == 20)
        try transport.receiveAttachedDedicatedFrame(event(30), sourceProcess: old)
        #expect(transport.installDedicatedProcess(current, writer: writer))
        transport.acknowledgeAgentEvent(event(30).payload, deliveryEpoch: oldEpoch)
        #expect(transport.committedAgentEventSequence == 20)
        try transport.receiveAttachedDedicatedFrame(event(30), sourceProcess: current)
        transport.acknowledgeAgentEvent(event(30).payload, deliveryEpoch: transport.deliveryEpochSnapshot())
        #expect(transport.committedAgentEventSequence == 30)
    }

    @Test func eventResetRetiresQueuedUIReceipts() throws {
        let writer = EventReceiptWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: .init(name: "Owned event reset", host: "owned-peer.invalid"), paneID: UUID(),
            capabilities: [], controlGranted: true)
        let source = Process()
        defer { transport.detach() }
        #expect(transport.installDedicatedProcess(source, writer: writer))
        let oldEpoch = transport.deliveryEpochSnapshot()
        try transport.receiveAttachedDedicatedFrame(event(10), sourceProcess: source)
        try transport.receiveAttachedDedicatedFrame(.init(type: .status,
            payload: Data("{\"state\":\"attached\",\"event_reset\":true}".utf8)), sourceProcess: source)
        transport.acknowledgeAgentEvent(event(10).payload, deliveryEpoch: oldEpoch)
        #expect(transport.committedAgentEventSequence == 0)
        #expect(!transport.isCurrentDeliveryEpoch(oldEpoch))
        try transport.receiveAttachedDedicatedFrame(event(1), sourceProcess: source)
        transport.acknowledgeAgentEvent(event(1).payload, deliveryEpoch: transport.deliveryEpochSnapshot())
        #expect(transport.committedAgentEventSequence == 1)
    }
}
