import Foundation
import Testing
@testable import Relay

@MainActor
struct RelayQuestionEvidenceTests {
    @MainActor private final class Backend {
        var requests: [[String: String]] = []
        var returnedThread = "test-thread"
        var available = true
    }

    @Test("Saved task evidence reopens the same binding without updating the journal")
    func reopensExactAttachment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-evidence-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceModel(restoreSavedWorkspace: false, workspaceDirectory: directory.appendingPathComponent("workspace"))
        let anchor = try #require(workspace.activePane)
        let pane = anchor.id
        let profile = anchor.profile
        let binding = UUID()
        let identity = ["pane_id": pane.uuidString.lowercased(), "binding_id": binding.uuidString.lowercased(),
                        "realm": "test-realm", "thread_id": "test-thread"]
        let backend = Backend()
        let deliveryKey = String(repeating: "a", count: 64)
        let questionID = UUID()
        let evidence = RelayQuestionEvidence { _, payload, _ in
            let packet = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(packet["operation"] as? String == "communication")
            let request = try #require(packet["communication"] as? [String: String])
            backend.requests.append(request)
            #expect(request["operation"] == "question_evidence")
            #expect(request["pane_id"] == identity["pane_id"])
            if request["thread_id"] == nil {
                return try JSONSerialization.data(withJSONObject: ["result": ["status": "attached", "attachment": identity]])
            }
            #expect(request["realm"] == "test-realm")
            #expect(request["thread_id"] == "test-thread")
            #expect(request["question_binding_id"] == identity["binding_id"])
            guard backend.available else { return Data(#"{"error":"unavailable"}"#.utf8) }
            let artifact = ["type": "artifact", "id": "fixture-source"]
            let entries: [[String: Any]] = [
                ["entry_id": "checked", "thread_id": backend.returnedThread, "kind": "evidence", "text": "Fixture passed",
                 "check": ["exit_status": 0, "selected_count": 1], "verification": "verified", "refs": [artifact],
                 "freshness": [["ref": artifact, "status": "unchanged"]]],
                ["entry_id": "failed", "thread_id": "test-thread", "kind": "counter", "text": "Fixture failed",
                 "check": ["exit_status": 2, "selected_count": 1], "verification": "unverified", "refs": [artifact],
                 "freshness": [["ref": artifact, "status": "changed"]]],
                ["entry_id": "unknown", "thread_id": "test-thread", "kind": "limitation", "text": "Source unavailable",
                 "refs": [], "freshness": []],
            ]
            return try JSONSerialization.data(withJSONObject: ["result": ["status": "ready", "attachment": identity,
                                                                           "total": entries.count, "rows": entries, "research_conclusions": [
                          ["schema": "research.conclusion_notice/1", "question_id": questionID.uuidString, "revision": 1,
                           "delivery_key": deliveryKey, "evidence_sha256": String(repeating: "b", count: 64),
                           "question": "Which candidate passed?", "disposition": "answered", "rationale": "A passed."]]]])
        }
        let attachment = try #require(await evidence.capture(paneID: pane, profile: profile))
        let state = RelayMikoTaskJournal.State(requestID: "request", objective: "Inspect the fixture", originKind: "user",
            hostID: "fixture", anchorPaneID: pane, paneDerived: false, messages: [], questionEvidenceAttachment: attachment)
        do {
            let journal = try RelayMikoTaskJournal(directory: directory)
            try journal.create(id: "fixture", state: state)
            var legacy = state
            legacy.questionEvidenceAttachment = nil
            try journal.create(id: "legacy", state: legacy)
        }
        let reopened = try RelayMikoTaskJournal(directory: directory)
        let harness = RelayAssistantHarness(workspace: workspace, taskJournal: reopened, questionEvidence: evidence)
        let journalURL = directory.appendingPathComponent("tasks.json")
        let before = try Data(contentsOf: journalURL)
        for _ in 0..<2 {
            guard case .ready(let observed, let rows, let total, let conclusions) = await harness.readSavedTaskEvidence("fixture") else {
                Issue.record("Saved-task detail failed to reopen evidence")
                return
            }
            #expect(observed == attachment.identity)
            #expect(conclusions.map(\.id) == [deliveryKey])
            #expect(conclusions.first?.questionID == questionID)
            #expect(total == 3)
            #expect(rows.map(\.id) == ["checked", "failed", "unknown"])
            #expect(rows.first?.verification == "verified")
            #expect(rows.map { $0.check?.outcome } == ["Check passed (1 selected)", "Check failed (exit 2)", nil])
            #expect(rows.map(\.freshnessLabel) == ["Unchanged", "Stale", "Unknown"])
        }
        backend.returnedThread = "foreign-thread"
        if case .unavailable = await harness.readSavedTaskEvidence("fixture") {} else { Issue.record("Foreign rows were visible") }
        backend.available = false
        if case .unavailable = await harness.readSavedTaskEvidence("fixture") {} else { Issue.record("Unavailable backend was shown as evidence") }
        if case .unattached = await harness.readSavedTaskEvidence("legacy") {} else { Issue.record("Legacy task acquired a new attachment") }
        #expect(backend.requests.count == 5)
        #expect(try Data(contentsOf: journalURL) == before)
    }
}
