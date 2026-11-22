import Foundation

/// A pane's agent composer: draft text and attachments. Owned by `PaneModel`,
/// so it survives view rebuilds from moves, stacking and regrouping. Uploads
/// are cancelled only when the pane itself is closed.
@MainActor
final class PaneComposerState: ObservableObject {
    @Published var draft = "" {
        // Once the restored text is sent or cleared, the warning no longer applies.
        didSet { if draft.isEmpty { restoredHeldMessages = 0 } }
    }
    /// Held messages from before a restart that came back inside `draft`.
    /// They are only text now: Return would send them with the draft as one message.
    @Published private(set) var restoredHeldMessages = 0
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
    /// Messages written while the agent was busy, sent one per confirmed idle.
    /// Shared by every view of this pane, so a message is taken exactly once.
    @Published var queue = RelayAgentPromptQueue()

    /// Anything the user wrote that has not certainly reached the agent: a
    /// draft, attachments, held messages, or a send in flight or held. A
    /// restart, rotation or resume must wait while this is true; held messages
    /// were written for the current conversation.
    var hasPendingInput: Bool {
        !draft.isEmpty || !attachmentQueue.attachments.isEmpty || !queue.isEmpty || submitting || nativeDeliveryHeld
    }

    /// Loads a saved draft once. A stored draft never replaces typed text.
    func restoreIfNeeded(hostID: String, paneID: UUID, store: RelayAgentDraftStore = .shared) {
        guard !restored else { return }
        restored = true
        guard draft.isEmpty, attachmentQueue.attachments.isEmpty,
              let saved = store.loadDraft(hostID: hostID, paneID: paneID) else { return }
        draft = saved.text
        restoredHeldMessages = saved.text.isEmpty ? 0 : saved.heldMessages
        attachmentQueue.restore(saved.attachments)
    }

    func persist(hostID: String, paneID: UUID, immediate: Bool, store: RelayAgentDraftStore = .shared) {
        if immediate {
            store.saveNow(queue.textForSaving(draft), hostID: hostID, paneID: paneID, attachments: attachmentQueue.attachments,
                          heldMessages: heldMessagesForSaving)
        } else {
            store.save(queue.textForSaving(draft), hostID: hostID, paneID: paneID, attachments: attachmentQueue.attachments,
                       heldMessages: heldMessagesForSaving)
        }
    }

    /// Held messages in the saved text: the live queue plus any restored ones
    /// still inside the draft, so the warning survives a second restart.
    private var heldMessagesForSaving: Int {
        queue.items.count + (draft.isEmpty ? 0 : restoredHeldMessages)
    }

    /// The composer hint for a restored draft that contains held messages.
    nonisolated static func restoredHeldWarning(count: Int) -> String? {
        guard count > 0 else { return nil }
        let messages = count == 1 ? "1 held message" : "\(count) held messages"
        return "This draft includes \(messages) from before Relay restarted. ↩ sends all of it as one message; edit it first to send them separately."
    }

    /// Called by `WorkspaceModel` when the pane is closed, never on view disappearance.
    func paneClosed() {
        attachmentQueue.cancelUploads()
    }
}
