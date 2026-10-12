import Foundation
import Testing
@testable import Relay

struct RelayRotationJournalTests {
    @Test func startIntentSurvivesRestartAndPreventsDuplicateFreshTask() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("journal.json")
        let journal = RelayRotationJournal(url: file)
        let intent = RelayRotationRecord(claimID: "claim-1", sourceThreadID: "old-1",
            epoch: "2", capsuleRevision: 7, codeHead: String(repeating: "a", count: 40),
            phase: .startIntent, freshThreadID: nil)
        #expect(journal.record(intent))
        #expect(RelayRotationJournal(url: file).records() == [intent])
        #expect(!journal.record(RelayRotationRecord(claimID: "claim-2", sourceThreadID: "old-1",
            epoch: "2", capsuleRevision: 7, codeHead: intent.codeHead,
            phase: .startIntent, freshThreadID: nil)))
        var started = intent
        started.phase = .freshThreadStarted; started.freshThreadID = "new-1"
        #expect(journal.record(started))
        var completed = started
        completed.phase = .firstTurnCompleted
        #expect(journal.record(completed))
        var wrong = completed
        wrong.freshThreadID = "new-2"
        #expect(!journal.record(wrong))
        var skipped = completed
        skipped.phase = .oldThreadRetired
        #expect(!journal.record(skipped))
        #expect(RelayRotationJournal(url: file).records() == [completed])
    }
    @Test func independentJournalInstancesCannotBothBeginTheSameIntent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("journal.json")
        let intent = RelayRotationRecord(claimID: "claim-race", sourceThreadID: "old-race",
            epoch: "1", capsuleRevision: 1, codeHead: String(repeating: "b", count: 40),
            phase: .startIntent, freshThreadID: nil)
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { RelayRotationJournal(url: file).begin(intent) }
            }
            var count = 0
            for await value in group { if value { count += 1 } }
            return count
        }
        #expect(accepted == 1)
        #expect(RelayRotationJournal(url: file).records() == [intent])
    }

}
