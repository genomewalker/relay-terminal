import XCTest
@testable import Relay

final class RelayAgentMaintenanceTests: XCTestCase {
    let pane = UUID(uuidString: "7d85fd72-64ec-46a4-8591-567bf64f7c93")!

    func proof(provider: String = "codex") throws -> RelayAgentMaintenanceProbe {
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","bound":false,"lifecycle":"quiet","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"resume_command":"/home/test/.local/bin/codex resume exact-session"}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayAgentMaintenanceProbe.self,
            from: Data(json.replacingOccurrences(of: "\"codex\"", with: "\"" + provider + "\"").utf8))
    }

    func testNativeWireIdentityIsExact() throws {
        let value = try proof()
        XCTAssertTrue(value.valid(for: pane))
        XCTAssertFalse(value.valid(for: UUID()))
        var other = value; other.processStart = 100
        XCTAssertFalse(other.sameSource(as: value))
        XCTAssertFalse(other.valid(for: pane))
    }

    func testAValidIdleEmptyPromptCanBeMaintained() throws {
        XCTAssertNil(RelayAgentMaintenancePolicy.deferral(try proof(), paneID: pane,
            emptyPrompt: true, hasDraft: false, pendingApprovals: 0, inputAge: 60))
    }

    func testClaudeBackgroundWorkMustBeRuledOutBeforeExit() throws {
        var value = try proof(provider: "claude")
        for state in [nil, true] as [Bool?] {
            value.backgroundWork = state
            XCTAssertNotNil(RelayAgentMaintenancePolicy.deferral(value, paneID: pane,
                emptyPrompt: true, hasDraft: false, pendingApprovals: 0, inputAge: 60))
        }
        value.backgroundWork = false
        XCTAssertNil(RelayAgentMaintenancePolicy.deferral(value, paneID: pane,
            emptyPrompt: true, hasDraft: false, pendingApprovals: 0, inputAge: 60))
    }

    func testDraftsApprovalsRecentInputAndActiveTurnsDefer() throws {
        var value = try proof()
        XCTAssertNotNil(RelayAgentMaintenancePolicy.deferral(value, paneID: pane,
            emptyPrompt: false, hasDraft: false, pendingApprovals: 0, inputAge: 60))
        XCTAssertNotNil(RelayAgentMaintenancePolicy.deferral(value, paneID: pane,
            emptyPrompt: true, hasDraft: true, pendingApprovals: 0, inputAge: 60))
        XCTAssertNotNil(RelayAgentMaintenancePolicy.deferral(value, paneID: pane,
            emptyPrompt: true, hasDraft: false, pendingApprovals: 1, inputAge: 60))
        XCTAssertNotNil(RelayAgentMaintenancePolicy.deferral(value, paneID: pane,
            emptyPrompt: true, hasDraft: false, pendingApprovals: 0, inputAge: 1))
        value.lifecycle = "active"
        XCTAssertNotNil(RelayAgentMaintenancePolicy.deferral(value, paneID: pane,
            emptyPrompt: true, hasDraft: false, pendingApprovals: 0, inputAge: 60))
    }

    func testTerminalTextCannotAuthorizeAnUpdateRestart() throws {
        var value = try proof(); value.bound = true; value.provider = "claude"
        XCTAssertNil(RelayAgentMaintenancePolicy.reason(value, updateBanner: true))
        value.installedUpdate = true
        XCTAssertEqual(RelayAgentMaintenancePolicy.reason(value, updateBanner: false), .update)
    }

    func testNativeMaintenanceDoesNotWaitForAModelRequest() throws {
        XCTAssertTrue(RelayAgentMaintenancePolicy.modelRequestIsCurrent(nil, reason: .update,
            evidenceID: "native-evidence"))
        XCTAssertTrue(RelayAgentMaintenancePolicy.modelRequestIsCurrent(nil, reason: .binding,
            evidenceID: "native-evidence"))
        // Removing the advisory-model gate does not admit a draft or active turn.
        var value = try proof()
        XCTAssertNotNil(RelayAgentMaintenancePolicy.deferral(value, paneID: pane,
            emptyPrompt: true, hasDraft: true, pendingApprovals: 0, inputAge: 60))
        value.lifecycle = "active"
        XCTAssertNotNil(RelayAgentMaintenancePolicy.deferral(value, paneID: pane,
            emptyPrompt: true, hasDraft: false, pendingApprovals: 0, inputAge: 60))
    }

    func testModelRequestedMaintenanceStillRequiresFreshExactEvidence() {
        let now = Date()
        let grant = RelayAgentMaintenancePolicy.ModelGrant(operationID: "operation", toolID: "tool",
            action: "apply_installed_update", evidenceID: "exact-evidence", expires: now.addingTimeInterval(10))
        XCTAssertTrue(RelayAgentMaintenancePolicy.modelRequestIsCurrent(grant, reason: .update,
            evidenceID: "exact-evidence", now: now))
        XCTAssertFalse(RelayAgentMaintenancePolicy.modelRequestIsCurrent(grant, reason: .binding,
            evidenceID: "exact-evidence", now: now))
        XCTAssertFalse(RelayAgentMaintenancePolicy.modelRequestIsCurrent(grant, reason: .update,
            evidenceID: "other-evidence", now: now))
        XCTAssertFalse(RelayAgentMaintenancePolicy.modelRequestIsCurrent(grant, reason: .update,
            evidenceID: "exact-evidence", now: grant.expires))
    }

    func testClaudeUsesSupportedExitAndRequiresAnExactResumePlan() throws {
        XCTAssertEqual(RelayAgentMaintenancePolicy.exitCommand(provider: "claude"), "/exit")
        XCTAssertEqual(RelayAgentMaintenancePolicy.exitCommand(provider: "codex"), "/quit")
        XCTAssertNil(RelayAgentMaintenancePolicy.exitCommand(provider: "shell"))
        var value = try proof()
        let old = try XCTUnwrap(value.owner)
        value.provider = "claude"
        value.owner = RelayPromptOwnerBinding(version: old.version, paneId: old.paneId,
            nodeBootId: old.nodeBootId, workerPid: old.workerPid, workerStart: old.workerStart,
            shellPid: old.shellPid, shellStart: old.shellStart, provider: "claude",
            processId: old.processId, processStart: old.processStart, sessionId: old.sessionId,
            transcriptIdentity: old.transcriptIdentity)
        XCTAssertTrue(value.valid(for: pane))
        value.resumeCommand = nil
        value.resumeError = "The original launch options need review"
        value.backgroundWork = false
        XCTAssertEqual(RelayAgentMaintenancePolicy.deferral(value, paneID: pane,
            emptyPrompt: true, hasDraft: false, pendingApprovals: 0, inputAge: 60), value.resumeError)
    }

    @MainActor func testRestartJournalSurvivesRelaunchAndHoldsUnknownActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("journal.json")
        let journal = RelayAgentMaintenanceJournal(url: path)
        let value = try proof()
        let id = try XCTUnwrap(journal.claim(pane: pane, host: "exact-host", proof: value, reason: .binding))
        XCTAssertEqual(RelayAgentMaintenanceJournal(url: path).entries[id]?.resumeCommand, value.resumeCommand)
        XCTAssertEqual(RelayAgentMaintenanceJournal(url: path).entries[id]?.originalOwner, value.owner)
        XCTAssertNil(try RelayAgentMaintenanceJournal(url: path).claim(pane: pane,
            host: "exact-host", proof: value, reason: .update))
        var changed = value; changed.processID = 43
        XCTAssertNil(try journal.claim(pane: pane, host: "exact-host", proof: changed, reason: .binding))
        try journal.mark(id, "verified")
        XCTAssertEqual(RelayAgentMaintenanceJournal(url: path).entries[id]?.state, "verified")
        XCTAssertNil(try journal.claim(pane: pane, host: "exact-host", proof: changed, reason: .binding))
    }

    @MainActor func testAnInterruptedRepairRequiresTheExactFreshNativeBinding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("journal.json")
        let journal = RelayAgentMaintenanceJournal(url: path)
        var value = try proof()
        let id = try XCTUnwrap(journal.claim(pane: pane, host: "exact-host", proof: value, reason: .binding))
        try journal.mark(id, "resume_submitted")
        let reloaded = RelayAgentMaintenanceJournal(url: path)
        XCTAssertFalse(try reloaded.reconcileBinding(pane: pane, host: "exact-host", proof: value))
        value.bound = true
        XCTAssertFalse(try reloaded.reconcileBinding(pane: pane, host: "another-host", proof: value))
        var another = value
        another.sessionID = "another-session"
        XCTAssertFalse(try reloaded.reconcileBinding(pane: pane, host: "exact-host", proof: another))
        XCTAssertEqual(reloaded.entries[id]?.state, "resume_submitted")
        XCTAssertTrue(try reloaded.reconcileBinding(pane: pane, host: "exact-host", proof: value))
        XCTAssertEqual(RelayAgentMaintenanceJournal(url: path).entries[id]?.state, "verified")
        XCTAssertFalse(try reloaded.reconcileBinding(pane: pane, host: "exact-host", proof: value))
    }

    @MainActor func testAnInterruptedUpdateRequiresTheExactInstalledRunningImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RelayAgentMaintenanceJournal(url: directory.appendingPathComponent("journal.json"))
        var value = try proof(); value.bound = true; value.installedUpdate = true
        let id = try XCTUnwrap(journal.claim(pane: pane, host: "host", proof: value, reason: .update))
        try journal.mark(id, "verification_required")
        value.installedUpdate = false
        XCTAssertFalse(try journal.reconcileBinding(pane: pane, host: "host", proof: value))
        value.installedImageCurrent = true
        XCTAssertFalse(try journal.reconcileBinding(pane: pane, host: "another-host", proof: value))
        XCTAssertTrue(try journal.reconcileBinding(pane: pane, host: "host", proof: value))
        XCTAssertEqual(journal.entries[id]?.state, "verified")
    }

    func testNativeVersionsDecodeAndOnlyAKnownChangeIsATransition() throws {
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"codex","running_version":"0.160.1","installed_version":"0.162.1","installed_image_current":false}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var value = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        XCTAssertEqual(value.versionTransition, "0.160.1 → 0.162.1")
        value.installedVersion = "0.160.1"
        XCTAssertNil(value.versionTransition)
        value.runningVersion = nil
        XCTAssertNil(value.versionTransition)
        XCTAssertNil(RelayAgentMaintenance.AgentVersion(value, paneID: pane))
        var valid = try proof(); valid.runningVersion = "0.160.1"; valid.installedVersion = "0.162.1"
        valid.installedUpdate = true; valid.installedImageCurrent = false
        let row = try XCTUnwrap(RelayAgentMaintenance.AgentVersion(valid, paneID: pane))
        XCTAssertEqual([row.provider, row.running, row.installed], ["codex", "0.160.1", "0.162.1"])
        XCTAssertTrue(row.updateInstalled); XCTAssertEqual(row.imageCurrent, false)
        XCTAssertFalse(row.outdatedOtherInstall)
    }

    func testANewerCopyInAnotherInstallIsReportedButNeverAnUpdateReason() throws {
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"quiet","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"installed_image_current":false,"running_version":"0.160.1","installed_version":"0.162.1","outdated_other_install":true}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        XCTAssertNil(RelayAgentMaintenancePolicy.reason(value, updateBanner: false))
        XCTAssertEqual(RelayAgentMaintenance.AgentVersion(value, paneID: pane)?.outdatedOtherInstall, true)
    }

    func testAnUpdateIsAppliedOnlyWhenTheResumedProcessRunsTheInstalledImage() throws {
        for provider in ["claude", "codex"] {
            var before = try proof(provider: provider); before.bound = true; before.installedUpdate = true
            var after = before; after.processID = 43; after.processStart = 100; after.installedUpdate = false
            // A resume that PATH sent to an older copy is not an applied update.
            after.installedImageCurrent = false
            XCTAssertFalse(RelayAgentMaintenancePolicy.updateApplied(before: before, after: after))
            after.installedImageCurrent = true
            XCTAssertTrue(RelayAgentMaintenancePolicy.updateApplied(before: before, after: after))
            // A current reader that could not compare the image: new PID, flag cleared, identity unknown.
            after.installedImageCurrent = nil
            XCTAssertFalse(RelayAgentMaintenancePolicy.updateApplied(before: before, after: after))
        }
    }

    @MainActor func testCompletionRecoveryAndJournalAgreeOnImageIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for provider in ["claude", "codex"] {
            for (current, verified) in [(nil, false), (false, false), (true, true)] as [(Bool?, Bool)] {
                var before = try proof(provider: provider); before.bound = true; before.installedUpdate = true
                // The same native owner keeps the proof valid for the journal check.
                var after = before; after.installedUpdate = false; after.installedImageCurrent = current
                XCTAssertEqual(RelayAgentMaintenancePolicy.updateApplied(before: before, after: after), verified)
                let journal = RelayAgentMaintenanceJournal(url: directory.appendingPathComponent(UUID().uuidString + ".json"))
                let id = try XCTUnwrap(journal.claim(pane: pane, host: "host", proof: before, reason: .update,
                    modelOperationID: "op", modelToolID: "tool"))
                let entry = try XCTUnwrap(journal.entries[id])
                XCTAssertEqual(RelayAgentMaintenance.recoveredReceipt(entry, pane: pane, host: "host", proof: after,
                    operationID: "op", toolID: "tool", updateApplied: true), verified)
                XCTAssertEqual(try journal.reconcileBinding(pane: pane, host: "host", proof: after), verified)
            }
        }
    }

    @MainActor func testAnInterruptedCodexUpdateReconcilesFromItsInstalledImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RelayAgentMaintenanceJournal(url: directory.appendingPathComponent("journal.json"))
        var value = try proof(); value.bound = true; value.installedUpdate = true; value.installedImageCurrent = false
        let id = try XCTUnwrap(journal.claim(pane: pane, host: "host", proof: value, reason: .update))
        try journal.mark(id, "verification_required")
        value.installedUpdate = false
        XCTAssertFalse(try journal.reconcileBinding(pane: pane, host: "host", proof: value))
        value.installedImageCurrent = true
        XCTAssertTrue(try journal.reconcileBinding(pane: pane, host: "host", proof: value))
    }

    @MainActor func testRecoveredUpdateReceiptNeedsTheInstalledImageProof() throws {
        var value = try proof(); value.bound = true; value.installedUpdate = false
        let entry = RelayAgentMaintenanceJournal.Entry(id: "a", paneID: pane, host: "host", reason: .update,
            sessionID: "exact-session", createdAt: Date(), state: "verification_unknown", modelOperationID: "op",
            modelToolID: "tool", resumeCommand: nil, originalOwner: nil, originalProcessID: 42, originalProcessStart: 99)
        for (current, verified) in [(false, false), (nil, false), (true, true)] as [(Bool?, Bool)] {
            value.installedImageCurrent = current
            XCTAssertEqual(RelayAgentMaintenance.recoveredReceipt(entry, pane: pane, host: "host", proof: value,
                operationID: "op", toolID: "tool", updateApplied: true), verified)
        }
        XCTAssertFalse(RelayAgentMaintenance.recoveredReceipt(entry, pane: pane, host: "host", proof: value,
            operationID: "op", toolID: "tool", updateApplied: false))
    }

    @MainActor func testLaterUpdateInTheSameProcessGetsADistinctJournalIdentityAfterCooldown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("journal.json")
        let first = RelayAgentMaintenanceJournal(url: path)
        var value = try proof()
        let id = try XCTUnwrap(first.claim(pane: pane, host: "exact-host", proof: value, reason: .update))
        try first.mark(id, "verified")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: [String: Any]])
        rows[id]?["createdAt"] = Date().addingTimeInterval(-3601).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: rows).write(to: path)
        value.revision = String(repeating: "b", count: 64)
        let reloaded = RelayAgentMaintenanceJournal(url: path)
        let next = try XCTUnwrap(reloaded.claim(pane: pane, host: "exact-host", proof: value, reason: .update,
            modelOperationID: String(repeating: "1", count: 32), modelToolID: "toolu_update"))
        XCTAssertNotEqual(id, next)
        XCTAssertEqual(reloaded.entries[next]?.modelToolID, "toolu_update")
        XCTAssertNil(try reloaded.claim(pane: pane, host: "exact-host", proof: value, reason: .update))
    }
}
