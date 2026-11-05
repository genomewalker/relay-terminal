import AppKit
import Foundation
@testable import GhosttyTerminal
import Testing
@testable import Relay

// Settings-CPU remediation (review e03f15f7): the active-screen observation is
// tri-state, its sample is state, rows, state, a changing screen vetoes every
// admission, and the admitted screen is re-verified at the transport write.

private final class FenceFrameWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [Data] = []
    func write(type: RelayWireType, payload: Data) throws { record(type, payload) }
    func writeAsync(type: RelayWireType, payload: Data) { record(type, payload) }
    private func record(_ type: RelayWireType, _ payload: Data) {
        guard type == .inputV2 || type == .input || type == .automationInputV2 else { return }
        lock.lock(); payloads.append(payload); lock.unlock()
    }
    /// Input bytes, without the inputV2 header.
    var inputs: [Data] {
        lock.lock(); defer { lock.unlock() }
        return payloads.map { Data($0.dropFirst(24)) }
    }
}

private func fenceTransport(_ writer: FenceFrameWriter, profile: ConnectionProfile, paneID: UUID) -> RelayRemoteTransport {
    RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: paneID,
        capabilities: ["input_ack_v1", "input_lease_v1", "automation_input_v1"], controlGranted: true)
}

/// A Claude screen whose prompt maintenance reads as empty (faint prediction).
private let emptyClaudeScreen = "\u{1b}[?2004h\u{1b}[2J\u{1b}[Howned transcript\r\n❯ \u{1b}[2mCheck this change\u{1b}[22m\r\n" +
    "────────────────\r\n⏵⏵ bypass permissions on · update installed\r\n"

@MainActor
private func attach(_ view: NSView) -> NSWindow {
    _ = NSApplication.shared
    view.frame = NSRect(x: 0, y: 0, width: 900, height: 440)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    return window
}

/// Waits until the session's screen is stable and shows `marker`.
@MainActor
private func settledKey(_ session: InMemoryTerminalSession, showing marker: String,
                        settled: () -> Bool = { true }) async throws -> RelayActiveScreenCache.Key {
    for _ in 0..<500 {
        await Task.detached { session.waitForPendingOutput() }.value
        if case .stable(let key) = session.activeScreenSample(), key.rows.joined().contains(marker), settled() {
            return key
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CancellationError()
}

// MARK: - The settle decision, exhaustively over its inputs

@Suite("Live-screen settle decision")
struct RelayLiveScreenSettleTests {
    @Test("Settled only with no output phase open, nothing in transit, nothing queued and the admitted screen still sampled")
    func settleDecision() {
        let state = InMemoryTerminalScreenState(surfaceGeneration: 1, mutations: 3, mutationInFlight: false,
                                                columns: 80, rows: 24)
        let admitted = RelayActiveScreenCache.Key(state: state, rows: ["❯ "])
        let other = RelayActiveScreenCache.Key(state: state, rows: ["❯ x"])
        let samples: [RelayActiveScreenCache.Sample] = [.stable(admitted), .stable(other), .unstable, .noSurface]
        var checked = 0
        for phaseOpen in [false, true] {
            for transit in [0, 1] {
                for pending in [0, 1] {
                    for sample in samples {
                        var sampled = false
                        let settled = TerminalIOBridge.liveScreenIsSettled(outputPhaseOpen: phaseOpen,
                            displayBytesInTransit: transit, sessionPendingBytes: { pending },
                            sample: { sampled = true; return sample }, expected: admitted)
                        #expect(settled == (!phaseOpen && transit == 0 && pending == 0 && sample == .stable(admitted)))
                        #expect(sampled == (!phaseOpen && transit == 0 && pending == 0))
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 32)
    }
}

// MARK: - Real surfaces: interleavings at the sample and dump boundaries

private final class Gate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func waitEntered() { entered.wait() }
}

@MainActor @Suite("Active-screen sampling on real surfaces", .serialized)
struct RelayActiveScreenInterleavingTests {
    private func session() async throws -> (InMemoryTerminalSession, AppTerminalView, NSWindow) {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let view = AppTerminalView(frame: .zero)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), context: .window)
        view.controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
        let window = attach(view)
        view.fitToSize()
        await Task.yield()
        view.fitToSize()
        session.receive("\u{1b}[2J\u{1b}[H❯ first\r\n")
        _ = try await settledKey(session, showing: "first")
        return (session, view, window)
    }

    @Test("Output between the first state read and the rows read makes the sample unstable", .timeLimit(.minutes(2)))
    func outputBeforeRows() async throws {
        let (session, _, window) = try await session()
        defer { window.contentView = nil }
        let sample = RelayActiveScreenCache.sample(state: { session.screenState }, rows: {
            session.receive("❯ second\r\n")
            session.waitForPendingOutput()
            return session.readViewportRows()
        })
        #expect(sample == .unstable)
    }

    @Test("Output between the rows read and the second state read makes the sample unstable", .timeLimit(.minutes(2)))
    func outputBeforeSecondState() async throws {
        let (session, _, window) = try await session()
        defer { window.contentView = nil }
        var states = 0
        let sample = RelayActiveScreenCache.sample(state: {
            states += 1
            if states == 2 { session.receive("❯ second\r\n"); session.waitForPendingOutput() }
            return session.screenState
        }, rows: { session.readViewportRows() })
        #expect(sample == .unstable)
    }

    @Test("A binding action or output during the dump makes the read unstable", .timeLimit(.minutes(2)))
    func changeDuringDump() async throws {
        let (session, view, window) = try await session()
        defer { window.contentView = nil }
        var cache = RelayActiveScreenCache()
        // libghostty applies a binding action asynchronously; wait inside the
        // dump until it has changed the rows, so it lands during the dump.
        let binding = cache.read(sample: { session.activeScreenSample() }, dump: {
            let screen = session.readActiveScreenVT()
            let before = session.readViewportRows()
            _ = view.performBindingAction("clear_screen")
            var changed = false
            for _ in 0..<500 where !changed {
                session.waitForPendingOutput()
                changed = session.readViewportRows() != before
                if !changed { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            }
            #expect(changed, "clear_screen must change the rows")
            return screen
        })
        #expect(binding == .unstable)
        #expect(cache.entry == nil)
        let output = cache.read(sample: { session.activeScreenSample() }, dump: {
            let screen = session.readActiveScreenVT()
            session.receive("❯ third\r\n")
            session.waitForPendingOutput()
            return screen
        })
        #expect(output == .unstable)
        let quiet = cache.read(sample: { session.activeScreenSample() }, dump: { session.readActiveScreenVT() })
        #expect(quiet.screen == session.readActiveScreenVT())
        #expect(quiet.key.map { .stable($0) } == session.activeScreenSample())
    }
}

@Suite("Active-screen sampling with a mutation in flight", .serialized)
struct RelayActiveScreenInFlightTests {
    @Test("A mutation in flight at the first sample or the second gives no screen", .timeLimit(.minutes(1)))
    func inFlightAtEitherSample() async throws {
        let gate = Gate()
        let access = InMemoryTerminalSurfaceAccess(write: { _, _ in
            gate.entered.signal()
            gate.release.wait()
        }, processExit: { _, _, _ in })
        // The fake write never dereferences the surface.
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 0x1000))
        defer { access.setSurface(nil) }
        func sample() -> RelayActiveScreenCache.Sample {
            RelayActiveScreenCache.sample(state: { access.screenState }, rows: { ["❯ "] })
        }
        var cache = RelayActiveScreenCache()

        access.enqueueWrite(Data("a".utf8))
        await Task.detached { gate.waitEntered() }.value
        var dumped = false
        #expect(cache.read(sample: sample, dump: { dumped = true; return "screen" }) == .unstable)
        #expect(!dumped, "an in-flight first sample is refused before the dump")
        gate.release.signal()
        await Task.detached { access.waitForPendingOutput() }.value

        let second = cache.read(sample: sample, dump: {
            access.enqueueWrite(Data("b".utf8))
            gate.waitEntered()
            return "screen"
        })
        #expect(second == .unstable)
        #expect(cache.entry == nil)
        gate.release.signal()
        await Task.detached { access.waitForPendingOutput() }.value
        if case .screen = cache.read(sample: sample, dump: { "screen" }) {} else {
            Issue.record("a quiet surface must be readable again")
        }
    }
}

// MARK: - The send fence at the transport boundary

@MainActor @Suite("Live-screen send fence", .serialized)
struct RelayLiveScreenSendFenceTests {
    @Test("Output after admission refuses both input paths until a fresh admission", .timeLimit(.minutes(2)))
    func outputAfterAdmissionIsRefused() async throws {
        let profile = ConnectionProfile(name: "Fence fixture", host: "owned-fence.invalid")
        let paneID = UUID(), writer = FenceFrameWriter()
        let transport = fenceTransport(writer, profile: profile, paneID: paneID)
        let io = TerminalIOBridge()
        io.installTransport(transport)
        defer { _ = io.removeTransport(); transport.detach() }
        let view = AppTerminalView(frame: .zero)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io.session), context: .window)
        view.controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
        let window = attach(view)
        defer { window.contentView = nil }
        view.fitToSize()
        #expect(io.receive(Data("❯ before\r\n".utf8)))
        let admitted = try await settledKey(io.session, showing: "before")
        let lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))

        // Output received after admission: wherever it is in the pipeline
        // (display buffer, session queue, parse, parsed), the fence refuses.
        #expect(io.receive(Data("❯ after\r\n".utf8)))
        #expect(!io.sendPromptEditorControlInput(Data("x".utf8), expectedControlLease: lease,
                                                  expectedLiveScreen: admitted, automation: true))
        #expect(!io.sendUserInput(Data("y".utf8), expectedLiveScreen: admitted, expectedMaintenanceScreen: nil))
        let fresh = try await settledKey(io.session, showing: "after")
        #expect(fresh != admitted)
        #expect(!io.sendPromptEditorControlInput(Data("x".utf8), expectedControlLease: lease,
                                                  expectedLiveScreen: admitted, automation: true))
        #expect(!io.sendUserInput(Data("y".utf8), expectedLiveScreen: admitted, expectedMaintenanceScreen: nil))
        #expect(writer.inputs.isEmpty)

        // The same transport accepts once the admission matches the screen.
        #expect(io.sendPromptEditorControlInput(Data("ok".utf8), expectedControlLease: lease,
                                                 expectedLiveScreen: fresh, automation: true))
        #expect(writer.inputs == [Data("ok".utf8)])
    }

    @Test("The fenced user-input path sends when the admitted screen is current", .timeLimit(.minutes(2)))
    func currentScreenSendsUserInput() async throws {
        let profile = ConnectionProfile(name: "Fence fixture", host: "owned-fence.invalid")
        let paneID = UUID(), writer = FenceFrameWriter()
        let transport = fenceTransport(writer, profile: profile, paneID: paneID)
        let io = TerminalIOBridge()
        io.installTransport(transport)
        defer { _ = io.removeTransport(); transport.detach() }
        let view = AppTerminalView(frame: .zero)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io.session), context: .window)
        view.controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
        let window = attach(view)
        defer { window.contentView = nil }
        view.fitToSize()
        #expect(io.receive(Data("❯ idle\r\n".utf8)))
        let admitted = try await settledKey(io.session, showing: "idle")
        #expect(io.sendUserInput(Data("go".utf8), expectedLiveScreen: admitted, expectedMaintenanceScreen: nil))
        #expect(writer.inputs == [Data("go".utf8)])
    }
}

// MARK: - Per-caller admissions on a real runtime

/// A started Claude pane on a fake transport, its view on a real surface.
@MainActor
private final class RuntimeFixture {
    let pane: PaneModel
    let writer = FenceFrameWriter()
    let transport: RelayRemoteTransport
    let window: NSWindow

    init(provider: String = "claude", screen: String = emptyClaudeScreen, marker: String = "Check this change") async throws {
        pane = PaneModel(profile: .sshConfigHost("owned-fence.invalid"))
        if provider != "shell" {
            pane.receivedHarnessIdentity(AgentHarnessIdentity(paneID: pane.id, role: "harness", provider: provider,
                processes: [.init(provider: provider, pid: 77, processStart: "kernel:123")], reason: nil))
        }
        transport = fenceTransport(writer, profile: pane.profile, paneID: pane.id)
        // Started before the view joins a window, so no real transport starts.
        pane.runtime.startForTesting(transport: transport)
        pane.connectionState = .connected
        window = attach(pane.runtime.view)
        pane.runtime.view.fitToSize()
        // The window's first layout opens a viewport transition (any frame
        // change of a presented relay pane does), and r4 refuses sends while
        // it is open. Let the pane settle before its screen arrives: no open
        // phase, and a viewport unchanged for 300 ms.
        let io = pane.runtime.ioForTesting
        var viewport = io.currentViewport, stableSince = Date()
        let deadline = Date().addingTimeInterval(10)
        while (io.outputPhaseOpenNow || Date().timeIntervalSince(stableSince) < 0.3), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            let now = io.currentViewport
            if now != viewport || io.outputPhaseOpenNow { viewport = now; stableSince = Date() }
        }
        try #require(!io.outputPhaseOpenNow, "the fixture's pane settles")
        // A recorded replay buffer at a positive remote sequence lets a
        // hidden-pane proof be prepared if allowed (as in
        // RelayPromptControlTransportTests; the pane is removed on close).
        _ = pane.runtime.ioForTesting.restoreSnapshot(paneID: pane.id)
        #expect(pane.runtime.ioForTesting.receive(Data(screen.utf8), remoteSequence: 100))
        _ = try await settledKey(io.session, showing: marker)
        try #require(!io.outputPhaseOpenNow)
    }

    func close() {
        pane.runtime.activeScreenSampleForTesting = nil
        window.contentView = nil
        _ = pane.runtime.ioForTesting.removeTransport()
        transport.detach()
        TerminalSnapshotStore.shared.remove(paneID: pane.id)
    }

    var probe: RelayAgentMaintenanceProbe {
        get throws {
            let id = pane.id.uuidString.lowercased()
            let json = #"{"version":1,"pane_id":"\#(id)","provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"quiet","background_work":false,"subagent_work":false,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"\#(id)","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"resume_command":"/home/test/.local/bin/claude --resume exact-session","move_command":"/home/test/.local/bin/claude --resume exact-session"}"#
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        }
    }

    /// A stable key the live screen does not show: admitted, then stale at the write.
    var staleKey: RelayActiveScreenCache.Key {
        get throws {
            guard case .stable(let live) = pane.runtime.ioForTesting.session.activeScreenSample() else {
                throw CancellationError()
            }
            return RelayActiveScreenCache.Key(state: live.state, rows: live.rows + ["stale"])
        }
    }
}

@MainActor @Suite("Screen admissions per caller", .serialized)
struct RelayScreenAdmissionCallerTests {
    @Test("Agent maintenance: a changing screen refuses; a stale admission is refused at the write; a current one sends",
          .timeLimit(.minutes(2)))
    func maintenanceCommand() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime
        let proof = try fixture.probe
        let revision = fixture.pane.agentInputRevision
        #expect(runtime.observeActiveScreen().screen != nil)
        #expect(runtime.agentMaintenancePromptIsEmpty)

        runtime.activeScreenSampleForTesting = { .unstable }
        #expect(runtime.observeActiveScreen() == .unstable)
        #expect(!runtime.agentMaintenancePromptIsEmpty)
        #expect(!runtime.agentMaintenanceTerminalPromptIsEmpty)
        #expect(!runtime.agentMaintenanceTerminalPromptHasTypedText)
        #expect(runtime.agentMaintenanceTerminalPromptBlocker == "the screen is changing, so its prompt cannot be read yet")
        #expect(!runtime.sendAgentMaintenanceCommand("/exit", proof: proof, inputRevision: revision))

        let stale = try fixture.staleKey
        runtime.activeScreenSampleForTesting = { .stable(stale) }
        #expect(runtime.agentMaintenancePromptIsEmpty, "admission passes on the stale key")
        #expect(!runtime.sendAgentMaintenanceCommand("/exit", proof: proof, inputRevision: revision))
        #expect(fixture.writer.inputs.isEmpty)

        runtime.activeScreenSampleForTesting = nil
        #expect(runtime.sendAgentMaintenanceCommand("/exit", proof: proof, inputRevision: revision))
        #expect(fixture.writer.inputs.count == 1)
    }

    @Test("Claude settings overlay: a changing screen never reads as the overlay", .timeLimit(.minutes(2)))
    func overlay() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime
        runtime.activeScreenSampleForTesting = { .unstable }
        #expect(!runtime.agentMaintenanceClaudeSettingsOverlay)
        #expect(!runtime.dismissClaudeSettingsOverlay(proof: try fixture.probe,
                                                      inputRevision: fixture.pane.agentInputRevision))
        #expect(fixture.writer.inputs.isEmpty)
    }

    @Test("Account move and pane health: a changing screen is refused and no replay proof is prepared",
          .timeLimit(.minutes(2)))
    func accountMoveAndPrepare() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime
        // The replay token names the viewport. Let the window's first layout
        // settle (unchanged for 300 ms) so a resize can't make it stale.
        var viewport = runtime.ioForTesting.currentViewport, stableSince = Date()
        let deadline = Date().addingTimeInterval(10)
        while Date().timeIntervalSince(stableSince) < 0.3, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            let now = runtime.ioForTesting.currentViewport
            if now != viewport { viewport = now; stableSince = Date() }
        }
        #expect(runtime.accountMoveScreenRefusal() == nil)
        runtime.activeScreenSampleForTesting = { .unstable }
        #expect(runtime.accountMoveScreenRefusal() == "the screen of “\(fixture.pane.displayName)” is changing")
        #expect(runtime.ioForTesting.maintenanceScreenSnapshot() != nil, "a replay proof is available to prepare")
        await runtime.prepareAgentMaintenancePromptProof()
        #expect(runtime.screenFence(.noSurface) == nil,
                "a live surface never prepares the hidden-pane proof, and no proof means no fence")
        #expect(runtime.screenFence(.unstable) == nil)
        // Positive control in the same state: with no surface sampled, the
        // proof is prepared, so the nil above comes from the veto.
        runtime.activeScreenSampleForTesting = { .noSurface }
        await runtime.prepareAgentMaintenancePromptProof()
        #expect(runtime.screenFence(.noSurface) != nil, "the replay proof is preparable in this fixture")
        runtime.activeScreenSampleForTesting = nil
    }

    @Test("Assistant approved text: a changing screen refuses; a stale admission is refused at the write",
          .timeLimit(.minutes(2)))
    func assistantApprovedText() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime
        let revision = fixture.pane.agentInputRevision
        runtime.activeScreenSampleForTesting = { .unstable }
        #expect(await runtime.sendAssistantApprovedText("hello", expectedInputRevision: revision) != .sent)
        let proof = await runtime.assistantPromptProof()
        #expect(proof?.empty == false)

        let stale = try fixture.staleKey
        runtime.activeScreenSampleForTesting = { .stable(stale) }
        #expect(await runtime.sendAssistantApprovedText("hello", expectedInputRevision: revision) == .unavailable)
        #expect(fixture.writer.inputs.isEmpty)

        runtime.activeScreenSampleForTesting = nil
        #expect(await runtime.sendAssistantApprovedText("hello", expectedInputRevision: revision) == .sent)
        #expect(fixture.writer.inputs.count == 1)
    }

    @Test("Retained shell: a changing screen vetoes the OSC 133 and replay branches", .timeLimit(.minutes(2)))
    func retainedShell() async throws {
        // OSC 133 marks an input start with nothing echoed: io.shellInputIsEmpty.
        let fixture = try await RuntimeFixture(provider: "shell",
            screen: "\u{1b}[2J\u{1b}[H\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}", marker: "$")
        defer { fixture.close() }
        let runtime = fixture.pane.runtime
        let revision = fixture.pane.agentInputRevision
        #expect(fixture.pane.runtime.ioForTesting.shellInputIsEmpty)
        runtime.activeScreenSampleForTesting = { .unstable }
        #expect(await runtime.assistantPromptProof()?.empty == false)
        #expect(await runtime.sendAssistantApprovedText("ls", expectedInputRevision: revision) != .sent)
        #expect(fixture.writer.inputs.isEmpty)
        runtime.activeScreenSampleForTesting = nil
        #expect(await runtime.assistantPromptProof()?.empty == true)
    }
}


// MARK: - Every display producer and output phase is ordered with the fence
//
// r4 correction of an unsafe r3 expectation: r3's viewport-transition and
// replay-commit producer tests buffered output *before* the send and expected
// the send to succeed. Output already received but not yet shown must refuse
// the send (review b4a40a04). Here nothing is pending when the send is
// admitted; each phase-shaped producer runs its whole phase (open, receive,
// close) inside the window, and the pending cases are refusal tests below.

/// Mutable state shared with the fence hook and the producer thread.
private final class WindowProbe: @unchecked Sendable {
    var fired = false
    var landed = false
    let done = DispatchSemaphore(value: 0)
}

/// Arms the hook that runs inside outputOrderingLock right after the send's
/// final fence check. It starts `producer` on another thread and, for 1 s,
/// watches for any of its effects: display bytes in transit, a changed replay
/// buffer, or an opened replay or viewport-transition phase. A producer
/// ordered with the fence cannot get in, so nothing lands until the input has
/// been recorded and the lock released.
@MainActor
private func armProducerWindow(_ io: TerminalIOBridge, producer: @escaping @Sendable () -> Void) -> WindowProbe {
    let probe = WindowProbe()
    io.fenceCheckedForTesting = { [io] in
        guard !probe.fired else { return }
        probe.fired = true
        let revision = io.snapshotRevisionForTesting
        DispatchQueue.global(qos: .userInitiated).async { producer(); probe.done.signal() }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if io.displayBytesInTransitForTesting > 0 || io.snapshotRevisionForTesting != revision
                || io.outputPhaseOpenNow {
                probe.landed = true
                break
            }
            usleep(2_000)
        }
    }
    return probe
}

private func waitDone(_ probe: WindowProbe) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: probe.done.wait(timeout: .now() + 10) == .success)
        }
    }
}

/// A live pane: real surface, fake transport, settled "before" screen.
@MainActor
private struct LiveBridge {
    let io: TerminalIOBridge
    let writer: FenceFrameWriter
    let transport: RelayRemoteTransport
    let window: NSWindow
    let lease: RelayPromptEditorControlLease
    let paneID: UUID

    init() async throws {
        let profile = ConnectionProfile(name: "Producer fixture", host: "owned-producer.invalid")
        paneID = UUID(); writer = FenceFrameWriter()
        transport = fenceTransport(writer, profile: profile, paneID: paneID)
        io = TerminalIOBridge()
        io.installTransport(transport)
        let view = AppTerminalView(frame: .zero)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io.session), context: .window)
        view.controller = TerminalController(configuration: RelayPreferences.shared.terminalConfiguration())
        window = attach(view)
        view.fitToSize()
        _ = io.restoreSnapshot(paneID: paneID)
        #expect(io.receive(Data("❯ before\r\n".utf8), remoteSequence: 100))
        lease = try #require(io.promptEditorControlLease(paneID: paneID, hostID: profile.id))
    }

    func admitted(showing marker: String = "before") async throws -> RelayActiveScreenCache.Key {
        try await settledKey(io.session, showing: marker, settled: {
            io.displayBytesInTransitForTesting == 0 && !io.outputPhaseOpenNow
        })
    }

    func send(_ key: RelayActiveScreenCache.Key) -> Bool {
        io.sendPromptEditorControlInput(Data("go".utf8), expectedControlLease: lease,
                                        expectedLiveScreen: key, automation: true)
    }

    func close() {
        io.fenceCheckedForTesting = nil
        window.contentView = nil
        _ = io.removeTransport(); transport.detach()
        TerminalSnapshotStore.shared.remove(paneID: paneID)
    }
}

/// A hidden pane: no surface, a recorded replay buffer at sequence 100.
@MainActor
private struct HiddenBridge {
    let io: TerminalIOBridge
    let writer: FenceFrameWriter
    let transport: RelayRemoteTransport
    let paneID: UUID
    let token: TerminalIOBridge.MaintenanceScreenToken

    init() throws {
        let profile = ConnectionProfile(name: "Hidden producer fixture", host: "owned-hidden.invalid")
        paneID = UUID(); writer = FenceFrameWriter()
        transport = fenceTransport(writer, profile: profile, paneID: paneID)
        io = TerminalIOBridge()
        io.installTransport(transport)
        _ = io.restoreSnapshot(paneID: paneID)
        #expect(io.receive(Data("\u{1b}[2J\u{1b}[H$ \r\n".utf8), remoteSequence: 100))
        // The probe reads bytes in transit as a landed producer, so start
        // from a drained display path.
        let deadline = Date().addingTimeInterval(5)
        while io.displayBytesInTransitForTesting > 0, Date() < deadline { usleep(2_000) }
        try #require(io.displayBytesInTransitForTesting == 0)
        token = try #require(io.maintenanceScreenSnapshot()?.token)
    }

    func send(_ token: TerminalIOBridge.MaintenanceScreenToken) -> Bool {
        io.sendUserInput(Data("go".utf8), expectedLiveScreen: nil, expectedMaintenanceScreen: token)
    }

    func close() {
        io.fenceCheckedForTesting = nil
        _ = io.removeTransport(); transport.detach()
        TerminalSnapshotStore.shared.remove(paneID: paneID)
    }
}

/// The whole replay phase, as the runtime drives it: open, buffered output,
/// commit (asynchronous; the producer waits for it).
private func replayPhase(_ io: TerminalIOBridge, _ text: String) {
    io.beginReplay()
    _ = io.receive(Data(text.utf8), remoteSequence: 200)
    io.endReplay()
    let deadline = Date().addingTimeInterval(5)
    while io.outputPhaseOpenNow, Date() < deadline { usleep(2_000) }
}

/// The whole viewport transition: open, sequence-zero replacement, close.
private func transitionPhase(_ io: TerminalIOBridge, _ text: String) {
    io.beginViewportTransition()
    _ = io.receive(Data(text.utf8))
    io.finishViewportTransition(rows: 24)
}

@MainActor @Suite("Display producers and output phases are ordered with the live-screen fence", .serialized)
struct RelayLiveFenceProducerTests {
    /// Admits the settled screen with nothing pending, lets `producer` race
    /// the window between the final check and the transport, and requires
    /// that nothing landed there.
    private func check(_ b: LiveBridge, producer: @escaping @Sendable () -> Void) async throws {
        let admitted = try await b.admitted()
        let probe = armProducerWindow(b.io, producer: producer)
        #expect(b.send(admitted))
        #expect(probe.fired)
        #expect(!probe.landed, "a display producer landed between the final fence check and the transport")
        #expect(b.writer.inputs == [Data("go".utf8)])
        #expect(await waitDone(probe), "the producer runs once the lock is released (no deadlock)")
    }

    @Test("An inline image enqueued during the window waits for the send", .timeLimit(.minutes(1)))
    func inlineImage() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        try await check(b) { [io = b.io] in io.receiveInlineImageOrdered(Data(repeating: 7, count: 64), imageID: 9) }
    }

    @Test("A whole viewport transition started during the window waits for the send", .timeLimit(.minutes(1)))
    func viewportTransition() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        try await check(b) { [io = b.io] in transitionPhase(io, "❯ resized\r\n") }
    }

    @Test("A whole replay started during the window waits for the send", .timeLimit(.minutes(1)))
    func replayCommit() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        try await check(b) { [io = b.io] in replayPhase(io, "\u{1b}[2J\u{1b}[H❯ replayed\r\n") }
    }

    @Test("A snapshot restore during the window waits for the send", .timeLimit(.minutes(1)))
    func restore() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        let other = UUID()
        defer { TerminalSnapshotStore.shared.remove(paneID: other) }
        TerminalSnapshotStore.shared.saveSynchronously(Data("\u{1b}[2J\u{1b}[H❯ restored\r\n".utf8), paneID: other,
            viewport: b.io.currentViewport, remoteSequence: 300)
        try await check(b) { [io = b.io] in _ = io.restoreSnapshot(paneID: other) }
    }

    @Test("Opening a viewport transition during the window waits for the send", .timeLimit(.minutes(1)))
    func transitionOpener() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        try await check(b) { [io = b.io] in io.beginViewportTransition() }
    }

    @Test("Opening a replay during the window waits for the send", .timeLimit(.minutes(1)))
    func replayOpener() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        try await check(b) { [io = b.io] in io.beginReplay() }
    }

    @Test("Re-entering a replay at the explicit boundary during the window waits for the send", .timeLimit(.minutes(1)))
    func explicitBoundaryOpener() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        try await check(b) { [io = b.io] in io.setExplicitReplayBoundary(true) }
    }
}

@MainActor @Suite("Replay-buffer producers and output phases are ordered with the hidden-pane fence", .serialized)
struct RelayReplayFenceProducerTests {
    private func check(_ b: HiddenBridge, producer: @escaping @Sendable () -> Void) async {
        let probe = armProducerWindow(b.io, producer: producer)
        #expect(b.send(b.token))
        #expect(probe.fired)
        #expect(!probe.landed, "a replay-buffer producer landed between the final fence check and the transport")
        #expect(b.writer.inputs == [Data("go".utf8)])
        #expect(await waitDone(probe))
    }

    @Test("An output reset during the window waits for the send", .timeLimit(.minutes(1)))
    func outputReset() async throws {
        let b = try HiddenBridge(); defer { b.close() }
        await check(b) { [io = b.io] in io.resetRemoteSequence() }
        #expect(!b.io.maintenanceScreenIsCurrent(b.token), "the reset lands after the send")
    }

    @Test("A snapshot restore during the window waits for the send", .timeLimit(.minutes(1)))
    func restore() async throws {
        let b = try HiddenBridge(); defer { b.close() }
        let other = UUID()
        defer { TerminalSnapshotStore.shared.remove(paneID: other) }
        TerminalSnapshotStore.shared.saveSynchronously(Data("\u{1b}[2J\u{1b}[H❯ restored\r\n".utf8), paneID: other,
            viewport: b.io.currentViewport, remoteSequence: 300)
        await check(b) { [io = b.io] in _ = io.restoreSnapshot(paneID: other) }
    }

    @Test("A whole viewport transition started during the window waits for the send", .timeLimit(.minutes(1)))
    func viewportTransition() async throws {
        let b = try HiddenBridge(); defer { b.close() }
        await check(b) { [io = b.io] in transitionPhase(io, "$ resized\r\n") }
        #expect(!b.io.maintenanceScreenIsCurrent(b.token), "the transition lands after the send")
    }

    @Test("A whole replay started during the window waits for the send", .timeLimit(.minutes(1)))
    func replay() async throws {
        let b = try HiddenBridge(); defer { b.close() }
        await check(b) { [io = b.io] in replayPhase(io, "\u{1b}[2J\u{1b}[H$ replayed\r\n") }
        #expect(!b.io.maintenanceScreenIsCurrent(b.token), "the replay lands after the send")
    }

    @Test("Opening a viewport transition during the window waits for the send", .timeLimit(.minutes(1)))
    func transitionOpener() async throws {
        let b = try HiddenBridge(); defer { b.close() }
        await check(b) { [io = b.io] in io.beginViewportTransition() }
    }

    @Test("Opening a replay during the window waits for the send", .timeLimit(.minutes(1)))
    func replayOpener() async throws {
        let b = try HiddenBridge(); defer { b.close() }
        await check(b) { [io = b.io] in io.beginReplay() }
    }

    @Test("While a replay is open no replay token is current, so a commit cannot race a hidden-pane send", .timeLimit(.minutes(1)))
    func replayOpenRefuses() async throws {
        let b = try HiddenBridge(); defer { b.close() }
        b.io.setExplicitReplayBoundary(true)
        b.io.beginReplay()
        b.io.receive(Data("\u{1b}[2J\u{1b}[H$ replayed\r\n".utf8), remoteSequence: 200)
        #expect(b.io.maintenanceScreenSnapshot()?.token == nil)
        #expect(!b.send(b.token))
        b.io.endReplay()
        // After the commit the replay generation has moved: the old token stays stale.
        let deadline = Date().addingTimeInterval(5)
        while b.io.maintenanceScreenSnapshot() == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!b.io.maintenanceScreenIsCurrent(b.token))
        #expect(!b.send(b.token))
        #expect(b.writer.inputs.isEmpty)
    }

    @Test("The replay token names the bytes: a closed same-sequence replacement makes it stale", .timeLimit(.minutes(1)))
    func tokenNamesBytes() throws {
        let b = try HiddenBridge(); defer { b.close() }
        transitionPhase(b.io, "$ resized\r\n")
        #expect(!b.io.maintenanceScreenIsCurrent(b.token))
        #expect(!b.send(b.token))
        #expect(b.writer.inputs.isEmpty)
    }

    @Test("A fenced send with neither a live key nor a replay token is refused", .timeLimit(.minutes(1)))
    func noFenceRefused() throws {
        let b = try HiddenBridge(); defer { b.close() }
        #expect(!b.io.sendUserInput(Data("go".utf8), expectedLiveScreen: nil, expectedMaintenanceScreen: nil))
        #expect(b.writer.inputs.isEmpty)
    }
}

// MARK: - r4 (review b4a40a04): output received but not yet shown refuses the send

@MainActor @Suite("Output pending before display refuses the live fence", .serialized)
struct RelayLivePendingOutputTests {
    // The first two are d415f009's negative probes (negative-probes.patch
    // 9c821700), verbatim apart from the shared fixture.
    @Test("REVIEW: received viewport-transition bytes must block the live fence", .timeLimit(.minutes(1)))
    func reviewBufferedViewportMustRefuse() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        let admitted = try await b.admitted()
        b.io.beginViewportTransition()
        #expect(b.io.receive(Data("danger after admission\r\n".utf8)))
        #expect(!b.send(admitted))
        #expect(b.writer.inputs.isEmpty)
    }

    @Test("REVIEW: buffered replay bytes must block the live fence", .timeLimit(.minutes(1)))
    func reviewBufferedReplayMustRefuse() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        let admitted = try await b.admitted()
        b.io.setExplicitReplayBoundary(true)
        b.io.beginReplay()
        _ = b.io.receive(Data("danger after admission\r\n".utf8), remoteSequence: 200)
        #expect(!b.send(admitted))
        #expect(b.writer.inputs.isEmpty)
    }

    @Test("An open viewport transition refuses even before any byte is buffered; a fresh admission after it sends",
          .timeLimit(.minutes(1)))
    func openTransitionRefusesThenFreshAdmissionSends() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        let admitted = try await b.admitted()
        b.io.beginViewportTransition()
        #expect(!b.send(admitted))
        #expect(b.io.receive(Data("❯ resized\r\n".utf8)))
        #expect(!b.send(admitted))
        b.io.finishViewportTransition(rows: 24)
        #expect(b.writer.inputs.isEmpty)
        #expect(!b.send(admitted), "the admitted screen predates the transition's output")
        // Positive control: the refusals came from the pending phase, not a dead fence.
        let fresh = try await b.admitted(showing: "resized")
        #expect(b.send(fresh))
        #expect(b.writer.inputs == [Data("go".utf8)])
    }

    @Test("An open replay refuses even before any byte is buffered, and while its commit is in flight; a fresh admission after it sends",
          .timeLimit(.minutes(1)))
    func openReplayRefusesThenFreshAdmissionSends() async throws {
        let b = try await LiveBridge(); defer { b.close() }
        let admitted = try await b.admitted()
        b.io.setExplicitReplayBoundary(true)
        b.io.beginReplay()
        #expect(!b.send(admitted))
        _ = b.io.receive(Data("\u{1b}[2J\u{1b}[H❯ replayed\r\n".utf8), remoteSequence: 200)
        b.io.endReplay()
        // Until the asynchronous commit has run, the phase stays open.
        #expect(!b.send(admitted))
        #expect(b.writer.inputs.isEmpty)
        let fresh = try await b.admitted(showing: "replayed")
        #expect(b.send(fresh))
        #expect(b.writer.inputs == [Data("go".utf8)])
    }
}

@MainActor @Suite("Output pending before display refuses the hidden-pane fence", .serialized)
struct RelayHiddenPendingOutputTests {
    @Test("Sequence-zero output buffered in an open transition: no token is current and the send is refused",
          .timeLimit(.minutes(1)))
    func bufferedSequenceZeroRefuses() throws {
        let b = try HiddenBridge(); defer { b.close() }
        b.io.beginViewportTransition()
        #expect(!b.send(b.token), "an open transition refuses before any byte")
        #expect(b.io.receive(Data("danger after admission\r\n".utf8)))
        #expect(b.io.maintenanceScreenSnapshot()?.token == nil)
        #expect(!b.send(b.token))
        b.io.finishViewportTransition(rows: 24)
        #expect(!b.send(b.token), "after the transition the bytes are in the buffer, and the token is stale")
        #expect(b.writer.inputs.isEmpty)
        // Positive control: a fresh token sends.
        let fresh = try #require(b.io.maintenanceScreenSnapshot()?.token)
        #expect(b.send(fresh))
        #expect(b.writer.inputs == [Data("go".utf8)])
    }

    @Test("An empty transition opened and closed leaves the token current", .timeLimit(.minutes(1)))
    func emptyTransitionKeepsToken() throws {
        let b = try HiddenBridge(); defer { b.close() }
        b.io.beginViewportTransition()
        #expect(!b.send(b.token))
        b.io.finishViewportTransition(rows: 24)
        #expect(b.send(b.token), "nothing was received, so the screen the token names is still the screen")
        #expect(b.writer.inputs == [Data("go".utf8)])
    }
}

/// Exhaustive bounded check on the real hidden-pane bridge: every sequence of
/// up to `depth` operations over receives (sequenced and sequence-zero),
/// transition and replay openers/closers, output reset and token captures.
/// Safety after every step: a token captured before any received byte (or
/// reset, or replay) is never current afterwards, and no token is offered
/// while a phase is open.
@MainActor @Suite("Hidden-pane token bounded check", .serialized)
struct RelayHiddenTokenBoundedTests {
    enum Op: CaseIterable, CustomStringConvertible {
        case receiveSequenced, receiveZero, beginTransition, finishTransition, beginReplay, reset, take
        var description: String { "\(self)".replacingOccurrences(of: "Op.", with: "") }
    }

    static let depth = 5

    @Test("Exhaustive bounded check: received output never leaves an earlier token current", .timeLimit(.minutes(10)))
    func boundedTokenCheck() async throws {
        let ops = Op.allCases
        var sequences = 0, steps = 0, currentAtEnd = 0
        for length in 0...Self.depth {
            let count = Int(pow(Double(ops.count), Double(length)))
            for index in 0..<count {
                var sequence: [Op] = [], rest = index
                for _ in 0..<length { sequence.append(ops[rest % ops.count]); rest /= ops.count }
                let b = try HiddenBridge()
                defer { b.close() }
                // Tokens with whether output (or a reset/replay) has happened since.
                var tokens: [(TerminalIOBridge.MaintenanceScreenToken, Bool)] = [(b.token, false)]
                var sequence100 = UInt64(100)
                for (position, op) in sequence.enumerated() {
                    var changes = false
                    switch op {
                    case .receiveSequenced:
                        sequence100 += 1
                        changes = true
                        _ = b.io.receive(Data("s\(sequence100)\r\n".utf8), remoteSequence: sequence100)
                    case .receiveZero:
                        changes = true
                        _ = b.io.receive(Data("z\r\n".utf8))
                    case .beginTransition: b.io.beginViewportTransition()
                    case .finishTransition: b.io.finishViewportTransition(rows: 24)
                    case .beginReplay:
                        changes = true
                        b.io.beginReplay()
                    case .reset:
                        changes = true
                        b.io.resetRemoteSequence()
                    case .take:
                        if let token = b.io.maintenanceScreenSnapshot()?.token { tokens.append((token, false)) }
                    }
                    if changes { tokens = tokens.map { ($0.0, true) } }
                    steps += 1
                    let phaseOpen = b.io.outputPhaseOpenNow
                    if phaseOpen, b.io.maintenanceScreenSnapshot() != nil {
                        Issue.record("a token is offered while a phase is open after \(sequence.prefix(position + 1))")
                        return
                    }
                    for (token, changed) in tokens where changed && b.io.maintenanceScreenIsCurrent(token) {
                        Issue.record("a token survived received output after \(sequence.prefix(position + 1))")
                        return
                    }
                }
                if tokens.contains(where: { !$0.1 && b.io.maintenanceScreenIsCurrent($0.0) }) { currentAtEnd += 1 }
                sequences += 1
                if sequences % 64 == 0 { await Task.yield() }
            }
        }
        print("hidden token bounded check: depth \(Self.depth), \(ops.count) ops, \(sequences) sequences, \(steps) steps, \(currentAtEnd) end with an untouched token current")
        #expect(sequences == (0...Self.depth).reduce(0) { $0 + Int(pow(Double(ops.count), Double($1))) })
        #expect(currentAtEnd > 0, "non-vacuous: some sequences keep an untouched token current")
    }
}

// MARK: - r3: the real retained-shell resume path on a hidden pane

@MainActor
private final class HiddenShellFixture {
    let pane: PaneModel
    let writer = FenceFrameWriter()
    let transport: RelayRemoteTransport

    /// A hidden (never presented) shell pane whose OSC 133 tracker reads an
    /// empty prompt. `replay` records the screen as a replay buffer.
    init(replay: Bool) {
        pane = PaneModel(profile: .sshConfigHost("owned-resume.invalid"))
        transport = fenceTransport(writer, profile: pane.profile, paneID: pane.id)
        pane.runtime.startForTesting(transport: transport)
        pane.connectionState = .connected
        let io = pane.runtime.ioForTesting
        if replay { _ = io.restoreSnapshot(paneID: pane.id) }
        #expect(io.receive(Data("\u{1b}[?2004h\u{1b}[2J\u{1b}[H\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}".utf8),
                           remoteSequence: replay ? 100 : 0))
        let id = pane.id.uuidString.lowercased()
        let hostID = pane.profile.id
        pane.runtime.promptOwnerBindingForTesting = {
            RelayPromptOwnerIdentity(hostID: hostID, binding: RelayPromptOwnerBinding(version: 1, paneId: id,
                nodeBootId: "boot", workerPid: 10, workerStart: 11, shellPid: 12, shellStart: 13, provider: "shell",
                processId: 12, processStart: 13, sessionId: nil, transcriptIdentity: nil))
        }
    }

    func close() {
        pane.runtime.promptOwnerBindingForTesting = nil
        _ = pane.runtime.ioForTesting.removeTransport()
        transport.detach()
        TerminalSnapshotStore.shared.remove(paneID: pane.id)
    }

    var original: RelayAgentMaintenanceProbe {
        get throws {
            let id = pane.id.uuidString.lowercased()
            let json = #"{"version":1,"pane_id":"\#(id)","provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"quiet","background_work":false,"subagent_work":false,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"\#(id)","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"resume_command":"/home/test/.local/bin/claude --resume exact-session","move_command":"/home/test/.local/bin/claude --resume exact-session"}"#
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        }
    }

    func resume(willSend: () throws -> Void = {}) async throws -> Bool {
        let proof = try original
        return try await pane.runtime.resumeAgentAfterMaintenance(try #require(proof.resumeCommand), original: proof,
            inputRevision: pane.agentInputRevision, willSend: willSend)
    }
}

@MainActor @Suite("Retained-shell resume on a hidden pane", .serialized)
struct RelayRetainedShellResumeTests {
    @Test("No replay proof: the OSC 133 empty prompt alone does not admit a resume", .timeLimit(.minutes(1)))
    func noProofRefuses() async throws {
        let fixture = HiddenShellFixture(replay: false)
        defer { fixture.close() }
        #expect(fixture.pane.runtime.ioForTesting.shellInputIsEmpty, "the OSC 133 branch reads empty")
        #expect(fixture.pane.runtime.observeActiveScreen() == .noSurface)
        #expect(fixture.pane.runtime.screenFence(.noSurface) == nil)
        #expect(try await !fixture.resume())
        #expect(fixture.writer.inputs.isEmpty)
    }

    @Test("A current replay proof admits the resume and the write carries its token", .timeLimit(.minutes(1)))
    func validProofSends() async throws {
        let fixture = HiddenShellFixture(replay: true)
        defer { fixture.close() }
        #expect(try await fixture.resume())
        #expect(fixture.writer.inputs.count == 1)
        #expect(fixture.writer.inputs.first.map { String(decoding: $0, as: UTF8.self).contains("--resume exact-session") } == true)
    }

    @Test("Output after admission makes the replay proof stale at the write", .timeLimit(.minutes(1)))
    func outputAtTheBoundaryRefuses() async throws {
        let fixture = HiddenShellFixture(replay: true)
        defer { fixture.close() }
        let io = fixture.pane.runtime.ioForTesting
        #expect(try await !fixture.resume(willSend: { io.receive(Data("x".utf8), remoteSequence: 101) }))
        #expect(fixture.writer.inputs.isEmpty)
    }

    @Test("A same-sequence replay replacement after admission is refused at the write", .timeLimit(.minutes(1)))
    func replacementAtTheBoundaryRefuses() async throws {
        let fixture = HiddenShellFixture(replay: true)
        defer { fixture.close() }
        let io = fixture.pane.runtime.ioForTesting
        #expect(try await !fixture.resume(willSend: {
            io.beginViewportTransition()
            io.receive(Data("$ resized\r\n".utf8))
            io.finishViewportTransition(rows: 24)
        }))
        #expect(fixture.writer.inputs.isEmpty)
    }

    // d415f009's third negative probe (negative-probes.patch 9c821700).
    @Test("REVIEW: hidden resume must refuse buffered sequence-zero viewport output", .timeLimit(.minutes(1)))
    func reviewHiddenViewportMustRefuse() async throws {
        let fixture = HiddenShellFixture(replay: true); defer { fixture.close() }
        let io = fixture.pane.runtime.ioForTesting
        #expect(try await !fixture.resume(willSend: {
            io.beginViewportTransition()
            _ = io.receive(Data("danger after admission\r\n".utf8))
        }))
        #expect(fixture.writer.inputs.isEmpty)
    }

    @Test("An open transition with nothing buffered refuses the resume; once it closes, a new resume sends",
          .timeLimit(.minutes(1)))
    func openTransitionRefusesThenResumeSends() async throws {
        let fixture = HiddenShellFixture(replay: true); defer { fixture.close() }
        let io = fixture.pane.runtime.ioForTesting
        #expect(try await !fixture.resume(willSend: { io.beginViewportTransition() }))
        #expect(fixture.writer.inputs.isEmpty)
        // While it stays open the resume is refused at admission.
        #expect(try await !fixture.resume())
        _ = io.receive(Data("\u{1b}[2J\u{1b}[H\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}".utf8))
        io.finishViewportTransition(rows: 24)
        // Positive control: the closed transition's bytes are in the replay
        // buffer; a new resume prepares a fresh proof and sends.
        #expect(try await fixture.resume())
        #expect(fixture.writer.inputs.count == 1)
    }
}

// MARK: - r4: admissions see an open output phase, so refusals come before any pre-send step

@MainActor @Suite("Admissions refuse while an output phase is open", .serialized)
struct RelayAdmissionPhaseTests {
    @Test("Live pane: an open viewport transition reads as a changing screen at admission; after it closes, the command sends",
          .timeLimit(.minutes(2)))
    func liveTransition() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime, io = runtime.ioForTesting
        let proof = try fixture.probe
        let revision = fixture.pane.agentInputRevision
        #expect(runtime.observeActiveScreen().screen != nil)
        io.beginViewportTransition()
        #expect(runtime.observeActiveScreen() == .unstable)
        #expect(!runtime.agentMaintenancePromptIsEmpty)
        #expect(runtime.accountMoveScreenRefusal() == "the screen of “\(fixture.pane.displayName)” is changing")
        #expect(runtime.screenFence(runtime.observeActiveScreen()) == nil)
        #expect(!runtime.sendAgentMaintenanceCommand("/exit", proof: proof, inputRevision: revision))
        #expect(fixture.writer.inputs.isEmpty)
        io.finishViewportTransition(rows: 24)
        // Positive control: the same pane admits and sends once the phase is closed.
        #expect(runtime.observeActiveScreen().screen != nil)
        #expect(runtime.accountMoveScreenRefusal() == nil)
        #expect(runtime.sendAgentMaintenanceCommand("/exit", proof: proof, inputRevision: revision))
        #expect(fixture.writer.inputs.count == 1)
    }

    @Test("Live pane: an open replay reads as a changing screen at admission until its commit has run",
          .timeLimit(.minutes(2)))
    func liveReplay() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime, io = runtime.ioForTesting
        #expect(runtime.observeActiveScreen().screen != nil)
        io.beginReplay()
        #expect(runtime.observeActiveScreen() == .unstable)
        #expect(runtime.accountMoveScreenRefusal() == "the screen of “\(fixture.pane.displayName)” is changing")
        io.endReplay()
        let deadline = Date().addingTimeInterval(5)
        while io.outputPhaseOpenNow, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!io.outputPhaseOpenNow)
        #expect(runtime.accountMoveScreenRefusal() == nil, "positive control: readable once the replay committed")
    }

    @Test("Hidden retained shell: an open transition refuses the resume before its pre-send step, so the caller can retry",
          .timeLimit(.minutes(1)))
    func hiddenResumeRefusesBeforeWillSend() async throws {
        let fixture = HiddenShellFixture(replay: true); defer { fixture.close() }
        let io = fixture.pane.runtime.ioForTesting
        io.beginViewportTransition()
        var attempted = false
        #expect(try await !fixture.resume(willSend: { attempted = true }))
        #expect(!attempted, "refused at admission, not at the write")
        #expect(fixture.writer.inputs.isEmpty)
        io.finishViewportTransition(rows: 24)
        #expect(try await fixture.resume(willSend: { attempted = true }))
        #expect(attempted)
        #expect(fixture.writer.inputs.count == 1)
    }

    @Test("Hidden retained shell: an open replay refuses the resume before its pre-send step", .timeLimit(.minutes(1)))
    func hiddenReplayRefusesBeforeWillSend() async throws {
        let fixture = HiddenShellFixture(replay: true); defer { fixture.close() }
        let io = fixture.pane.runtime.ioForTesting
        io.setExplicitReplayBoundary(true)
        var attempted = false
        #expect(try await !fixture.resume(willSend: { attempted = true }))
        #expect(!attempted)
        #expect(fixture.writer.inputs.isEmpty)
    }
}

// MARK: - r4: the maintenance exit retried across a resize or reconnect

@MainActor @Suite("Maintenance exit across an open output phase, real runtime", .serialized)
struct RelayMaintenanceExitPhaseTests {
    @Test("An open transition refuses with nothing typed; the bounded retry sends once it closes", .timeLimit(.minutes(2)))
    func retrySendsAfterTheTransitionCloses() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime, io = runtime.ioForTesting
        let proof = try fixture.probe
        let revision = fixture.pane.agentInputRevision
        io.beginViewportTransition()
        #expect(runtime.sendAgentMaintenanceCommandOutcome("/exit", proof: proof, inputRevision: revision) == .outputPhaseOpen)
        #expect(fixture.writer.inputs.isEmpty)
        var attempts = 0, sleeps = 0
        let result = try await RelayAgentMaintenanceRestartAdmission.send(initial: proof,
            attempt: { proof in
                attempts += 1
                return runtime.sendAgentMaintenanceCommandOutcome("/exit", proof: proof, inputRevision: revision)
            },
            readmit: { .admit(proof) },
            sleep: {
                sleeps += 1
                if sleeps == 3 { io.finishViewportTransition(rows: 24) }
            },
            limit: 5)
        #expect(result.outcome == .sent)
        #expect(attempts == 4, "three refusals while open, then one send")
        #expect(fixture.writer.inputs.count == 1, "the exit is typed exactly once")
    }

    @Test("A transition that stays open ends the retry at its bound with nothing typed", .timeLimit(.minutes(2)))
    func retryGivesUpAtTheBound() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime, io = runtime.ioForTesting
        let proof = try fixture.probe
        let revision = fixture.pane.agentInputRevision
        io.beginReplay()
        var attempts = 0
        let result = try await RelayAgentMaintenanceRestartAdmission.send(initial: proof,
            attempt: { proof in
                attempts += 1
                return runtime.sendAgentMaintenanceCommandOutcome("/exit", proof: proof, inputRevision: revision)
            },
            readmit: { .admit(proof) }, sleep: {}, limit: 3)
        #expect(result.outcome == .outputPhaseOpen)
        #expect(attempts == 4)
        #expect(fixture.writer.inputs.isEmpty)
    }

    @Test("Only an open phase is retryable: a changing screen without a phase, and a refusal at the write, are not",
          .timeLimit(.minutes(2)))
    func otherRefusalsAreNotRetryable() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime
        let proof = try fixture.probe
        let revision = fixture.pane.agentInputRevision
        runtime.activeScreenSampleForTesting = { .unstable }
        #expect(runtime.sendAgentMaintenanceCommandOutcome("/exit", proof: proof, inputRevision: revision) == .refused)
        // Admission passes on a stale key; the fence refuses at the write.
        let stale = try fixture.staleKey
        runtime.activeScreenSampleForTesting = { .stable(stale) }
        #expect(runtime.sendAgentMaintenanceCommandOutcome("/exit", proof: proof, inputRevision: revision) == .refused)
        var attempts = 0
        let result = try await RelayAgentMaintenanceRestartAdmission.send(initial: proof,
            attempt: { proof in
                attempts += 1
                return runtime.sendAgentMaintenanceCommandOutcome("/exit", proof: proof, inputRevision: revision)
            },
            readmit: { .admit(proof) }, sleep: {}, limit: 5)
        #expect(result.outcome == .refused)
        #expect(attempts == 1, "a refusal at the write is never retried")
        #expect(fixture.writer.inputs.isEmpty)
        runtime.activeScreenSampleForTesting = nil
    }

    @Test("Each retry re-runs the full admission: input typed during the phase ends it refused", .timeLimit(.minutes(2)))
    func inputDuringThePhaseIsRefused() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime, io = runtime.ioForTesting
        let proof = try fixture.probe
        let revision = fixture.pane.agentInputRevision
        io.beginViewportTransition()
        var sleeps = 0
        let result = try await RelayAgentMaintenanceRestartAdmission.send(initial: proof,
            attempt: { proof in runtime.sendAgentMaintenanceCommandOutcome("/exit", proof: proof, inputRevision: revision) },
            readmit: { .admit(proof) },
            sleep: {
                sleeps += 1
                if sleeps == 1 {
                    fixture.pane.userEnteredInput()
                    io.finishViewportTransition(rows: 24)
                }
            },
            limit: 5)
        #expect(fixture.pane.agentInputRevision != revision)
        #expect(result.outcome == .refused)
        #expect(fixture.writer.inputs.isEmpty)
    }

    @Test("A pane that stops being current ends the retry with nothing typed", .timeLimit(.minutes(2)))
    func paneNoLongerCurrentStops() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime, io = runtime.ioForTesting
        let proof = try fixture.probe
        let revision = fixture.pane.agentInputRevision
        io.beginViewportTransition()
        var attempts = 0
        let result = try await RelayAgentMaintenanceRestartAdmission.send(initial: proof,
            attempt: { proof in
                attempts += 1
                return runtime.sendAgentMaintenanceCommandOutcome("/exit", proof: proof, inputRevision: revision)
            },
            readmit: { .hold("the pane is no longer current") },
            sleep: { io.finishViewportTransition(rows: 24) },
            limit: 5)
        #expect(result.outcome == .outputPhaseOpen)
        #expect(result.held == "the pane is no longer current", "a readmission hold is reported as held, not as busy")
        #expect(attempts == 1)
        #expect(fixture.writer.inputs.isEmpty)
    }
}

// MARK: - r5: every retry readmits on fresh native evidence and the current grant

/// Drives the readmission the maintenance call site builds
/// (`RelayAgentMaintenanceRestartAdmission.readmission`) with a real pane and
/// runtime, a controlled native inspection, grant and clock. The exit stays
/// refused while a viewport transition is open; the first sleep closes the
/// transition and applies one change, so the retry's readmission sees it.
@MainActor @Suite("Maintenance exit retry readmission, real runtime", .serialized)
struct RelayMaintenanceExitReadmissionTests {
    typealias Grant = RelayAgentMaintenancePolicy.ModelGrant

    static func probe(_ pane: PaneModel, process: Int = 42, start: UInt64 = 99, session: String = "exact-session",
                      background: Bool = false, lifecycle: String = "quiet") throws -> RelayAgentMaintenanceProbe {
        let id = pane.id.uuidString.lowercased()
        let json = #"{"version":1,"pane_id":"\#(id)","provider":"claude","process_id":\#(process),"process_start":\#(start),"session_id":"\#(session)","bound":true,"lifecycle":"\#(lifecycle)","background_work":\#(background),"subagent_work":false,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"\#(id)","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"claude","process_id":\#(process),"process_start":\#(start),"session_id":"\#(session)","transcript_identity":"1:2"},"installed_update":false,"resume_command":"/home/test/.local/bin/claude --resume \#(session)","move_command":"/home/test/.local/bin/claude --resume \#(session)"}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
    }

    enum Change: String, CaseIterable, Sendable {
        case none, ownerProcess, ownerSession, backgroundWork, notQuiet, inspectFails
        case grantExpired, grantReplaced, grantRevoked, preferenceOff, inputTyped, paneReplaced
    }

    /// State the readmission reads, changed by the first sleep.
    @MainActor final class World {
        var refreshed: RelayAgentMaintenanceProbe?
        var grant: Grant?
        var now: Date
        var automatic = true
        var current = true
        var inspections = 0
        init(refreshed: RelayAgentMaintenanceProbe?, grant: Grant?, now: Date) {
            self.refreshed = refreshed; self.grant = grant; self.now = now
        }
    }

    struct Run {
        let result: RelayAgentMaintenanceRestartAdmission.Result
        let attempts: Int
        let sentAgainst: [RelayAgentMaintenanceProbe]
        let inspections: Int
        let typed: Int
    }

    static func run(_ change: Change, withGrant: Bool) async throws -> Run {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let pane = fixture.pane, runtime = pane.runtime, io = runtime.ioForTesting
        let original = try probe(pane)
        let revision = pane.agentInputRevision
        let start = Date(timeIntervalSince1970: 1_000_000)
        let grant = withGrant ? Grant(operationID: "op", toolID: "tool", action: "apply_installed_update",
                                      evidenceID: "evidence", expires: start.addingTimeInterval(60)) : nil
        let world = World(refreshed: original, grant: grant, now: start)
        let readmit = RelayAgentMaintenanceRestartAdmission.readmission(
            pane: pane, paneID: pane.id, original: original, inputRevision: revision, reason: .update,
            grantAtStart: grant,
            paneCurrent: { world.current },
            currentGrant: { world.grant },
            automaticMaintenance: { world.automatic },
            evidenceID: { _ in "evidence" },
            inspect: { _ in
                world.inspections += 1
                guard let refreshed = world.refreshed else { throw CancellationError() }
                return refreshed
            },
            now: { world.now })
        io.beginViewportTransition()
        var attempts = 0, sleeps = 0
        var sentAgainst: [RelayAgentMaintenanceProbe] = []
        let result = try await RelayAgentMaintenanceRestartAdmission.send(
            initial: original,
            attempt: { proof in
                attempts += 1
                sentAgainst.append(proof)
                return runtime.sendAgentMaintenanceCommandOutcome("/exit", proof: proof, inputRevision: revision)
            },
            readmit: readmit,
            sleep: {
                sleeps += 1
                guard sleeps == 1 else { return }
                io.finishViewportTransition(rows: 24)
                // Within the 30 s retry window: inside the grant's 60 s life
                // unless the change is its expiry.
                world.now = start.addingTimeInterval(change == .grantExpired ? 61 : 30)
                switch change {
                case .none, .grantExpired: break
                case .ownerProcess: world.refreshed = try probe(pane, process: 43, start: 100)
                case .ownerSession: world.refreshed = try probe(pane, session: "other-session")
                case .backgroundWork: world.refreshed = try probe(pane, background: true)
                case .notQuiet: world.refreshed = try probe(pane, lifecycle: "busy")
                case .inspectFails: world.refreshed = nil
                case .grantReplaced:
                    world.grant = Grant(operationID: "op2", toolID: "tool2", action: "apply_installed_update",
                                        evidenceID: "evidence", expires: start.addingTimeInterval(120))
                case .grantRevoked: world.grant = nil
                case .preferenceOff: world.automatic = false
                case .inputTyped: pane.userEnteredInput()
                case .paneReplaced: world.current = false
                }
            },
            limit: 5)
        return Run(result: result, attempts: attempts, sentAgainst: sentAgainst,
                   inspections: world.inspections, typed: fixture.writer.inputs.count)
    }

    @Test("Unchanged native evidence and grant: the retry readmits once and sends once, against the refreshed evidence",
          .timeLimit(.minutes(2)), arguments: [false, true])
    func unchangedSends(withGrant: Bool) async throws {
        let run = try await Self.run(.none, withGrant: withGrant)
        #expect(run.result == .init(outcome: .sent, held: nil))
        #expect(run.attempts == 2, "refused while the transition was open, then sent")
        #expect(run.inspections == 1, "one fresh native inspection, after the wait")
        #expect(run.typed == 1, "the exit is typed exactly once")
    }

    @Test("A change during the retry wait holds the exit with nothing typed",
          .timeLimit(.minutes(2)),
          arguments: Change.allCases.filter { $0 != .none }, [false, true])
    func changeHolds(change: Change, withGrant: Bool) async throws {
        // Grant changes only apply to a model-requested action.
        let grantChange = [.grantExpired, .grantReplaced, .grantRevoked].contains(change)
        guard withGrant || !grantChange || change == .grantReplaced else { return }
        let run = try await Self.run(change, withGrant: withGrant)
        #expect(run.result.outcome == .outputPhaseOpen, "\(change)")
        #expect(run.result.held != nil, "\(change): reported as a readmission hold, not as busy")
        #expect(run.attempts == 1, "\(change): no attempt after the hold")
        #expect(run.typed == 0, "\(change): nothing typed")
        #expect(run.inspections == 1, "\(change): the hold followed a fresh inspection")
    }
}

// MARK: - r5: the replay commit against a concurrent send's phase read (lock order)

/// Ends the process if the barrier interleaving has not completed in time: a
/// lock cycle leaves runtime locks held, so the test could not even clean up.
private final class LockCycleWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false

    init(_ label: String, seconds: Double) {
        Thread.detachNewThread { [self] in
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
                lock.lock(); let done = passed; lock.unlock()
                if done { return }
            }
            FileHandle.standardError.write(Data("DEADLOCK: \(label) did not complete within \(seconds) s\n".utf8))
            _exit(87)
        }
    }

    func pass() { lock.lock(); passed = true; lock.unlock() }
}

private final class ArmedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor @Suite("Replay commit and a concurrent send's phase read: lock order", .serialized)
struct RelayReplayCommitLockOrderTests {
    /// Barriers pin the interleaving root named for P4: the commit holds
    /// replayLock before entering the display queue while a send, holding
    /// outputOrderingLock, reads the replay phase. The commit must hold
    /// outputOrderingLock across that window (taken first, the order
    /// receive() uses), so the send waits at outputOrderingLock instead of
    /// taking it and then waiting for replayLock, which closes a cycle with the
    /// commit's enqueueDisplay.
    @Test("A send's phase read waits for the whole replay commit, and both complete", .timeLimit(.minutes(1)))
    func commitAgainstPhaseRead() throws {
        let b = try HiddenBridge(); defer { b.close() }
        let io = b.io
        let commitHeld = DispatchSemaphore(value: 0), releaseCommit = DispatchSemaphore(value: 0)
        let sendReading = DispatchSemaphore(value: 0), sendDone = DispatchSemaphore(value: 0)
        let armed = ArmedFlag()
        io.replayCommitWillEnqueueForTesting = {
            commitHeld.signal()
            releaseCommit.wait()
        }
        io.phaseReadWillLockReplayForTesting = {
            if armed.isSet { sendReading.signal() }
        }
        defer {
            io.replayCommitWillEnqueueForTesting = nil
            io.phaseReadWillLockReplayForTesting = nil
        }
        io.beginReplay()
        _ = io.receive(Data("\u{1b}[2J\u{1b}[H$ replayed\r\n".utf8), remoteSequence: 200)
        io.endReplay()
        // 1. The commit holds replayLock (and, unmutated, outputOrderingLock).
        try #require(commitHeld.wait(timeout: .now() + 5) == .success, "the commit reached the display queue")
        let watchdog = LockCycleWatchdog("replay commit against a send's phase read", seconds: 10)
        // 2. A send starts its phase read.
        armed.set()
        let token = b.token
        Thread.detachNewThread {
            _ = io.sendUserInput(Data("go".utf8), expectedLiveScreen: nil, expectedMaintenanceScreen: token)
            sendDone.signal()
        }
        // Unmutated, the send blocks at outputOrderingLock and never reaches
        // its phase read while the commit runs. If it reaches it, the commit
        // did not hold outputOrderingLock over the window.
        let readDuringCommit = sendReading.wait(timeout: .now() + 0.5) == .success
        #expect(!readDuringCommit, "the send read the replay phase while the commit held replayLock without the ordering lock")
        // 3. The commit enters the display queue; both must complete.
        releaseCommit.signal()
        let completed = sendDone.wait(timeout: .now() + 5) == .success
        // A lock cycle leaves replayLock held, so any later phase read here
        // would hang: only completion passes the watchdog; otherwise it ends
        // the process with DEADLOCK.
        guard completed else {
            Issue.record("the send did not complete after the commit: lock cycle")
            while true { Thread.sleep(forTimeInterval: 1) }
        }
        watchdog.pass()
        let deadline = Date().addingTimeInterval(5)
        while io.outputPhaseOpenNow, Date() < deadline { usleep(10_000) }
        #expect(!io.outputPhaseOpenNow, "the commit completed and closed the replay")
        #expect(b.writer.inputs.isEmpty, "the pre-replay token is stale after the commit")
    }
}

@MainActor @Suite("Context rotation send: one observation", .serialized)
struct RelayContextRotationSendObservationTests {
    /// The send judges its blocker on the screen it fences. The seam returns the
    /// real screen on the first sample and `.unstable` on the second, so a
    /// blocker that samples again on its own refuses the send.
    @Test("sendContextRotationInput gates and fences one observed screen", .timeLimit(.minutes(2)))
    func sendJudgesOneObservation() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.close() }
        let runtime = fixture.pane.runtime
        let proof = try fixture.probe
        let revision = fixture.pane.agentInputRevision
        let session = runtime.ioForTesting.session

        // Positive control: the blocker judges the observation it is given.
        #expect(runtime.contextRotationSendBlocker("/clear", kind: .clear, proof: proof, inputRevision: revision) == nil)
        #expect(runtime.contextRotationSendBlocker("/clear", kind: .clear, proof: proof, inputRevision: revision,
                                                   observation: .unstable) != nil)

        final class Count { var value = 0 }
        let samples = Count()
        runtime.activeScreenSampleForTesting = {
            samples.value += 1
            return samples.value == 2 ? .unstable : session.activeScreenSample()
        }
        #expect(runtime.sendContextRotationInput("/clear", kind: .clear, proof: proof, inputRevision: revision))
        #expect(samples.value == 1, "one screen sample per send; got \(samples.value)")
        #expect(fixture.writer.inputs.count == 1)
    }
}
