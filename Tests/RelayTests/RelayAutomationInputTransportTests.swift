import Foundation
import Testing
@testable import Relay

private final class RecordingFrameWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(RelayWireType, Data)] = []
    func write(type: RelayWireType, payload: Data) throws { writeAsync(type: type, payload: payload) }
    func writeAsync(type: RelayWireType, payload: Data) {
        lock.lock(); frames.append((type, payload)); lock.unlock()
    }
    var inputs: [(RelayWireType, Data)] {
        lock.lock(); defer { lock.unlock() }
        return frames.filter { $0.0 == .inputV2 || $0.0 == .automationInputV2 }
    }
}

/// Relay's own maintenance and compiled-prompt keystrokes are sent as
/// automation input so the worker does not treat them as a human takeover.
private func admit(capabilities: [String], automation: Bool, requireAutomation: Bool = false)
    -> (sent: Bool, frames: [(RelayWireType, Data)]) {
    let writer = RecordingFrameWriter()
    let profile = ConnectionProfile(name: "Owned automation input", host: "owned-peer.invalid")
    let paneID = UUID()
    let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: paneID,
        capabilities: capabilities, controlGranted: true)
    defer { transport.detach() }
    guard let lease = transport.promptEditorControlLease(paneID: paneID, hostID: profile.id) else {
        Issue.record("no prompt control lease")
        return (false, [])
    }
    let admission = transport.preparePromptControlInput(Data("/exit\r".utf8), expectedControlLease: lease,
        automation: automation, requireAutomation: requireAutomation)
    let sent = admission?.dispatch() == true
    return (sent, writer.inputs)
}

@Test func automationInputUsesItsOwnFrameWhenTheWorkerSupportsIt() {
    let result = admit(capabilities: ["input_ack_v1", "input_lease_v1", "automation_input_v1"], automation: true)
    #expect(result.sent)
    #expect(result.frames.map(\.0) == [.automationInputV2])
    #expect(result.frames.first?.1.suffix(6) == Data("/exit\r".utf8))
}

@Test func ordinaryPromptControlInputStaysHumanInput() {
    let result = admit(capabilities: ["input_ack_v1", "input_lease_v1", "automation_input_v1"], automation: false)
    #expect(result.sent)
    #expect(result.frames.map(\.0) == [.inputV2])
}

@Test func olderWorkerReceivesMaintenanceAsOrdinaryInput() {
    let result = admit(capabilities: ["input_ack_v1", "input_lease_v1"], automation: true)
    #expect(result.sent)
    #expect(result.frames.map(\.0) == [.inputV2])
}

@Test func requiredAutomationInputIsRefusedByAnOlderWorker() {
    let result = admit(capabilities: ["input_ack_v1", "input_lease_v1"], automation: true, requireAutomation: true)
    #expect(!result.sent)
    #expect(result.frames.isEmpty)
    let supported = admit(capabilities: ["input_ack_v1", "input_lease_v1", "automation_input_v1"],
        automation: true, requireAutomation: true)
    #expect(supported.sent)
    #expect(supported.frames.map(\.0) == [.automationInputV2])
}

@Test func automationWireTypeMatchesRelayd() {
    #expect(RelayWireType.automationInputV2.rawValue == 22)
    #expect(RelayWireType(rawValue: 22) == .automationInputV2)
}
