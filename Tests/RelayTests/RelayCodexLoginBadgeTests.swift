import Foundation
import Testing
@testable import Relay

/// The incident: ~/.codex-personal held the business login while its panes
/// showed "personal". The badge must turn red and name the real login.
@Suite("Codex login pin: probe decode, badge and pane list")
@MainActor
struct RelayCodexLoginBadgeTests {
    func probe(_ login: String) throws -> RelayAgentMaintenanceProbe {
        let json = #"{"version":1,"provider":"codex","config_dir":"~/.codex-personal","login":\#(login)}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
    }

    func state(_ login: RelayAgentLoginObservation?) -> RelayPaneAgentAccountState {
        var state = RelayPaneAgentAccountState(recorded: RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal"))
        state.observedProvider = "codex"
        state.observedDirectory = "~/.codex-personal"
        state.observedLabel = "personal"
        state.observedMatches = true
        state.observedLogin = login
        return state
    }

    @Test func mismatchIsRedAndNamesTheRealLogin() throws {
        let login = try #require(try probe(#"{"status":"mismatch","label":"personal","expected":"4fea6400","state":"chatgpt","account":"02bb1caa","plan":"self_serve_business_prolite","started_before_login_change":true}"#).login)
        #expect(login.startedBeforeLoginChange == true)
        let state = state(login)
        #expect(state.loginMismatch)
        #expect(!state.mismatch)
        #expect(state.displayLabel == "personal · login 02bb1caa… (self_serve_business_prolite)")
        #expect(RelayAgentAccountBadge.tint(state) == RelayTheme.red)
        let help = RelayAgentAccountBadge.help(state, label: state.displayLabel ?? "")
        #expect(help.contains("4fea6400") && help.contains("02bb1caa") && help.contains("until it is restarted"))
    }

    @Test func unpinnedUnknownAndOlderHostsAreNotRed() throws {
        for status in ["unpinned", "unknown", "match", "unregistered"] {
            let login = try #require(try probe(#"{"status":"\#(status)","state":"chatgpt","account":"02bb1caa","plan":"pro"}"#).login)
            let state = state(login)
            #expect(!state.loginMismatch)
            #expect(RelayAgentAccountBadge.tint(state) == nil)
            #expect(state.displayLabel == "personal")
            // Unpinned or unreadable: an amber outline, the label unverified.
            #expect((RelayAgentAccountBadge.unverifiedStroke(state) != nil) == ["unpinned", "unknown"].contains(status))
        }
        // A host relayd that does not report the login.
        #expect(try probe("null").login == nil)
        #expect(RelayAgentAccountBadge.tint(state(nil)) == nil)
    }

    /// Logging the folder in again does not fix a running process: it keeps
    /// the token it loaded, so the pane stays red until it restarts.
    @Test func aFixedFolderKeepsTheRestartWarningUntilTheProcessIsNew() throws {
        let pane = PaneModel(profile: .sshConfigHost("owned-peer.invalid"))
        pane.recordAgentAccount(RelayAgentAccount(provider: "codex", label: "personal", dir: "~/.codex-personal"))
        let log = RelayActivityLog()
        let wrong = RelayAgentLoginObservation(status: "mismatch", label: "personal", expected: "4fea6400",
            state: "chatgpt", account: "02bb1caa", plan: "self_serve_business_prolite", startedBeforeLoginChange: false)
        pane.observeAgentLogin(wrong, activity: log)
        #expect(pane.agentAccount?.loginMismatch == true)
        #expect(log.entries.count == 1 && log.entries[0].summary.contains("02bb1caa"))
        pane.observeAgentLogin(wrong, activity: log)
        #expect(log.entries.count == 1)
        var fixed = RelayAgentLoginObservation(status: "match", label: "personal", expected: "4fea6400",
            state: "chatgpt", account: "4fea6400", plan: "pro", startedBeforeLoginChange: true)
        pane.observeAgentLogin(fixed, activity: log)
        #expect(pane.agentAccount?.loginMismatch == true)
        #expect(pane.agentAccount?.displayLabel == "personal · restart for login")
        #expect(pane.agentAccount?.observedLogin?.mismatchDescription?.contains("restarted") == true)
        pane.observeAgentLogin(fixed, activity: log)
        #expect(pane.agentAccount?.loginMismatch == true)
        // The restarted process started after the fix.
        fixed.startedBeforeLoginChange = false
        pane.observeAgentLogin(fixed, activity: log)
        #expect(pane.agentAccount?.loginMismatch == false)
        #expect(pane.agentAccount?.displayLabel == "personal")
    }

    /// A move is how a pane leaves a wrong-login folder: relayd withholds the
    /// same-pane resume there, and the move must not wait for it.
    @Test func aMoveLeavesAWrongLoginFolderWithoutASamePaneResume() throws {
        let json = #"{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","bound":true,"lifecycle":"quiet","revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","owner":{"version":1,"pane_id":"7d85fd72-64ec-46a4-8591-567bf64f7c93","node_boot_id":"boot","worker_pid":10,"worker_start":11,"shell_pid":12,"shell_start":13,"provider":"codex","process_id":42,"process_start":99,"session_id":"exact-session","transcript_identity":"1:2"},"installed_update":false,"resume_error":"Codex account personal (~/.codex-personal) is pinned to ChatGPT account 4fea6400… but its auth.json is logged in to 02bb1caa….","move_command":"/home/test/.local/bin/codex resume exact-session","login":{"status":"mismatch","label":"personal","expected":"4fea6400","state":"chatgpt","account":"02bb1caa"}}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var proof = try decoder.decode(RelayAgentMaintenanceProbe.self, from: Data(json.utf8))
        let pane = UUID(uuidString: "7d85fd72-64ec-46a4-8591-567bf64f7c93")!
        let target = RelayAgentAccount(provider: "codex", label: "work", dir: "")
        #expect(RelayAgentAccountMovePolicy.refusal(proof, paneID: pane, target: target, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60) == nil)
        // A same-pane restart there is refused with relayd's reason.
        #expect(RelayAgentMaintenancePolicy.deferral(proof, paneID: pane, emptyPrompt: true, hasDraft: false,
            pendingApprovals: 0, inputAge: 60)?.contains("02bb1caa") == true)
        // Without the login reason a missing resume still holds a move.
        proof.login = nil
        #expect(RelayAgentAccountMovePolicy.refusal(proof, paneID: pane, target: target, emptyPrompt: true,
            hasDraft: false, pendingApprovals: 0, inputAge: 60) != nil)
    }

    @Test func persistedStateWithoutLoginStillDecodes() throws {
        let data = #"{"recorded":{"provider":"codex","label":"personal","dir":"~/.codex-personal"}}"#
        let state = try JSONDecoder().decode(RelayPaneAgentAccountState.self, from: Data(data.utf8))
        #expect(state.observedLogin == nil && !state.loginMismatch)
    }
}
