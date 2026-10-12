import Foundation
import Combine

enum ContextDestination: String, Codable, Sendable {
    case files, changes, jobs, rWorkspace, participant
}

/// The single right-hand contextual surface for a tab. Hiding the dock restores
/// the full pane canvas instead of leaving a permanent R results split.
enum WorkspaceRightSurface: Equatable, Sendable {
    case contextDock(ContextDestination)
}

/// A restoration/inspection anchor, never a permission or proof of liveness.
struct WorkspaceContextAnchor: Equatable, Sendable {
    let paneID: UUID
    let profile: ConnectionProfile
    let directory: String?
}

struct ContextReadTicket: Equatable, Sendable {
    let requestID: UUID
    let bindingRevision: UInt64
    let presentationEpoch: UInt64
}

/// A user-selected export may coexist with a newer folder read, but it must
/// still be fenced to the same pane binding and visible presentation.
struct ContextExportTicket: Equatable, Sendable {
    let bindingRevision: UInt64
    let presentationEpoch: UInt64
}

/// Small, per-tab presentation state. No tasks, controllers, grants or results.
/// Views observe this object, not a published global dictionary of tab chrome.
@MainActor final class WorkspaceChrome: ObservableObject {
    @Published private(set) var visible = false
    @Published private(set) var destination: ContextDestination = .files
    @Published private(set) var anchor: WorkspaceContextAnchor?
    @Published private(set) var unresolved = false
    @Published private(set) var followsActivePane = false
    @Published private(set) var hasDraft = false
    @Published private(set) var width: Double = 320
    private(set) var bindingRevision: UInt64 = 0
    private(set) var presentationEpoch: UInt64 = 0
    private var currentRead: ContextReadTicket?
    private(set) var presentationActive = false

    /// Reveal does not replace a previous capture and never requests focus/read.
    func reveal(_ destination: ContextDestination, initial: WorkspaceContextAnchor?) {
        if !visible || self.destination != destination { invalidatePresentation() }
        if anchor == nil, !unresolved, let initial { replaceAnchor(initial) }
        self.destination = destination
        visible = true
        resumePresentation()
    }

    func hide() {
        invalidatePresentation()
        visible = false
        presentationActive = false
    }

    func suspendPresentation() {
        presentationActive = false
        invalidatePresentation()
    }

    /// Mount/selection restores a lease, not the validity of an earlier read.
    func resumePresentation() {
        guard visible, !presentationActive else { return }
        invalidatePresentation()
        presentationActive = true
    }

    @discardableResult
    func useContext(_ anchor: WorkspaceContextAnchor) -> Bool {
        guard !hasDraft else { return false }
        followsActivePane = false
        replaceAnchor(anchor)
        return true
    }

    func setFollowing(_ enabled: Bool) {
        followsActivePane = enabled && !hasDraft
    }

    func setDraft(_ present: Bool) {
        hasDraft = present
        if present { followsActivePane = false }
        // Following never resumes implicitly after a draft ends.
    }

    func activeContextChanged(_ anchor: WorkspaceContextAnchor) {
        guard visible, presentationActive, followsActivePane, !hasDraft else { return }
        if self.anchor != anchor { replaceAnchor(anchor) }
    }

    func invalidateBinding() {
        bindingRevision &+= 1
        unresolved = true
        followsActivePane = false
        invalidatePresentation()
        // Keep the old anchor to explain what became unavailable.
    }

    func setWidth(_ value: Double) {
        guard value.isFinite else { return }
        width = min(520, max(280, value))
    }

    func beginRead() -> ContextReadTicket? {
        guard visible, presentationActive, anchor != nil, !unresolved else { return nil }
        let ticket = ContextReadTicket(requestID: UUID(), bindingRevision: bindingRevision,
                                       presentationEpoch: presentationEpoch)
        currentRead = ticket
        return ticket
    }

    func beginExport() -> ContextExportTicket? {
        guard visible, presentationActive, anchor != nil, !unresolved else { return nil }
        return ContextExportTicket(bindingRevision: bindingRevision,
                                   presentationEpoch: presentationEpoch)
    }

    func rightSurface(rLayoutEditorID _: UUID?) -> WorkspaceRightSurface? {
        if visible { return .contextDock(destination) }
        return nil
    }

    /// Permission must ALSO be revalidated by the existing operation owner.
    func accepts(_ ticket: ContextReadTicket) -> Bool {
        visible && presentationActive && !unresolved && currentRead == ticket &&
        ticket.bindingRevision == bindingRevision && ticket.presentationEpoch == presentationEpoch
    }

    func acceptsExport(_ ticket: ContextExportTicket) -> Bool {
        visible && presentationActive && !unresolved && anchor != nil &&
        ticket.bindingRevision == bindingRevision && ticket.presentationEpoch == presentationEpoch
    }

    private func replaceAnchor(_ anchor: WorkspaceContextAnchor) {
        self.anchor = anchor
        unresolved = false
        bindingRevision &+= 1
        invalidatePresentation()
    }

    private func invalidatePresentation() {
        presentationEpoch &+= 1
        currentRead = nil
    }
}
