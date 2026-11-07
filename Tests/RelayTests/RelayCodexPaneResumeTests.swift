import Foundation
import Testing
@testable import Relay

@Suite("Same-pane Codex resume", .serialized)
struct RelayCodexPaneResumeTests {
    @Test func codexPaneResumeTakeoverRequiresExplicitUserResumeFlag() throws {
        let id = UUID()
        let ordinary = RelayContextRotationRequest(instance: id, requestID: id, enabled: true)
        #expect(!ordinary.permitsResumingHumanTakeover)
        let resumed = RelayContextRotationRequest(instance: id, requestID: id, enabled: true, resumeHumanTakeover: true)
        #expect(resumed.permitsResumingHumanTakeover)
        #expect(!RelayContextRotationRequest(instance: id, requestID: id, enabled: false, resumeHumanTakeover: true).permitsResumingHumanTakeover)
        #expect(try JSONDecoder().decode(RelayContextRotationRequest.self, from: JSONEncoder().encode(resumed)).permitsResumingHumanTakeover)
    }
    private func owner(session: String, process: Int = 20, worker: Int = 10, boot: String = "boot") -> RelayPromptOwnerBinding {
        .init(version: 1, paneId: "pane", nodeBootId: boot, workerPid: worker, workerStart: 100,
              shellPid: 11, shellStart: 101, provider: "codex", processId: process, processStart: 200,
              sessionId: session, transcriptIdentity: "transcript")
    }
    @Test @MainActor func codexPaneResumeVerificationRequiresExactSessionAndRetainedProcesses() {
        let target = UUID(), before = owner(session: UUID().uuidString.lowercased())
        let correct = owner(session: target.uuidString.lowercased(), process: 21)
        #expect(RelayCodexPaneResume.verified(before, after: correct, target: target))
        #expect(!RelayCodexPaneResume.verified(before, after: owner(session: UUID().uuidString.lowercased(), process: 21), target: target))
        #expect(!RelayCodexPaneResume.verified(before, after: owner(session: target.uuidString.lowercased(), process: 21, worker: 12), target: target))
        #expect(!RelayCodexPaneResume.verified(before, after: owner(session: target.uuidString.lowercased(), process: 21, boot: "other"), target: target))
        #expect(!RelayCodexPaneResume.verified(before, after: owner(session: target.uuidString.lowercased()), target: target))
    }
    @Test @MainActor func codexPaneResumeInterruptedReceiptDoesNotBecomePermissionToReplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pane = UUID(), request = RelayCodexPaneResumeRequest(instance: UUID(), requestID: UUID(), expectedSession: UUID(), targetSession: UUID())
        let original = RelayCodexPaneResume.Receipt(paneID: pane, request: request, state: "launching", detail: "launch reserved", updatedAt: Date())
        let path = directory.appendingPathComponent(request.requestID.uuidString.lowercased() + ".json")
        let data = try JSONEncoder().encode(original)
        try data.write(to: path)
        let store = RelayCodexPaneResume(directory: directory)
        #expect(store.receipt(request.requestID, paneID: pane)?.state == "interrupted_outcome_unknown")
        #expect(store.receipt(request.requestID, paneID: UUID()) == nil)
        #expect(try Data(contentsOf: path) == data)
    }
}

@Suite("Same-pane Claude resume")
struct RelayClaudePaneResumeTests {
    private func owner(_ provider: String, session: String, process: Int = 20) -> RelayPromptOwnerBinding {
        .init(version: 1, paneId: "pane", nodeBootId: "boot", workerPid: 10, workerStart: 100,
              shellPid: 11, shellStart: 101, provider: provider, processId: process, processStart: 200,
              sessionId: session, transcriptIdentity: "transcript")
    }

    @Test func legacyRequestsStayCodexAndClaudeResumesOnlyItsOwnSession() throws {
        let id = UUID(), other = UUID()
        let legacy = try JSONDecoder().decode(RelayCodexPaneResumeRequest.self, from: Data(
            #"{"instance":"\#(id)","requestID":"\#(id)","expectedSession":"\#(id)","targetSession":"\#(other)"}"#.utf8))
        #expect(legacy.agent == "codex" && legacy.isAdmissible)
        let claude = RelayCodexPaneResumeRequest(instance: id, requestID: id, expectedSession: id, targetSession: id, provider: "claude")
        #expect(claude.isAdmissible)
        #expect(try JSONDecoder().decode(RelayCodexPaneResumeRequest.self, from: JSONEncoder().encode(claude)) == claude)
        #expect(!RelayCodexPaneResumeRequest(instance: id, requestID: id, expectedSession: id, targetSession: other, provider: "claude").isAdmissible)
        for provider in ["gemini", "Claude", "", "shell"] {
            #expect(!RelayCodexPaneResumeRequest(instance: id, requestID: id, expectedSession: id, targetSession: id, provider: provider).isAdmissible)
        }
        // A receipt request differing only by provider is a different request.
        #expect(RelayCodexPaneResumeRequest(instance: id, requestID: id, expectedSession: id, targetSession: id) != claude)
    }

    @Test @MainActor func planAndExitAreProviderExact() {
        let pane = UUID(), session = "01a18b32-f284-7220-91a2-6a81cde6db14"
        #expect(RelayCodexPaneResume.planArguments(pane: pane, provider: "claude", expected: session, target: session)
            == ["claude-pane-resume-plan", pane.uuidString.lowercased(), session])
        #expect(RelayCodexPaneResume.planArguments(pane: pane, provider: "codex", expected: session, target: "t")
            == ["codex-pane-resume-plan", pane.uuidString.lowercased(), session, "t"])
        let (claudeExit, claudeSubmit) = RelayCodexPaneResume.exitEdit(provider: "claude", instance: pane, requestID: pane, token: pane)
        #expect(claudeExit.isValid && claudeSubmit && claudeExit.action == "insert_text" && claudeExit.text == "/exit")
        let (codexExit, codexSubmit) = RelayCodexPaneResume.exitEdit(provider: "codex", instance: pane, requestID: pane, token: pane)
        #expect(codexExit.isValid && !codexSubmit && codexExit.key == "d" && codexExit.modifiers == ["control"])
    }

    @Test @MainActor func claudeVerificationRequiresTheSameSessionInANewClaudeProcess() {
        let session = UUID(), before = owner("claude", session: session.uuidString.lowercased())
        #expect(RelayCodexPaneResume.verified(before, after: owner("claude", session: session.uuidString.lowercased(), process: 21), target: session))
        #expect(!RelayCodexPaneResume.verified(before, after: owner("claude", session: session.uuidString.lowercased()), target: session))
        #expect(!RelayCodexPaneResume.verified(before, after: owner("codex", session: session.uuidString.lowercased(), process: 21), target: session))
        #expect(!RelayCodexPaneResume.verified(before, after: owner("claude", session: UUID().uuidString.lowercased(), process: 21), target: session))
        var inputOnly = owner("claude", session: session.uuidString.lowercased(), process: 21); inputOnly.inputOnly = true
        #expect(!RelayCodexPaneResume.verified(before, after: inputOnly, target: session))
        let shell = owner("shell", session: session.uuidString.lowercased())
        #expect(!RelayCodexPaneResume.verified(shell, after: owner("shell", session: session.uuidString.lowercased(), process: 21), target: session))
    }

    /// relayd's real plan output (snake_case, including the nested owner).
    /// A plain decoder cannot read the owner, which refused every resume.
    @Test func hostPlanOutputDecodesWithItsNestedOwner() throws {
        let json = #"{"owner":{"version":1,"pane_id":"5c1d5455-3dc5-498f-a600-87cd325b6bf6","node_boot_id":"darwin:FE75E508-8443-44D6-B9D3-28BE8CA6DBD2","worker_pid":2059,"worker_start":1793657772073452,"shell_pid":2153,"shell_start":1793657772304410,"provider":"claude","process_id":40162,"process_start":1793940321860445,"session_id":"2545b07e-aabb-44df-8753-c6a019dd8a3f","transcript_identity":"16777231:1005594247"},"session_id":"2545b07e-aabb-44df-8753-c6a019dd8a3f","directory":"/Users/example/work","command":"cd -- '/Users/example/work' && env -u CLAUDE_CONFIG_DIR '/Users/example/.local/share/relay/shims/claude' --resume '2545b07e-aabb-44df-8753-c6a019dd8a3f'","config_dir":""}"#
        let plan = try #require(RelayCodexPaneResume.decodePlan(Data(json.utf8)))
        #expect(plan.owner.paneId == "5c1d5455-3dc5-498f-a600-87cd325b6bf6")
        #expect(plan.owner.sessionId == "2545b07e-aabb-44df-8753-c6a019dd8a3f")
        #expect(plan.owner.transcriptIdentity == "16777231:1005594247")
        #expect(plan.owner.isValid(for: UUID(uuidString: "5c1d5455-3dc5-498f-a600-87cd325b6bf6")!))
        #expect(plan.sessionId == "2545b07e-aabb-44df-8753-c6a019dd8a3f" && plan.configDir == "")
        #expect(RelayCodexPaneResume.decodePlan(Data(#"{"owner":{},"session_id":"x"}"#.utf8)) == nil)
    }
}
