import AppKit
import Foundation
import Testing
@testable import Relay

/// A displayed idle Codex pane, as the renderer shows it: weekly-limit notice
/// above the composer, the faint native placeholder, the context line and the
/// segmented hint row with a right-aligned warnings segment (QA-F04 shape).
private enum ResumeScreen {
    static let placeholder = "\u{1b}[2mAsk Codex to do anything\u{1b}[22m"
    static let weekly = "  ⚠ weekly limit: 7% left · resets at 11:02 PM on 8 Nov · /status"
    static let codexFooter = ["  gpt-5.5 high · Context 91% left · ~/project",
                              "  ← for agents · ? for shortcuts" + String(repeating: " ", count: 20) + "⚠ 2 warnings · f2 to view"]

    static func codex(input: String = placeholder, above: String = weekly) -> String {
        (["  Worked for 24s • 5:20 PM", " ", above, " ", "› " + input, " "] + codexFooter).joined(separator: "\r\n")
    }

    static let claudeFooter = ["────────────────────────────────────────",
                               "  term:main | [Opus 5.5] | 12m",
                               "  ◈ v5.73.1 mem:12K",
                               "  ⏵⏵ bypass permissions on (shift+tab to cycle)"]

    static func claude(input: String = "", footerSuffix: String = "") -> String {
        var footer = claudeFooter
        footer[footer.count - 1] += footerSuffix
        return (["● Done.", " ", "────────────────────────────────────────", "❯ " + input] + footer).joined(separator: "\r\n")
    }
}

private final class ResumeFrameWriter: RelayFrameWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [Data] = []
    func write(type: RelayWireType, payload: Data) throws { writeAsync(type: type, payload: payload) }
    func writeAsync(type: RelayWireType, payload: Data) {
        guard type == .inputV2 || type == .automationInputV2 else { return }
        lock.lock(); inputs.append(payload); lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return inputs.count }
}

@MainActor private struct Observed {
    let token: UUID?
    let writer: ResumeFrameWriter
    let runtime: TerminalRuntime
    let close: @MainActor () -> Void
}

@MainActor private func binding(_ pane: PaneModel, provider: String, process: Int = 444, session: String? = "01a18b32-f284-7220-91a2-6a81cde6db14",
                     inputOnly: Bool? = nil) -> RelayPromptOwnerBinding {
    RelayPromptOwnerBinding(version: 1, paneId: pane.id.uuidString.lowercased(), nodeBootId: "owned-boot",
        workerPid: 222, workerStart: 1, shellPid: 333, shellStart: 2, provider: provider,
        processId: process, processStart: 3, sessionId: session, transcriptIdentity: "1:2", inputOnly: inputOnly)
}

@Suite("Same-pane agent resume prompt proof", .serialized)
struct RelayAgentResumePromptProofTests {
    /// Drives the real attached-renderer path: no ordered worker snapshot, so
    /// the proof must come from the live native screen under its fence.
    @MainActor
    private func proof(screen: String, owner provider: String = "codex", expected: String = "codex",
                       change: String = "none") async throws -> Observed {
        _ = NSApplication.shared
        let profile = ConnectionProfile(name: "Owned resume renderer proof", kind: .local, backend: .relay)
        let pane = PaneModel(profile: profile), writer = ResumeFrameWriter()
        let runtime = pane.runtime
        let transport = RelayRemoteTransport(attachedFrameWriter: writer, profile: profile, paneID: pane.id,
            capabilities: ["input_ack_v1", "input_lease_v1", "automation_input_v1"], controlGranted: true)
        runtime.startForTesting(transport: transport)
        let session = runtime.ioForTesting.session, view = runtime.view
        let (bridgeViewports, sink) = AsyncStream<RelayViewport>.makeStream(bufferingPolicy: .bufferingNewest(1))
        runtime.ioForTesting.onViewportReady = { sink.yield($0) }
        let deadline = Task { try? await Task.sleep(for: .seconds(2)); sink.finish() }
        defer { deadline.cancel(); sink.finish() }
        var bridgeSizes = bridgeViewports.makeAsyncIterator()
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 440)
        var sizes = session.nativeResizeEvents().makeAsyncIterator()
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.fitToSize()
        _ = try #require(await sizes.next())
        await Task.yield()
        var parsed = session.parsedHostOutputEvents().makeAsyncIterator()
        _ = await parsed.next()
        #expect(runtime.ioForTesting.receive(Data(("\u{1b}[2J\u{1b}[H" + screen).utf8), remoteSequence: 1))
        _ = try #require(await parsed.next())
        await Task.detached { session.waitForPendingOutput() }.value
        view.synchronizeAndRedraw()
        pane.connectionState = .connected
        let state = try #require(session.screenState)
        let viewport = RelayViewport(columns: try #require(state.columns), rows: try #require(state.rows))
        while runtime.ioForTesting.currentViewport != viewport { _ = try #require(await bridgeSizes.next()) }
        #expect(runtime.ioForTesting.maintenanceScreenSnapshot() == nil, "a displayed pane has no worker snapshot")
        let original = binding(pane, provider: provider)
        let successor = binding(pane, provider: provider, process: 445)
        var reads = 0
        runtime.promptOwnerBindingForTesting = {
            reads += 1
            return .init(hostID: profile.id, binding: change == "owner" && reads > 1 ? successor : original)
        }
        if change == "composer" { pane.composerState.draft = "unsent composer draft" }
        let token = await runtime.agentResumePromptProof(expected: binding(pane, provider: expected))
        return Observed(token: token, writer: writer, runtime: runtime) {
            _ = runtime.ioForTesting.removeTransport(); transport.detach(); runtime.stop(); window.contentView = nil; window.close()
        }
    }

    @MainActor
    @Test("A displayed idle Codex prompt yields a proof whose exit key is sendable once", .timeLimit(.minutes(2)))
    func displayedIdleCodexPromptIsProven() async throws {
        let observed = try await proof(screen: ResumeScreen.codex())
        defer { observed.close() }
        let runtime = observed.runtime, writer = observed.writer
        let proven = try #require(observed.token, "an idle empty Codex prompt on screen must be provable")
        let exit = RelayTerminalEditRequest(instance: UUID(), requestID: UUID(), token: proven, action: "key", text: nil, key: "d", modifiers: ["control"])
        #expect(await runtime.sendTerminalEdit(exit) == "input_submitted")
        #expect(writer.count == 1)
        #expect(await runtime.sendTerminalEdit(exit) == "not_sent")
        #expect(writer.count == 1)
    }

    @MainActor
    @Test("Displayed Codex panes that are busy, drafted, re-owned or another provider are refused", .timeLimit(.minutes(3)))
    func displayedCodexRefusals() async throws {
        let cases: [(String, String, String, String, String)] = [
            ("draft", ResumeScreen.codex(input: "coordinate with claude"), "codex", "codex", "none"),
            ("placeholder words typed", ResumeScreen.codex(input: "Ask Codex to do anything"), "codex", "codex", "none"),
            ("busy", ResumeScreen.codex(above: "• Working (3s • esc to interrupt)"), "codex", "codex", "none"),
            ("owner change", ResumeScreen.codex(), "codex", "codex", "owner"),
            ("composer draft", ResumeScreen.codex(), "codex", "codex", "composer"),
            ("owner is another provider", ResumeScreen.codex(), "claude", "codex", "none"),
            ("expected is another provider", ResumeScreen.codex(), "claude", "claude", "none"),
        ]
        for (name, screen, owner, expected, change) in cases {
            let observed = try await proof(screen: screen, owner: owner, expected: expected, change: change)
            #expect(observed.token == nil, "must refuse: \(name)")
            #expect(observed.writer.count == 0, "no input for: \(name)")
            observed.close()
        }
    }

    @MainActor @Test func admissionRefusesApprovalsComposerActivityInputOnlyAndUnknownProviders() {
        let pane = PaneModel(profile: ConnectionProfile(name: "Owned admission", kind: .local, backend: .relay))
        let codex = binding(pane, provider: "codex")
        let vt = ResumeScreen.codex().replacingOccurrences(of: "\r\n", with: "\n")
        #expect(TerminalRuntime.agentResumePromptAdmits(expected: codex, vt: vt, pendingApprovals: 0, composerBusy: false))
        #expect(!TerminalRuntime.agentResumePromptAdmits(expected: codex, vt: vt, pendingApprovals: 1, composerBusy: false))
        #expect(!TerminalRuntime.agentResumePromptAdmits(expected: codex, vt: vt, pendingApprovals: 0, composerBusy: true))
        #expect(!TerminalRuntime.agentResumePromptAdmits(expected: codex, vt: nil, pendingApprovals: 0, composerBusy: false))
        let inputOnly = binding(pane, provider: "codex", inputOnly: true)
        #expect(!TerminalRuntime.agentResumePromptAdmits(expected: inputOnly, vt: vt, pendingApprovals: 0, composerBusy: false))
        for provider in ["gemini", "", "Codex"] {
            let other = binding(pane, provider: provider)
            #expect(!TerminalRuntime.agentResumePromptAdmits(expected: other, vt: vt, pendingApprovals: 0, composerBusy: false))
        }
    }
}
