import Foundation
import Testing
@testable import Relay

private final class OwnedPromptFrameWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var inputPayloads: [Data] = []
    private var onInput: (@Sendable () -> Void)?
    func setInputCallback(_ callback: @escaping @Sendable () -> Void) {
        lock.lock(); onInput = callback; lock.unlock()
    }
    func write(type: RelayWireType, payload: Data) throws { record(type, payload) }
    func writeAsync(type: RelayWireType, payload: Data) { record(type, payload) }
    private func record(_ type: RelayWireType, _ payload: Data) {
        guard type == .inputV2 else { return }
        lock.lock()
        inputPayloads.append(payload)
        let callback = onInput
        lock.unlock()
        callback?()
    }
    var inputs: [Data] {
        lock.lock(); defer { lock.unlock() }
        return inputPayloads
    }

}

@Suite(.serialized)
struct RelayPromptControlTransportTests {
    @MainActor @Test
    func retiredCaptureCannotAppendEndOrCancelItsSuccessor() throws {
        let profile = ConnectionProfile(name: "Owned capture identity", host: "owned-peer.invalid")
        let paneID = UUID(), writer = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        let io = TerminalIOBridge()
        io.installTransport(original)
        defer { _ = io.removeTransport(); original.detach() }
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        let retired = try #require(io.currentPromptControlCaptureIdentity)
        io.cancelPromptControlCapture(expectedCapture: retired)
        #expect(!io.appendNativePromptControlInput(Data("stale".utf8), expectedCapture: retired))
        #expect(writer.inputs.isEmpty)
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        let successor = try #require(io.currentPromptControlCaptureIdentity)
        #expect(successor != retired)
        #expect(!io.appendNativePromptControlInput(Data("stale".utf8), expectedCapture: retired))
        #expect(!io.endPromptControlCapture(expectedCapture: retired))
        io.cancelPromptControlCapture(expectedCapture: retired)
        #expect(io.currentPromptControlCaptureIdentity == successor)
        #expect(io.appendNativePromptControlInput(Data("fresh".utf8), expectedCapture: successor))
        #expect(io.endPromptControlCapture(expectedCapture: successor))
        #expect(writer.inputs.count == 1)
        #expect(writer.inputs.first.map { Data($0.dropFirst(24)) } == Data("fresh".utf8))
    }

    @MainActor @Test(arguments: [false, true])
    func synchronousPasteJoinsTranslatedControlsInOriginalPacket(bracketed: Bool) throws {
        let profile = ConnectionProfile(name: "Owned paste transaction", host: "owned-peer.invalid")
        let paneID = UUID(), writer = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        let io = TerminalIOBridge()
        io.installTransport(original)
        defer { _ = io.removeTransport(); original.detach() }
        #expect(io.receive(Data((bracketed ? "\u{001B}[?2004h" : "\u{001B}[?2004l").utf8)))
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        let text = "first\r\nsecond\t界👩🏽‍💻"
        let keys = Data(repeating: 0x7F, count: 8)
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        io.sendPromptControlInput(keys)
        #expect(io.appendPromptControlPaste(text))
        #expect(writer.inputs.isEmpty)
        #expect(io.endPromptControlCapture())
        #expect(writer.inputs.count == 1)
        let expected = keys + (try #require(TerminalPastePayload.encodedPayload(for: text, bracketed: bracketed)))
        #expect(writer.inputs.first.map { Data($0.dropFirst(24)) } == expected)
    }

    @MainActor @Test
    func cancelledUnencodablePasteCannotSendDeletionPrefix() throws {
        let profile = ConnectionProfile(name: "Owned refused paste", host: "owned-peer.invalid")
        let paneID = UUID(), writer = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        let io = TerminalIOBridge()
        io.installTransport(original)
        defer { _ = io.removeTransport(); original.detach() }
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        io.sendPromptControlInput(Data(repeating: 0x7F, count: 8))
        #expect(!io.appendPromptControlPaste(String(repeating: "x", count: 65_537)))
        io.cancelPromptControlCapture()
        #expect(!io.endPromptControlCapture())
        #expect(writer.inputs.isEmpty)
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        #expect(io.appendPromptControlPaste("fresh"))
        #expect(io.endPromptControlCapture())
        #expect(writer.inputs.count == 1)
        #expect(writer.inputs.first.map { Data($0.dropFirst(24)) } == Data("fresh".utf8))
    }

    private func transport(_ writer: OwnedPromptFrameWriter, profile: ConnectionProfile,
        paneID: UUID) -> RelayRemoteTransport {
        RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: paneID,
            capabilities: ["input_ack_v1", "input_lease_v1"], controlGranted: true)
    }

    @MainActor @Test
    func captureRejectsTransportReplacementWithoutWritingEitherConnection() throws {
        let profile = ConnectionProfile(name: "Owned framed fixture", host: "owned-fixture.invalid")
        let paneID = UUID()
        let oldWriter = OwnedPromptFrameWriter(), newWriter = OwnedPromptFrameWriter()
        let original = transport(oldWriter, profile: profile, paneID: paneID)
        let replacement = transport(newWriter, profile: profile, paneID: paneID)
        defer { original.detach(); replacement.detach() }
        let io = TerminalIOBridge()
        io.installTransport(original)
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        io.sendPromptControlInput(Data("original edit".utf8))
        io.installTransport(replacement)
        #expect(!io.endPromptControlCapture())
        #expect(oldWriter.inputs.isEmpty && newWriter.inputs.isEmpty)
        let fresh = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(fresh != lease)
        #expect(!replacement.sendInput(Data("stale".utf8), expectedControlLease: lease))
        #expect(io.beginPromptControlCapture(expectedControlLease: fresh))
        let packet = Data("fresh edit".utf8)
        io.sendPromptControlInput(packet)
        #expect(io.endPromptControlCapture())
        #expect(newWriter.inputs.count == 1)
        #expect(newWriter.inputs.first?.dropFirst(24) == packet)
        #expect(oldWriter.inputs.isEmpty)
    }

    @MainActor @Test
    func captureRejectsRevokedOriginalControlBeforeAdmission() throws {
        let profile = ConnectionProfile(name: "Owned framed fixture", host: "owned-fixture.invalid")
        let paneID = UUID(), writer = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        let io = TerminalIOBridge()
        io.installTransport(original)
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        io.sendPromptControlInput(Data("edit".utf8))
        original.detach()
        #expect(!io.endPromptControlCapture())
        #expect(writer.inputs.isEmpty)
        #expect(!original.sendInput(Data("stale".utf8), expectedControlLease: lease))
        #expect(writer.inputs.isEmpty)
    }

    @MainActor @Test
    func captureRejectsInputThatBecamePendingAfterLeaseCapture() throws {
        let profile = ConnectionProfile(name: "Owned framed fixture", host: "owned-fixture.invalid")
        let paneID = UUID(), writer = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        defer { original.detach() }
        let io = TerminalIOBridge()
        io.installTransport(original)
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        io.sendPromptControlInput(Data("captured edit".utf8))
        let competing = Data("ordinary pending input".utf8)
        #expect(original.sendInput(competing))
        #expect(io.promptEditorControlLease(paneID: paneID, hostID: profile.id) == nil)
        #expect(!io.endPromptControlCapture())
        #expect(writer.inputs.count == 1)
        #expect(writer.inputs.first?.dropFirst(24) == competing)
        #expect(!original.sendInput(Data("late edit".utf8), expectedControlLease: lease))
        #expect(writer.inputs.count == 1)
    }

    @MainActor @Test
    func captureOverflowWritesNoPrefixAndFreshBatchStillWorks() throws {
        let profile = ConnectionProfile(name: "Owned framed fixture", host: "owned-fixture.invalid")
        let paneID = UUID(), writer = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        defer { original.detach() }
        let io = TerminalIOBridge()
        io.installTransport(original)
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        io.sendPromptControlInput(Data("prefix".utf8))
        io.sendPromptControlInput(Data(repeating: 0x78, count: 64 << 10))
        io.sendPromptControlInput(Data("suffix".utf8))
        #expect(!io.endPromptControlCapture())
        #expect(writer.inputs.isEmpty)
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        let fresh = Data("fresh".utf8)
        io.sendPromptControlInput(fresh)
        #expect(io.endPromptControlCapture())
        #expect(writer.inputs.count == 1)
        #expect(writer.inputs.first?.dropFirst(24) == fresh)
    }
    @MainActor @Test(.timeLimit(.minutes(1)))
    func admittedCaptureDispatchesOutsideIOBindingLock() throws {
        let profile = ConnectionProfile(name: "Owned framed fixture", host: "owned-fixture.invalid")
        let paneID = UUID()
        let writer = OwnedPromptFrameWriter(), nextWriter = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        let replacement = transport(nextWriter, profile: profile, paneID: paneID)
        defer { original.detach(); replacement.detach() }
        let io = TerminalIOBridge()
        io.installTransport(original)
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        writer.setInputCallback { io.installTransport(replacement) }
        #expect(io.beginPromptControlCapture(expectedControlLease: lease))
        let packet = Data("admitted before replacement".utf8)
        io.sendPromptControlInput(packet)
        #expect(io.endPromptControlCapture())
        #expect(writer.inputs.count == 1)
        #expect(writer.inputs.first?.dropFirst(24) == packet)
        #expect(nextWriter.inputs.isEmpty)
        #expect(io.promptEditorControlLease(paneID: paneID, hostID: profile.id)?.connectionID != lease.connectionID)
    }

    @MainActor @Test
    func admittedPacketDispatchesOnce() throws {
        let profile = ConnectionProfile(name: "Owned framed fixture", host: "owned-fixture.invalid")
        let paneID = UUID(), writer = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        defer { original.detach() }
        let lease = try #require(original.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        let packet = Data("one packet".utf8)
        let admitted = try #require(original.preparePromptControlInput(packet, expectedControlLease: lease))
        #expect(writer.inputs.isEmpty)
        #expect(original.promptEditorControlLease(paneID: paneID, hostID: profile.id) == nil)
        #expect(admitted.dispatch())
        #expect(!admitted.dispatch())
        #expect(writer.inputs.count == 1)
        #expect(writer.inputs.first?.dropFirst(24) == packet)
    }

    @MainActor @Test
    func editorTriggerCannotUseReplacedIOConnection() throws {
        let profile = ConnectionProfile(name: "Owned framed fixture", host: "owned-fixture.invalid")
        let paneID = UUID()
        let writer = OwnedPromptFrameWriter(), nextWriter = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        let replacement = transport(nextWriter, profile: profile, paneID: paneID)
        defer { original.detach(); replacement.detach() }
        let io = TerminalIOBridge()
        io.installTransport(original)
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        io.installTransport(replacement)
        #expect(!io.sendPromptEditorControlInput(Data([7]), expectedControlLease: lease))
        #expect(writer.inputs.isEmpty && nextWriter.inputs.isEmpty)
        let fresh = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(io.sendPromptEditorControlInput(Data([7]), expectedControlLease: fresh))
        #expect(nextWriter.inputs.count == 1)
        #expect(nextWriter.inputs.first?.dropFirst(24) == Data([7]))
    }

    @MainActor @Test
    func maintenanceScreenRejectsNewOutputAndChangedGeometryBeforeInputAdmission() throws {
        let profile = ConnectionProfile(name: "Owned hidden screen", host: "owned-screen.invalid")
        let paneID = UUID(), writer = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        let io = TerminalIOBridge()
        io.installTransport(original)
        _ = io.restoreSnapshot(paneID: paneID)
        defer {
            _ = io.removeTransport(); original.detach()
            TerminalSnapshotStore.shared.remove(paneID: paneID)
        }
        io.receive(Data("\u{1b}[2J\u{1b}[H❯ \r\n────────\r\n⏵⏵ bypass permissions on".utf8), remoteSequence: 100)
        let snapshot = try #require(io.maintenanceScreenSnapshot())
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
        #expect(io.maintenanceScreenIsCurrent(snapshot.token))
        io.receive(Data("new output".utf8), remoteSequence: 110)
        #expect(!io.sendPromptEditorControlInput(Data("/exit\r".utf8), expectedControlLease: lease,
            expectedMaintenanceScreen: snapshot.token))
        #expect(writer.inputs.isEmpty)
        let next = try #require(io.maintenanceScreenSnapshot())
        io.terminalDidResize(columns: 90, rows: 30)
        #expect(!io.maintenanceScreenIsCurrent(next.token))
        #expect(!io.sendPromptEditorControlInput(Data("/exit\r".utf8), expectedControlLease: lease,
            expectedMaintenanceScreen: next.token))
        #expect(writer.inputs.isEmpty)
        io.beginReplay()
        #expect(io.maintenanceScreenSnapshot() == nil)
    }

    /// 0.5.61: a held update names the check that refused the saved screen.
    @MainActor @Test
    func maintenanceScreenAvailabilityNamesTheRefusingCheck() throws {
        let profile = ConnectionProfile(name: "Named refusal", host: "named-refusal.invalid")
        let paneID = UUID(), writer = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        let io = TerminalIOBridge()
        #expect(io.maintenanceScreenAvailability().reason == "the terminal has no live connection")
        io.installTransport(original)
        #expect(io.maintenanceScreenAvailability().reason == "the pane's screen is not being saved")
        _ = io.restoreSnapshot(paneID: paneID)
        defer {
            _ = io.removeTransport(); original.detach()
            TerminalSnapshotStore.shared.remove(paneID: paneID)
        }
        #expect(io.maintenanceScreenAvailability().reason == "the saved copy is empty")
        io.receive(Data("\u{1b}[2J\u{1b}[H❯ \r\n────────\r\n⏵⏵ bypass permissions on".utf8), remoteSequence: 100)
        #expect(io.maintenanceScreenAvailability().reason == nil)
        #expect(io.maintenanceScreenSnapshot() != nil)
        io.beginReplay()
        #expect(io.maintenanceScreenAvailability().reason == "a replay is in progress")
        #expect(io.maintenanceScreenSnapshot() == nil)
    }

    /// 0.5.61 step 2: an ordinary resume never makes a cut-short copy
    /// readable; only a replay requested as a fresh base does.
    @MainActor @Test
    func onlyAFreshBaseReplayMakesACutShortCopyReadable() async throws {
        let profile = ConnectionProfile(name: "Fresh base", host: "fresh-base.invalid")
        let paneID = UUID(), writer = OwnedPromptFrameWriter()
        let original = transport(writer, profile: profile, paneID: paneID)
        let io = TerminalIOBridge()
        io.installTransport(original)
        _ = io.restoreSnapshot(paneID: paneID)
        defer {
            _ = io.removeTransport(); original.detach()
            TerminalSnapshotStore.shared.remove(paneID: paneID)
        }
        func replay(_ text: String, sequence: UInt64) async {
            io.beginReplay()
            io.setExplicitReplayBoundary(true)
            _ = io.receive(Data(text.utf8), remoteSequence: sequence)
            await withCheckedContinuation { continuation in
                io.onReplayFinished = { _ in continuation.resume() }
                io.endReplay()
            }
            io.onReplayFinished = nil
        }
        let screen = "\u{1b}[2J\u{1b}[H❯ \r\n────────\r\n⏵⏵ bypass permissions on"
        await replay(screen, sequence: 100)
        #expect(io.maintenanceScreenAvailability().reason == nil)
        io.markSnapshotCutShortForTesting()
        #expect(io.maintenanceScreenAvailability().reason == TerminalIOBridge.savedCopyCutShort)
        // A cursor resume carries only the bytes after the cursor.
        await replay("\u{1b}[3;1Hdelta", sequence: 101)
        #expect(io.maintenanceScreenAvailability().reason == TerminalIOBridge.savedCopyCutShort)
        // fresh_redraw_begin, then a sequence-zero reset and the agent's
        // redraw, then fresh_redraw_done.
        io.beginFreshRedrawReplay()
        #expect(io.maintenanceScreenAvailability().reason == "a replay is in progress")
        _ = io.receive(Data("\u{1b}c".utf8), remoteSequence: 0)
        _ = io.receive(Data(screen.utf8), remoteSequence: 102)
        await withCheckedContinuation { continuation in
            io.onReplayFinished = { _ in continuation.resume() }
            io.endReplay()
        }
        io.onReplayFinished = nil
        #expect(io.maintenanceScreenAvailability().reason == nil)
        let snapshot = try #require(io.maintenanceScreenSnapshot())
        #expect(snapshot.token.sequence == 102)
        #expect(snapshot.data.range(of: Data("delta".utf8)) == nil || snapshot.data.range(of: Data("\u{1b}c".utf8)) != nil)
    }

    @MainActor @Test
    func installedUpdateScreenRefreshNeedsAnIdleUpdateWithNoDraftOrApproval() throws {
        let paneID = RelayMaintenanceOrchestrationTests.paneID
        var proof = try RelayMaintenanceOrchestrationTests.probe()
        proof.installedUpdate = true
        proof.harnessStatus = "idle"
        let admits = { (p: RelayAgentMaintenanceProbe, draft: Bool, approvals: Int) in
            RelayInstalledUpdateScreenRefresh.admits(p, paneID: paneID, hasDraft: draft, pendingApprovals: approvals)
        }
        #expect(proof.valid(for: paneID))
        #expect(admits(proof, false, 0))
        #expect(!admits(proof, true, 0))
        #expect(!admits(proof, false, 1))
        var busy = proof; busy.harnessStatus = "busy"
        #expect(!admits(busy, false, 0))
        var unknown = proof; unknown.harnessStatus = nil
        #expect(!admits(unknown, false, 0))
        var none = proof; none.installedUpdate = false
        #expect(!admits(none, false, 0))
        #expect(!RelayInstalledUpdateScreenRefresh.admits(proof, paneID: UUID(), hasDraft: false, pendingApprovals: 0))
    }
}
