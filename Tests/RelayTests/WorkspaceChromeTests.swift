import Foundation
import Testing
@testable import Relay

@Test @MainActor func chromeSuspensionRequiresExplicitResume() throws {
    let chrome = WorkspaceChrome()
    let a = WorkspaceContextAnchor(paneID: UUID(), profile: .local, directory: "/a")
    let b = WorkspaceContextAnchor(paneID: UUID(), profile: .local, directory: "/b")
    chrome.reveal(.files, initial: a)
    chrome.setFollowing(true)
    let old = try #require(chrome.beginRead())
    chrome.suspendPresentation()
    #expect(chrome.visible) // Saved visibility is independent of tab activity.
    #expect(chrome.beginRead() == nil)
    #expect(!chrome.accepts(old))
    chrome.activeContextChanged(b)
    #expect(chrome.anchor == a)
    chrome.resumePresentation()
    #expect(!chrome.accepts(old))
    #expect(chrome.accepts(try #require(chrome.beginRead())))
    chrome.hide()
    chrome.resumePresentation()
    #expect(chrome.beginRead() == nil)
    #expect(!chrome.presentationActive)
}

@Test @MainActor func networkCoverSurvivesTabSwitchAndPaneUndo() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let first = try #require(workspace.selectedTab)
    let firstPane = try #require(workspace.activePane)
    first.chrome.reveal(.files, initial: WorkspaceContextAnchor(
        paneID: firstPane.id, profile: firstPane.profile, directory: firstPane.directory))
    workspace.splitActive(axis: .vertical)
    workspace.newTab(profile: .local)
    let second = try #require(workspace.selectedTab)
    let secondPane = try #require(workspace.activePane)
    second.chrome.reveal(.changes, initial: WorkspaceContextAnchor(
        paneID: secondPane.id, profile: secondPane.profile, directory: secondPane.directory))

    workspace.showNetwork()
    workspace.selectTab(first.id)
    #expect(workspace.networkVisible)
    #expect(!first.chrome.presentationActive)
    #expect(!second.chrome.presentationActive)

    workspace.closeActivePane()
    workspace.reopenLastClosedPane()
    #expect(workspace.networkVisible)
    #expect(!first.chrome.presentationActive)

    workspace.networkVisible = false
    #expect(first.chrome.presentationActive)
    #expect(!second.chrome.presentationActive)
}

@Test @MainActor func tabSwitchSuspendsOldChromeAndRestoresItsLeaseOnReturn() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let first = try #require(workspace.selectedTab)
    let pane = try #require(workspace.activePane)
    first.chrome.reveal(.files, initial: WorkspaceContextAnchor(
        paneID: pane.id, profile: pane.profile, directory: pane.directory))
    let old = try #require(first.chrome.beginRead())
    workspace.newTab(profile: .local)
    #expect(!first.chrome.accepts(old))
    #expect(!first.chrome.presentationActive)
    workspace.selectTab(first.id)
    #expect(first.chrome.presentationActive)
    #expect(first.chrome.beginRead() != nil)
}

@Test @MainActor func chromeCapturedContextAndDraftNeverFollowImplicitly() throws {
    let chrome = WorkspaceChrome()
    let a = WorkspaceContextAnchor(paneID: UUID(), profile: .local, directory: "/a")
    let b = WorkspaceContextAnchor(paneID: UUID(), profile: .local, directory: "/b")
    chrome.reveal(.files, initial: a)
    chrome.activeContextChanged(b)
    #expect(chrome.anchor == a)
    chrome.hide()
    chrome.reveal(.changes, initial: b)
    #expect(chrome.anchor == a)
    chrome.setFollowing(true)
    chrome.activeContextChanged(b)
    #expect(chrome.anchor == b)
    chrome.setDraft(true)
    chrome.setFollowing(true)
    #expect(!chrome.useContext(a))
    #expect(!chrome.followsActivePane)
    chrome.setDraft(false)
    #expect(!chrome.followsActivePane)
    chrome.invalidateBinding()
    chrome.reveal(.files, initial: a)
    #expect(chrome.anchor == b)
    #expect(chrome.unresolved)
    #expect(chrome.beginRead() == nil)
}

@Test @MainActor func explicitPaneChoicePinsContextAndDraftBlocksSwitches() throws {
    let chrome = WorkspaceChrome()
    let first = WorkspaceContextAnchor(paneID: UUID(), profile: .local, directory: "/first")
    let second = WorkspaceContextAnchor(paneID: UUID(), profile: .local, directory: "/second")
    chrome.reveal(.files, initial: first)
    chrome.setFollowing(true)
    #expect(chrome.useContext(second))
    #expect(chrome.anchor == second)
    #expect(!chrome.followsActivePane)
    chrome.setDraft(true)
    #expect(!chrome.useContext(first))
    chrome.setFollowing(true)
    #expect(chrome.anchor == second)
    #expect(!chrome.followsActivePane)
    chrome.setDraft(false)
    #expect(!chrome.followsActivePane)
}

@Test @MainActor func chromeRejectsSupersededReadAcrossCycles() throws {
    let chrome = WorkspaceChrome()
    let anchor = WorkspaceContextAnchor(paneID: UUID(), profile: .local, directory: "/a")
    for _ in 0..<100 {
        chrome.reveal(.files, initial: anchor)
        let old = try #require(chrome.beginRead())
        let latest = try #require(chrome.beginRead())
        #expect(!chrome.accepts(old))
        #expect(chrome.accepts(latest))
        chrome.hide()
        #expect(!chrome.accepts(latest))
        #expect(chrome.anchor == anchor)
    }
    chrome.setWidth(.infinity)
    #expect(chrome.width == 320)
    chrome.setWidth(900)
    #expect(chrome.width == 520)
}

@Test @MainActor func exportSurvivesNewReadButNotBindingOrPresentationChange() throws {
    let chrome = WorkspaceChrome()
    let first = WorkspaceContextAnchor(paneID: UUID(), profile: .local, directory: "/first")
    let second = WorkspaceContextAnchor(paneID: UUID(), profile: .local, directory: "/second")
    chrome.reveal(.files, initial: first)
    let export = try #require(chrome.beginExport())
    let oldRead = try #require(chrome.beginRead())
    let newRead = try #require(chrome.beginRead())
    #expect(!chrome.accepts(oldRead))
    #expect(chrome.accepts(newRead))
    #expect(chrome.acceptsExport(export))
    chrome.setFollowing(true)
    chrome.activeContextChanged(second)
    #expect(!chrome.acceptsExport(export))
    let nextExport = try #require(chrome.beginExport())
    chrome.suspendPresentation()
    #expect(!chrome.acceptsExport(nextExport))
}

@Test @MainActor func hidingRResultsRestoresFullCanvas() {
    let chrome = WorkspaceChrome()
    let editorID = UUID()
    #expect(chrome.rightSurface(rLayoutEditorID: editorID) == nil)
    chrome.reveal(.files, initial: WorkspaceContextAnchor(
        paneID: UUID(), profile: .local, directory: "/project"))
    #expect(chrome.rightSurface(rLayoutEditorID: editorID) == .contextDock(.files))
    chrome.reveal(.rWorkspace, initial: nil)
    #expect(chrome.rightSurface(rLayoutEditorID: editorID) == .contextDock(.rWorkspace))
    chrome.hide()
    #expect(chrome.rightSurface(rLayoutEditorID: editorID) == nil)
}

@Test @MainActor func workspaceSurvivesOneHundredDockCoverAndTabCycles() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    defer { workspace.shutdown() }
    let first = try #require(workspace.selectedTab)
    let pane = try #require(workspace.activePane)
    let runtime = pane.runtime
    let anchor = WorkspaceContextAnchor(
        paneID: pane.id, profile: pane.profile, directory: pane.directory)
    first.chrome.reveal(.files, initial: anchor)
    first.chrome.setWidth(417)
    workspace.newTab(profile: .local)
    let alternate = try #require(workspace.selectedTab)
    workspace.selectTab(first.id)

    for _ in 0..<100 {
        let ticket = try #require(first.chrome.beginRead())
        workspace.showNetwork()
        #expect(!first.chrome.accepts(ticket))
        workspace.networkVisible = false
        #expect(first.chrome.presentationActive)
        workspace.selectTab(alternate.id)
        #expect(!first.chrome.presentationActive)
        workspace.selectTab(first.id)
        #expect(first.chrome.presentationActive)
        #expect(first.chrome.anchor == anchor)
        #expect(first.chrome.width == 417)
        #expect(workspace.panes[pane.id] === pane)
        #expect(workspace.panes[pane.id]?.runtime === runtime)
    }
}
