import AppKit
import Foundation

struct AgentInputProposal: Codable, Equatable, Sendable {
    let instance: UUID
    let requestID: UUID
    let text: String
    /// Set by the Relay assistant: send only if the pane's input revision is
    /// still this one and its prompt is provably empty. MCP clients omit it.
    var expectedInputRevision: UInt64? = nil
    var isValid: Bool {
        !text.isEmpty && text.utf8.count <= 65536 &&
        !text.unicodeScalars.contains { $0.value < 32 && $0.value != 10 && $0.value != 9 }
    }
}

/// MCP request to enable or pause host context rotation for one exact pane.
struct RelayContextRotationRequest: Codable, Equatable, Sendable {
    let instance: UUID
    let requestID: UUID
    let enabled: Bool
    /// Explicit user-requested resume; ordinary Enable never lifts takeover.
    var resumeHumanTakeover: Bool? = nil
    var permitsResumingHumanTakeover: Bool { enabled && resumeHumanTakeover == true }
}

struct AgentInputReceipt: Codable, Sendable {
    let requestID: UUID
    let paneID: UUID
    var status: String
}

/// A request is never executed by HTTP alone. One visible native approval is
/// required per submission. Receipts live for this server incarnation, which
/// clients must name explicitly so a restart cannot replay an old proposal.
@MainActor
final class AgentInputRequests {
    let instance = UUID()
    private var proposals: [UUID: AgentInputProposal] = [:]
    private var receipts: [UUID: AgentInputReceipt] = [:]
    private var pending: UUID?

    func receipt(_ id: UUID) -> AgentInputReceipt? { receipts[id] }

    func propose(_ proposal: AgentInputProposal, pane: PaneModel,
                 stillCurrent: @escaping @MainActor () -> Bool) throws -> AgentInputReceipt {
        guard proposal.instance == instance, proposal.isValid else {
            throw PluginError.invalid("Invalid or stale request; rediscover the Relay instance")
        }
        if let old = receipts[proposal.requestID] {
            guard old.paneID == pane.id, proposals[proposal.requestID] == proposal else {
                throw PluginError.invalid("Request ID already belongs to another proposal")
            }
            return old
        }
        guard receipts.count < 256, pending == nil else {
            throw PluginError.invalid("Approval queue is busy or full")
        }
        guard pane.connectionState == .connected, pane.contentKind == .terminal,
              let window = pane.runtime.view.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              window.attachedSheet == nil else {
            throw PluginError.invalid("Open Relay and select a connected terminal before requesting input")
        }
        let revision = pane.agentInputRevision
        let deadline = Date().addingTimeInterval(120)
        let receipt = AgentInputReceipt(requestID: proposal.requestID, paneID: pane.id, status: "awaiting_approval")
        receipts[proposal.requestID] = receipt
        proposals[proposal.requestID] = proposal
        pending = proposal.requestID
        let alert = RelayTheme.alert()
        alert.messageText = "Send this input to \(pane.displayName)?"
        alert.informativeText = "Host: \(pane.profile.name)\nPane: \(pane.id.uuidString)\nThis pastes the text and presses Return. Check that the console is ready and its input is empty. Approval expires in two minutes. Delivery is not proof of execution or completion."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Send and press Return")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 240))
        let text = NSTextView(frame: scroll.bounds)
        text.string = proposal.text
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { [weak self, weak pane] response in
            guard let self else { return }
            self.pending = nil
            var status = "cancelled"
            if response == .alertSecondButtonReturn {
                if let pane, Date() < deadline, stillCurrent(),
                   pane.agentInputRevision == revision, pane.connectionState == .connected {
                    status = pane.runtime.sendSidePanelPrompt(proposal.text) ? "submitted_outcome_unknown" : "unavailable"
                } else { status = "stale_or_expired" }
            }
            self.receipts[proposal.requestID]?.status = status
        }
        return receipt
    }
}

/// The Relay assistant's draft fence for text typed into a pane.
enum RelayAssistantInputFence {
    struct Proof: Equatable, Sendable {
        let empty: Bool
        let inputRevision: UInt64
        /// Positive evidence of typed text. Not empty and not a draft means
        /// the prompt simply could not be verified (for example still drawing).
        var draft: Bool = false
    }
    enum Outcome: String, Sendable {
        case sent = "submitted_outcome_unknown"
        case draftPresent = "draft_present"
        case promptUnverified = "prompt_unverified"
        case inputChanged = "input_changed"
        case unavailable
    }
    /// Revision first: any input since the card was shown refuses, even if the
    /// prompt is empty again. Then the prompt must be provably empty now.
    static func admit(expected: UInt64, current: UInt64, empty: Bool, draft: Bool = true) -> Outcome {
        guard expected == current else { return .inputChanged }
        return empty ? .sent : draft ? .draftPresent : .promptUnverified
    }
}
