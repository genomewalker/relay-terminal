import Foundation
import Testing
@testable import Relay

/// 2026-11-20: each preserving update reopened the window out of full screen.
@MainActor
@Suite struct RelayWorkspaceFullScreenMemoryTests {
    private func memory() -> (RelayWorkspaceFullScreenMemory, UserDefaults) {
        let defaults = UserDefaults(suiteName: "relay-fullscreen-test-\(UUID().uuidString)")!
        return (RelayWorkspaceFullScreenMemory(defaults: defaults), defaults)
    }

    @Test func aWindowInFullScreenAtQuitReopensInFullScreen() {
        let (before, defaults) = memory()
        before.windowDidChangeFullScreen(true)
        before.applicationWillTerminate()
        // AppKit may take the window out of full screen while quitting.
        before.windowDidChangeFullScreen(false)
        let relaunched = RelayWorkspaceFullScreenMemory(defaults: defaults)
        #expect(relaunched.shouldRestore(windowIsFullScreen: false))
    }

    @Test func leavingFullScreenBeforeQuitReopensAWindow() {
        let (before, defaults) = memory()
        before.windowDidChangeFullScreen(true)
        before.windowDidChangeFullScreen(false)
        let relaunched = RelayWorkspaceFullScreenMemory(defaults: defaults)
        #expect(!relaunched.shouldRestore(windowIsFullScreen: false))
    }

    @Test func onlyTheFirstWindowOfALaunchIsRestored() {
        let (before, defaults) = memory()
        before.windowDidChangeFullScreen(true)
        let relaunched = RelayWorkspaceFullScreenMemory(defaults: defaults)
        #expect(relaunched.shouldRestore(windowIsFullScreen: false))
        #expect(!relaunched.shouldRestore(windowIsFullScreen: false))
    }

    @Test func aWindowAlreadyInFullScreenIsLeftAlone() {
        let (before, defaults) = memory()
        before.windowDidChangeFullScreen(true)
        let relaunched = RelayWorkspaceFullScreenMemory(defaults: defaults)
        #expect(!relaunched.shouldRestore(windowIsFullScreen: true))
    }
}
