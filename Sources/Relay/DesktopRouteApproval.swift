import AppKit

struct DesktopRouteProposal: Codable, Equatable, Sendable {
    let instance: UUID
    let requestID: UUID
    let thread: String
    let host: String
    let remoteName: String
    let remoteSession: String
    let remotePID: Int
    let remoteStart: String

    func isValid(for currentInstance: UUID) -> Bool {
        instance == currentInstance && PeerDiscovery.routeHostIsValid(host) &&
        thread.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$"#, options: .regularExpression) != nil &&
        remoteName.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$"#, options: .regularExpression) != nil &&
        remoteSession.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,109}$"#, options: .regularExpression) != nil &&
        remotePID > 0 && remotePID <= Int(Int32.max) &&
        PeerDiscovery.validProcessStart(remoteStart, host: host)
    }
}

struct DesktopRouteReceipt: Codable {
    let requestID: UUID
    var status: String
    var replyName: String?
    var reason: String?
}

@MainActor
final class DesktopRouteApproval {
    typealias Presenter = (NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool
    private let present: Presenter
    private var proposals: [UUID: DesktopRouteProposal] = [:]
    private var receipts: [UUID: DesktopRouteReceipt] = [:]
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

    func receipt(_ id: UUID) -> DesktopRouteReceipt? { receipts[id] }

    func propose(_ proposal: DesktopRouteProposal, instance: UUID) throws -> DesktopRouteReceipt {
        guard proposal.isValid(for: instance) else {
            throw PluginError.invalid("Invalid or stale desktop route proposal")
        }
        if let receipt = receipts[proposal.requestID] {
            guard proposals[proposal.requestID] == proposal else {
                throw PluginError.invalid("Request ID already used for another proposal")
            }
            return receipt
        }
        guard !pending, receipts.count < 256 else {
            throw PluginError.invalid("Another network approval is pending")
        }
        let receipt = DesktopRouteReceipt(requestID: proposal.requestID, status: "awaiting_approval")
        proposals[proposal.requestID] = proposal
        receipts[proposal.requestID] = receipt
        pending = true
        let deadline = Date().addingTimeInterval(120)
        let alert = RelayTheme.alert()
        alert.messageText = "Connect this desktop task to the remote agent?"
        let targetLocation = proposal.host == "laptop" ? "This Mac" : "SSH host: \(proposal.host)"
        alert.informativeText = "Desktop task: \(proposal.thread)\n\(targetLocation)\nAgent: \(proposal.remoteName) · \(proposal.remoteSession) · PID \(proposal.remotePID) · start \(proposal.remoteStart)\n\nRelay will save and start a messaging route. It will not restart either agent. Approval expires in two minutes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Connect and remember")
        alert.buttons[0].keyEquivalent = "\r"
        let presented = present(alert) { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard self.receipts[proposal.requestID]?.status == "awaiting_approval" else { return }
                self.receipts[proposal.requestID]?.status = "confirming"
                defer { self.pending = false }
                guard response == .alertSecondButtonReturn else {
                    self.receipts[proposal.requestID]?.status = "cancelled"
                    return
                }
                guard Date() < deadline else {
                    self.receipts[proposal.requestID]?.status = "stale_or_expired"
                    self.receipts[proposal.requestID]?.reason = "approval_expired"
                    return
                }
                do {
                    let result = try await Task.detached(priority: .utility) {
                        let available = try DesktopPeerRoute.taskAvailable(proposal.thread)
                        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
                            .appendingPathComponent("relay-peer-link") else {
                            throw PluginError.invalid("The bundled peer discovery helper is unavailable")
                        }
                        let peers = try PeerDiscovery.routePeers(host: proposal.host, localExecutable: executable)
                        return (available, peers)
                    }.value
                    // A truncated inventory can still contain the exact verified peer.
                    // PID and start time pin its incarnation independently of other peers.
                    guard Date() < deadline,
                          result.0,
                          let peer = result.1.peers.first(where: {
                              $0.name == proposal.remoteName && $0.sessionId == proposal.remoteSession &&
                              $0.pid == proposal.remotePID && $0.procStart == proposal.remoteStart
                          }) else {
                        self.receipts[proposal.requestID]?.status = "stale_or_expired"
                        self.receipts[proposal.requestID]?.reason = Date() >= deadline ? "approval_expired" :
                            (!result.0 ? "desktop_task_unavailable" : "peer_identity_unavailable")
                        return
                    }
                    try await Task.detached(priority: .utility) {
                        try DesktopPeerRoute.remember(thread: proposal.thread, host: proposal.host, peer: peer)
                    }.value
                    let route = DesktopPeerRoute.read().first {
                        $0.thread == proposal.thread && $0.host == proposal.host &&
                        $0.remoteSession == proposal.remoteSession && $0.remotePID == proposal.remotePID &&
                        $0.remoteStart == proposal.remoteStart
                    }
                    self.receipts[proposal.requestID]?.replyName = route?.localName
                    self.receipts[proposal.requestID]?.status = route == nil ? "unknown" : "launch_requested"
                } catch {
                    self.receipts[proposal.requestID]?.status = "failed"
                }
            }
        }
        guard presented else {
            pending = false
            proposals.removeValue(forKey: proposal.requestID)
            receipts.removeValue(forKey: proposal.requestID)
            throw PluginError.invalid("Select Relay with no open dialog before requesting a desktop route")
        }
        return receipt
    }
}

/// Explicit user instructions can create an exact route without a second
/// confirmation sheet. The adapter cannot infer authorization from peer or
/// terminal content; callers must only use this path for user-authored intent.
@MainActor
final class DesktopRouteDirectControl {
    private var proposals: [UUID: DesktopRouteProposal] = [:]
    private var receipts: [UUID: DesktopRouteReceipt] = [:]
    private var pending = false

    func receipt(_ id: UUID) -> DesktopRouteReceipt? { receipts[id] }

    func create(_ proposal: DesktopRouteProposal, instance: UUID) async throws -> DesktopRouteReceipt {
        guard proposal.isValid(for: instance) else { throw PluginError.invalid("Invalid or stale desktop route") }
        if let previous = receipts[proposal.requestID] {
            guard proposals[proposal.requestID] == proposal else {
                throw PluginError.invalid("Request ID already used for another route")
            }
            return previous
        }
        guard !pending, receipts.count < 256 else { throw PluginError.invalid("Another route setup is in progress") }
        pending = true
        proposals[proposal.requestID] = proposal
        receipts[proposal.requestID] = DesktopRouteReceipt(requestID: proposal.requestID, status: "checking")
        defer { pending = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                let peers: PeerDiscovery
                if proposal.host == "laptop" {
                    guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
                        .appendingPathComponent("relay-peer-link"),
                        FileManager.default.isExecutableFile(atPath: executable.path) else {
                        throw PluginError.invalid("The local peer discovery helper is missing from this Relay build")
                    }
                    peers = try PeerDiscovery.local(executable: executable)
                } else {
                    peers = try PeerDiscovery.remote(host: proposal.host,
                        helper: ".local/share/relay/peer-network/relay-peer-link")
                }
                return (try DesktopPeerRoute.taskAvailable(proposal.thread), peers)
            }.value
            // An incomplete inventory does not invalidate this exact verified peer.
            guard result.0,
                  let peer = result.1.peers.first(where: {
                      $0.name == proposal.remoteName && $0.sessionId == proposal.remoteSession &&
                      $0.pid == proposal.remotePID && $0.procStart == proposal.remoteStart
                  }) else {
                receipts[proposal.requestID]?.status = "stale_or_expired"
                receipts[proposal.requestID]?.reason = !result.0 ?
                    "desktop_task_unavailable" : "peer_identity_unavailable"
                return receipts[proposal.requestID]!
            }
            if let saved = DesktopPeerRoute.read().first(where: {
                $0.thread == proposal.thread && $0.host == proposal.host &&
                $0.remoteSession == proposal.remoteSession && $0.remotePID == proposal.remotePID &&
                $0.remoteStart == proposal.remoteStart
            }) {
                let evidence = DesktopRouteRecoveryEvidence(
                    routeID: saved.id, identityVerified: true, reconnectAuthorized: true,
                    identityConflict: false, observedAt: Date())
                let plan = await DesktopRouteRecoveryPlanner.shared.plan(evidence)
                guard DesktopRouteRecoveryPolicy.permits(plan, current: evidence) else {
                    receipts[proposal.requestID]?.status = "waiting_recovery"
                    return receipts[proposal.requestID]!
                }
                try await Task.detached(priority: .utility) {
                    // Revalidate the saved identity after the model yields.
                    try saved.setConnected(true)
                }.value
                RelayDiagnostics.shared.record(category: "network", name: "recovery-plan",
                    details: ["source": plan.usedAppleModel ? "apple" : "policy",
                              "action": plan.action.rawValue])
                receipts[proposal.requestID]?.replyName = saved.localName
                receipts[proposal.requestID]?.status = "launch_requested"
                return receipts[proposal.requestID]!
            }
            try await Task.detached(priority: .utility) {
                try DesktopPeerRoute.remember(thread: proposal.thread, host: proposal.host, peer: peer)
            }.value
            let route = DesktopPeerRoute.read().first {
                $0.thread == proposal.thread && $0.host == proposal.host &&
                $0.remoteSession == proposal.remoteSession && $0.remotePID == proposal.remotePID &&
                $0.remoteStart == proposal.remoteStart
            }
            receipts[proposal.requestID]?.replyName = route?.localName
            receipts[proposal.requestID]?.status = route == nil ? "unknown" : "launch_requested"
        } catch {
            receipts[proposal.requestID]?.status = "failed"
        }
        return receipts[proposal.requestID]!
    }
}
