import AppKit
import Testing
@testable import Relay

@Suite("Workspace window recovery geometry")
struct RelayWorkspaceWindowRecoveryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    @Test func visibleOffScreenWorkspaceNeedsRecovery() {
        #expect(RelayWorkspaceWindowRecoveryPolicy.needsPresentation(isVisible: true,
            isMiniaturized: false, frame: CGRect(x: 4000, y: 3000, width: 1320, height: 820),
            visibleScreenFrames: [screen]))
    }
    @Test func hiddenAndMiniaturizedWorkspacesNeedPresentation() {
        let frame = CGRect(x: 20, y: 20, width: 1320, height: 820)
        #expect(RelayWorkspaceWindowRecoveryPolicy.needsPresentation(isVisible: false,
            isMiniaturized: false, frame: frame, visibleScreenFrames: [screen]))
        #expect(RelayWorkspaceWindowRecoveryPolicy.needsPresentation(isVisible: true,
            isMiniaturized: true, frame: frame, visibleScreenFrames: [screen]))
    }
    @Test func visibleWorkspaceOnAnotherMonitorKeepsItsFrame() {
        let second = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        #expect(!RelayWorkspaceWindowRecoveryPolicy.needsPresentation(isVisible: true,
            isMiniaturized: false, frame: CGRect(x: -1600, y: 0, width: 1320, height: 820),
            visibleScreenFrames: [screen, second]))
    }
    @Test func displayHandoffDoesNotRelocateFromUnknownGeometry() {
        #expect(RelayWorkspaceWindowRecoveryPolicy.isOnScreen(
            frame: CGRect(x: -1600, y: 0, width: 1320, height: 820), visibleScreenFrames: []))
    }
}
