import Foundation
import Testing
@testable import Relay

@Suite("Full screen hides the sidebar without changing the saved choice", .serialized)
struct SidebarFullScreenPersistenceTests {
    @MainActor private func withHidePreference(_ value: Bool, _ body: () async throws -> Void) async rethrows {
        let previous = RelayPreferences.shared.hideSidebarInFullScreen
        RelayPreferences.shared.hideSidebarInFullScreen = value
        defer { RelayPreferences.shared.hideSidebarInFullScreen = previous }
        try await body()
    }

    // 0.5.34 regression: the window came back in full screen, the auto-hide
    // ran, and the next save stored sidebarVisible=false as the user's choice.
    @MainActor @Test func autoHiddenSidebarIsSavedAsVisibleAndReturnsOnExit() async throws {
        try await withHidePreference(true) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-sidebar-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = WorkspaceModel(restoreSavedWorkspace: false, workspaceDirectory: directory)
            defer { workspace.shutdown() }
            workspace.sidebarVisible = true
            workspace.setFullScreen(true)
            #expect(!workspace.sidebarVisible && workspace.sidebarAutoHidden)
            #expect(workspace.savedSidebarVisible)
            workspace.persistWorkspace()
            try await Task.sleep(for: .milliseconds(600))
            let saved = try #require(try workspace.sharedWorkspaceStore.restore(legacy: nil))
            #expect(saved.sidebarVisible == true)
            workspace.setFullScreen(false)
            #expect(workspace.sidebarVisible && !workspace.sidebarAutoHidden)
        }
    }

    @MainActor @Test func aUserToggleInFullScreenIsTheSavedChoice() async {
        await withHidePreference(true) {
            let workspace = WorkspaceModel(restoreSavedWorkspace: false)
            defer { workspace.shutdown() }
            workspace.sidebarVisible = true
            workspace.setFullScreen(true)
            // Shown, then hidden again by the user while in full screen.
            workspace.sidebarVisible = true
            workspace.sidebarVisible = false
            #expect(!workspace.savedSidebarVisible)
            workspace.setFullScreen(false)
            #expect(!workspace.sidebarVisible)
            // A user show in full screen stays and is saved.
            workspace.setFullScreen(true)
            workspace.sidebarVisible = true
            #expect(workspace.savedSidebarVisible)
            workspace.setFullScreen(false)
            #expect(workspace.sidebarVisible)
        }
    }

    @MainActor @Test func aHiddenSidebarStaysHiddenAndThePreferenceIsHonoured() async {
        await withHidePreference(true) {
            let workspace = WorkspaceModel(restoreSavedWorkspace: false)
            defer { workspace.shutdown() }
            workspace.sidebarVisible = false
            workspace.setFullScreen(true)
            workspace.setFullScreen(false)
            #expect(!workspace.sidebarVisible && !workspace.savedSidebarVisible)
        }
        await withHidePreference(false) {
            let workspace = WorkspaceModel(restoreSavedWorkspace: false)
            defer { workspace.shutdown() }
            workspace.sidebarVisible = true
            workspace.setFullScreen(true)
            #expect(workspace.sidebarVisible && !workspace.sidebarAutoHidden)
            workspace.setFullScreen(false)
            #expect(workspace.sidebarVisible)
        }
    }
}
