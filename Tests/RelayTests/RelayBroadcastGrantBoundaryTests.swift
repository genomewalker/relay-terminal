import Foundation
import Testing
@testable import Relay

/// Broadcast and auto-link scopes are the user's own grants: only Relay's
/// native menus write them. The settings API (relay_update_settings, and
/// Miko's update_settings through it) is typed and must not name them.
struct RelayBroadcastGrantBoundaryTests {
    @Test("The settings API defines no broadcast or auto-link grant and rejects their keys")
    func settingsCannotGrant() {
        let names = RelaySettingsPolicy.definitions.map { $0.key.lowercased() }
        #expect(!names.contains { $0.contains("broadcast") || $0.contains("auto_link") || $0.contains("auto-link") || $0.contains("autolink") })
        let scope = "tab:" + UUID().uuidString.lowercased()
        for key in ["relay.broadcast.scopes.v1", "relay.auto-link.scopes.v1", "relay.auto-link.owned.v1", "broadcast", "broadcast_scopes", "auto_link"] {
            for value in [RelaySettingValue.string(scope), .bool(true)] {
                #expect(throws: (any Error).self, "\(key) was accepted") { try RelaySettingsPolicy.validate([key: value]) }
            }
        }
    }
}
