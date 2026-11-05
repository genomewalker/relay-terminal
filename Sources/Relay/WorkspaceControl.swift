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
    case overview, back, forward, up
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
    /// Starting directory for a new tab or split pane (absolute). Optional and
    /// absent from older MCP clients, which keep the profile default.
    var directory: String? = nil
    /// Set only by the remote MCP bridge; see WorkspaceApplyAdmission.
    var bridgeScope: WorkspaceBridgeScope? = nil

    var validDirectory: Bool {
        guard let directory else { return true }
        return [.newTab, .splitRight, .splitDown].contains(action) && directory.hasPrefix("/") &&
            directory.utf8.count <= 1024 && !directory.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
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

struct MCPPrivateSecretEnvelope: Decodable {
    let tool: String
    let requestID: UUID
    let attestationID: String
    let sourcePaneID: UUID
    let arguments: String
    enum CodingKeys: String, CodingKey {
        case tool, arguments
        case requestID = "request_id", attestationID = "attestation_id", sourcePaneID = "source_pane_id"
    }
}
struct MCPPrivateSecretArguments: Decodable {
    let instance: UUID
    let requestID: UUID
    let accountID: String?
    let credentialReference: String?
    let purpose: String?
    enum CodingKeys: String, CodingKey {
        case instance, purpose
        case requestID = "request_id", accountID = "account_id", credentialReference = "credential_reference"
    }
}

struct MCPAccountPreviewRequest: Decodable {
    let instance: UUID
    let paneID: UUID
    let account: String
}

struct MCPAccountSyncRequest: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let paneID: UUID
    let account: String
    let reviewToken: String
}

struct MCPMovePaneAccountRequest: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let paneID: UUID
    let account: String
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
    func applyWorkspacePaneDrop(_ paneID: UUID, toTab tabID: UUID, onto targetID: UUID,
                                placement: PaneDropPlacement) throws {
        guard paneID != targetID else { return }
        let floatingSource = tabs.contains { tab in tab.floatingPanes.contains { $0.paneID == paneID } }
        if placement == .center && !floatingSource {
            try stackPane(paneID, onto: targetID)
        } else if self.tabID(containingPane: paneID) == tabID {
            try movePane(paneID, toTab: tabID, beside: targetID, placement: placement == .center ? .trailing : placement)
        } else {
            // Any workspace, any legacy session: the same pane object is re-homed.
            try movePane(paneID, to: .split(tabID: tabID, beside: targetID, placement: placement == .center ? .trailing : placement),
                         reveal: selectedTabID == tabID)
        }
    }

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
                  let placement = proposal.placement else {
                throw PluginError.invalid("Move requires a target tab and before or after placement")
            }
            let destination = try workspaceTabMoveDestination(tab.id, beside: targetID, placement: placement)
            let name = ownership.workspace(destination.workspaceID)?.name ?? "its workspace"
            return "Move this tab \(placement.rawValue) tab \(targetID) in workspace ‘\(name)’. Its panes, processes, agent sessions, pane links and remote attachments are unchanged; nothing is restarted, detached or closed."
        }
    }

    /// Where an exact tab move lands: the target tab's workspace, at the
    /// index beside the target among that workspace's other tabs. The same
    /// ownership move the tab rail's drag and drop performs, so it works
    /// across workspaces and legacy sessions and only edits ownership records.
    func workspaceTabMoveDestination(_ sourceID: UUID, beside targetID: UUID,
                                     placement: TabMovePlacement) throws -> (workspaceID: UUID, index: Int) {
        guard sourceID != targetID else { throw WorkspaceMoveRefusal.samePlace }
        guard tabs.contains(where: { $0.id == sourceID }), tabs.contains(where: { $0.id == targetID }),
              workspaceID(forTab: sourceID) != nil, let workspaceID = workspaceID(forTab: targetID) else {
            throw WorkspaceMoveRefusal.unknownTab
        }
        guard !tabsAwaitingCloseConfirmation.contains(sourceID),
              !tabsAwaitingCloseConfirmation.contains(targetID) else { throw WorkspaceMoveRefusal.tabClosing }
        if let refusal = canMoveTab(sourceID, toWorkspace: workspaceID) { throw refusal }
        let others = tabs(inWorkspace: workspaceID).map(\.id).filter { $0 != sourceID }
        guard let targetIndex = others.firstIndex(of: targetID) else { throw WorkspaceMoveRefusal.unknownTab }
        return (workspaceID, targetIndex + (placement == .after ? 1 : 0))
    }

    /// Moves one exact tab beside another, in any workspace. Validated first;
    /// on success the tab sits immediately before or after the target in
    /// the target's workspace. Returns the destination workspace.
    @discardableResult
    func moveWorkspaceTab(_ sourceID: UUID, beside targetID: UUID, placement: TabMovePlacement) throws -> UUID {
        let destination = try workspaceTabMoveDestination(sourceID, beside: targetID, placement: placement)
        try performDrop(.tabOnWorkspace(tabID: sourceID, workspaceID: destination.workspaceID, index: destination.index))
        placeInOrganization(sourceID, beside: targetID, placement: placement)
        // Never report a move that left either projection unchanged.
        guard workspaceTabIsBeside(sourceID, targetID, placement: placement) else { throw WorkspaceMoveRefusal.unknownTarget }
        return destination.workspaceID
    }

    /// Tabs shown with `tabID` in the organization outline: its group's
    /// direct tabs, or the Ungrouped tabs. The same sibling list the
    /// outline's tab drag and drop uses.
    func organizationSiblings(ofTab tabID: UUID) -> (groupID: UUID?, tabIDs: [UUID]) {
        let group = organization.group(containingTab: tabID)?.id
        let nodes = group.map { organization.children(of: $0) } ?? organization.outline()
        let ids = nodes.flatMap { node -> [UUID] in
            switch node {
            case let .tab(value): [value]
            case let .ungrouped(children) where group == nil:
                children.compactMap { if case let .tab(value) = $0 { value } else { nil } }
            default: []
            }
        }
        return (group, ids)
    }

    /// Shows `tabID` immediately before or after `targetID` in the target's
    /// organization group (a session group, a project, or Ungrouped).
    /// Presentation records only.
    func placeInOrganization(_ tabID: UUID, beside targetID: UUID, placement: TabMovePlacement) {
        let siblings = organizationSiblings(ofTab: targetID)
        let others = siblings.tabIDs.filter { $0 != tabID }
        guard let index = others.firstIndex(of: targetID) else { return }
        organization.placeTab(tabID, inGroup: siblings.groupID, at: index + (placement == .after ? 1 : 0))
    }

    /// True when `tabID` sits immediately before or after `targetID` both in
    /// workspace ownership (tab rail, Workspaces navigator) and in the
    /// organization outline (session groups).
    func workspaceTabIsBeside(_ tabID: UUID, _ targetID: UUID, placement: TabMovePlacement) -> Bool {
        let step = placement == .after ? 1 : -1
        guard let workspaceID = workspaceID(forTab: targetID), self.workspaceID(forTab: tabID) == workspaceID else { return false }
        let order = ownership.tabIDs(in: workspaceID)
        guard let source = order.firstIndex(of: tabID), let target = order.firstIndex(of: targetID),
              source == target + step else { return false }
        let mine = organizationSiblings(ofTab: tabID), theirs = organizationSiblings(ofTab: targetID)
        guard mine.groupID == theirs.groupID,
              let shown = theirs.tabIDs.firstIndex(of: tabID), let anchor = theirs.tabIDs.firstIndex(of: targetID) else { return false }
        return shown == anchor + step
    }

    /// Where an anchored new tab goes: the anchor tab (given directly, or
    /// the tab holding the anchor pane), which must exist, be owned and not
    /// be closing.
    func newTabAnchor(paneID: UUID?, tabID: UUID?) throws -> (tab: TabModel, sourcePane: UUID, workspaceID: UUID) {
        let resolved: UUID?
        switch (paneID, tabID) {
        case let (pane?, nil):
            guard panes[pane] != nil else { throw PluginError.invalid("Anchor pane no longer exists") }
            resolved = self.tabID(containingPane: pane)
        case let (nil, tab?): resolved = tab
        default: throw PluginError.invalid("Give exactly one anchor: a pane ID or a tab ID")
        }
        guard let anchorID = resolved, let tab = tabs.first(where: { $0.id == anchorID }),
              let workspaceID = workspaceID(forTab: anchorID),
              let sourcePane = paneID ?? tab.allPaneIDs.first else {
            throw PluginError.invalid("Anchor tab no longer exists")
        }
        guard !tabsAwaitingCloseConfirmation.contains(anchorID) else { throw WorkspaceMoveRefusal.tabClosing }
        return (tab, sourcePane, workspaceID)
    }

    /// Opens a local shell tab immediately after the anchor tab, in the
    /// anchor's legacy session and workspace. No existing tab, pane or
    /// runtime is touched; only the new tab is placed.
    func newLocalTab(anchorPaneID: UUID?, anchorTabID: UUID?) throws -> (tabID: UUID, paneID: UUID) {
        let anchor = try newTabAnchor(paneID: anchorPaneID, tabID: anchorTabID)
        let existing = Set(tabs.map(\.id))
        withTabAdmission(.workspace(anchor.workspaceID)) {
            newTab(inSession: anchor.tab.sessionID, profile: .local, origin: .agent(sourcePane: anchor.sourcePane))
        }
        guard let created = selectedTab, !existing.contains(created.id), let paneID = activePaneID,
              created.allPaneIDs == [paneID], created.sessionID == anchor.tab.sessionID else {
            throw PluginError.invalid("Local tab creation failed")
        }
        // Legacy order too, so session views also show it beside the anchor.
        if let from = tabs.firstIndex(where: { $0 === created }) {
            var reordered = tabs
            reordered.remove(at: from)
            if let anchorIndex = reordered.firstIndex(where: { $0.id == anchor.tab.id }) {
                reordered.insert(created, at: anchorIndex + 1)
                tabs = reordered
            }
        }
        if workspaceID(forTab: created.id) != nil {
            let others = tabs(inWorkspace: anchor.workspaceID).map(\.id).filter { $0 != created.id }
            let index = (others.firstIndex(of: anchor.tab.id) ?? others.count - 1) + 1
            try moveTab(created.id, toWorkspace: anchor.workspaceID, at: index)
        }
        placeInOrganization(created.id, beside: anchor.tab.id, placement: .after)
        persistWorkspace()
        // The tab exists now; report its exact IDs, but only claim the
        // anchored place when both projections show it there.
        guard workspaceTabIsBeside(created.id, anchor.tab.id, placement: .after) else {
            throw PluginError.invalid("Created tab \(created.id.uuidString.lowercased()) could not be placed after the anchor")
        }
        return (created.id, paneID)
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
            guard let targetID = proposal.targetTabID, let placement = proposal.placement,
                  (try? moveWorkspaceTab(tab.id, beside: targetID, placement: placement)) != nil else { return nil }
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
        // Floating R panels belong to a tab without being in its layout.
        guard let pane = panes[paneID], let tabID = tabID(containingPane: paneID) else {
            throw PluginError.invalid("Pane no longer exists")
        }
        revealPane(paneID)
        guard selectedTabID == tabID, activePaneID == pane.id else {
            throw PluginError.invalid("Pane selection failed")
        }
        activateSelectedWorkspacePane(pane)
        return (tabID, pane.id)
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
        // History navigation must not first reveal the anchoring pane: doing so
        // would insert a different history entry before processing Back.
        if [.overview, .back, .forward, .up].contains(proposal.action) {
            guard let tabID = tabID(containingPane: proposal.paneID) else { return nil }
            switch proposal.action {
            case .overview: organization.navigate(to: .all)
            case .back: organization.goBack()
            case .forward: organization.goForward()
            case .up: organization.goUp()
            default: break
            }
            if let selected = selectedTab, let active = activePaneID, selected.allPaneIDs.contains(active) {
                return (selected.id, active)
            }
            return (tabID, proposal.paneID)
        }
        // A starting directory is never invented: it must already be in use on
        // that host or have been resolved there (MCP clients never send one).
        if let directory = proposal.directory,
           !admitsStartingDirectory(directory, profile: profile ?? expected.profile) { return nil }
        revealPane(proposal.paneID)
        guard let tab = selectedTab, tab.allPaneIDs.contains(proposal.paneID) else { return nil }
        switch proposal.action {
        case .select: activateSelectedWorkspacePane(expected)
        case .conversation:
            showOriginalCLIConversation(pane: expected)
        case .terminal:
            expected.nativeConversationVisible = false
        case .newTab:
            // An approval route captures its scope at admission (outer wins).
            newTabInActiveSession(profile: profile ?? expected.profile, directory: proposal.directory,
                                  origin: .agent(sourcePane: proposal.paneID))
            guard let newTab = selectedTab, let newPane = activePaneID,
                  newTab.id != tab.id else { return nil }
            return (newTab.id, newPane)
        case .splitRight: splitActive(axis: .horizontal, profile: profile ?? expected.profile, directory: proposal.directory)
        case .splitDown: splitActive(axis: .vertical, profile: profile ?? expected.profile, directory: proposal.directory)
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
        case .overview, .back, .forward, .up: break
        }
        return (tab.id, activePaneID ?? proposal.paneID)
    }
}
