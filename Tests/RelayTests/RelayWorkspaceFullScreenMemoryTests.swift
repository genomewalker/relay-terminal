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

@Suite struct RelayQuickLookSymbolTests {
    @Test func theBarIconSaysWhatKindOfItemIsShown() {
        func symbol(_ path: String) -> String { RelayQuickLookItem(source: .localFile(path), openLink: path).symbol }
        #expect(symbol("/tmp/a.PNG") == "photo")
        #expect(symbol("/tmp/paper.pdf") == "doc.richtext")
        #expect(symbol("/tmp/change.diff") == "doc.text")
        #expect(symbol("/tmp/blob") == "doc")
        #expect(RelayQuickLookItem(source: .web(URL(string: "https://example.org")!), openLink: "").symbol == "globe")
    }
}
