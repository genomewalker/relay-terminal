import AppKit

enum MCPWorkspaceCapability: String, CaseIterable, Codable {
    case navigate, create, layout, input, terminate
}

/// One native decision for this Relay installation. The grant is
/// deliberately limited to terminal and workspace control; other MCP domains
/// keep their own authorization rules.
@MainActor final class MCPWorkspaceGrant {
    static let shared = MCPWorkspaceGrant()
    private struct SavedGrant: Codable {
        let installationID: String
        let policyVersion: Int
        let capabilities: [MCPWorkspaceCapability]
    }
    private let defaultsKey = "relay.mcp-workspace-grant.v1"
    private let installationID: String?
    private let defaults: UserDefaults
    typealias Presenter = (NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool
    private let present: Presenter
    private(set) var allowed: Set<MCPWorkspaceCapability> = []
    private(set) var status = "not_requested"

    init(present: Presenter? = nil) {
        defaults = RelayStateProfile.defaults
        // Injected presenters are used by unit fixtures; never load production consent.
        installationID = present == nil
            ? (Bundle.main.object(forInfoDictionaryKey: "RelayInstallationID") as? String)
                .flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
            : nil
        self.present = present ?? { alert, completion in
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ??
                    NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  window.attachedSheet == nil else { return false }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: completion)
            return true
        }
        if let installationID,
           let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(SavedGrant.self, from: data),
           saved.installationID == installationID, saved.policyVersion == 1 {
            allowed = Set(saved.capabilities)
            status = "granted"
        }
    }

    func revoke() {
        defaults.removeObject(forKey: defaultsKey)
        allowed = []
        status = "not_requested"
    }

    private func save() {
        guard let installationID else { return }
        let grant = SavedGrant(installationID: installationID, policyVersion: 1,
            capabilities: allowed.sorted { $0.rawValue < $1.rawValue })
        if let data = try? JSONEncoder().encode(grant) { defaults.set(data, forKey: defaultsKey) }
    }

    func permits(_ capability: MCPWorkspaceCapability) -> Bool {
        status == "granted" && allowed.contains(capability)
    }

    func request() throws {
        guard status == "not_requested" || status == "denied" else { return }
        let alert = RelayTheme.alert()
        alert.messageText = "Allow MCP agents to control Relay terminals?"
        alert.informativeText = "Choose what agents may do for this Relay installation. Approval survives app restarts and updates. Reinstalling with a new installation identity or resetting MCP permissions requires approval again. Commands run in your terminals; termination ends a selected Relay-managed process. You can turn off any capability before approving."
        let labels: [(MCPWorkspaceCapability, String)] = [
            (.navigate, "Select and focus tabs and panes"),
            (.create, "Create tabs and terminal panes"),
            (.layout, "Split, arrange, and close panes or tabs"),
            (.input, "Send commands to terminals"),
            (.terminate, "Terminate Relay-managed terminal processes")
        ]
        let buttons = labels.map { capability, title -> (MCPWorkspaceCapability, NSButton) in
            let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            button.state = .on
            return (capability, button)
        }
        let stack = NSStackView(views: buttons.map { $0.1 })
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 140)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow selected")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        status = "awaiting_approval"
        guard present(alert, { [weak self] response in
            guard let self else { return }
            guard self.status == "awaiting_approval" else { return }
            if response == .alertSecondButtonReturn {
                self.allowed = Set(buttons.compactMap { $0.1.state == .on ? $0.0 : nil })
                self.status = "granted"
                self.save()
            } else {
                self.allowed = []
                self.status = "denied"
            }
        }) else {
            status = "not_requested"
            throw PluginError.invalid("Open Relay with no other dialog to approve agent control")
        }
    }
}

enum WorkspaceAction: String, Codable, CaseIterable {
    case select, newTab, splitRight, splitDown, zoom, unzoom, float, dock, balance, close, conversation, terminal
}

enum WorkspaceTabAction: String, Codable {
    case rename, close, move
}

struct WorkspaceTabProposal: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let tabID: UUID
    let action: WorkspaceTabAction
    let name: String?
    let targetTabID: UUID?
    let placement: TabMovePlacement?
}

struct WorkspaceProposal: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let paneID: UUID
    let action: WorkspaceAction
    var connectionHost: String? = nil
}

struct MCPRecoverablePanesRequest: Codable {
    let host: String?
}

struct MCPRecoverPaneRequest: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let host: String
    let paneID: UUID
}

struct MCPTerminatePaneRequest: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let host: String
    let paneID: UUID
}

/// Exact-target, instance-bound workspace operations. The UI and MCP share the
/// same model operations; no synthetic clicks, key presses or shell commands.
@MainActor final class WorkspaceControl {
    private let approval: LocalPaneApproval
    private var proposals: [UUID: WorkspaceProposal] = [:]
    private var tabProposals: [UUID: WorkspaceTabProposal] = [:]

    init(present: PeerNetworkApproval.Presenter? = nil) {
        approval = LocalPaneApproval(present: present)
    }

    func receipt(_ id: UUID) -> LocalPaneReceipt? {
        guard var result = approval.receipt(id) else { return nil }
        if result.status == "created" { result.status = "applied" }
        return result
    }

    func propose(_ proposal: WorkspaceProposal, instance: UUID, detail: String,
                 apply: @escaping () -> (UUID, UUID)?) throws -> LocalPaneReceipt {
        guard proposal.instance == instance else { throw PluginError.invalid("Stale Relay instance") }
        if let old = proposals[proposal.requestID], old != proposal {
            throw PluginError.invalid("Conflicting workspace request ID")
        }
        proposals[proposal.requestID] = proposal
        do {
            _ = try approval.propose(.init(instance: proposal.instance, requestID: proposal.requestID),
                instance: instance, title: "Allow workspace action: \(proposal.action.rawValue)?",
                detail: detail + "\nTarget: \(proposal.paneID). Approval expires in two minutes.",
                button: "Apply") { apply() }
        } catch {
            if approval.receipt(proposal.requestID) == nil { proposals.removeValue(forKey: proposal.requestID) }
            throw error
        }
        return receipt(proposal.requestID)!
    }

    func propose(_ proposal: WorkspaceTabProposal, instance: UUID, detail: String,
                 apply: @escaping () -> (UUID, UUID)?) throws -> LocalPaneReceipt {
        guard proposal.instance == instance else { throw PluginError.invalid("Stale Relay instance") }
        if let old = tabProposals[proposal.requestID], old != proposal {
            throw PluginError.invalid("Conflicting workspace request ID")
        }
        tabProposals[proposal.requestID] = proposal
        do {
            _ = try approval.propose(.init(instance: proposal.instance, requestID: proposal.requestID),
                instance: instance, title: "Allow tab action: \(proposal.action.rawValue)?",
                detail: detail + "\nTarget tab: \(proposal.tabID). Approval expires in two minutes.",
                button: "Apply") { apply() }
        } catch {
            if approval.receipt(proposal.requestID) == nil { tabProposals.removeValue(forKey: proposal.requestID) }
            throw error
        }
        return receipt(proposal.requestID)!
    }
}

extension WorkspaceModel {
    func workspaceTabActionDetail(_ proposal: WorkspaceTabProposal) throws -> String {
        guard let tab = tabs.first(where: { $0.id == proposal.tabID }) else {
            throw PluginError.invalid("Tab no longer exists")
        }
        switch proposal.action {
        case .rename:
            guard let name = proposal.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 80,
                  proposal.targetTabID == nil, proposal.placement == nil else {
                throw PluginError.invalid("Rename requires a tab name of 1–80 characters")
            }
            return "Rename this tab to ‘\(name)’; its panes and running processes are unchanged."
        case .close:
            guard proposal.name == nil, proposal.targetTabID == nil, proposal.placement == nil else {
                throw PluginError.invalid("Close accepts only a tab ID")
            }
            return "Close this tab and all its panes. Local processes stop; remote sessions may remain available for reconnection. Unsaved editor changes still require native confirmation."
        case .move:
            guard proposal.name == nil, let targetID = proposal.targetTabID,
                  let placement = proposal.placement,
                  let target = tabs.first(where: { $0.id == targetID }),
                  targetID != tab.id, target.sessionID == tab.sessionID else {
                throw PluginError.invalid("Move requires a different target tab in the same Relay session")
            }
            return "Move this tab \(placement.rawValue) tab \(targetID) within its Relay session."
        }
    }

    @discardableResult
    func applyWorkspaceTabAction(_ proposal: WorkspaceTabProposal) -> UUID? {
        guard (try? workspaceTabActionDetail(proposal)) != nil,
              let tab = tabs.first(where: { $0.id == proposal.tabID }) else { return nil }
        switch proposal.action {
        case .rename:
            guard let name = proposal.name,
                  (try? renameTab(tab.id, to: name)) != nil else { return nil }
        case .close:
            closeTab(tab.id)
            guard !tabs.contains(where: { $0.id == tab.id }) else { return nil }
        case .move:
            guard let targetID = proposal.targetTabID, let placement = proposal.placement else { return nil }
            moveTab(tab.id, relativeTo: targetID, placement: placement)
        }
        return tab.id
    }

    /// Navigation is an exact-pane operation. It never creates or closes a pane,
    /// submits terminal input, or changes the pane's connection.
    /// External navigation is an explicit request to focus this application.
    /// Use the selected pane's own hosting window; never choose an unrelated
    /// main/focused window while a cold tab is mounting its terminal view.
    func activateSelectedWorkspacePane(_ pane: PaneModel) {
        guard !RelayLaunchMode.isRunningTests, let application = NSApp else { return }
        application.activate(ignoringOtherApps: true)
        if pane.contentKind == .terminal {
            pane.runtime.view.window?.makeKeyAndOrderFront(nil)
        }
        Task { @MainActor [weak self, weak pane] in
            await Task.yield()
            guard let self, let pane, self.panes[pane.id] === pane,
                  self.activePaneID == pane.id else { return }
            if pane.contentKind == .terminal {
                pane.runtime.view.window?.makeKeyAndOrderFront(nil)
            }
            pane.focus()
        }
    }

    func selectWorkspacePane(_ paneID: UUID) throws -> (UUID, UUID) {
        guard let pane = panes[paneID],
              let tab = tabs.first(where: { $0.allPaneIDs.contains(paneID) }) else {
            throw PluginError.invalid("Pane no longer exists")
        }
        revealPane(paneID)
        guard selectedTabID == tab.id, activePaneID == pane.id else {
            throw PluginError.invalid("Pane selection failed")
        }
        activateSelectedWorkspacePane(pane)
        return (tab.id, pane.id)
    }

    func workspaceActionDetail(_ proposal: WorkspaceProposal) throws -> String {
        guard let pane = panes[proposal.paneID],
              let tab = tabs.first(where: { $0.allPaneIDs.contains(pane.id) }) else {
            throw PluginError.invalid("Pane no longer exists")
        }
        let acceptsConnection = proposal.action == .newTab || proposal.action == .splitRight || proposal.action == .splitDown
        guard acceptsConnection || proposal.connectionHost == nil,
              proposal.connectionHost.map({ !$0.isEmpty }) ?? true else {
            throw PluginError.invalid("A connection target is valid only for tab or pane creation")
        }
        switch proposal.action {
        case .conversation, .terminal:
            guard pane.contentKind == .terminal else { throw PluginError.invalid("Select a terminal conversation") }
            return "Show this pane's original CLI conversation or terminal."
        case .newTab:
            guard pane.contentKind == .terminal else { throw PluginError.invalid("Select a terminal to create a tab") }
            return proposal.connectionHost.map { "Create a tab in this Relay session using connection target \($0)." }
                ?? "Create a tab in this Relay session using this terminal's connection profile."
        case .close:
            // closeActivePane closes the whole tab when its last tiled pane is
            // removed. Never let a targeted request close floating neighbours.
            guard pane.contentKind == .terminal,
                  tab.layout.paneIDs != [pane.id] || tab.allPaneIDs.count == 1 else {
                throw PluginError.invalid("Cannot close an editor or the last tiled pane with floating neighbours")
            }
            return pane.profile.backend == .relay
                ? "Detach this terminal pane; its persistent session keeps running. No other pane is closed."
                : "Close this nonpersistent terminal and stop its running process. No other pane is closed."
        case .splitRight, .splitDown:
            guard pane.contentKind == .terminal else { throw PluginError.invalid("Select a terminal to split") }
            return proposal.connectionHost.map { "Create a terminal beside this pane using connection target \($0). No command is submitted." }
                ?? "Create a terminal using this pane's connection profile. No command is submitted."
        case .float:
            guard tab.layout.paneIDs.count > 1, tab.layout.paneIDs.contains(pane.id) else {
                throw PluginError.invalid("Only a tiled pane with a tiled neighbour can float")
            }
        case .dock:
            guard tab.floatingPanes.contains(where: { $0.paneID == pane.id }) else {
                throw PluginError.invalid("Only a floating pane can be docked")
            }
        default: break
        }
        return "Change this pane's workspace presentation. No terminal input is sent."
    }

    func applyWorkspaceAction(_ proposal: WorkspaceProposal, expected: PaneModel, profile: ConnectionProfile? = nil) -> (UUID, UUID)? {
        guard panes[proposal.paneID] === expected,
              (try? workspaceActionDetail(proposal)) != nil else { return nil }
        revealPane(proposal.paneID)
        guard let tab = selectedTab, tab.allPaneIDs.contains(proposal.paneID) else { return nil }
        switch proposal.action {
        case .select: activateSelectedWorkspacePane(expected)
        case .conversation:
            showOriginalCLIConversation(pane: expected)
        case .terminal:
            expected.nativeConversationVisible = false
        case .newTab:
            newTabInActiveSession(profile: profile ?? expected.profile)
            guard let newTab = selectedTab, let newPane = activePaneID,
                  newTab.id != tab.id else { return nil }
            return (newTab.id, newPane)
        case .splitRight: splitActive(axis: .horizontal, profile: profile ?? expected.profile)
        case .splitDown: splitActive(axis: .vertical, profile: profile ?? expected.profile)
        case .zoom:
            if zoomedPaneID != proposal.paneID { togglePaneZoom(proposal.paneID) }
        case .unzoom:
            if let zoomed = zoomedPaneID {
                togglePaneZoom(zoomed)
                selectPane(proposal.paneID)
            }
        case .float: floatTiledPane(proposal.paneID)
        case .dock: dockFloatingPane(proposal.paneID)
        case .balance: balanceActiveTabPanes()
        case .close:
            closeActivePane()
            guard panes[proposal.paneID] == nil else { return nil }
            return (tab.id, proposal.paneID)
        }
        return (tab.id, activePaneID ?? proposal.paneID)
    }
}
