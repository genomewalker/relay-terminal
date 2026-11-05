import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Same-daemon pane pairs link through relayd")
struct PaneLinkDaemonRouteTests {
    private func terminal(_ host: String) -> PaneModel {
        PaneModel(profile: .sshConfigHost(host), contentKind: .terminal)
    }

    @Test func twoTerminalsOnOneRelaydShareItsProfile() throws {
        let codex = terminal("dandy-link.invalid"), claude = terminal("dandy-link.invalid")
        let profile = try #require(RelayPaneMessaging.sharedDaemonProfile([codex, claude]))
        #expect(profile.connectionKey == codex.profile.connectionKey)
    }

    @Test func panesOnDifferentHostsHaveNoSharedDaemon() {
        #expect(RelayPaneMessaging.sharedDaemonProfile([terminal("dandy-link.invalid"), terminal("other-link.invalid")]) == nil)
    }

    @Test func onlyExactlyTwoDistinctPanesFormAPair() {
        let pane = terminal("dandy-link.invalid")
        #expect(RelayPaneMessaging.sharedDaemonProfile([pane]) == nil)
        #expect(RelayPaneMessaging.sharedDaemonProfile([pane, pane]) == nil)
        #expect(RelayPaneMessaging.sharedDaemonProfile([pane, terminal("dandy-link.invalid"), terminal("dandy-link.invalid")]) == nil)
    }

    @Test func aDirectSSHPaneHasNoRelaydToAsk() {
        var direct = ConnectionProfile.sshConfigHost("dandy-link.invalid")
        direct.backend = .direct
        let pane = PaneModel(profile: direct, contentKind: .terminal)
        #expect(RelayPaneMessaging.sharedDaemonProfile([pane, terminal("dandy-link.invalid")]) == nil)
    }

    @Test func anEditorIsNotALinkablePane() {
        let editor = PaneModel(profile: .sshConfigHost("dandy-link.invalid"), contentKind: .editor)
        #expect(RelayPaneMessaging.sharedDaemonProfile([editor, terminal("dandy-link.invalid")]) == nil)
    }

    @Test func aCodexAppServerEndpointIsVerified() {
        let reply: [String: Any] = ["ok": true, "endpoint": ["transport": "codex_app_server_message", "pane_id": "x"]]
        #expect(RelayPaneMessaging.verifiedDaemonTransport(reply) == "codex_app_server_message")
        #expect(RelayPaneMessaging.verifiedDaemonTransport(["endpoint": ["transport": "native_peer_socket"]]) == "native_peer_socket")
    }

    @Test func anUnavailableOrMissingEndpointIsNotVerified() {
        #expect(RelayPaneMessaging.verifiedDaemonTransport(["endpoint": ["transport": "unavailable"]]) == nil)
        #expect(RelayPaneMessaging.verifiedDaemonTransport(["endpoint": ["transport": ""]]) == nil)
        #expect(RelayPaneMessaging.verifiedDaemonTransport(["endpoint": [:] as [String: Any]]) == nil)
        #expect(RelayPaneMessaging.verifiedDaemonTransport(["ok": false, "error": "No exact live agent session"]) == nil)
    }

    @Test func aPairIsReadyOnlyWhenBothPanesAreVerified() {
        let a = UUID(), b = UUID()
        #expect(RelayPaneMessaging.daemonPairVerified([a, b], transports: [a: "codex_app_server_message", b: "native_peer_socket"]))
        #expect(!RelayPaneMessaging.daemonPairVerified([a, b], transports: [a: "codex_app_server_message"]))
        #expect(!RelayPaneMessaging.daemonPairVerified([a], transports: [a: "native_peer_socket"]))
    }

    @Test func aFailedRecheckWithdrawsAnEarlierSuccess() {
        let a = UUID(), b = UUID()
        var check = RelayPaneMessaging.DaemonPairCheck()
        let first = check.begin()
        check.record(a, check: first, result: .success("codex_app_server_message"))
        check.record(b, check: first, result: .success("native_peer_socket"))
        #expect(RelayPaneMessaging.daemonPairVerified([a, b], transports: check.transports))
        let second = check.begin()
        check.record(a, check: second, result: .failure(RemoteCatalogError.failed("endpoint gone")))
        check.record(b, check: second, result: .failure(RemoteCatalogError.failed("endpoint gone")))
        #expect(check.transports.isEmpty)
        #expect(check.failures.count == 2)
        #expect(!RelayPaneMessaging.daemonPairVerified([a, b], transports: check.transports))
    }

    @Test func aSupersededReplyCannotRestoreSuccess() {
        let a = UUID()
        var check = RelayPaneMessaging.DaemonPairCheck()
        let older = check.begin()
        let newer = check.begin()
        check.record(a, check: newer, result: .failure(RemoteCatalogError.failed("endpoint gone")))
        check.record(a, check: older, result: .success("native_peer_socket"))
        #expect(check.transports[a] == nil)
        #expect(check.failures[a] != nil)
    }

    @Test func aSuccessClearsTheEarlierFailure() {
        let a = UUID()
        var check = RelayPaneMessaging.DaemonPairCheck()
        check.record(a, check: check.begin(), result: .failure(RemoteCatalogError.failed("not yet")))
        check.record(a, check: check.begin(), result: .success("native_peer_socket"))
        #expect(check.transports[a] == "native_peer_socket")
        #expect(check.failures[a] == nil)
    }
}
