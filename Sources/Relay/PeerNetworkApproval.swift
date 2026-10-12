import AppKit

struct PeerNetworkProposal: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let linkID: UUID
    let action: String
}

struct PeerNetworkReceipt: Codable {
    let requestID: UUID
    let linkID: UUID
    var status: String
}

struct PeerNetworkApprovalContext {
    let configuration: PeerLinkConfiguration
    let revision: UInt64
    let wasRunning: Bool
    let deadline: Date

    func isCurrent(now: Date, revision: UInt64, configurations: [PeerLinkConfiguration], running: Set<UUID>) -> Bool {
        now < deadline && self.revision == revision && configurations.contains(configuration) &&
            running.contains(configuration.id) == wasRunning
    }
}

/// Approval is tied to an immutable saved configuration and this server lifetime.
/// A receipt reports a launch/stop request, never remote delivery or completion.
@MainActor
final class PeerNetworkApproval {
    typealias Presenter = (NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool
    private let present: Presenter
    private var proposals: [UUID: PeerNetworkProposal] = [:]
    private var receipts: [UUID: PeerNetworkReceipt] = [:]
    private var pending = false

    init(present: Presenter? = nil) {
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

    func receipt(_ id: UUID) -> PeerNetworkReceipt? { receipts[id] }

    func propose(_ proposal: PeerNetworkProposal, instance: UUID,
                 controller: PeerNetworkController) throws -> PeerNetworkReceipt {
        guard proposal.instance == instance, ["connect", "disconnect"].contains(proposal.action) else {
            throw PluginError.invalid("Invalid or stale network proposal")
        }
        if let receipt = receipts[proposal.requestID] {
            guard proposals[proposal.requestID] == proposal else {
                throw PluginError.invalid("Request ID already used for another proposal")
            }
            return receipt
        }
        guard !pending, receipts.count < 256,
              let configuration = controller.configurations.first(where: { $0.id == proposal.linkID }) else {
            throw PluginError.invalid("Select Relay with no open dialog and choose an existing saved link")
        }
        let wasRunning = controller.running.contains(configuration.id)
        let revision = controller.revision
        guard proposal.action == "connect" ? !wasRunning : wasRunning else {
            throw PluginError.invalid("Link is already in the requested state or is not owned by Relay")
        }
        let receipt = PeerNetworkReceipt(requestID: proposal.requestID, linkID: proposal.linkID, status: "awaiting_approval")
        proposals[proposal.requestID] = proposal
        receipts[proposal.requestID] = receipt
        pending = true
        let deadline = Date().addingTimeInterval(120)
        let context = PeerNetworkApprovalContext(configuration: configuration, revision: revision,
                                                wasRunning: wasRunning, deadline: deadline)
        let alert = RelayTheme.alert()
        alert.messageText = proposal.action == "connect" ? "Connect these agent sessions?" : "Disconnect this agent link?"
        alert.informativeText = "SSH host: \(configuration.host)\nLocal: \(configuration.localName) · \(configuration.localSession) · PID \(configuration.localPID)\nRemote: \(configuration.remoteName) · \(configuration.remoteSession) · PID \(configuration.remotePID)\nHelper: \(configuration.remoteBinary)\n\nThis changes only Relay’s messaging link, not the underlying agents or terminals. Approval expires in two minutes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: proposal.action == "connect" ? "Connect" : "Disconnect link")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        let presented = present(alert) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
            guard self.receipts[proposal.requestID]?.status == "awaiting_approval" else { return }
            // Consume confirmation before awaiting discovery; duplicate callbacks
            // must not launch a second helper while the first is suspended.
            self.receipts[proposal.requestID]?.status = "confirming"
            defer { self.pending = false }
            var status = "cancelled"
            if response == .alertSecondButtonReturn {
                // Status files can live on slow storage. Never read them on the
                // UI thread; keep admission closed and revalidate after awaiting.
                let observed: [PeerNetworkStatus]
                if proposal.action == "connect" {
                    observed = await Task.detached(priority: .utility) {
                        PeerNetworkStatus.read(directory: RelayStateProfile.peerNetworkStatusRoot)
                    }.value
                } else { observed = [] }
                if context.isCurrent(now: Date(), revision: controller.revision,
                                     configurations: controller.configurations, running: controller.running) {
                    if proposal.action == "connect" {
                        controller.connect(configuration, observed: observed)
                        status = controller.running.contains(configuration.id) ? "launch_requested" : "failed"
                    } else {
                        controller.disconnect(configuration)
                        status = "stop_requested"
                    }
                } else { status = "stale_or_expired" }
            }
            self.receipts[proposal.requestID]?.status = status
            }
        }
        guard presented else {
            pending = false
            proposals.removeValue(forKey: proposal.requestID)
            receipts.removeValue(forKey: proposal.requestID)
            throw PluginError.invalid("Select Relay with no open dialog before requesting a network change")
        }
        return receipt
    }
}
