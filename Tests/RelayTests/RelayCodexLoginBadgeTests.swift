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

    @Test func unpinnedUnknownAndOlderHostsStayNeutral() throws {
        for status in ["unpinned", "unknown", "match", "unregistered"] {
            let login = try #require(try probe(#"{"status":"\#(status)","state":"chatgpt","account":"02bb1caa","plan":"pro"}"#).login)
            let state = state(login)
            #expect(!state.loginMismatch)
            #expect(RelayAgentAccountBadge.tint(state) == nil)
            #expect(state.displayLabel == "personal")
        }
        // A host relayd that does not report the login.
        #expect(try probe("null").login == nil)
        #expect(RelayAgentAccountBadge.tint(state(nil)) == nil)
    }

    @Test func persistedStateWithoutLoginStillDecodes() throws {
        let data = #"{"recorded":{"provider":"codex","label":"personal","dir":"~/.codex-personal"}}"#
        let state = try JSONDecoder().decode(RelayPaneAgentAccountState.self, from: Data(data.utf8))
        #expect(state.observedLogin == nil && !state.loginMismatch)
    }
}
