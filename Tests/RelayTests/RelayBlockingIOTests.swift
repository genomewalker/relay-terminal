import Foundation
import Dispatch
import Testing
@testable import Relay

private final class BlockingIOState: @unchecked Sendable {
    let condition = NSCondition()
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    var entered = 0
    var wrongName = 0
}
@Suite(.serialized)
struct RelayBlockingIOTests {
@Test func idleReadersLeaveSharedPoolAvailable() {
let state = BlockingIOState()
let count = 96
let began = Date()
for index in 0..<count {
    state.finished.enter()
    RelayBlockingIO.start(name: "reader-test-\(index)", qos: .utility) {
        state.condition.lock()
        if Thread.current.name != "reader-test-\(index)" { state.wrongName += 1 }
        state.entered += 1
        state.condition.broadcast()
        state.condition.unlock()
        state.release.wait()
        state.finished.leave()
    }
}
state.condition.lock()
let deadline = Date().addingTimeInterval(5)
while state.entered < count && Date() < deadline { _ = state.condition.wait(until: deadline) }
let entered = state.entered
let wrong = state.wrongName
state.condition.unlock()
let probe = DispatchSemaphore(value: 0)
let probeStart = Date()
DispatchQueue.global(qos: .utility).async { probe.signal() }
let probeSucceeded = probe.wait(timeout: .now() + 1) == .success
let probeSeconds = Date().timeIntervalSince(probeStart)
for _ in 0..<count { state.release.signal() }
let drained = state.finished.wait(timeout: .now() + 5) == .success
print("readers=\(entered)/\(count) wrong_thread_names=\(wrong) shared_pool_probe=\(probeSucceeded) probe_seconds=\(probeSeconds) drained=\(drained) elapsed=\(Date().timeIntervalSince(began))")
#expect(entered == count)
#expect(wrong == 0)
#expect(probeSucceeded)
#expect(drained)
}
}
