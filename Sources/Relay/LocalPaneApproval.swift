import AppKit

struct LocalPaneProposal: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    /// Optional anchor for MCP local tabs: open right after this pane's tab
    /// or this tab, in its session and workspace. At most one is set.
    var anchorPaneID: UUID? = nil
    var anchorTabID: UUID? = nil

    var isAnchored: Bool { anchorPaneID != nil || anchorTabID != nil }
}

struct LocalPaneReceipt: Codable {
    let requestID: UUID
    var status: String
    var tabID: UUID?
    var paneID: UUID?
}

/// Creates a local shell only after approval. No command, path or environment
/// supplied by a client is accepted; terminal input has its own approval flow.
@MainActor final class LocalPaneApproval {
    private let present: PeerNetworkApproval.Presenter
    private var proposals: [UUID: LocalPaneProposal] = [:]
    private var receipts: [UUID: LocalPaneReceipt] = [:]
    private var pending = false

    init(present: PeerNetworkApproval.Presenter? = nil) {
        self.present = present ?? { alert, completion in
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ??
                    NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  window.attachedSheet == nil else { return false }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: completion)
            return true
        }
    }

    func receipt(_ id: UUID) -> LocalPaneReceipt? { receipts[id] }

    func propose(_ proposal: LocalPaneProposal, instance: UUID,
                 title: String = "Open a local terminal?",
                 detail: String = "This creates and selects a new tab on this Mac using your normal local shell. It does not submit a command or change existing panes. Approval expires in two minutes.",
                 button: String = "Open local terminal",
                 create: @escaping () -> (UUID, UUID)?) throws -> LocalPaneReceipt {
        guard proposal.instance == instance else { throw PluginError.invalid("Stale Relay instance") }
        if let old = receipts[proposal.requestID] {
            guard proposals[proposal.requestID] == proposal else { throw PluginError.invalid("Conflicting request ID") }
            return old
        }
        guard !pending, receipts.count < 256 else { throw PluginError.invalid("Pane approval busy or receipt limit reached") }
        let initial = LocalPaneReceipt(requestID: proposal.requestID, status: "awaiting_approval")
        proposals[proposal.requestID] = proposal
        receipts[proposal.requestID] = initial
        pending = true
        let deadline = Date().addingTimeInterval(120)
        let alert = RelayTheme.alert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: button)
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        guard present(alert, { [weak self] response in
            guard let self, self.pending,
                  self.receipts[proposal.requestID]?.status == "awaiting_approval" else { return }
            defer { self.pending = false }
            guard response == .alertSecondButtonReturn else {
                self.receipts[proposal.requestID]?.status = "cancelled"; return
            }
            guard Date() < deadline else {
                self.receipts[proposal.requestID]?.status = "expired"; return
            }
            guard let (tab, pane) = create() else {
                self.receipts[proposal.requestID]?.status = "failed"; return
            }
            self.receipts[proposal.requestID] = LocalPaneReceipt(requestID: proposal.requestID,
                status: "created", tabID: tab, paneID: pane)
        }) else {
            pending = false
            proposals.removeValue(forKey: proposal.requestID)
            receipts.removeValue(forKey: proposal.requestID)
            throw PluginError.invalid("Select Relay with no open dialog before requesting a local terminal")
        }
        return receipts[proposal.requestID] ?? initial
    }
}
