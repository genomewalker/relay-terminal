import AppKit
import Combine

struct PluginResultStamp: Equatable {
    let requestID: UUID
    let pluginID: String
    let digest: String
    let operation: RelayPluginOperation
    let scope: PluginScope
    let resource: String
}

/// Exact content reviewed by the user; authorization is still checked at dispatch.
struct PluginReviewedRequest: Equatable {
    let pluginID: String
    let digest: String
    let operation: RelayPluginOperation
    let scope: PluginScope
    let path: String
    let script: String
}

struct PluginPresentationLease: Equatable, Sendable {
    let presenterID: UUID
    let generation: UInt64
}

/// Retained drafts/results for one captured tool presentation. Not an authority.
@MainActor final class PluginToolPresentation: ObservableObject {
    @Published var capturedPane: (id: UUID, profile: ConnectionProfile, directory: String?)?
    @Published var selection = ""
    @Published var path = ""
    @Published var entrySearch = ""
    @Published var logStream = "stdout"
    @Published var batchScript = "#!/bin/bash\n#SBATCH --time=00:05:00\n#SBATCH --cpus-per-task=1\n\n# Add your command here.\n"
    @Published var projectCommand = "{\n  \"argv\": [\"/usr/bin/true\"],\n  \"environment\": {},\n  \"timeout_seconds\": 60\n}"
    @Published var actionConfirmation = ""
    @Published var reviewingAction = false
    @Published var mutationAttempted = false
    @Published var selectedJobFromList: String?
    @Published var result: PluginOperationResult?
    @Published private(set) var resultStamp: PluginResultStamp?
    @Published private(set) var cacheValidated = false

    func stampResult(_ stamp: PluginResultStamp) {
        resultStamp = stamp
        cacheValidated = false
    }

    func beginNewMutationReview() {
        guard !operationLifetime.running else { return }
        mutationAttempted = false
        reviewingAction = false
        actionConfirmation = ""
    }

    func validateCache(_ stamp: PluginResultStamp, lease: PluginPresentationLease) {
        guard !workspaceCovered, activeLease == lease,
              presenterID == lease.presenterID, resultStamp == stamp else { return }
        cacheValidated = true
    }
    @Published var fileBytes: Data?
    @Published var transferPath: String?
    @Published var imagePreview: NSImage?
    @Published var textPreview: String?
    @Published var markdownPreview: AttributedString?
    @Published var showMarkdownSource = false
    @Published var tablePreview: [[String]]?
    @Published var previewPartial = false
    @Published var agentSnapshot: PluginAgentSnapshot?
    @Published var error: String?
    @Published var busy = false
    @Published var showingManager = false
    let operationLifetime = PluginPresentationOperation()
    let transferPresentation = PluginTransferPresentation()
    private var presenterID: UUID?
    private var leaseGeneration: UInt64 = 0
    private var activeLease: PluginPresentationLease?
    private var workspaceCovered = false

    /// Only the mounted owner may consume the pending job selection/reset state.
    func selectionChanged(by id: UUID) {
        guard presenterID == id else { return }
        resultStamp = nil; cacheValidated = false
        transferPresentation.pause()
        result = nil; fileBytes = nil; imagePreview = nil; textPreview = nil
        markdownPreview = nil; tablePreview = nil; agentSnapshot = nil
        previewPartial = false; showMarkdownSource = false; transferPath = nil
        error = nil; entrySearch = ""
        path = selectedJobFromList ?? ""
        selectedJobFromList = nil; actionConfirmation = ""
    }

    func claimPresenter(_ id: UUID) -> Bool {
        guard presenterID == nil || presenterID == id else { return false }
        presenterID = id
        if !workspaceCovered { issueLease(to: id) }
        return true
    }

    func presentationLease(for id: UUID) -> PluginPresentationLease? {
        guard presenterID == id, !workspaceCovered else { return nil }
        return activeLease
    }

    func releasePresenter(_ id: UUID) {
        guard presenterID == id else { return }
        reviewingAction = false
        actionConfirmation = ""
        cacheValidated = false
        invalidateLease()
        presenterID = nil
        operationLifetime.presenterHidden()
        transferPresentation.pause()
    }

    /// The view can remain mounted beneath Network or another workspace cover.
    /// Suspend active reads/transfer fetching without surrendering presenter
    /// ownership; returning never auto-resumes an operation.
    func suspendForWorkspaceCover() {
        workspaceCovered = true
        cacheValidated = false
        invalidateLease()
        operationLifetime.presenterHidden()
        transferPresentation.pause()
    }

    func resumeAfterWorkspaceCover() {
        guard workspaceCovered else { return }
        workspaceCovered = false
        if let presenterID { issueLease(to: presenterID) }
    }

    private func issueLease(to presenter: UUID) {
        leaseGeneration &+= 1
        activeLease = PluginPresentationLease(presenterID: presenter, generation: leaseGeneration)
    }

    private func invalidateLease() {
        leaseGeneration &+= 1
        activeLease = nil
    }

    func captureOnce(id: UUID, profile: ConnectionProfile, directory: String?) {
        guard capturedPane == nil else { return }
        capturedPane = (id, profile, directory)
    }
}
