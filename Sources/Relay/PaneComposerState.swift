import Foundation

/// A pane's agent composer: draft text and attachments. Owned by `PaneModel`,
/// so it survives view rebuilds from moves, stacking and regrouping. Uploads
/// are cancelled only when the pane itself is closed.
@MainActor
final class PaneComposerState: ObservableObject {
    @Published var draft = ""
    let attachmentQueue = RelayAgentAttachmentQueue()
    /// Whether the saved draft has been loaded into this state.
    var restored = false
    // Submission state lives with the pane too: a view rebuilt by a stack
    // switch or overview visit must never reset a staged or uncertain send
    // and allow the same message to be submitted twice.
    @Published var submitting = false
    @Published var submitted = false
    @Published var nativeDeliveryHeld = false
    @Published var stopRequested = false
    @Published var submissionStatus: String?

    /// Loads a saved draft once. A stored draft never replaces typed text.
    func restoreIfNeeded(hostID: String, paneID: UUID, store: RelayAgentDraftStore = .shared) {
        guard !restored else { return }
        restored = true
        guard draft.isEmpty, attachmentQueue.attachments.isEmpty,
              let saved = store.loadDraft(hostID: hostID, paneID: paneID) else { return }
        draft = saved.text
        attachmentQueue.restore(saved.attachments)
    }

    func persist(hostID: String, paneID: UUID, immediate: Bool, store: RelayAgentDraftStore = .shared) {
        if immediate {
            store.saveNow(draft, hostID: hostID, paneID: paneID, attachments: attachmentQueue.attachments)
        } else {
            store.save(draft, hostID: hostID, paneID: paneID, attachments: attachmentQueue.attachments)
        }
    }

    /// Called by `WorkspaceModel` when the pane is closed, never on view disappearance.
    func paneClosed() {
        attachmentQueue.cancelUploads()
    }
}
