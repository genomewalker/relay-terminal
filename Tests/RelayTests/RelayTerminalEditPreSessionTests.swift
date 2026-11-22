import AppKit
import Foundation
import Testing
@testable import Relay

private final class PreSessionEditFrameWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var inputCount = 0
    func write(type: RelayWireType, payload: Data) throws { writeAsync(type: type, payload: payload) }
    func writeAsync(type: RelayWireType, payload: Data) {
        guard type == .inputV2 || type == .automationInputV2 else { return }
        lock.lock(); inputCount += 1; lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return inputCount }
}

@MainActor
@Test("A startup dialog before any session gets an edit proof; an unverified owner does not", .timeLimit(.minutes(2)))
func terminalEditingAdmitsAPreSessionAgentOwner() async throws {
    _ = NSApplication.shared
    for ownerKind in ["presession", "none", "changed"] {
        let profile = ConnectionProfile(name: "Startup dialog edit", host: "owned-peer.invalid", backend: .relay)
        let pane = PaneModel(profile: profile)
        let runtime = pane.runtime
        let writer = PreSessionEditFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: pane.id,
            capabilities: ["input_ack_v1", "input_lease_v1", "automation_input_v1"], controlGranted: true)
        runtime.ioForTesting.seedInitialViewport(.init(columns: 100, rows: 30))
        runtime.startForTesting(transport: transport)
        _ = runtime.ioForTesting.restoreSnapshot(paneID: pane.id)
        defer { TerminalSnapshotStore.shared.remove(paneID: pane.id) }
        let session = runtime.ioForTesting.session
        #expect(runtime.ioForTesting.receive(Data("\u{1b}[2J\u{1b}[HDo you trust the files in this folder?\r\n ❯ 1. Yes, proceed\r\n   2. No, exit".utf8), remoteSequence: 1))
        await Task.detached { session.waitForPendingOutput() }.value
        runtime.view.synchronizeAndRedraw()
        pane.connectionState = .connected
        let startup = RelayPromptOwnerBinding(version: 1, paneId: pane.id.uuidString.lowercased(),
            nodeBootId: "owned-boot", workerPid: 222, workerStart: 1, shellPid: 333, shellStart: 2,
            provider: "claude", processId: 444, processStart: 3, sessionId: nil,
            transcriptIdentity: RelayPromptOwnerBinding.preSessionIdentity, inputOnly: true)
        #expect(startup.isValid(for: pane.id))
        var reads = 0
        runtime.promptOwnerBindingForTesting = {
            reads += 1
            switch ownerKind {
            case "presession": return RelayPromptOwnerIdentity(hostID: profile.id, binding: startup)
            case "changed":
                // The second read sees a successor process: the proof must not issue.
                let successor = RelayPromptOwnerBinding(version: 1, paneId: pane.id.uuidString.lowercased(),
                    nodeBootId: "owned-boot", workerPid: 222, workerStart: 1, shellPid: 333, shellStart: 2,
                    provider: "claude", processId: 445, processStart: 4, sessionId: nil,
                    transcriptIdentity: RelayPromptOwnerBinding.preSessionIdentity, inputOnly: true)
                return RelayPromptOwnerIdentity(hostID: profile.id, binding: reads == 1 ? startup : successor)
            default: return nil
            }
        }
        let state = await runtime.terminalEditState()
        switch ownerKind {
        case "presession":
            #expect(state["status"] == "observed", "\(state)")
            #expect(state["provider"] == "claude" && state["session_id"] == "")
            #expect(state["proof_id"] != nil)
        case "changed":
            #expect(state["status"] == "changed" && state["proof_id"] == nil, "\(state)")
        default:
            #expect(state["status"] == "changed" && state["proof_id"] == nil, "\(state)")
            #expect(state["reason"]?.contains("could not verify which program owns") == true)
        }
        #expect(writer.count == 0)
        _ = runtime.ioForTesting.removeTransport(); transport.detach()
        runtime.stop()
    }
}
