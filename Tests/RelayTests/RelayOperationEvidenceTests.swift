import Foundation
import Testing
@testable import Relay

@Suite("Operation evidence export")
struct RelayOperationEvidenceTests {
    private let id = UUID()
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func source(_ record: [String: Any]?, name: String = "pane_message_receipt",
                        at offset: TimeInterval = 0, error: String? = nil) -> RelayOperationEvidence.Source {
        .init(name: name, observedAt: now.addingTimeInterval(offset), record: record, error: error)
    }

    private func export(_ kind: RelayOperationEvidence.Kind, _ sources: [RelayOperationEvidence.Source]) -> [String: Any] {
        RelayOperationEvidence.export(kind: kind, id: id, sources: sources, now: now)
    }

    @Test("An admitted message is reported as admitted, never as processed")
    func admittedIsNotProcessed() {
        let result = export(.message, [source(["status": "admitted_not_processed", "acknowledgement": "not_implied"])])
        #expect(result["conclusion"] as? String == "admitted_processing_unproven")
        #expect((result["evidence_ends_at"] as? String)?.contains("processing is not proven") == true)
        #expect((result["gaps"] as? [String])?.contains { $0.contains("acknowledg") } == true)
        #expect(result["replay_permitted"] as? Bool == false)
        #expect(result["read_only"] as? Bool == true)
    }

    @Test func sourceLabelsUseTheExportRedactionPolicy() {
        for (input, expected) in [
            ("ssh:operator@example.org:22", "ssh:<email>:22"),
            ("ssh:someuser@dandy-07:22", "ssh:<user>@dandy-07:22"),
            ("config:someuser@dandy-07", "config:<user>@dandy-07"),
            ("ssh:someuser@[::1]:22", "ssh:<user>@[::1]:22"),
            ("ssh:dandy-07:22", "ssh:dandy-07:22"),
        ] {
            let result = export(.message, [source(nil, name: "daemon_receipt " + input)])
            let timeline = result["timeline"] as? [[String: Any]]
            #expect(timeline?.first?["source"] as? String == "daemon_receipt " + expected)
        }
    }

    @Test func transportAndProviderCompletionHaveDistinctConclusions() {
        for (status, expected) in [("written_to_socket", "written_to_socket"), ("turn_completed", "provider_turn_completed")] {
            let result = export(.message, [source(["status": status])])
            #expect(result["conclusion"] as? String == expected)
        }
    }

    @Test("An outcome-unknown receipt stays unknown, not failed")
    func unknownStaysUnknown() {
        let result = export(.message, [source(["status": "outcome_unknown", "replay_permitted": false])])
        #expect(result["conclusion"] as? String == "unknown")
    }

    @Test("A source that cannot be read is unknown and its error is redacted")
    func unreadableSourceIsUnknown() {
        let result = export(.message, [source(nil, error: "token=abc reading /Users/someone failed for a.person@example.org")])
        #expect(result["conclusion"] as? String == "unknown")
        let entry = (result["timeline"] as? [[String: Any]])?.first
        #expect(entry?["stage"] as? String == "read_failed")
        let error = entry?["error"] as? String ?? ""
        #expect(!error.contains("a.person@example.org"))
        #expect(error.contains("<email>"))
    }

    @Test("No record anywhere is no evidence, and says so")
    func noRecordIsNoEvidence() {
        let result = export(.accountMove, [source(nil, name: "app_account_move_receipt")])
        #expect(result["conclusion"] as? String == "no_evidence")
        #expect((result["gaps"] as? [String])?.contains { $0.contains("lost when Relay restarts") } == true)
    }

    @Test("A refused move keeps its reason and redacts its explanation")
    func refusedMoveKeepsReason() {
        let record: [String: Any] = ["status": "refused", "reason_code": "background_work",
                                     "blocker": "Waiting for shells owned by a.person@example.org",
                                     "account": "business"]
        let result = export(.accountMove, [source(record, name: "app_account_move_receipt")])
        #expect(result["conclusion"] as? String == "refused")
        let fields = (result["timeline"] as? [[String: Any]])?.first?["fields"] as? [String: Any]
        #expect(fields?["reason_code"] as? String == "background_work")
        #expect(fields?["account"] as? String == "business")
        #expect((fields?["blocker"] as? String)?.contains("example.org") == false)
    }

    @Test("Message bodies, nested values and unknown keys are listed by name only")
    func contentIsNeverExported() {
        let record: [String: Any] = ["status": "written_to_socket", "text": "secret plan", "prompt": "draft",
                                     "binding": ["pid": 1], "socket_path": "/tmp/x"]
        let result = export(.message, [source(record)])
        let entry = (result["timeline"] as? [[String: Any]])?.first
        let fields = entry?["fields"] as? [String: Any] ?? [:]
        #expect(fields["text"] == nil && fields["prompt"] == nil && fields["binding"] == nil)
        #expect(entry?["omitted_fields"] as? [String] == ["binding", "prompt", "socket_path", "text"])
        let encoded = String(data: (try? JSONSerialization.data(withJSONObject: result)) ?? Data(), encoding: .utf8) ?? ""
        #expect(!encoded.contains("secret plan"))
    }

    @Test("Sources that disagree are reported as conflicting, in time order")
    func disagreementIsReported() {
        let result = export(.message, [source(["status": "turn_started"], name: "daemon", at: 5),
                                       source(["status": "not_sent"], name: "desktop_intent", at: 1)])
        #expect(result["conclusion"] as? String == "conflicting")
        let names = (result["timeline"] as? [[String: Any]])?.compactMap { $0["source"] as? String }
        #expect(names == ["desktop_intent", "daemon"])
    }

    @Test("A verified move and a started provider turn are their own end points")
    func strongestOutcomes() {
        #expect(export(.accountMove, [source(["status": "verified"])])["conclusion"] as? String == "completed")
        #expect(export(.accountMove, [source(["status": "moving"])])["conclusion"] as? String == "in_progress")
        #expect(export(.message, [source(["status": "turn_started"])])["conclusion"] as? String == "provider_turn_started")
        #expect(export(.message, [source(["status": "read_acknowledged"])])["conclusion"] as? String == "acknowledged")
    }

    private struct Unreachable: LocalizedError {
        var errorDescription: String? { "relayd unreachable for a.person@example.org" }
    }

    @Test("An unreadable daemon stays in the timeline even when the desktop has a record")
    func unreadableDaemonIsNotHiddenByDesktopRecord() {
        let sources = RelayOperationEvidence.messageSources(
            daemon: [(name: "daemon_receipt dandy-07", result: .failure(Unreachable()))],
            desktop: .success(["status": "not_sent"]), observedAt: now)
        let result = export(.message, sources)
        let timeline = result["timeline"] as? [[String: Any]] ?? []
        #expect(timeline.map { $0["source"] as? String } == ["daemon_receipt dandy-07", "desktop_intent_record"])
        #expect(timeline.map { $0["stage"] as? String } == ["read_failed", "not_sent"])
        #expect((timeline.first?["error"] as? String)?.contains("example.org") == false)
        // The daemon may hold proof of delivery, so not_sent is not concluded.
        #expect(result["conclusion"] as? String == "unknown")
        #expect((result["gaps"] as? [String])?.contains { $0.contains("could not be read") } == true)
    }

    @Test("A daemon without a record and a desktop admission conclude from the desktop")
    func daemonUnknownIsNoRecord() {
        let sources = RelayOperationEvidence.messageSources(
            daemon: [(name: "daemon_receipt a", result: .success(["status": "unknown"])),
                     (name: "daemon_receipt b", result: .success(["status": "accepted_by_provider"]))],
            desktop: .success(nil), observedAt: now)
        let result = export(.message, sources)
        let stages = (result["timeline"] as? [[String: Any]])?.map { $0["stage"] as? String }
        #expect(stages == ["no_record", "admitted", "no_record"])
        #expect(result["conclusion"] as? String == "admitted_processing_unproven")
    }

    @Test("Proof of progress survives an unreadable source")
    func progressSurvivesReadFailure() {
        let sources = RelayOperationEvidence.messageSources(
            daemon: [(name: "daemon_receipt a", result: .failure(Unreachable())),
                     (name: "daemon_receipt b", result: .success(["status": "turn_started"]))],
            desktop: .failure(Unreachable()), observedAt: now)
        #expect(export(.message, sources)["conclusion"] as? String == "provider_turn_started")
    }

    @Test("Only the two documented paths route")
    func routes() {
        let instance = UUID()
        let message = "/api/operation-evidence/message/\(id.uuidString)"
        let move = "/api/operation-evidence/account-move/\(instance.uuidString)/\(id.uuidString)"
        #expect(RelayOperationEvidence.route(message) == .message(id))
        #expect(RelayOperationEvidence.route(move) == .accountMove(instance: instance, request: id))
        #expect(RelayOperationEvidence.route("/api/operation-evidence/message/not-a-uuid") == nil)
        #expect(RelayOperationEvidence.route("/api/operation-evidence/account-move/\(id.uuidString)") == nil)
        #expect(RelayOperationEvidence.route("/api/operation-evidence/message/\(id.uuidString)/extra") == nil)
        #expect(RelayOperationEvidence.route("/api/operation-evidence/other/\(id.uuidString)") == nil)
    }
}
