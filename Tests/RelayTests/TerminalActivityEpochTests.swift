import Foundation
import Testing
@testable import Relay

private final class ActivityEpochValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

struct TerminalActivityEpochTests {
    @Test(arguments: [false, true])
    func successorBatchSurvivesRetiredTimer(disableFirst: Bool) {
        let values = ActivityEpochValues()
        let finished = DispatchSemaphore(value: 0)
        let coalescer = TerminalActivityCoalescer(delayMilliseconds: 50)
        coalescer.ingest("retired", deliveryEpoch: UUID()) { values.append("old:" + $0) }
        if disableFirst { coalescer.setEnabled(false); coalescer.setEnabled(true) }
        coalescer.ingest("current", deliveryEpoch: UUID()) {
            values.append("new:" + $0)
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(values.snapshot == ["new:current"])
    }

    @Test func sameEpochCoalescesWithOriginalCallback() {
        let values = ActivityEpochValues()
        let finished = DispatchSemaphore(value: 0)
        let coalescer = TerminalActivityCoalescer(delayMilliseconds: 50)
        let epoch = UUID()
        coalescer.ingest("first", deliveryEpoch: epoch) {
            values.append($0)
            finished.signal()
        }
        coalescer.ingest("second", deliveryEpoch: epoch) { values.append("wrong:" + $0) }
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(values.snapshot == ["firstsecond"])
    }
}
