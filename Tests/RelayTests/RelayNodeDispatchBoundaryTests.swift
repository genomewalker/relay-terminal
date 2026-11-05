import Foundation
import Testing
@testable import Relay

private final class NodeBoundaryValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}

struct RelayNodeDispatchBoundaryTests {
    @Test func lifecycleCannotOvertakeQueuedOutput() {
        let values = NodeBoundaryValues()
        let finished = DispatchSemaphore(value: 0)
        let dispatcher = RelayNodeFrameDispatcher(label: "relay.tests.boundary.order", initiallyPaused: true) {
            values.append(Int($0.payload.first ?? 0))
        }
        dispatcher.enqueue(.init(type: .output, payload: Data([1])))
        dispatcher.enqueueLifecycle { values.append(2) } // disconnect
        dispatcher.enqueueLifecycle { values.append(3) } // next Hello
        dispatcher.enqueue(.init(type: .output, payload: Data([4])))
        dispatcher.enqueueLifecycle { finished.signal() }
        #expect(values.snapshot.isEmpty)
        dispatcher.resume()
        #expect(finished.wait(timeout: .now() + 2) == .success)
        dispatcher.close()
        #expect(values.snapshot == [1, 2, 3, 4])
    }

    @Test func closeRetiresInflightDeliveryBeforeReturning() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let closing = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        let values = NodeBoundaryValues()
        let dispatcher = RelayNodeFrameDispatcher(label: "relay.tests.boundary.close") { _ in
            started.signal()
            release.wait()
            values.append(1)
        }
        dispatcher.enqueue(.init(type: .output, payload: Data()))
        #expect(started.wait(timeout: .now() + 2) == .success)
        // A dedicated thread: a saturated global pool must not stand in for close.
        Thread {
            closing.signal()
            dispatcher.close()
            closed.signal()
        }.start()
        #expect(closing.wait(timeout: .now() + 2) == .success)
        let prematureClose = closed.wait(timeout: .now() + 0.05)
        #expect(prematureClose == .timedOut)
        release.signal()
        if prematureClose == .timedOut { #expect(closed.wait(timeout: .now() + 2) == .success) }
        #expect(values.snapshot == [1])
        dispatcher.enqueueLifecycle { values.append(2) }
        dispatcher.resume()
        #expect(values.snapshot == [1])
    }

    @Test func lifecycleCanCloseItsOwnDispatcher() {
        let finished = DispatchSemaphore(value: 0)
        let values = NodeBoundaryValues()
        let dispatcher = RelayNodeFrameDispatcher(label: "relay.tests.boundary.reentrant", initiallyPaused: true) { _ in
            values.append(1)
        }
        dispatcher.enqueueLifecycle {
            dispatcher.close()
            finished.signal()
        }
        dispatcher.enqueue(.init(type: .output, payload: Data()))
        dispatcher.resume()
        #expect(finished.wait(timeout: .now() + 2) == .success)
        dispatcher.close()
        #expect(values.snapshot.isEmpty)
    }
}
