import Foundation
import Testing
@testable import Relay

/// Case 3 (0.5.113, pane 7db531e6): a Codex resume under the managed backend
/// was held after "Exit submitted" and left the pane without its agent. A new
/// resume of the same session relaunches it in the same retained shell and
/// account, only from a held receipt that kept its admitted plan.
@Suite("Codex same-pane recovery")
struct RelayCodexPaneRecoveryTests {
    static let pane = UUID(uuidString: "7db531e6-0000-4000-8000-000000000001")!
    static let session = "01a18b32-f284-7220-91a2-6a81cde6db14"

    static func owner(_ provider: String, process: Int, shell: Int = 12) -> RelayPromptOwnerBinding {
        .init(version: 1, paneId: pane.uuidString.lowercased(), nodeBootId: "boot", workerPid: 10, workerStart: 11,
              shellPid: shell, shellStart: 13, provider: provider, processId: process, processStart: 99,
              sessionId: provider == "shell" ? nil : session, transcriptIdentity: provider == "shell" ? nil : "1:2")
    }
    static func plan(_ owner: RelayPromptOwnerBinding, config: String = "/home/u/.codex-work", directory: String = "/work") -> RelayCodexPaneResume.Plan {
        .init(owner: owner, sessionId: session, directory: directory, command: "cd -- /work && CODEX_HOME=/home/u/.codex-work shim resume x",
              configDir: config)
    }
    static func held(state: String = "held", code: RelayPaneOperationRefusal.Code? = .exitNotVerified,
                     plan: RelayCodexPaneResume.Plan? = plan(owner("codex", process: 42))) -> RelayCodexPaneResume.Receipt {
        let request = RelayCodexPaneResumeRequest(instance: UUID(), requestID: UUID(), expectedSession: UUID(uuidString: session)!,
                                                  targetSession: UUID(uuidString: session)!)
        var receipt = RelayCodexPaneResume.Receipt(paneID: pane, request: request, state: state, detail: "Exit submitted; …", updatedAt: Date())
        if let code { receipt.set(.init(code, receipt.detail)) }
        receipt.plan = plan
        return receipt
    }

    @Test func onlyAHeldAfterExitReceiptWithItsPlanIsRecoverable() {
        #expect(RelayCodexPaneResume.recoverable(Self.held(), pane: Self.pane, target: Self.session))
        #expect(!RelayCodexPaneResume.recoverable(Self.held(), pane: UUID(), target: Self.session))
        #expect(!RelayCodexPaneResume.recoverable(Self.held(), pane: Self.pane, target: "01a18b32-f284-7220-91a2-6a81cde6db15"))
        #expect(!RelayCodexPaneResume.recoverable(Self.held(state: "refused"), pane: Self.pane, target: Self.session))
        #expect(!RelayCodexPaneResume.recoverable(Self.held(code: .trustPrompt), pane: Self.pane, target: Self.session))
        #expect(!RelayCodexPaneResume.recoverable(Self.held(plan: nil), pane: Self.pane, target: Self.session))
    }

    @Test func theRelaunchMustBeTheSameShellAccountDirectoryAndSession() {
        let held = Self.plan(Self.owner("codex", process: 42))
        let shell = Self.owner("shell", process: 12)
        #expect(RelayCodexPaneResume.relaunchMatches(Self.plan(shell), held: held))
        #expect(!RelayCodexPaneResume.relaunchMatches(Self.plan(Self.owner("codex", process: 77)), held: held))
        #expect(!RelayCodexPaneResume.relaunchMatches(Self.plan(Self.owner("shell", process: 55, shell: 55)), held: held))
        #expect(!RelayCodexPaneResume.relaunchMatches(Self.plan(shell, config: "/home/u/.codex-other"), held: held))
        #expect(!RelayCodexPaneResume.relaunchMatches(Self.plan(shell, directory: "/elsewhere"), held: held))
    }

    @Test func aReceiptKeepsItsPlanAndOldReceiptsStillDecode() throws {
        let receipt = Self.held()
        let decoded = try JSONDecoder().decode(RelayCodexPaneResume.Receipt.self, from: JSONEncoder().encode(receipt))
        #expect(decoded.plan?.configDir == "/home/u/.codex-work" && decoded.plan?.owner == receipt.plan?.owner)
        var object = try receipt.object(); object.removeValue(forKey: "plan")
        #expect(try JSONDecoder().decode(RelayCodexPaneResume.Receipt.self, from: JSONSerialization.data(withJSONObject: object)).plan == nil)
    }

    @MainActor @Test func aNewRequestFindsTheHeldPlanInTheReceiptDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let held = Self.held()
        try JSONEncoder().encode(held).write(to: directory.appendingPathComponent(held.request.requestID.uuidString.lowercased() + ".json"))
        let resume = RelayCodexPaneResume(directory: directory)
        let request = RelayCodexPaneResumeRequest(instance: UUID(), requestID: UUID(), expectedSession: UUID(uuidString: Self.session)!,
                                                  targetSession: UUID(uuidString: Self.session)!)
        #expect(resume.recoverablePlan(pane: Self.pane, request: request)?.configDir == "/home/u/.codex-work")
        var claude = request; claude.provider = "claude"
        #expect(resume.recoverablePlan(pane: Self.pane, request: claude) == nil)
    }
}
