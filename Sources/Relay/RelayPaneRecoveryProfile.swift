import Foundation

/// An existing pane owns its captured connection profile. A newly resolved SSH
/// alias can have a different profile ID even when its display host is the same.
enum RelayPaneRecoveryProfile {
    static func captured(_ profile: ConnectionProfile, requestedHost: String) -> ConnectionProfile? {
        guard profile.backend == .relay else { return nil }
        switch profile.kind {
        case .local:
            return requestedHost == "This Mac" ? profile : nil
        case .ssh:
            return requestedHost == profile.host && !requestedHost.isEmpty ? profile : nil
        }
    }

    static func unchanged(captured: ConnectionProfile?, current: ConnectionProfile?, samePane: Bool) -> Bool {
        if captured == nil { return current == nil }
        return samePane && captured == current
    }
}

@MainActor
enum RelayPaneRecoveryAttachment {
    static func attach(workspace: WorkspaceModel, profile: ConnectionProfile,
                       pane: RemoteCatalogPane, sessionLabel: String) -> Bool {
        // The pane's catalog workspace, not whichever tab is selected after
        // catalog I/O, determines the session when its tab is not open.
        workspace.attachRemotePane(profile: profile, remotePane: pane,
                                   workspaceID: pane.workspaceID, sessionLabel: sessionLabel,
                                   intoSessionID: nil)
    }
}

@MainActor
enum RelayPaneRecoveryAuthorization {
    static func permits(grant: MCPWorkspaceGrant, callers: RelayCallerControl, caller: String?) -> Bool {
        guard let caller else { return false }
        return grant.permits(.create) && callers.permitted(caller)
    }
}

/// Captured on the main actor before catalog I/O. A new pane with the same ID
/// and profile is still a different owner and may not inherit the request.
@MainActor
struct RelayPaneRecoveryCapture {
    struct Changed: Error {}
    struct Revoked: Error {}
    private let pane: PaneModel?
    let profile: ConnectionProfile?

    init(_ pane: PaneModel?) {
        self.pane = pane
        self.profile = pane?.profile
    }

    func unchanged(current: PaneModel?) -> Bool {
        RelayPaneRecoveryProfile.unchanged(captured: profile, current: current?.profile,
                                           samePane: pane != nil && current === pane)
    }

    func transact<T, R>(current: () -> PaneModel?, permitted: () -> Bool = { true }, load: () async throws -> T, apply: (T) -> R) async throws -> R {
        let value = try await load()
        guard unchanged(current: current()) else { throw Changed() }
        guard permitted() else { throw Revoked() }
        return apply(value)
    }
}

/// One in-flight recovery per request ID. The original request owns its
/// receipt; retries observe pending or the recorded result, never re-dispatch.
@MainActor
final class RelayPaneRecoveryReceipts {
    enum Decision: Equatable {
        case started, pending, conflict, full
        case replay([String: String])
    }
    private struct Entry {
        let request: MCPRecoverPaneRequest
        var result: [String: String]?
    }
    private var entries: [UUID: Entry] = [:]
    private let limit: Int
    init(limit: Int = 256) { self.limit = limit }

    func begin(_ request: MCPRecoverPaneRequest) -> Decision {
        if let existing = entries[request.requestID] {
            guard existing.request == request else { return .conflict }
            return existing.result.map(Decision.replay) ?? .pending
        }
        guard entries.count < limit else { return .full }
        entries[request.requestID] = Entry(request: request, result: nil)
        return .started
    }

    func finish(_ request: MCPRecoverPaneRequest, result: [String: String]) -> Bool {
        guard var entry = entries[request.requestID], entry.request == request, entry.result == nil else { return false }
        entry.result = result
        entries[request.requestID] = entry
        return true
    }

    func cancel(_ request: MCPRecoverPaneRequest) {
        guard let entry = entries[request.requestID], entry.request == request, entry.result == nil else { return }
        entries.removeValue(forKey: request.requestID)
    }
}
