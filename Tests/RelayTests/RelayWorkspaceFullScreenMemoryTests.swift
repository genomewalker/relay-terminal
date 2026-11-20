import Foundation
import UniformTypeIdentifiers
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

@Suite struct RelayQuickLookTypeTests {
    /// The bar shows macOS's own icon for the item's type, local or remote.
    @Test func macOSDecidesTheTypeFromTheNameForLocalAndRemoteFiles() {
        let remote = ConnectionProfile(name: "dandy", kind: .ssh, backend: .direct)
        #expect(RelayQuickLookItem(source: .localFile("/tmp/a.PNG"), openLink: "").contentType == .png)
        #expect(RelayQuickLookItem(source: .remoteFile(remote, path: "~/paper.pdf", cwd: nil), openLink: "").contentType == .pdf)
        #expect(RelayQuickLookItem(source: .localFile("/tmp/blob"), openLink: "").contentType == .data)
        #expect(RelayQuickLookItem(source: .web(URL(string: "https://example.org")!), openLink: "").contentType == nil)
    }
}

/// 2026-11-20: files dropped on a Mac pane were uploaded into a staging folder,
/// and previews used Relay's own floating viewer instead of Quick Look.
@Suite struct RelayLocalFilesTests {
    @Test func aDropOnAMacPaneUsesTheFilesWhereTheyAre() {
        let urls = [URL(fileURLWithPath: "/Users/me/data/a.csv"), URL(fileURLWithPath: "/tmp/b c.png")]
        #expect(TerminalDropPolicy.localPaths(for: urls, profileKind: .local) == ["/Users/me/data/a.csv", "/tmp/b c.png"])
        #expect(TerminalDropPolicy.localPaths(for: urls, profileKind: .ssh) == nil)
        #expect(TerminalDropPolicy.localPaths(for: [], profileKind: .local) == nil)
    }

    @Test func previewsOfRealFilesOpenInQuickLook() {
        #expect(PaneArtifact.opensInQuickLook("/tmp/claude-501/tasks/bxbck9x8v.output"))
        #expect(PaneArtifact.opensInQuickLook("~/project/fig.pdf"))
        #expect(!PaneArtifact.opensInQuickLook("Provider image.png"))
    }

    @Test func theInPanePreviewUsesTheFilesOwnType() {
        #expect(PaneArtifact(remotePath: "/tmp/a/fig.png", data: Data()).contentType == .png)
        #expect(PaneArtifact(remotePath: "/tmp/a/paper.pdf", data: Data()).contentType == .pdf)
        #expect(PaneArtifact(remotePath: "/tmp/tasks/bxbck9x8v.output", data: Data()).contentType != .png)
    }
}
