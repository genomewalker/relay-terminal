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
