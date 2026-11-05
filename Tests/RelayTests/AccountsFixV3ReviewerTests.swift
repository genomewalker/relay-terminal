import Foundation
import Testing
@testable import Relay

@Suite("Accounts fix v3 independent review")
@MainActor
struct AccountsFixV3ReviewerTests {
    @Test("An account summary reports a failed fresh check even when earlier usage has an identity")
    func failedCheckIsNotHiddenByUsageIdentity() throws {
        let directory = RelayAgentAccountDirectory()
        let account = RelayAgentAccount(provider: "claude", label: "work", dir: "")
        let usageJSON = #"""
        {"provider":"claude","label":"work","status":"ok","read_at":"2026-10-17T20:00:00Z",
         "windows":[{"name":"primary","used_percent":4,"window_minutes":300}],
         "email":"previous@example.org","plan":"max","identity_key":"previous-key"}
        """#
        let failedJSON = #"""
        {"provider":"claude","label":"work","dir":"~/.claude","root":"/fixture/.claude",
         "default":true,"exists":true,"logged_in":"unknown","probe":"failed"}
        """#
        let reading = try JSONDecoder().decode(RelayAgentAccountUsage.self, from: Data(usageJSON.utf8))
        let failed = try JSONDecoder().decode(RelayAgentAccountStatus.self, from: Data(failedJSON.utf8))
        directory.store([reading], fromHost: "local")
        directory.record([failed], executables: nil, fromHost: "local", probeRequested: true)
        let status = try #require(directory.status(for: .local, account: account))
        #expect(status.checkFailed && status.email == nil && status.identityKey == nil)
        let shown = directory.summary(for: .local, account: account)
        #expect(shown.contains("check failed"), "a failed fresh login check was hidden by the old usage identity: \(shown)")
    }
}
