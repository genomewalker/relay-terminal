import Foundation
import Testing
@testable import Relay

private actor RotationFixture: RelayRotationLifecycle {
    nonisolated let client: String
    var calls: [String] = []
    let loseStartReply: Bool
    init(loseStartReply: Bool = false, client: String = "codex") {
        self.loseStartReply = loseStartReply; self.client = client
    }
    func validate(_ admission: RelayRotationAdmission) { calls.append("validate") }
    func persistIntent(_ admission: RelayRotationAdmission, intentID: String) { calls.append("intent") }
    func startFreshThread(_ admission: RelayRotationAdmission, intentID: String) throws -> String {
        calls.append("start")
        if loseStartReply { throw CocoaError(.fileReadUnknown) }
        return "new-1"
    }
    func bind(_ admission: RelayRotationAdmission, intentID: String, freshThreadID: String) { calls.append("bind") }
    func loadCapsuleAndCompleteFirstTurn(_ admission: RelayRotationAdmission, freshThreadID: String) { calls.append("load-and-complete") }
    func acknowledge(_ admission: RelayRotationAdmission, intentID: String, freshThreadID: String) { calls.append("ack") }
    func retire(_ admission: RelayRotationAdmission, freshThreadID: String) { calls.append("retire") }
}

struct RelayChittaRotationExecutorTests {
    private func admission(owner: String = "relay", completed: Int = 12, client: String = "codex") -> RelayRotationAdmission {
        RelayRotationAdmission(sourceThreadID: "old-1", owner: owner, client: client,
            enrolled: true, turnIdle: true, epoch: "2", signalSequence: 10,
            completedTurnSequence: completed, claimID: "claim-1", fencingToken: 13,
            claimExpiresAt: .distantFuture, capsuleRevision: 7,
            capsuleLedgerSequence: 12, codeHead: String(repeating: "a", count: 40))
    }

    @Test func completionIsDurableAndAcknowledgesBeforeRetirement() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = RelayRotationJournal(url: dir.appendingPathComponent("journal.json"))
        let backend = RotationFixture()
        let result = await RelayChittaRotationExecutor(journal: journal).execute(admission(), using: backend)
        #expect(result == .completed("new-1"))
        #expect(await backend.calls == ["validate", "intent", "validate", "start", "bind", "validate", "load-and-complete", "validate", "ack", "retire"])
        #expect(journal.records()?.first?.phase == .oldThreadRetired)
    }

    @Test func lostStartReplyNeverStartsAgainAfterExecutorRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("journal.json")
        let first = RotationFixture(loseStartReply: true)
        let result = await RelayChittaRotationExecutor(journal: .init(url: file)).execute(admission(), using: first)
        #expect(result == .reconciliationRequired(.startIntent))
        let second = RotationFixture()
        let replay = await RelayChittaRotationExecutor(journal: .init(url: file)).execute(admission(), using: second)
        #expect(replay == .reconciliationRequired(.startIntent))
        #expect(await second.calls == ["validate"])
        #expect(await first.calls == ["validate", "intent", "validate", "start"])
    }

    @Test func desktopOwnerAndUncrossedBoundaryCannotExecute() async {
        let backend = RotationFixture()
        let executor = RelayChittaRotationExecutor(journal: .init())
        #expect(await executor.execute(admission(owner: "desktop"), using: backend) == .rejected)
        #expect(await executor.execute(admission(completed: 10), using: backend) == .rejected)
        #expect(await backend.calls.isEmpty)
    }
    @Test func claudeAdmissionRequiresAClaudeLifecycleAdapter() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executor = RelayChittaRotationExecutor(journal: .init(url: dir.appendingPathComponent("journal.json")))
        let codex = RotationFixture()
        #expect(await executor.execute(admission(client: "claude"), using: codex) == .rejected)
        #expect(await codex.calls.isEmpty)
        let claude = RotationFixture(client: "claude")
        #expect(await executor.execute(admission(client: "claude"), using: claude) == .completed("new-1"))
    }

}
