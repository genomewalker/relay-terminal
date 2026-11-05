import Foundation
import Testing
@testable import Relay

@MainActor
struct RelayNavigationProfileIsolationTests {
    @Test func navigationReadsAndWritesConfiguredProfile() throws {
        let defaults = RelayStateProfile.defaults
        let key = "relay.workspace.navigation-state.v1"
        let backup = defaults.data(forKey: key)
        defer {
            if let backup { defaults.set(backup, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let written = UUID()
        _ = WorkspaceNavigationState.updating { $0.visibleWorkspace = written }
        let data = try #require(defaults.data(forKey: key), "NAVIGATION_WRITES_CONFIGURED_PROFILE")
        #expect(try JSONDecoder().decode(WorkspaceNavigationState.self, from: data).visibleWorkspace == written,
                "NAVIGATION_WRITES_CONFIGURED_PROFILE")
        var external = WorkspaceNavigationState()
        external.visibleWorkspace = UUID()
        defaults.set(try JSONEncoder().encode(external), forKey: key)
        #expect(WorkspaceNavigationState.load().visibleWorkspace == external.visibleWorkspace,
                "NAVIGATION_READS_CONFIGURED_PROFILE")
    }
}
