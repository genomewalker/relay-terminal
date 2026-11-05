import Foundation
import Testing
@testable import Relay

@Suite("Accounts fix independent review")
@MainActor
struct AccountsFixReviewerTests {
    @Test("Removing a selected SSH alias must not redirect account actions to This Mac")
    func removedSelectedHostDoesNotBecomeLocal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-review-host-removal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alias = "relay-review-" + UUID().uuidString.prefix(8).lowercased()
        let config = root.appendingPathComponent("config")
        try Data("Host \(alias)\n    HostName \(alias).invalid\n".utf8).write(to: config)
        let store = ProfileStore()
        store.refreshSSHConfig(configURL: config)
        let chosen = try #require(RelayAgentAccountsSettingsView.hosts(store).first { $0.host == alias })
        let selection = RelayAgentAccountsSettingsView.selectionKey(chosen)
        try Data("# selected alias has been removed\n".utf8).write(to: config)
        store.refreshSSHConfig(configURL: config)
        let hosts = RelayAgentAccountsSettingsView.hosts(store)
        #expect(!hosts.contains { $0.host == alias })
        let resolved = RelayAgentAccountsSettingsView.host(selection, in: hosts)
        #expect(resolved.kind != .local, "remote choice \(selection) was silently redirected to \(resolved.name)")
    }
}
