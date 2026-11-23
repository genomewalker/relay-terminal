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

    /// The background refresh of a cut-short hidden screen needs the same
    /// idle proof as an installed update, but no update.
    @MainActor @Test
    func hiddenScreenRefreshNeedsAnIdleAgentWithNoDraftOrApproval() throws {
        let paneID = RelayMaintenanceOrchestrationTests.paneID
        var proof = try RelayMaintenanceOrchestrationTests.probe()
        proof.installedUpdate = false
        proof.harnessStatus = "idle"
        let admits = { (p: RelayAgentMaintenanceProbe, draft: Bool, approvals: Int) in
            RelayHiddenScreenRefresh.admits(p, paneID: paneID, hasDraft: draft, pendingApprovals: approvals)
        }
        #expect(admits(proof, false, 0), "no update is needed")
        #expect(!admits(proof, true, 0))
        #expect(!admits(proof, false, 1))
        var busy = proof; busy.harnessStatus = "busy"
        #expect(!admits(busy, false, 0))
        var unknown = proof; unknown.harnessStatus = nil
        #expect(!admits(unknown, false, 0))
        #expect(!RelayHiddenScreenRefresh.admits(proof, paneID: UUID(), hasDraft: false, pendingApprovals: 0))
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

// dandy-07 d62c62eb, 2026-11-22: agents enable any-motion mouse tracking
// (1003), so every pointer move over a busy agent queued another report ahead
// of the next keystroke (1.9 s median input delay). Motion with no button held
// waits for earlier input to be acknowledged and only its latest position is sent.
@Suite(.serialized)
struct RelayPointerMotionCoalescingTests {
    @MainActor @Test
    func pointerMotionWaitsBehindUnacknowledgedInputAndKeepsOnlyTheLatest() throws {
        let profile = ConnectionProfile(name: "Motion fixture", host: "motion-fixture.invalid")
        let writer = OwnedPromptFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: UUID(),
            capabilities: ["input_ack_v1"], controlGranted: true)
        defer { transport.detach() }
        let motion1 = Data("\u{1B}[<35;10;5M".utf8), motion2 = Data("\u{1B}[<35;11;5M".utf8)
        let key = Data("a".utf8), wheel = Data("\u{1B}[<0;11;5M".utf8)  // a click
        #expect(transport.sendInput(motion1))           // nothing outstanding: sent
        #expect(writer.inputs.count == 1)
        #expect(transport.sendInput(motion2))           // behind motion1: withheld
        #expect(transport.sendInput(Data("\u{1B}[<35;12;5M".utf8)))  // replaces motion2
        #expect(writer.inputs.count == 1)
        #expect(transport.sendInput(key))               // keys are never withheld
        #expect(transport.sendInput(wheel))             // nor are clicks
        #expect(writer.inputs.count == 3)
        #expect(writer.inputs[1].dropFirst(24) == key && writer.inputs[2].dropFirst(24) == wheel)
        let sequences = transport.pendingInputSequencesForTesting
        transport.acknowledgeInput(sequence: sequences[0], pane: "p")
        #expect(writer.inputs.count == 3)               // still outstanding input
        transport.acknowledgeInput(sequence: sequences[1], pane: "p")
        transport.acknowledgeInput(sequence: sequences[2], pane: "p")
        #expect(writer.inputs.count == 4)               // latest position, once
        #expect(writer.inputs[3].dropFirst(24) == Data("\u{1B}[<35;12;5M".utf8))
        #expect(transport.deferredMotionReportForTesting == nil)
    }
}

// dandy-07 d62c62eb, 2026-11-22: 300 wheel reports at 10 ms to a busy agent,
// one frame each, overflowed the supervisor's 128-frame route queue and every
// reattach resent them one by one. Beyond 32 outstanding frames, input is held
// and sent in order as one frame when the worker catches up.
@Suite(.serialized)
struct RelayOutstandingInputFrameCapTests {
    @MainActor @Test
    func inputBeyondTheFrameCapIsHeldAndSentInOrderAsOneFrame() throws {
        let profile = ConnectionProfile(name: "Cap fixture", host: "cap-fixture.invalid")
        let writer = OwnedPromptFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: UUID(),
            capabilities: ["input_ack_v1"], controlGranted: true)
        defer { transport.detach() }
        let cap = RelayRemoteTransport.maximumOutstandingInputFrames
        // Keys, not wheel steps: wheel steps are coalesced separately.
        let up = Data("j".utf8), down = Data("k".utf8)
        for i in 0..<300 { #expect(transport.sendInput(i % 2 == 0 ? up : down)) }
        #expect(writer.inputs.count == cap)
        #expect(transport.sendInput(Data("x".utf8)))   // a key queues behind held wheels
        var expectedHeld = Data()
        for i in cap..<300 { expectedHeld.append(i % 2 == 0 ? up : down) }
        expectedHeld.append(Data("x".utf8))
        #expect(transport.heldInputForTesting == expectedHeld)
        let first = transport.pendingInputSequencesForTesting[0]
        transport.acknowledgeInput(sequence: first, pane: "p")
        #expect(writer.inputs.count == cap + 1)        // one frame, all bytes in order
        #expect(writer.inputs[cap].dropFirst(24) == expectedHeld)
        #expect(transport.heldInputForTesting.isEmpty)
        // 31 original frames plus the flushed one: at the cap again, so new
        // input is held until another acknowledgement.
        #expect(transport.sendInput(up))
        #expect(writer.inputs.count == cap + 1 && transport.heldInputForTesting == up)
        let next = transport.pendingInputSequencesForTesting[0]
        transport.acknowledgeInput(sequence: next, pane: "p")
        #expect(writer.inputs.count == cap + 2 && writer.inputs[cap + 1].dropFirst(24) == up)
    }
}

// dandy-07 d62c62eb, 2026-11-22: an idle Claude took ~10 s to drain 300 wheel
// reports, so typing after a fast scroll waited. While input is unacknowledged,
// wheel steps of one kind collapse to a capped net count sent once caught up.
@Suite(.serialized)
struct RelayWheelCoalescingTests {
    @MainActor @Test
    func wheelStepsWhileBehindCancelAndAreCapped() throws {
        let writer = OwnedPromptFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: ConnectionProfile(name: "Wheel fixture", host: "wheel-fixture.invalid"), paneID: UUID(),
            capabilities: ["input_ack_v1"], controlGranted: true)
        defer { transport.detach() }
        var clock: UInt64 = 1_000_000_000
        transport.inputClock = { clock }
        let up = Data("\u{1B}[<64;10;5M".utf8), down = Data("\u{1B}[<65;10;5M".utf8)
        #expect(transport.sendInput(up))                      // caught up: sent at once
        #expect(writer.inputs.count == 1)
        clock += RelayRemoteTransport.wheelLagNanoseconds    // the ack is lagging
        for _ in 0..<15 { #expect(transport.sendInput(up)) }   // +15
        for _ in 0..<5 { #expect(transport.sendInput(down)) }  // capped at +8, then -5
        #expect(writer.inputs.count == 1)
        var three = Data(); for _ in 0..<3 { three.append(up) }
        #expect(transport.deferredWheelForTesting == three)
        transport.acknowledgeInput(sequence: transport.pendingInputSequencesForTesting[0], pane: "p")
        #expect(writer.inputs.count == 2 && writer.inputs[1].dropFirst(24) == three)
        // Up and down cancel completely: nothing is sent.
        clock += RelayRemoteTransport.wheelLagNanoseconds
        #expect(transport.sendInput(up)); #expect(transport.sendInput(down))
        transport.acknowledgeInput(sequence: transport.pendingInputSequencesForTesting[0], pane: "p")
        #expect(writer.inputs.count == 2)
    }

    @MainActor @Test
    func aThreeHundredStepBurstSendsTwoFramesAndTheKeyGoesOutOnTheNextAck() throws {
        let writer = OwnedPromptFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: ConnectionProfile(name: "Wheel fixture", host: "wheel-fixture.invalid"), paneID: UUID(),
            capabilities: ["input_ack_v1"], controlGranted: true)
        defer { transport.detach() }
        var clock: UInt64 = 1_000_000_000
        transport.inputClock = { clock }
        let up = Data("\u{1B}[<64;10;5M".utf8), down = Data("\u{1B}[<65;10;5M".utf8), key = Data("x".utf8)
        for i in 0..<300 {
            #expect(transport.sendInput((i / 15) % 2 == 0 ? up : down))
            if i == 0 { clock += RelayRemoteTransport.wheelLagNanoseconds }   // a busy worker
        }
        #expect(transport.sendInput(key))
        #expect(writer.inputs.count == 1)                     // the first step only
        transport.acknowledgeInput(sequence: transport.pendingInputSequencesForTesting[0], pane: "p")
        #expect(writer.inputs.count == 2)                     // net steps (<= 8) then the key, one frame
        let batch = writer.inputs[1].dropFirst(24)
        #expect(batch.suffix(1) == key && batch.count <= 8 * up.count + key.count)
    }

    // d62c62eb, 2026-11-22 21:15Z: "cannot even scroll". Withheld steps
    // must never wait on an ack that does not come.
    @MainActor @Test
    func withNoAckForASecondNothingIsWithheld() throws {
        let writer = OwnedPromptFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: ConnectionProfile(name: "Wheel fixture", host: "wheel-fixture.invalid"), paneID: UUID(),
            capabilities: ["input_ack_v1"], controlGranted: true)
        defer { transport.detach() }
        var clock: UInt64 = 1_000_000_000
        transport.inputClock = { clock }
        let up = Data("\u{1B}[<64;10;5M".utf8), key = Data("q".utf8)
        #expect(transport.sendInput(key))                     // outstanding, never acknowledged
        clock += RelayRemoteTransport.wheelLagNanoseconds    // lagging: steps are merged
        #expect(transport.sendInput(up)); #expect(transport.sendInput(up))
        #expect(transport.sendInput(key))                     // held behind the wheel steps
        #expect(writer.inputs.count == 1)
        clock += RelayRemoteTransport.inputStallNanoseconds
        #expect(transport.sendInput(up))                      // stalled: everything goes now, in order
        #expect(writer.inputs.count == 2)
        #expect(writer.inputs[1].dropFirst(24) == up + up + key + up)
        #expect(transport.heldInputForTesting.isEmpty && transport.deferredWheelForTesting == nil)
        #expect(transport.sendInput(up))                      // still stalled: sent directly
        #expect(writer.inputs.count == 3)
    }

    @MainActor @Test
    func aKeyAfterDeferredWheelStepsKeepsItsOrder() throws {
        let writer = OwnedPromptFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: ConnectionProfile(name: "Wheel fixture", host: "wheel-fixture.invalid"), paneID: UUID(),
            capabilities: ["input_ack_v1"], controlGranted: true)
        defer { transport.detach() }
        var clock: UInt64 = 1_000_000_000
        transport.inputClock = { clock }
        let up = Data("\u{1B}[<64;10;5M".utf8), key = Data("q".utf8)
        #expect(transport.sendInput(key))
        clock += RelayRemoteTransport.wheelLagNanoseconds
        #expect(transport.sendInput(up)); #expect(transport.sendInput(up))
        #expect(transport.sendInput(key))                     // after the wheel steps
        #expect(writer.inputs.count == 1)
        transport.acknowledgeInput(sequence: transport.pendingInputSequencesForTesting[0], pane: "p")
        #expect(writer.inputs.count == 2 && writer.inputs[1].dropFirst(24) == up + up + key)
        #expect(RelayWheelStep(Data("\u{1B}[<35;10;5M".utf8)) == nil)   // motion is not a wheel step
        #expect(RelayWheelStep(Data("\u{1B}[<80;10;5M".utf8))?.kind == 80)  // ctrl+wheel up keeps its kind
    }

    // f42326bf, 2026-11-23: scrolling a streaming remote agent felt stuck
    // while dandy-07 acknowledged in about 1 ms. With acks flowing, every
    // wheel step goes out at once instead of waiting a round trip per batch.
    @MainActor @Test
    func onAHealthyLinkEveryWheelStepIsSentAtOnce() throws {
        let writer = OwnedPromptFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: ConnectionProfile(name: "Wheel fixture", host: "wheel-fixture.invalid"), paneID: UUID(),
            capabilities: ["input_ack_v1"], controlGranted: true)
        defer { transport.detach() }
        var clock: UInt64 = 1_000_000_000
        transport.inputClock = { clock }
        let up = Data("\u{1B}[<64;10;5M".utf8), down = Data("\u{1B}[<65;10;5M".utf8)
        for i in 0..<20 {
            #expect(transport.sendInput(i % 3 == 2 ? down : up))
            clock += 5_000_000                                // 5 ms apart, none acknowledged yet
        }
        #expect(writer.inputs.count == 20)                    // nothing merged, cancelled or held
        #expect(transport.deferredWheelForTesting == nil)
        #expect(writer.inputs[2].dropFirst(24) == down)       // each step unchanged, in order
        // Acks keep arriving: still sent directly.
        transport.acknowledgeInput(sequence: transport.pendingInputSequencesForTesting[0], pane: "p")
        clock += 5_000_000
        #expect(transport.sendInput(up))
        #expect(writer.inputs.count == 21)
        // No progress for the lag interval: merging starts.
        clock += RelayRemoteTransport.wheelLagNanoseconds
        #expect(transport.sendInput(up)); #expect(transport.sendInput(up))
        #expect(writer.inputs.count == 21)
        #expect(transport.deferredWheelForTesting == up + up)
    }

    // Kapk on dandy-07, 2026-11-23: a fast scroll was quick "until a point".
    // At the 32-frame cap later steps were held in full; now they merge.
    @MainActor @Test
    func atTheFrameCapAFastScrollMergesInsteadOfQueueing() throws {
        let writer = OwnedPromptFrameWriter()
        let transport = RelayRemoteTransport(attachedFrameWriter: writer,
            profile: ConnectionProfile(name: "Wheel fixture", host: "wheel-fixture.invalid"), paneID: UUID(),
            capabilities: ["input_ack_v1"], controlGranted: true)
        defer { transport.detach() }
        var clock: UInt64 = 1_000_000_000
        transport.inputClock = { clock }
        let up = Data("\u{1B}[<64;10;5M".utf8), down = Data("\u{1B}[<65;10;5M".utf8)
        let cap = RelayRemoteTransport.maximumOutstandingInputFrames
        for _ in 0..<cap { #expect(transport.sendInput(up)); clock += 1_000_000 }
        #expect(writer.inputs.count == cap)
        for _ in 0..<100 { #expect(transport.sendInput(up)) }   // far more than the cap
        for _ in 0..<3 { #expect(transport.sendInput(down)) }
        #expect(writer.inputs.count == cap)
        #expect(transport.heldInputForTesting.isEmpty)          // nothing queued in full
        var five = Data(); for _ in 0..<5 { five.append(up) }
        #expect(transport.deferredWheelForTesting == five)       // capped at +8, then -3
        // Acks drain the outstanding frames; the merged steps go out once.
        while let sequence = transport.pendingInputSequencesForTesting.first {
            transport.acknowledgeInput(sequence: sequence, pane: "p")
        }
        #expect(writer.inputs.count == cap + 1 && writer.inputs[cap].dropFirst(24) == five)
    }
}
