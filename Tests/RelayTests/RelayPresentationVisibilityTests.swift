import Testing
@testable import Relay

@Test("Visible workspaces remain live without keyboard ownership")
func visibleWorkspaceRemainsLive() {
    #expect(RelayPresentationVisibilityPolicy.allowsUpdates(
        applicationHidden: false, hasVisibleWorkspace: true
    ))
    #expect(!RelayPresentationVisibilityPolicy.allowsUpdates(
        applicationHidden: true, hasVisibleWorkspace: true
    ))
    #expect(!RelayPresentationVisibilityPolicy.allowsUpdates(
        applicationHidden: false, hasVisibleWorkspace: false
    ))
    #expect(!RelayPresentationVisibilityPolicy.allowsUpdates(
        applicationHidden: true, hasVisibleWorkspace: false
    ))
}
