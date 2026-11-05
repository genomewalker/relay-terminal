import Foundation

/// The scope a remote MCP bridge asserts for one /api/workspace/apply request:
/// its own SSH host and the source pane's tab and Relay session as the bridge
/// saw them. Only the bridge constructs it (remote clients cannot send the
/// key); the desktop revalidates it against live state at mutation time.
struct WorkspaceBridgeScope: Codable, Equatable {
    let host: String
    let tabID: UUID
    let sessionID: UUID
}

/// /api/workspace/apply admission, idempotency and mutation. The side-panel
/// route delegates here; tests drive the same object.
@MainActor
final class WorkspaceApplyAdmission {
    enum Outcome: Equatable {
        case applied([String: String])
        case rejected(status: Int, message: String)
    }

    /// Same-ID replay cache, per desktop instance and lost on restart. A
    /// restarted desktop has a new instance, so old requests fail closed.
    private(set) var requests: [UUID: WorkspaceProposal] = [:]
    private(set) var results: [UUID: [String: String]] = [:]
    static let receiptLimit = 256

    func apply(_ body: Data, instance: UUID, permits: (MCPWorkspaceCapability) -> Bool, workspace: WorkspaceModel,
               resolve: (String) -> ConnectionProfile?) -> Outcome {
        guard let proposal = try? JSONDecoder().decode(WorkspaceProposal.self, from: body),
              proposal.instance == instance, proposal.validDirectory else {
            return .rejected(status: 400, message: "Invalid or stale workspace request")
        }
        let requiredCapabilities: Set<MCPWorkspaceCapability> = switch proposal.action {
        case .select, .overview, .back, .forward, .up: [.navigate]
        case .newTab: [.create]
        case .splitRight, .splitDown: [.create, .layout]
        case .zoom, .unzoom, .float, .dock, .balance, .close, .conversation, .terminal: [.layout]
        }
        guard requiredCapabilities.allSatisfy(permits) else {
            return .rejected(status: 403, message: "MCP workspace capability is not granted")
        }
        if let old = requests[proposal.requestID] {
            guard old == proposal, let result = results[proposal.requestID] else {
                return .rejected(status: 409, message: "Conflicting workspace request ID")
            }
            return .applied(result)
        }
        guard requests.count < Self.receiptLimit else {
            return .rejected(status: 409, message: "Workspace receipt limit reached")
        }
        do {
            let targetProfile: ConnectionProfile?
            if let host = proposal.connectionHost {
                guard let resolved = resolve(host) else {
                    return .rejected(status: 400, message: "Connection target is not a configured Relay host")
                }
                targetProfile = resolved
            } else {
                targetProfile = nil
            }
            _ = try workspace.workspaceActionDetail(proposal)
            guard let pane = workspace.panes[proposal.paneID] else {
                return .rejected(status: 409, message: "Workspace target changed")
            }
            // Final bridge fence: no suspension point between here and the
            // mutation, so the checked state is the state that is changed.
            if let scope = proposal.bridgeScope,
               let reason = Self.bridgeFence(proposal, scope: scope, pane: pane, target: targetProfile, workspace: workspace) {
                return .rejected(status: 403, message: reason)
            }
            guard let (tabID, paneID) = workspace.applyWorkspaceAction(proposal, expected: pane, profile: targetProfile) else {
                return .rejected(status: 409, message: "Workspace target changed")
            }
            let result = ["status": "applied", "tabID": tabID.uuidString.lowercased(), "paneID": paneID.uuidString.lowercased()]
            requests[proposal.requestID] = proposal
            results[proposal.requestID] = result
            return .applied(result)
        } catch {
            return .rejected(status: 409, message: "Workspace action unavailable: \(error.localizedDescription)")
        }
    }

    /// Why a bridge-scoped request must not mutate, or nil when it may. The
    /// remote host must be the bridge host on every axis: the requested and
    /// resolved target, the source pane, and every pane of the source tab,
    /// which must still be the scoped tab in the scoped Relay session.
    static func bridgeFence(_ proposal: WorkspaceProposal, scope: WorkspaceBridgeScope, pane: PaneModel,
                            target: ConnectionProfile?, workspace: WorkspaceModel) -> String? {
        guard [.newTab, .splitRight, .splitDown].contains(proposal.action), proposal.directory == nil else {
            return "Only tab and split creation are available through a remote bridge"
        }
        guard !scope.host.isEmpty, scope.host != "This Mac", proposal.connectionHost == scope.host else {
            return "Connection target must be the bridge SSH host"
        }
        guard let target, target.kind == .ssh, target.backend == .relay, target.host == scope.host else {
            return "Connection target must resolve to the bridge SSH host"
        }
        func onHost(_ candidate: PaneModel) -> Bool {
            candidate.profile.kind == .ssh && candidate.profile.name == scope.host &&
                (candidate.contentKind == .terminal || candidate.contentKind == .editor)
        }
        guard onHost(pane) else { return "Source pane is no longer on the bridge host" }
        guard workspace.tabID(containingPane: pane.id) == scope.tabID,
              let tab = workspace.tabs.first(where: { $0.id == scope.tabID }), tab.sessionID == scope.sessionID else {
            return "Source pane is no longer in the bridge workspace"
        }
        let tabPanes = workspace.paneIDs(inTab: scope.tabID)
        guard !tabPanes.isEmpty, tabPanes.allSatisfy({ workspace.panes[$0].map(onHost) == true }) else {
            return "Bridge workspace is no longer wholly on the bridge host"
        }
        return nil
    }
}
