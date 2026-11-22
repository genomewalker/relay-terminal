import Foundation

struct RelayInstalledUpdateRequest: Codable, Equatable {
    let instance: UUID
    let requestID: UUID
    static func decode(_ data: Data) throws -> Self {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object, Set(object.keys) == ["instance", "requestID"] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

/// Instance-scoped receipts never authorize replay after an app restart.
struct RelayInstalledUpdateReceipts {
    enum Admission { case admitted, existing(RelayPaneHealthJSON), refused }
    private struct Entry {
        let pane: UUID
        let request: RelayInstalledUpdateRequest
        var result: RelayPaneHealthJSON
    }
    private var entries: [UUID: Entry] = [:]
    mutating func begin(pane: UUID, request: RelayInstalledUpdateRequest, instance: UUID,
                        granted: Bool) -> Admission {
        guard granted, request.instance == instance else { return .refused }
        if let old = entries[request.requestID] {
            guard old.pane == pane, old.request == request else { return .refused }
            return .existing(old.result)
        }
        guard entries.count < 256 else { return .refused }
        entries[request.requestID] = Entry(pane: pane, request: request,
            result: .object(["state": .string("pending"), "pane_id": .string(pane.uuidString.lowercased())]))
        return .admitted
    }
    mutating func finish(_ id: UUID, result: RelayPaneHealthJSON) {
        guard entries[id] != nil else { return }
        entries[id]?.result = result
    }
    func result(pane: UUID, request: RelayInstalledUpdateRequest, instance: UUID) -> RelayPaneHealthJSON? {
        guard request.instance == instance, let old = entries[request.requestID],
              old.pane == pane, old.request == request else { return nil }
        return old.result
    }
}

enum RelayInstalledUpdatePostcondition {
    static func verified(before: RelayAgentMaintenanceProbe, after: RelayAgentMaintenanceProbe, pane: UUID) -> Bool {
        before.valid(for: pane) && after.valid(for: pane) && after.bound == true &&
            before.sessionID == after.sessionID && before.provider == after.provider &&
            before.configDir == after.configDir && after.accountMatches != false &&
            RelayAgentMaintenancePolicy.installedImageVerified(after)
    }
}

/// 0.5.61: when a user-requested installed update may ask a hidden pane for a
/// fresh screen. Only a pane with an installed update to adopt, a verified
/// identity, relayd's idle harness proof, no draft and no pending approval.
/// The runtime adds its own checks (no surface, one viewer, copy cut short).
/// 2026-11-22: when background attach may ask a hidden agent pane for a
/// fresh screen with no update pending. A restart restores a hidden pane's
/// saved screen only as a cursor when its grid changed (81 dandy-07 panes
/// after the 13:35Z relaunch), so the copy stays cut short and every read
/// is refused until the idle agent repaints, which it never does by itself.
/// The same proof as an installed update, without the update.
enum RelayHiddenScreenRefresh {
    @MainActor
    static func admits(_ proof: RelayAgentMaintenanceProbe, paneID: UUID, pane: PaneModel) -> Bool {
        let draft = pane.composerStateIfCreated?.hasPendingInput ?? false
        return admits(proof, paneID: paneID, hasDraft: draft, pendingApprovals: pane.pendingAgentApprovals)
    }

    static func admits(_ proof: RelayAgentMaintenanceProbe, paneID: UUID, hasDraft: Bool, pendingApprovals: Int) -> Bool {
        proof.valid(for: paneID) && proof.harnessStatus == "idle" && !hasDraft && pendingApprovals == 0
    }

    /// A pane the user protected from automatic maintenance is never asked.
    static func excluded(_ paneID: UUID, protected: [String]) -> Bool {
        protected.contains(paneID.uuidString.lowercased())
    }

    /// One fresh screen for a hidden idle agent pane; nothing is typed.
    @MainActor
    static func refresh(_ pane: PaneModel) async -> Bool {
        guard pane.kind != .shell, !excluded(pane.id, protected: RelayPreferences.shared.maintenanceProtectedPanes),
              pane.runtime.hiddenScreenCutShort,
              let proof = try? await RelayAgentMaintenanceReader.inspect(pane),
              admits(proof, paneID: pane.id, pane: pane), pane.runtime.hiddenScreenCutShort else { return false }
        return await pane.runtime.refreshHiddenScreenBaseForInstalledUpdate()
    }
}

enum RelayInstalledUpdateScreenRefresh {
    @MainActor
    static func admits(_ proof: RelayAgentMaintenanceProbe, paneID: UUID, pane: PaneModel) -> Bool {
        let draft = pane.composerStateIfCreated?.hasPendingInput ?? false
        return admits(proof, paneID: paneID, hasDraft: draft, pendingApprovals: pane.pendingAgentApprovals)
    }

    static func admits(_ proof: RelayAgentMaintenanceProbe, paneID: UUID, hasDraft: Bool, pendingApprovals: Int) -> Bool {
        proof.valid(for: paneID) && proof.installedUpdate == true && !RelayAgentMaintenancePolicy.installedImageVerified(proof) &&
            proof.harnessStatus == "idle" && !hasDraft && pendingApprovals == 0
    }
}
