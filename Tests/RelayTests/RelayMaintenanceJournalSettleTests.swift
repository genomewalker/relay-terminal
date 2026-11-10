import XCTest
@testable import Relay

/// Old journal records stop holding a pane only with exact native proof that
/// nothing happened: the same agent process, start time and conversation.
final class RelayMaintenanceJournalSettleTests: XCTestCase {
    let pane = UUID(uuidString: "7d85fd72-64ec-46a4-8591-567bf64f7c93")!
    let host = "config:dandy-07"

    func proof() throws -> RelayAgentMaintenanceProbe {
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"quiet","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"claude","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":true,"resume_command":"/home/test/.local/bin/claude --resume exact-session"}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
    }

    /// A journal holding one record from two hours ago, as left by an earlier build.
    @MainActor func journal(state: String, draft: Data? = nil, process: Int = 42, start: UInt64 = 99,
                            session: String = "exact-session") throws -> (RelayAgentMaintenanceJournal, URL, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("journal.json")
        let id = String(repeating: "b", count: 64)
        let entry = RelayAgentMaintenanceJournal.Entry(id: id, paneID: pane, host: host, reason: .update,
            sessionID: session, createdAt: Date().addingTimeInterval(-7200), state: state,
            modelOperationID: nil, modelToolID: nil, resumeCommand: "resume", originalOwner: nil,
            originalProcessID: process, originalProcessStart: start,
            draftDigest: draft.map(RelayPromptEditorRPC.digest), draftRestored: draft.map { _ in false })
        try JSONEncoder().encode([id: entry]).write(to: url)
        return (RelayAgentMaintenanceJournal(url: url), url, id)
    }

    // MARK: restart_admission_unknown (8e4b42ae)

    @MainActor func testAnUnknownRestartOnTheSameProcessIsSettledAsNotRestarted() throws {
        let (journal, url, id) = try journal(state: "restart_admission_unknown")
        let value = try proof()
        // Held before: no new action may be claimed.
        XCTAssertNil(try journal.claim(pane: pane, host: host, proof: value, reason: .update))
        XCTAssertTrue(try journal.resolveUnadmittedRestarts(pane: pane, host: host, proof: value))
        XCTAssertEqual(RelayAgentMaintenanceJournal(url: url).entries[id]?.state, "restart_not_admitted")
        // Settled: the next update may be claimed, and a second pass changes nothing.
        XCTAssertFalse(try journal.resolveUnadmittedRestarts(pane: pane, host: host, proof: value))
        XCTAssertNotNil(try journal.claim(pane: pane, host: host, proof: value, reason: .update))
    }

    @MainActor func testAnUnknownRestartStaysHeldWithoutExactProcessProof() throws {
        var other = try proof(); other.processStart = 100        // a restarted agent
        var session = try proof(); session.sessionID = "other"   // another conversation
        var unbound = try proof(); unbound.bound = false
        for value in [other, session, unbound] {
            let (journal, url, id) = try journal(state: "restart_admission_unknown")
            XCTAssertFalse(try journal.resolveUnadmittedRestarts(pane: pane, host: host, proof: value))
            XCTAssertEqual(RelayAgentMaintenanceJournal(url: url).entries[id]?.state, "restart_admission_unknown")
        }
        let (journal, _, _) = try journal(state: "restart_admission_unknown")
        XCTAssertFalse(try journal.resolveUnadmittedRestarts(pane: pane, host: "another-host", proof: try proof()))
        XCTAssertFalse(try journal.resolveUnadmittedRestarts(pane: UUID(), host: host, proof: try proof()))
        // Other states are never touched.
        let (submitted, url, id) = try self.journal(state: "restart_submitted")
        XCTAssertFalse(try submitted.resolveUnadmittedRestarts(pane: pane, host: host, proof: try proof()))
        XCTAssertEqual(RelayAgentMaintenanceJournal(url: url).entries[id]?.state, "restart_submitted")
    }

    // MARK: stale draft_saved (111342dc, ddb6ab25, 27e6852d)

    @MainActor func testASavedDraftAlreadyInThePromptOfTheSameProcessIsSettled() throws {
        let draft = Data("check the joint fit residuals".utf8)
        let (journal, url, id) = try journal(state: "draft_saved", draft: draft)
        let value = try proof()
        XCTAssertNil(try journal.claim(pane: pane, host: host, proof: value, reason: .update))
        XCTAssertTrue(try journal.settleDraftAlreadyInPrompt(id, proof: value, prompt: draft))
        let saved = try XCTUnwrap(RelayAgentMaintenanceJournal(url: url).entries[id])
        XCTAssertEqual(saved.state, "draft_restored_without_restart")
        XCTAssertEqual(saved.draftRestored, true)
        XCTAssertNil(RelayAgentMaintenanceRestartAdmission.pendingDraftRestore(journal, paneID: pane, host: host,
            sessionID: "exact-session"))
        XCTAssertNotNil(try journal.claim(pane: pane, host: host, proof: value, reason: .update))
    }

    @MainActor func testASavedDraftStaysPendingUnlessThePromptAndProcessMatchExactly() throws {
        let draft = Data("check the joint fit residuals".utf8)
        var restarted = try proof(); restarted.processID = 43
        var session = try proof(); session.sessionID = "other"
        let cases: [(RelayAgentMaintenanceProbe, Data)] = [
            (try proof(), Data()),                                       // empty prompt: the restore path puts it back
            (try proof(), Data("check the joint fit".utf8)),             // different text: new input
            (try proof(), Data("check the joint fit residuals ".utf8)),  // not byte-exact
            (restarted, draft),                                          // another process
            (session, draft),                                            // another conversation
        ]
        for (value, prompt) in cases {
            let (journal, url, id) = try journal(state: "draft_saved", draft: draft)
            XCTAssertFalse(try journal.settleDraftAlreadyInPrompt(id, proof: value, prompt: prompt))
            let entry = try XCTUnwrap(RelayAgentMaintenanceJournal(url: url).entries[id])
            XCTAssertEqual(entry.state, "draft_saved")
            XCTAssertEqual(entry.draftRestored, false)
        }
        // A record already held for new input is left for the user.
        let (held, url, id) = try journal(state: "draft_restore_held", draft: draft)
        XCTAssertFalse(try held.settleDraftAlreadyInPrompt(id, proof: try proof(), prompt: draft))
        XCTAssertEqual(RelayAgentMaintenanceJournal(url: url).entries[id]?.state, "draft_restore_held")
    }
}
