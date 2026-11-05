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
