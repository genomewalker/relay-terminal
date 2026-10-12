import Foundation
import Testing
@testable import Relay

@Test @MainActor func workspaceReusesPresentationOnlyForSameCapturedPane() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let first = UUID(), second = UUID()
    let a = workspace.pluginPresentation(paneID: first, profile: .local, directory: "/a")
    let again = workspace.pluginPresentation(paneID: first, profile: .local, directory: "/changed")
    let b = workspace.pluginPresentation(paneID: second, profile: .local, directory: "/b")
    #expect(a === again)
    #expect(a !== b)
    #expect(again.capturedPane?.directory == "/a")
}

@Test @MainActor func reopenedPaneGetsFreshPresentationWhileOutcomeRemainsReachable() throws {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let originalPane = try #require(workspace.activePane)
    let original = workspace.pluginPresentation(
        paneID: originalPane.id, profile: originalPane.profile, directory: originalPane.directory
    )
    original.result = PluginOperationResult(
        root: "/test", text: "completed", entries: [], truncated: false
    )
    original.stampResult(PluginResultStamp(
        requestID: UUID(), pluginID: "test", digest: "v1", operation: .projectRun,
        scope: try PluginScope(paneID: originalPane.id, profile: originalPane.profile, root: "/test"),
        resource: ""
    ))

    workspace.closeActivePane()
    #expect(workspace.retiredPluginPresentation(for: originalPane.id) === original)
    #expect(workspace.retiredPluginPresentation(for: originalPane.id)?.result?.text == "completed")
    workspace.reopenLastClosedPane()
    let reopened = try #require(workspace.activePane)
    #expect(reopened.id == originalPane.id)
    let fresh = workspace.pluginPresentation(
        paneID: reopened.id, profile: reopened.profile, directory: reopened.directory
    )
    #expect(fresh !== original)
    #expect(fresh.result == nil)
    #expect(fresh.capturedPane?.id == originalPane.id)
}

@Test @MainActor func networkCoverSuspendsMountedDockWithoutRetargeting() {
    let workspace = WorkspaceModel(restoreSavedWorkspace: false)
    let pane = workspace.activePane!
    let tab = workspace.selectedTab!
    let anchor = WorkspaceContextAnchor(
        paneID: pane.id, profile: pane.profile, directory: pane.directory
    )
    let presentation = workspace.pluginPresentation(
        paneID: pane.id, profile: pane.profile, directory: pane.directory
    )
    tab.chrome.reveal(.files, initial: anchor)
    let presenter = UUID()
    #expect(presentation.claimPresenter(presenter))
    let originalLease = presentation.presentationLease(for: presenter)!
    let ticket = tab.chrome.beginRead()
    #expect(ticket != nil)
    presentation.stampResult(PluginResultStamp(
        requestID: UUID(), pluginID: "test", digest: "v1",
        operation: .artifacts,
        scope: try! PluginScope(paneID: pane.id, profile: pane.profile, root: "/test"),
        resource: "file.txt"
    ))
    let stamp = presentation.resultStamp!
    presentation.validateCache(stamp, lease: originalLease)
    #expect(presentation.cacheValidated)

    workspace.showNetwork()
    #expect(!tab.chrome.presentationActive)
    #expect(tab.chrome.beginRead() == nil)
    #expect(ticket.map(tab.chrome.accepts) == false)
    #expect(!presentation.cacheValidated)
    #expect(tab.chrome.anchor?.paneID == pane.id)

    workspace.networkVisible = false
    #expect(tab.chrome.presentationActive)
    #expect(tab.chrome.anchor?.paneID == pane.id)
    #expect(!presentation.cacheValidated)
    presentation.validateCache(stamp, lease: originalLease)
    #expect(!presentation.cacheValidated)
    let freshLease = presentation.presentationLease(for: presenter)!
    presentation.validateCache(stamp, lease: freshLease)
    #expect(presentation.cacheValidated)
}

@Test func isolatedStateConfigurationFailsClosed() {
    let production = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
    let normal = RelayStateConfiguration.resolve(
        stateRoot: nil, defaultsSuite: nil, sidePanelPort: nil,
        bundleIdentifier: "dev.relay.terminal", productionSupportRoot: production, processID: 7
    )
    #expect(!normal.isIsolated)
    #expect(normal.sidePanelPort == 47_471)

    let isolated = RelayStateConfiguration.resolve(
        stateRoot: "/tmp/relay-candidate", defaultsSuite: "dev.relay.candidate.defaults",
        sidePanelPort: "47472", bundleIdentifier: "dev.relay.terminal.candidate",
        productionSupportRoot: production, processID: 7
    )
    #expect(isolated.isIsolated)
    #expect(isolated.error == nil)
    #expect(isolated.sidePanelPort == 47_472)

    let ownSuite = RelayStateConfiguration.resolve(
        stateRoot: "/tmp/relay-candidate", defaultsSuite: "dev.relay.terminal.candidate",
        sidePanelPort: "47472", bundleIdentifier: "dev.relay.terminal.candidate",
        productionSupportRoot: production, processID: 7
    )
    #expect(ownSuite.error != nil)

    for invalid in [
        RelayStateConfiguration.resolve(
            stateRoot: "/tmp/relay-candidate", defaultsSuite: nil, sidePanelPort: "47472",
            bundleIdentifier: "dev.relay.terminal", productionSupportRoot: production, processID: 7),
        RelayStateConfiguration.resolve(
            stateRoot: production.path, defaultsSuite: "dev.relay.candidate", sidePanelPort: "47472",
            bundleIdentifier: "dev.relay.terminal", productionSupportRoot: production, processID: 7),
        RelayStateConfiguration.resolve(
            stateRoot: "/tmp/relay-candidate", defaultsSuite: "dev.relay.terminal", sidePanelPort: "47471",
            bundleIdentifier: "dev.relay.terminal", productionSupportRoot: production, processID: 7)
    ] {
        #expect(invalid.isIsolated)
        #expect(invalid.error != nil)
        #expect(invalid.applicationSupportRoot.path.contains("relay-invalid-profile-7"))
        #expect(invalid.sidePanelPort == 0)
    }
}

@Test func candidateWithoutCompleteProfileIsQuarantined() {
    let production = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
    for candidateID in ["dev.relay.terminal.candidate", "dev.relay.preview"] {
        for values: (String?, String?, String?) in [(nil, nil, nil), ("", "", "")] {
            let configuration = RelayStateConfiguration.resolve(
                stateRoot: values.0, defaultsSuite: values.1, sidePanelPort: values.2,
                bundleIdentifier: candidateID, productionSupportRoot: production, processID: 7
            )
            #expect(configuration.isIsolated)
            #expect(configuration.error != nil)
            #expect(configuration.sidePanelPort == 0)
        }
    }
}

@Test func isolatedDefaultsSuiteFailureNeverFallsBackToStandard() {
    let configuration = RelayStateConfiguration(
        applicationSupportRoot: URL(fileURLWithPath: "/tmp/relay-candidate"),
        defaultsSuite: "dev.relay.candidate", sidePanelPort: 47_472,
        isIsolated: true, error: nil
    )
    #expect(RelayStateProfile.makeDefaults(
        configuration: configuration, suiteFactory: { _ in nil }
    ) == nil)
}

@Test @MainActor func pluginPresentationCacheRequiresOwnerRevalidation() throws {
    let session = PluginToolPresentation()
    let owner = UUID(), next = UUID()
    let scope = try PluginScope(paneID: UUID(), profile: .local, root: "/test")
    let stamp = PluginResultStamp(requestID: UUID(), pluginID: "test", digest: "old",
                                  operation: .artifacts, scope: scope, resource: "file.txt")
    #expect(session.claimPresenter(owner))
    let ownerLease = try #require(session.presentationLease(for: owner))
    session.stampResult(stamp)
    #expect(!session.cacheValidated)
    session.validateCache(stamp, lease: ownerLease)
    #expect(session.cacheValidated)
    session.releasePresenter(owner)
    #expect(!session.cacheValidated)
    #expect(session.claimPresenter(next))
    let nextLease = try #require(session.presentationLease(for: next))
    #expect(!session.cacheValidated)
    session.validateCache(stamp, lease: ownerLease)
    #expect(!session.cacheValidated)
    session.validateCache(stamp, lease: nextLease)
    #expect(session.cacheValidated)
    session.selectionChanged(by: next)
    session.validateCache(stamp, lease: nextLease)
    #expect(!session.cacheValidated)
    #expect(session.resultStamp == nil)
}

@Test @MainActor func pluginPresentationNewReviewKeepsPriorOutcome() throws {
    let session = PluginToolPresentation()
    let scope = try PluginScope(paneID: UUID(), profile: .local, root: "/test")
    let stamp = PluginResultStamp(requestID: UUID(), pluginID: "test", digest: "v1",
                                  operation: .projectRun, scope: scope, resource: "")
    session.result = PluginOperationResult(root: "/test", text: "completed", entries: [], truncated: false)
    session.stampResult(stamp)
    session.mutationAttempted = true
    session.actionConfirmation = "RUN"
    session.beginNewMutationReview()
    #expect(!session.mutationAttempted)
    #expect(session.actionConfirmation.isEmpty)
    #expect(session.result?.text == "completed")
    #expect(session.resultStamp == stamp)
}

@Test func pluginReviewedRequestBindsPayloadAndRevision() throws {
    let scope = try PluginScope(paneID: UUID(), profile: .local, root: "/test")
    let review = PluginReviewedRequest(pluginID: "test", digest: "v1", operation: .projectRun,
                                      scope: scope, path: "", script: "original")
    #expect(review != PluginReviewedRequest(pluginID: "test", digest: "v2", operation: .projectRun,
                                           scope: scope, path: "", script: "original"))
    #expect(review != PluginReviewedRequest(pluginID: "test", digest: "v1", operation: .projectRun,
                                           scope: scope, path: "", script: "changed"))
}

@Test @MainActor func pluginPresentationRefusedObserverCannotConsumeJob() {
    let session = PluginToolPresentation()
    let owner = UUID(), refused = UUID()
    #expect(session.claimPresenter(owner))
    #expect(!session.claimPresenter(refused))
    session.selectedJobFromList = "123_4"
    session.transferPath = "obsolete.csv"
    session.selectionChanged(by: refused)
    #expect(session.selectedJobFromList == "123_4")
    session.selectionChanged(by: owner)
    session.selectionChanged(by: refused)
    #expect(session.path == "123_4")
    #expect(session.transferPath == nil)
}

@Test @MainActor func pluginPresentationRetainsDraftAndExactCapture() {
    let session = PluginToolPresentation()
    let a = UUID(), b = UUID(), legacy = UUID(), dock = UUID()
    session.captureOnce(id: a, profile: .local, directory: "/a")
    session.batchScript = "user draft"
    #expect(session.claimPresenter(legacy))
    session.reviewingAction = true
    session.actionConfirmation = "RUN"
    #expect(!session.claimPresenter(dock))
    session.releasePresenter(dock)
    #expect(!session.claimPresenter(dock))
    #expect(session.reviewingAction)
    #expect(session.actionConfirmation == "RUN")
    session.releasePresenter(legacy)
    #expect(!session.reviewingAction)
    #expect(session.actionConfirmation.isEmpty)
    #expect(session.claimPresenter(dock))
    session.captureOnce(id: b, profile: .local, directory: "/b")
    #expect(session.capturedPane?.id == a)
    #expect(session.capturedPane?.directory == "/a")
    #expect(session.batchScript == "user draft")
}
