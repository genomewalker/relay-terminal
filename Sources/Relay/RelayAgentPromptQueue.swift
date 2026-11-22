import Foundation

/// A message the user wrote while the agent was busy. Relay holds it and sends
/// it through the normal composer send once the agent confirms it is idle, for
/// the same conversation it was written for.
struct RelayAgentQueuedPrompt: Identifiable, Equatable {
    let id: UUID
    let text: String
    let binding: RelayAgentConversationBinding
    let queuedAt: Date
}

/// The composer's queue of held messages. Delivery is at most once: an item
/// leaves the queue before its send starts and comes back only when the send
/// certainly did not happen or its outcome needs the user's review. The queue
/// never retries by itself; any doubt pauses it until the user resumes.
struct RelayAgentPromptQueue: Equatable {
    private(set) var items: [RelayAgentQueuedPrompt] = []
    /// Why delivery is paused, shown beside the queued messages.
    private(set) var pausedReason: String?

    var isEmpty: Bool { items.isEmpty }
    var paused: Bool { pausedReason != nil }

    @discardableResult
    mutating func enqueue(_ text: String, binding: RelayAgentConversationBinding,
                          id: UUID = UUID(), now: Date = Date()) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        items.append(RelayAgentQueuedPrompt(id: id, text: text, binding: binding, queuedAt: now))
        return true
    }

    /// Removes a queued message. An empty queue is no longer paused.
    @discardableResult
    mutating func cancel(_ id: UUID) -> RelayAgentQueuedPrompt? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: index)
        if items.isEmpty { pausedReason = nil }
        return item
    }

    mutating func pause(_ reason: String) {
        guard !items.isEmpty else { return }
        pausedReason = reason
    }

    mutating func resume() { pausedReason = nil }

    /// The next message to send to `binding`, removed from the queue. Returns
    /// nil while paused, and pauses instead of sending when the agent is now
    /// in a different conversation than the one the message was written for.
    mutating func takeNext(for binding: RelayAgentConversationBinding?) -> RelayAgentQueuedPrompt? {
        guard pausedReason == nil, let first = items.first else { return nil }
        guard let binding, Self.sameConversation(first.binding, binding) else {
            pausedReason = "The agent is in a different conversation now. Cancel these messages or resume to send them there."
            return nil
        }
        items.removeFirst()
        return first
    }

    /// Returns an item whose send did not certainly happen to the front of the
    /// queue and pauses delivery with `reason`.
    mutating func putBack(_ item: RelayAgentQueuedPrompt, reason: String) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        pausedReason = reason
    }

    /// After the user resumes in a new conversation, held messages follow it.
    mutating func rebind(to binding: RelayAgentConversationBinding) {
        items = items.map { RelayAgentQueuedPrompt(id: $0.id, text: $0.text, binding: binding, queuedAt: $0.queuedAt) }
    }

    /// What the draft store keeps: the draft followed by every held message.
    /// A restored draft is never sent by itself, so a crash cannot auto-send.
    func textForSaving(_ draft: String) -> String {
        ([draft] + items.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The same agent process and session; a refreshed source path is not a new conversation.
    static func sameConversation(_ a: RelayAgentConversationBinding, _ b: RelayAgentConversationBinding) -> Bool {
        let samePane: Bool = a.hostID == b.hostID && a.paneID == b.paneID
        let sameProcess: Bool = a.provider == b.provider && a.processID == b.processID && a.processStart == b.processStart
        return samePane && sameProcess && a.sessionID == b.sessionID
    }
}
