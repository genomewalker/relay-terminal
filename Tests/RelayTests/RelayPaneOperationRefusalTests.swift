import Foundation
import Testing
@testable import Relay

/// Case 1 (0.5.113): every refusal of close, restart, update, account move or
/// resume carries {reason_code, blocker, how_to_clear} to the MCP result and
/// the UI, and the blocker is the operation's existing text.
@Suite("Pane operation refusals")
struct RelayPaneOperationRefusalTests {
    typealias Refusal = RelayPaneOperationRefusal

    private static let pane = UUID(uuidString: "7d85fd72-64ec-46a4-8591-567bf64f7c93")!
    private static func proof(_ extra: String = "") throws -> RelayAgentMaintenanceProbe {
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"quiet","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false"# +
            extra + "}"
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
    }
    private static let target = RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal")
    private static let resumable = #","resume_command":"/home/test/.local/bin/codex resume exact-session","move_command":"/home/test/.local/bin/codex resume exact-session""#

    @Test func everyCodeHasDistinctRawValueAndClearingAdvice() {
        let raw = Refusal.Code.allCases.map(\.rawValue)
        #expect(Set(raw).count == raw.count)
        for code in Refusal.Code.allCases {
            #expect(!code.howToClear.isEmpty, "\(code)")
            let refusal = Refusal(code, "held")
            #expect(refusal.fields == ["reason_code": code.rawValue, "blocker": "held", "how_to_clear": code.howToClear])
            #expect(refusal.localizedDescription == "held")
        }
    }

    /// relayd's PaneRefusal* constants (internal/daemon/pane_refusal.go) are
    /// all Swift codes, so a host refusal keeps its code.
    @Test func everyRelaydCodeIsKnown() {
        for code in ["identity_unavailable", "pane_changed", "resume_unavailable", "manual_restart_required", "login_mismatch",
                     "target_account_unavailable", "relaunch_unavailable", "outside_project", "launcher_unavailable",
                     "invalid_request", "trust_prompt", "unclassified"] {
            #expect(Refusal.Code(rawValue: code) != nil, "\(code)")
        }
    }

    @Test func aHostRefusalLineIsReadFromStderr() {
        let stderr = Data(("relayd: managed Codex launcher unavailable\n" +
            #"refusal: {"reason_code":"launcher_unavailable","blocker":"managed Codex launcher unavailable","how_to_clear":"Repair it."}"# + "\n").utf8)
        let refusal = Refusal.hostRefusal(stderr: stderr)
        #expect(refusal == Refusal(.launcherUnavailable, "managed Codex launcher unavailable", howToClear: "Repair it."))
        #expect(Refusal.hostBlocker(stderr: stderr) == "managed Codex launcher unavailable")
        // An older relayd prints only the blocker line.
        #expect(Refusal.hostRefusal(stderr: Data("relayd: something\n".utf8)) == nil)
        // A code this Relay does not know keeps the blocker, with generic advice.
        let unknown = Refusal.hostRefusal(stderr: Data(#"refusal: {"reason_code":"future_code","blocker":"b","how_to_clear":"x"}"#.utf8))
        #expect(unknown == Refusal(.unclassified, "b"))
    }

    @Test func eachMaintenanceDeferralHasItsCodeAndUnchangedText() throws {
        let proof = try Self.proof(Self.resumable)
        func reason(_ proof: RelayAgentMaintenanceProbe, empty: Bool = true, draft: Bool = false, approvals: Int = 0,
                    age: TimeInterval = 60, blocker: String? = nil) -> Refusal? {
            let typed = RelayAgentMaintenancePolicy.deferralReason(proof, paneID: Self.pane, emptyPrompt: empty, hasDraft: draft,
                pendingApprovals: approvals, inputAge: age, promptBlocker: blocker)
            #expect(typed?.blocker == RelayAgentMaintenancePolicy.deferral(proof, paneID: Self.pane, emptyPrompt: empty,
                hasDraft: draft, pendingApprovals: approvals, inputAge: age, promptBlocker: blocker))
            return typed
        }
        #expect(reason(proof) == nil)
        var invalid = proof; invalid.processID = nil
        #expect(reason(invalid)?.code == .identityUnavailable)
        #expect(reason(proof, approvals: 1)?.code == .approvalPending)
        #expect(reason(proof, draft: true)?.code == .draftPresent)
        var background = proof; background.backgroundWork = true
        #expect(reason(background)?.code == .backgroundWork)
        #expect(reason(proof, empty: false)?.code == .promptUnverified)
        #expect(reason(proof, empty: false, blocker: RelayAgentMaintenancePrompt.goalBlockerPrefix + " (Pursuing goal (3m))")?.code == .goalActive)
        #expect(reason(proof, empty: false, blocker: RelayAgentMaintenancePrompt.folderTrustBlocker)?.code == .trustPrompt)
        var settling = proof; settling.lifecycle = "settling"
        #expect(reason(settling)?.code == .transcriptSettling)
        settling.lifecycle = "active"
        #expect(reason(settling)?.code == .turnActive)
        #expect(reason(proof, age: 1)?.code == .userTyping)
        var unresumable = proof; unresumable.resumeCommand = nil
        unresumable.resumeError = "This custom Codex launch needs a manual restart."
        #expect(reason(unresumable)?.code == .manualRestartRequired)
        unresumable.resumeErrorCode = "relaunch_unavailable"
        #expect(reason(unresumable)?.code == .relaunchUnavailable)
        // relayd 0.5.77 sends this live text (2026-11-22, f62dee0f) with code
        // "unclassified"; Relay's table still names it.
        let live = "The initial Claude prompt is not verified incorporated in an idle conversation."
        unresumable.resumeError = live; unresumable.resumeErrorCode = "unclassified"
        #expect(reason(unresumable)?.code == .initialPromptUnproven)
        unresumable.resumeErrorCode = "initial_prompt_unproven"
        #expect(reason(unresumable)?.code == .initialPromptUnproven)
        unresumable.resumeError = "something entirely new"; unresumable.resumeErrorCode = "unclassified"
        #expect(reason(unresumable)?.code == .unclassified)
        unresumable.resumeError = nil; unresumable.resumeErrorCode = nil
        #expect(reason(unresumable) == Refusal(.resumeUnavailable, "The exact agent resume command is unavailable"))
    }

    @Test func aMoveRefusalNamesTheTargetAccountCode() throws {
        var proof = try Self.proof(Self.resumable)
        proof.moveCommand = nil
        proof.moveError = "This conversation is not visible from the target account. Turn on shared conversation history"
        proof.moveErrorCode = "target_account_unavailable"
        let refusal = RelayAgentAccountMovePolicy.refusalReason(proof, paneID: Self.pane, target: Self.target, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60)
        #expect(refusal?.code == .targetAccountUnavailable)
        var unproven = proof
        unproven.moveError = "The initial Claude prompt is not verified incorporated in an idle conversation."
        unproven.moveErrorCode = "unclassified"
        #expect(RelayAgentAccountMovePolicy.refusalReason(unproven, paneID: Self.pane, target: Self.target, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60)?.code == .initialPromptUnproven)
        #expect(refusal?.blocker == RelayAgentAccountMovePolicy.refusal(proof, paneID: Self.pane, target: Self.target,
            emptyPrompt: true, hasDraft: false, pendingApprovals: 0, inputAge: 60))
        let claude = RelayAgentAccount(provider: "claude", label: "max", dir: "~/.claude-max")
        #expect(RelayAgentAccountMovePolicy.refusalReason(proof, paneID: Self.pane, target: claude, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60)?.code == .targetAccountUnavailable)
        #expect(RelayAgentAccountMovePolicy.refusalReason(proof, paneID: Self.pane, target: Self.target, emptyPrompt: true,
            hasDraft: true, pendingApprovals: 0, inputAge: 60)?.code == .draftPresent)
    }

    @Test func aMoveOutcomeCarriesFieldsAndTheUIShowsHowToClear() {
        let refused = RelayAgentAccountMove.Outcome(state: "refused", message: "Waiting for the pending approval",
                                                    refusal: Refusal(.approvalPending, "Waiting for the pending approval"))
        #expect(refused.fields["status"] == "refused")
        #expect(refused.fields["reason_code"] == "approval_pending")
        #expect(refused.fields["how_to_clear"] == Refusal.Code.approvalPending.howToClear)
        #expect(refused.displayMessage == "Waiting for the pending approval To clear: " + Refusal.Code.approvalPending.howToClear)
        let verified = RelayAgentAccountMove.Outcome(state: "verified", message: "Moved")
        #expect(verified.fields == ["status": "verified", "message": "Moved"])
        #expect(verified.displayMessage == "Moved")
    }

    @Test func existingRefusalTextsAreClassified() {
        #expect(Refusal.classify("Relay cannot read this pane's screen: the pane is not connected") == .paneNotConnected)
        #expect(Refusal.classify("Maintenance or another move is acting on this pane; try again when it finishes.") == .operationInProgress)
        #expect(Refusal.classify("A permission prompt is waiting for your answer; a forced move does not answer it.") == .approvalPending)
        #expect(Refusal.classify("The agent changed while the move was being checked; nothing was sent.") == .paneChanged)
        #expect(Refusal.classify("Only the user can force an account move.") == .notAuthorized)
        // relayd's phClaudeInitialPromptRefusal: a launch prompt it cannot prove completed.
        #expect(Refusal.classify("The initial Claude prompt is not verified incorporated in an idle conversation.") == .initialPromptUnproven)
        #expect(Refusal.classify("The \("personal") account is not ready for this conversation; nothing was sent.") == .targetAccountUnavailable)
        #expect(Refusal.classify("something entirely new") == .unclassified)
    }

    @Test func eachResumeStartConditionHasItsOwnCode() {
        let id = UUID()
        let codex = RelayCodexPaneResumeRequest(instance: id, requestID: UUID(), expectedSession: UUID(), targetSession: UUID())
        let claude = RelayCodexPaneResumeRequest(instance: id, requestID: UUID(), expectedSession: UUID(), targetSession: UUID(),
                                                 provider: "claude")
        func code(_ request: RelayCodexPaneResumeRequest = codex, busy: Bool = false, authorized: Bool = true,
                  backend: RemoteSessionBackend = .relay, connection: PaneConnectionState = .connected,
                  content: PaneContentKind = .terminal) -> Refusal.Code? {
            RelayCodexPaneResume.startRefusal(request, busy: busy, authorized: authorized, backend: backend,
                                              connection: connection, content: content)?.code
        }
        #expect(code() == nil)
        #expect(code(claude) == .invalidRequest)
        #expect(code(busy: true) == .operationInProgress)
        // 0.5.113: a missing or expired grant is its own code (was not_authorized).
        #expect(code(authorized: false) == .authorizationGrant)
        #expect(code(backend: .direct) == .unsupportedPane)
        #expect(code(connection: .disconnected("gone")) == .paneNotConnected)
        #expect(code(content: .editor) == .unsupportedPane)
    }

    @Test func aResumeReceiptEncodesFlatFieldsAndOldReceiptsStillDecode() throws {
        let request = RelayCodexPaneResumeRequest(instance: UUID(), requestID: UUID(), expectedSession: UUID(), targetSession: UUID())
        var receipt = RelayCodexPaneResume.Receipt(paneID: Self.pane, request: request, state: "held",
            detail: "Exit submitted; the same retained empty shell was not verified (x). No resume was sent.", updatedAt: Date())
        receipt.set(Refusal(.exitNotVerified, receipt.detail))
        let object = try receipt.object()
        #expect(object["reason_code"] as? String == "exit_not_verified")
        #expect(object["blocker"] as? String == receipt.detail)
        #expect(object["how_to_clear"] as? String == Refusal.Code.exitNotVerified.howToClear)
        var old = object
        old.removeValue(forKey: "reason_code"); old.removeValue(forKey: "blocker"); old.removeValue(forKey: "how_to_clear")
        let decoded = try JSONDecoder().decode(RelayCodexPaneResume.Receipt.self,
                                               from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.state == "held" && decoded.reasonCode == nil)
    }

    @Test func theHTTPRefusalBodyIsStructuredJSON() throws {
        let response = RelaySidePanelHTTPResponse.refusal(Refusal(.notAuthorized, "MCP process termination is not granted"), status: 403)
        #expect(response.status == 403 && response.reason == "Forbidden")
        let body = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: String])
        #expect(body == ["status": "refused", "reason_code": "not_authorized", "blocker": "MCP process termination is not granted",
                         "how_to_clear": Refusal.Code.notAuthorized.howToClear])
        // The MCP bridge keeps the first 1024 bytes of a refusal body.
        #expect(response.body.count < 1024)
    }
}

/// Item 4 (0173baf5): relayd's outside-proxy refusal keeps its code in Swift,
/// from a coded refusal line and from the plain resume_error text alike.
@Test func aCodexOutsideRelaysProxyIsNamed() {
    let message = "This Codex runs outside Relay's proxy, attached directly to Codex's own app-server daemon (shared with Codex desktop); Relay does not exit or relaunch it."
    #expect(RelayPaneOperationRefusal.classify(message) == .nativeOutsideProxy)
    let line = #"refusal: {"reason_code":"native_outside_proxy","blocker":"x","how_to_clear":"y"}"#
    #expect(RelayPaneOperationRefusal.hostRefusal(stderr: Data(("relayd: x\n" + line + "\n").utf8))?.code == .nativeOutsideProxy)
}
