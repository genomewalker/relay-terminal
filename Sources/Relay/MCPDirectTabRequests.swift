import Foundation

/// The direct (pre-granted) MCP tab endpoints: `relay_tab_action` and
/// `relay_new_local_tab`. Each is admitted by one existing workspace grant
/// capability, read through `permits`; nothing here can request, widen or
/// record a grant. Request IDs are idempotent: a repeated identical request
/// returns the first result, a different request under the same ID is refused.
@MainActor final class MCPDirectTabRequests {
    /// The one capability each endpoint requires.
    enum Endpoint: CaseIterable {
        case tabAction, newLocalTab, stackPane, newStackedPane, renamePane
        /// Every capability the endpoint requires; all must be permitted.
        var capabilities: Set<MCPWorkspaceCapability> {
            switch self {
            case .tabAction, .stackPane, .renamePane: [.layout]
            case .newLocalTab: [.create]
            case .newStackedPane: [.create, .layout]
            }
        }
    }

    struct PaneRenameProposal: Codable, Equatable {
        let instance: UUID
        let requestID: UUID
        let paneID: UUID
        let name: String
    }
    private var renameRequests: [UUID: PaneRenameProposal] = [:]
    private var renameResults: [UUID: [String: String]] = [:]
    private var tabRequests: [UUID: WorkspaceTabProposal] = [:]
    private var tabResults: [UUID: [String: String]] = [:]
    private var localRequests: [UUID: LocalPaneProposal] = [:]
    private var localResults: [UUID: [String: String]] = [:]
    private var stackRequests: [UUID: PaneStackProposal] = [:]
    private var stackResults: [UUID: RelaySidePanelHTTPResponse] = [:]
    private var newStackedRequests: [UUID: NewStackedPaneProposal] = [:]
    private var newStackedResults: [UUID: RelaySidePanelHTTPResponse] = [:]
    let receiptLimit: Int

    init(receiptLimit: Int = 256) { self.receiptLimit = receiptLimit }

    /// The /api/local-pane/request proposal. That approval route cannot place
    /// a tab beside an anchor, so an anchored proposal is refused, not ignored.
    static func localPaneApprovalProposal(_ body: Data) throws -> LocalPaneProposal {
        let proposal = try JSONDecoder().decode(LocalPaneProposal.self, from: body)
        guard !proposal.isAnchored else { throw PluginError.invalid("Anchors are accepted only by new-local-tab") }
        return proposal
    }

    func renamePane(_ body: Data, instance: UUID, permits: (MCPWorkspaceCapability) -> Bool,
                    workspace: WorkspaceModel) -> RelaySidePanelHTTPResponse {
        guard Endpoint.renamePane.capabilities.allSatisfy(permits) else {
            return .text("MCP workspace layout capability is not granted", status: 403, reason: "Forbidden")
        }
        guard body.count <= 4096, (try? RelayCapacityJSON.validate(body)) != nil,
              let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(fields.keys) == ["instance", "requestID", "paneID", "name"],
              let proposal = try? JSONDecoder().decode(PaneRenameProposal.self, from: body),
              proposal.instance == instance else {
            return .text("Invalid or stale pane rename request", status: 400, reason: "Bad Request")
        }
        let name = proposal.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return .text("Pane name must contain 1–80 visible characters", status: 400, reason: "Bad Request")
        }
        if let old = renameRequests[proposal.requestID] {
            guard old == proposal, let result = renameResults[proposal.requestID] else {
                return .text("Conflicting pane rename request ID", status: 409, reason: "Conflict")
            }
            return .json(result)
        }
        guard renameRequests.count < receiptLimit, let pane = workspace.panes[proposal.paneID] else {
            return .text("Pane unavailable or rename receipt limit reached", status: 409, reason: "Conflict")
        }
        pane.customName = name
        workspace.persistWorkspace()
        let result = ["status": "applied", "paneID": proposal.paneID.uuidString.lowercased(), "name": name]
        renameRequests[proposal.requestID] = proposal
        renameResults[proposal.requestID] = result
        return .json(result)
    }

    func tabAction(_ body: Data, instance: UUID, permits: (MCPWorkspaceCapability) -> Bool,
                   workspace: WorkspaceModel) -> RelaySidePanelHTTPResponse {
        guard let proposal = try? JSONDecoder().decode(WorkspaceTabProposal.self, from: body),
              proposal.instance == instance else {
            return .text("Invalid or stale tab request", status: 400, reason: "Bad Request")
        }
        guard Endpoint.tabAction.capabilities.allSatisfy(permits) else {
            return .text("MCP workspace layout capability is not granted", status: 403, reason: "Forbidden")
        }
        if let old = tabRequests[proposal.requestID] {
            guard old == proposal, let result = tabResults[proposal.requestID] else {
                return .text("Conflicting tab request ID", status: 409, reason: "Conflict")
            }
            return .json(result)
        }
        guard tabRequests.count < receiptLimit else {
            return .text("Tab receipt limit reached", status: 409, reason: "Conflict")
        }
        do {
            _ = try workspace.workspaceTabActionDetail(proposal)
            guard let tabID = workspace.applyWorkspaceTabAction(proposal) else {
                return .text("Tab action was not applied", status: 409, reason: "Conflict")
            }
            var result = ["status": "applied", "tabID": tabID.uuidString.lowercased(),
                          "selectedTabID": workspace.selectedTabID?.uuidString.lowercased() ?? ""]
            if proposal.action == .move, let owner = workspace.workspaceID(forTab: tabID) {
                result["workspaceID"] = owner.uuidString.lowercased()
            }
            tabRequests[proposal.requestID] = proposal
            tabResults[proposal.requestID] = result
            return .json(result)
        } catch {
            return .text("Tab action unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
        }
    }

    func newLocalTab(_ body: Data, instance: UUID, permits: (MCPWorkspaceCapability) -> Bool,
                     workspace: WorkspaceModel) -> RelaySidePanelHTTPResponse {
        guard Endpoint.newLocalTab.capabilities.allSatisfy(permits) else {
            return .text("MCP terminal creation is not granted", status: 403, reason: "Forbidden")
        }
        guard let proposal = try? JSONDecoder().decode(LocalPaneProposal.self, from: body),
              proposal.instance == instance,
              proposal.anchorPaneID == nil || proposal.anchorTabID == nil else {
            return .text("Invalid or stale local tab request", status: 400, reason: "Bad Request")
        }
        if let old = localRequests[proposal.requestID] {
            guard old == proposal, let result = localResults[proposal.requestID] else {
                return .text("Conflicting local tab request ID", status: 409, reason: "Conflict")
            }
            return .json(result)
        }
        guard localRequests.count < receiptLimit else {
            return .text("Local tab receipt limit reached", status: 409, reason: "Conflict")
        }
        let tabID: UUID, paneID: UUID
        if proposal.isAnchored {
            // Right after the anchor, in the anchor's session and workspace.
            do {
                (tabID, paneID) = try workspace.newLocalTab(anchorPaneID: proposal.anchorPaneID,
                                                            anchorTabID: proposal.anchorTabID)
            } catch {
                return .text("Anchored local tab unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
            }
        } else {
            // No source pane: an MCP-created tab goes to the Inbox.
            if workspace.selectedTab != nil {
                workspace.newTabInActiveSession(profile: .local, origin: .agent(sourcePane: nil))
            } else {
                workspace.newTab(profile: .local, origin: .agent(sourcePane: nil))
            }
            guard let selected = workspace.selectedTabID, let active = workspace.activePaneID else {
                return .text("Local tab creation failed", status: 409, reason: "Conflict")
            }
            (tabID, paneID) = (selected, active)
        }
        var result = ["status": "created", "tabID": tabID.uuidString.lowercased(), "paneID": paneID.uuidString.lowercased()]
        if proposal.isAnchored, let owner = workspace.workspaceID(forTab: tabID) {
            result["workspaceID"] = owner.uuidString.lowercased()
        }
        localRequests[proposal.requestID] = proposal
        localResults[proposal.requestID] = result
        return .json(result)
    }

    /// `relay_stack_pane`: existing pane X joins the stack showing pane Y,
    /// in any tab or session. 409 unless X is a member of Y's stack after.
    func stackPane(_ body: Data, instance: UUID, permits: (MCPWorkspaceCapability) -> Bool,
                   workspace: WorkspaceModel) -> RelaySidePanelHTTPResponse {
        guard let proposal = try? JSONDecoder().decode(PaneStackProposal.self, from: body),
              proposal.instance == instance else {
            return .text("Invalid or stale stack request", status: 400, reason: "Bad Request")
        }
        guard Endpoint.stackPane.capabilities.allSatisfy(permits) else {
            return .text("MCP workspace layout capability is not granted", status: 403, reason: "Forbidden")
        }
        if let old = stackRequests[proposal.requestID] {
            guard old == proposal, let result = stackResults[proposal.requestID] else {
                return .text("Conflicting stack request ID", status: 409, reason: "Conflict")
            }
            return result
        }
        guard stackRequests.count < receiptLimit else {
            return .text("Stack receipt limit reached", status: 409, reason: "Conflict")
        }
        do {
            // Final bridge fence: synchronous, nothing suspends between the
            // check and the mutation, so the checked state is the one changed.
            if let scope = proposal.bridgeScope,
               let reason = Self.bridgeFence(scope: scope, paneIDs: [proposal.paneID, proposal.targetPaneID],
                                             requestedHost: nil, profile: nil, workspace: workspace) {
                return .text(reason, status: 403, reason: "Forbidden")
            }
            let done = try workspace.stackPaneAnywhere(proposal.paneID, onto: proposal.targetPaneID)
            guard let result = Self.membership(proposal.paneID, with: proposal.targetPaneID, workspace: workspace,
                                               status: "stacked", removedTabID: done.removedTabID) else {
                return .text("Stack was not applied", status: 409, reason: "Conflict")
            }
            // The exact bytes are kept: a repeated request gets the same body.
            let response = RelaySidePanelHTTPResponse.json(result)
            stackRequests[proposal.requestID] = proposal
            stackResults[proposal.requestID] = response
            return response
        } catch {
            return .text("Stack unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
        }
    }

    /// `relay_new_stacked_pane`: a new terminal pane on This Mac or an exact
    /// SSH host alias, created directly in the stack showing pane Y.
    func newStackedPane(_ body: Data, instance: UUID, permits: (MCPWorkspaceCapability) -> Bool,
                        workspace: WorkspaceModel, resolve: (String) -> ConnectionProfile?) -> RelaySidePanelHTTPResponse {
        guard let proposal = try? JSONDecoder().decode(NewStackedPaneProposal.self, from: body),
              proposal.instance == instance else {
            return .text("Invalid or stale stacked pane request", status: 400, reason: "Bad Request")
        }
        guard Endpoint.newStackedPane.capabilities.allSatisfy(permits) else {
            return .text("MCP terminal creation and layout capabilities are not both granted", status: 403, reason: "Forbidden")
        }
        if let old = newStackedRequests[proposal.requestID] {
            guard old == proposal, let result = newStackedResults[proposal.requestID] else {
                return .text("Conflicting stacked pane request ID", status: 409, reason: "Conflict")
            }
            return result
        }
        guard newStackedRequests.count < receiptLimit else {
            return .text("Stacked pane receipt limit reached", status: 409, reason: "Conflict")
        }
        guard let profile = resolve(proposal.host) else {
            return .text("Use This Mac or an exact configured SSH host alias", status: 400, reason: "Bad Request")
        }
        do {
            if let scope = proposal.bridgeScope,
               let reason = Self.bridgeFence(scope: scope, paneIDs: [proposal.targetPaneID],
                                             requestedHost: proposal.host, profile: profile, workspace: workspace) {
                return .text(reason, status: 403, reason: "Forbidden")
            }
            let created = try workspace.newStackedPane(onto: proposal.targetPaneID, profile: profile)
            guard let result = Self.membership(created.paneID, with: proposal.targetPaneID, workspace: workspace,
                                               status: "created", removedTabID: nil) else {
                return .text("Stacked pane was not placed", status: 409, reason: "Conflict")
            }
            let response = RelaySidePanelHTTPResponse.json(result)
            newStackedRequests[proposal.requestID] = proposal
            newStackedResults[proposal.requestID] = response
            return response
        } catch {
            return .text("Stacked pane unavailable: \(error.localizedDescription)", status: 409, reason: "Conflict")
        }
    }

    /// Why a bridge-scoped stack request must not mutate, or nil when it may.
    /// Every named pane and every pane of the tabs holding them must be an
    /// SSH terminal or editor on the bridge host, so a remote caller cannot
    /// change a tab that contains a Mac or other-host pane. A resolved
    /// profile (new stacked pane) must be the bridge host. Comparisons are
    /// those of WorkspaceApplyAdmission.bridgeFence.
    static func bridgeFence(scope: PaneStackBridgeScope, paneIDs: [UUID], requestedHost: String?,
                            profile: ConnectionProfile?, workspace: WorkspaceModel) -> String? {
        guard !scope.host.isEmpty, scope.host != "This Mac" else {
            return "Bridge scope must name a remote SSH host"
        }
        if let requestedHost {
            guard requestedHost == scope.host else { return "Connection target must be the bridge SSH host" }
        }
        if let profile {
            guard profile.kind == .ssh, profile.backend == .relay, profile.host == scope.host else {
                return "Connection target must resolve to the bridge SSH host"
            }
        }
        func onHost(_ candidate: PaneModel) -> Bool {
            candidate.profile.kind == .ssh && candidate.profile.name == scope.host &&
                (candidate.contentKind == .terminal || candidate.contentKind == .editor)
        }
        for id in paneIDs {
            guard let pane = workspace.panes[id], onHost(pane) else { return "Pane is not on the bridge host" }
            guard let tabID = workspace.tabID(containingPane: id) else { return "Pane is not in a bridge workspace tab" }
            let tabPanes = workspace.paneIDs(inTab: tabID)
            guard !tabPanes.isEmpty, tabPanes.allSatisfy({ workspace.panes[$0].map(onHost) == true }) else {
                return "Tab is not wholly on the bridge host"
            }
        }
        return nil
    }

    /// The result only when `paneID` and `targetID` are members of one
    /// stack, in one tab, with `paneID` not tiled as a separate split.
    static func membership(_ paneID: UUID, with targetID: UUID, workspace: WorkspaceModel,
                           status: String, removedTabID: UUID?) -> PaneStackResult? {
        guard let tab = workspace.tabs.first(where: { $0.stack(containing: targetID) != nil }),
              let stack = tab.stack(containing: targetID), stack.members.contains(paneID),
              tab.layout.paneIDs.filter({ stack.members.contains($0) }) == [stack.selected] else { return nil }
        func id(_ value: UUID) -> String { value.uuidString.lowercased() }
        return PaneStackResult(status: status, paneID: id(paneID), targetPaneID: id(targetID), tabID: id(tab.id),
                               stackID: id(stack.id), members: stack.members.map(id), selectedPaneID: id(stack.selected),
                               removedTabID: removedTabID.map(id))
    }
}

/// Set only by the remote MCP bridge: its own SSH host, rechecked against
/// live state immediately before the mutation. A present `bridgeScope` that is
/// null, empty, mistyped or carries extra keys fails the whole decode (400);
/// it never decodes as absent.
struct PaneStackBridgeScope: Codable, Equatable {
    let host: String

    init(host: String) { self.host = host }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { return nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        guard container.allKeys.count == 1, let key = AnyKey(stringValue: "host"), container.contains(key) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bridgeScope takes exactly host"))
        }
        let host = try container.decode(String.self, forKey: key)
        guard !host.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bridgeScope host is empty"))
        }
        self.host = host
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(host, forKey: AnyKey(stringValue: "host")!)
    }
}

/// A `bridgeScope` key that is present must decode; JSON null is refused.
private func decodeBridgeScope<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> PaneStackBridgeScope? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "bridgeScope must not be null")
    }
    return try container.decode(PaneStackBridgeScope.self, forKey: key)
}

struct PaneStackProposal: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let paneID: UUID
    let targetPaneID: UUID
    /// Set only by the remote MCP bridge.
    var bridgeScope: PaneStackBridgeScope? = nil

    enum CodingKeys: String, CodingKey { case instance, requestID, paneID, targetPaneID, bridgeScope }
}

extension PaneStackProposal {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instance = try c.decode(UUID.self, forKey: .instance)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        paneID = try c.decode(UUID.self, forKey: .paneID)
        targetPaneID = try c.decode(UUID.self, forKey: .targetPaneID)
        bridgeScope = try decodeBridgeScope(c, .bridgeScope)
    }
}

struct NewStackedPaneProposal: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    let targetPaneID: UUID
    /// "This Mac" or an exact configured Relay SSH host alias.
    let host: String
    /// Set only by the remote MCP bridge.
    var bridgeScope: PaneStackBridgeScope? = nil

    enum CodingKeys: String, CodingKey { case instance, requestID, targetPaneID, host, bridgeScope }
}

extension NewStackedPaneProposal {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instance = try c.decode(UUID.self, forKey: .instance)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        targetPaneID = try c.decode(UUID.self, forKey: .targetPaneID)
        host = try c.decode(String.self, forKey: .host)
        bridgeScope = try decodeBridgeScope(c, .bridgeScope)
    }
}

struct PaneStackResult: Codable, Equatable {
    let status: String
    let paneID: String
    let targetPaneID: String
    let tabID: String
    let stackID: String
    let members: [String]
    let selectedPaneID: String
    let removedTabID: String?
}
