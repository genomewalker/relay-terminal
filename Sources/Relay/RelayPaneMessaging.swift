import Foundation
import CryptoKit

/// Pane-addressed collaborator messages travel through Relay to the recipient host.
/// Provider inboxes own admission; terminal commands use a separate input path.
@MainActor final class RelayPaneMessaging {
    static let shared = RelayPaneMessaging()
    struct Link: Codable {
        struct Member: Codable {
            let paneID: UUID
            let hostID: UUID
            let name: String
            let provider: String
            let pid: Int
            let start: String
            var sessionID: String? = nil
            var unavailable: String? = nil

            init(paneID: UUID, hostID: UUID, name: String, provider: String,
                 pid: Int, start: String, sessionID: String? = nil, unavailable: String? = nil) {
                self.paneID = paneID; self.hostID = hostID; self.name = name
                self.provider = provider; self.pid = pid; self.start = start
                self.sessionID = sessionID; self.unavailable = unavailable
            }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                paneID = try values.decode(UUID.self, forKey: .paneID)
                hostID = try values.decode(UUID.self, forKey: .hostID)
                name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Pane"
                provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? "unresolved"
                pid = try values.decodeIfPresent(Int.self, forKey: .pid) ?? 0
                start = try values.decodeIfPresent(String.self, forKey: .start) ?? ""
                sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
                unavailable = try values.decodeIfPresent(String.self, forKey: .unavailable)
            }
        }
        let id: String
        let members: [Member]
        let transport: String
        var resolutionErrors: [String: String]? = nil
    }
    struct Request: Codable {
        let sourcePaneID: UUID
        let messageID: UUID
        let text: String
    }
    private let receipts = RelayClaudeRotationActionStore(directory:
        RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/PaneMessages"))
    private let links = RelayClaudeRotationActionStore(directory:
        RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/PaneMessageLinks"))
    private var activeDeliveries: [UUID: Set<UUID>] = [:]
    // Client-side locator only. Membership and receipts live on the daemon.
    private var daemonLinkOwners: [String: ConnectionProfile] = [:]

    private func daemonRequest(profile: ConnectionProfile, packet: [String: Any]) async throws -> [String: Any] {
        try await RelayCallerControl.shared.attachDaemon(profile: profile)
        let fallback = RelayHostExecution.daemonCommand(profile: profile, arguments: ["communication"])
        let command = "if [ -x \"$HOME/.local/share/relay/bin/relayd-communication\" ]; then \"$HOME/.local/share/relay/bin/relayd-communication\" communication; else " + fallback + "; fi"
        let result = try await RelayHostExecution.capture(profile: profile, command: command,
            input: JSONSerialization.data(withJSONObject: packet, options: .sortedKeys), timeout: 60, maximumBytes: 128 << 10)
        guard result.exitCode == 0, let value = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw RemoteCatalogError.failed(String(data: result.stderr, encoding: .utf8) ?? "The communication daemon is unavailable")
        }
        return value
    }

    private func daemonProfiles(_ workspace: WorkspaceModel) -> [ConnectionProfile] {
        var seen: Set<String> = []
        return workspace.panes.values.map(\.profile).filter { $0.backend == .relay && seen.insert($0.connectionKey).inserted }
    }

    func disconnect(linkID: String, workspace: WorkspaceModel) async throws -> [String: String] {
        if daemonLinkOwners[linkID] == nil { _ = try await savedLinks(workspace: workspace) }
        if let owner = daemonLinkOwners[linkID] {
            let result = try await daemonRequest(profile: owner, packet: ["operation": "unlink", "link_id": linkID])
            return result.reduce(into: [:]) { result, entry in if let value = entry.value as? String { result[entry.key] = value } }
        }
        guard linkID.utf8.count == 64,
              linkID.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw RemoteCatalogError.failed("Use the exact saved link ID.")
        }
        guard let record = try links.read(intent: linkID, action: "link") else {
            return ["link_id": linkID, "status": "not_found", "prior_removal": "unknown"]
        }
        guard record.completed, let bytes = record.result else {
            throw RemoteCatalogError.failed("Link creation is unresolved; do not remove it.")
        }
        let link = try JSONDecoder().decode(Link.self, from: bytes)
        guard link.id == linkID else { throw RelayRotationAdapterError.mismatchedEvidence }
        let pair = Set(link.members.map(\.paneID))
        guard !activeDeliveries.values.contains(pair) else {
            throw RemoteCatalogError.failed("A message between these panes is in flight. Check its receipt before removing the link.")
        }
        let removed = try links.retire(intent: linkID, action: "link")
        return ["link_id": linkID, "status": removed ? "retired" : "not_found",
                "history": "retained", "message_receipts": "retained"]
    }

    // Native endpoints are host/kernel observations. A lazy or reconnecting
    // renderer does not determine whether the unchanged agent socket is live.
    // Endpoint discovery and pre-send revalidation remain authoritative.
    func connect(panes ids: [UUID], workspace: WorkspaceModel) async throws -> Link {
        guard ids.count == 2, Set(ids).count == 2 else { throw RemoteCatalogError.failed("Select two distinct agent panes.") }
        if let source = workspace.panes[ids[0]], let target = workspace.panes[ids[1]],
           source.profile.backend == .relay, target.profile.backend == .relay,
           source.profile.connectionKey == target.profile.connectionKey {
            let result = try await daemonRequest(profile: source.profile, packet: ["operation": "link",
                "source_pane_id": source.id.uuidString.lowercased(), "pane_id": target.id.uuidString.lowercased()])
            guard let value = result["link"] else { throw RemoteCatalogError.invalidResponse }
            let link = try JSONDecoder().decode(Link.self, from: JSONSerialization.data(withJSONObject: value))
            daemonLinkOwners[link.id] = source.profile
            return link
        }
        var members: [Link.Member] = []
        var errors: [String: String] = [:]
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let pane = workspace.panes[id], pane.contentKind == .terminal else {
                throw RemoteCatalogError.failed("Both panes must be existing agent terminals.")
            }
            let profile = pane.profile
            let process: Endpoint?
            do { process = try await endpoint(pane) }
            catch { process = nil; errors[id.uuidString] = error.localizedDescription }
            guard workspace.panes[id] === pane, pane.profile == profile else { throw RelayHostRPCError.outcomeUnknown }
            members.append(.init(paneID: id, hostID: profile.id, name: String(pane.displayName.prefix(256)),
                provider: process?.provider ?? "unresolved", pid: process?.pid ?? 0,
                start: process?.start ?? "", sessionID: process?.sessionID))
        }
        for member in members {
            guard member.pid > 0 else { continue }
            guard let pane = workspace.panes[member.paneID], pane.profile.id == member.hostID,
                  pane.contentKind == .terminal,
                  matches(member, process: try await endpoint(pane)) else {
                throw RemoteCatalogError.failed("An agent changed while connecting. Check the panes again.")
            }
        }
        // Membership is stable across process restarts. Bindings are a
        // separately revalidated observation, never the relationship ID.
        let identity = members.map { "\($0.paneID):\($0.hostID)" }.joined(separator: "\n")
        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let records = try links.records(limit: 64)
        let prior = try links.read(intent: id, action: "link")
        if prior == nil, records.count >= 64 { throw RemoteCatalogError.failed("Saved pane link limit reached.") }
        let link = Link(id: id, members: members, transport: errors.isEmpty ? "relay_native_socket" : "unavailable",
            resolutionErrors: errors.isEmpty ? nil : errors)
        try links.replacePaneLink(intent: id, result: JSONEncoder().encode(link))
        // Retire obsolete process-derived IDs for this explicitly linked pair;
        // retain their files as history and leave message receipts untouched.
        for record in records {
            guard let bytes = record.result, let old = try? JSONDecoder().decode(Link.self, from: bytes),
                  old.id != id, Set(old.members.map(\.paneID)) == Set(ids),
                  old.members.allSatisfy({ member in members.contains { $0.paneID == member.paneID && $0.hostID == member.hostID } }) else { continue }
            _ = try links.retire(intent: old.id, action: "link")
        }
        if let pane = workspace.panes[ids[0]] {
            RelayRecoveryStore.shared.record(kind: "pane_relationship_saved", paneID: pane.id, profile: pane.profile,
                links: [.init(from: "pane:\(ids[0])", to: "pane:\(ids[1])", kind: "communication_member")])
        }
        return link
    }

    func savedLinks(workspace: WorkspaceModel) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for profile in daemonProfiles(workspace) {
            do {
                let response = try await daemonRequest(profile: profile, packet: ["operation": "list"])
                for var link in response["links"] as? [[String: Any]] ?? [] {
                    guard let id = link["id"] as? String else { continue }
                    daemonLinkOwners[id] = profile
                    link["authority"] = "relayd"
                    link["process_revalidated"] = false
                    link["acknowledgement"] = "not_implied"
                    result.append(link)
                }
            } catch {
                RelayDiagnostics.shared.record(category: "communication", name: "daemon-unavailable",
                    details: ["host": profile.connectionKey, "reason": error.localizedDescription])
            }
        }
        for record in try links.records(limit: 64) {
            guard record.completed, let bytes = record.result else { continue }
            let link = try JSONDecoder().decode(Link.self, from: bytes)
            var current = true
            for member in link.members {
                guard let pane = workspace.panes[member.paneID], pane.profile.id == member.hostID,
                      pane.contentKind == .terminal else { current = false; continue }
            }
            let data = try JSONEncoder().encode(link)
            var value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            value["state"] = !current ? "pane_unavailable" : link.resolutionErrors != nil ? "transport_unavailable" : "membership_saved"
            value["process_revalidated"] = false
            value["acknowledgement"] = "not_implied"
            value["authority"] = "legacy_desktop_record"
            result.append(value)
        }
        return result
    }

    func receipt(_ id: UUID, workspace: WorkspaceModel) async throws -> [String: Any]? {
        for profile in daemonProfiles(workspace) {
            if let result = try? await daemonRequest(profile: profile, packet: ["operation": "receipt", "message_id": id.uuidString.lowercased()]),
               result["status"] as? String != "unknown" { return result }
        }
        guard let record = try receipts.read(intent: id.uuidString, action: "send") else { return nil }
        guard let result = record.result else {
            return ["message_id": id.uuidString.lowercased(), "status": "outcome_unknown", "replay_permitted": false]
        }
        return try JSONSerialization.jsonObject(with: result) as? [String: Any]
    }

    private struct Endpoint: Codable, Equatable {
        let transcriptIdentity: String?
        let pid: Int
        let start: String
        let provider: String
        let sessionID: String
        let rootPID: Int
        let rootStart: String
        let socketPath: String
        let socketIdentity: String
        let socketPID: Int
        let socketStart: String
        let transport: String
    }

    private func matches(_ member: Link.Member, process: Endpoint) -> Bool {
        // Previous link records stored unprefixed kernel incarnation strings.
        let rawStart = process.start.split(separator: ":", maxSplits: 1).last.map(String.init) ?? process.start
        return member.pid == process.pid && member.provider == process.provider &&
            (member.start == process.start || member.start == rawStart) &&
            (member.sessionID == nil || member.sessionID == process.sessionID)
    }

    private func nativeRequest(_ pane: PaneModel, packet: [String: Any]) async throws -> [String: Any] {
        guard let root = RelayResources.bundle?.url(forResource: "Rotation", withExtension: nil) else {
            throw RemoteCatalogError.failed("The native messaging adapter is missing from this Relay build.")
        }
        let discovery = try Data(contentsOf: root.appendingPathComponent("agent_conversation.py"))
        let adapter = try Data(contentsOf: root.appendingPathComponent("pane_messaging.py"))
        var script = Data(("RELAY_DISCOVERY_SOURCE = '" + discovery.base64EncodedString() + "'\n").utf8)
        script.append(adapter)
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        var validatedPacket = packet
        // Without an attached renderer, require the daemon's kernel-validated
        // binding in addition to socket/session discovery. A manifest alone
        // must never let a recycled process inherit another pane's identity.
        validatedPacket["requireAuthenticatedBinding"] = pane.connectionState != .connected
        let encoded = try JSONSerialization.data(withJSONObject: validatedPacket, options: .sortedKeys).base64EncodedString()
        let daemon = RelayHostExecution.daemonCommand(profile: pane.profile, arguments: [])
        let rootPID = pane.profile.kind == .local ? Int(pane.networkForegroundPID ?? 0) : 0
        let command = "python3 - --daemon " + daemon + " --pane " + quote(pane.id.uuidString.lowercased()) +
            " --root-pid " + String(rootPID) + " --request " + quote(encoded)
        let result = try await RelayHostExecution.capture(profile: pane.profile, command: command,
            input: script, timeout: 30, maximumBytes: 64 << 10)
        guard result.exitCode == 0,
              let value = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw RemoteCatalogError.failed("Native messaging outcome unavailable; job \(result.jobID). Do not replay.")
        }
        return value
    }

    private func endpoint(_ pane: PaneModel) async throws -> Endpoint {
        let result = try await nativeRequest(pane, packet: ["operation": "discover"])
        guard let object = result["endpoint"] as? [String: Any] else {
            throw RemoteCatalogError.failed(result["error"] as? String ?? "No exact live agent session is bound to this pane.")
        }
        return try JSONDecoder().decode(Endpoint.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func send(_ request: Request, targetID: UUID, workspace: WorkspaceModel, submittingClientID: String) async throws -> [String: Any] {
        guard request.sourcePaneID != targetID, !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.utf8.count <= 16384,
              !request.text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 }) else {
            throw RemoteCatalogError.failed("Use distinct source and target panes and a message of 1–16384 bytes.")
        }
        if let source = workspace.panes[request.sourcePaneID], let target = workspace.panes[targetID],
           source.profile.backend == .relay, target.profile.backend == .relay,
           source.profile.connectionKey == target.profile.connectionKey {
            return try await daemonRequest(profile: source.profile, packet: ["operation": "send",
                "source_pane_id": request.sourcePaneID.uuidString.lowercased(), "pane_id": targetID.uuidString.lowercased(),
                "message_id": request.messageID.uuidString.lowercased(), "text": request.text, "client_id": submittingClientID])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let fingerprint = SHA256.hash(data: try encoder.encode(request) + Data(targetID.uuidString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let prior = try receipts.read(intent: request.messageID.uuidString, action: "send") {
            guard prior.fingerprint == fingerprint else { throw RemoteCatalogError.failed("Message ID conflicts with an existing request.") }
            return try await receipt(request.messageID, workspace: workspace) ?? [:]
        }
        guard let source = workspace.panes[request.sourcePaneID], let target = workspace.panes[targetID],
              source.contentKind == .terminal, target.contentKind == .terminal else {
            throw RemoteCatalogError.failed("Both exact panes must be existing terminals.")
        }
        let sourceProfile = source.profile, targetProfile = target.profile
        guard activeDeliveries[request.messageID] == nil else {
            throw RemoteCatalogError.failed("This message is in flight. Check its receipt; do not replay.")
        }
        activeDeliveries[request.messageID] = Set([source.id, targetID])
        defer { activeDeliveries.removeValue(forKey: request.messageID) }
        let sourceProcess = try await endpoint(source), targetProcess = try await endpoint(target)
        let pair = Set([source.id, targetID])
        let configured = try links.records(limit: 64).compactMap { record -> Link? in
            guard record.completed, let bytes = record.result else { return nil }
            return try JSONDecoder().decode(Link.self, from: bytes)
        }.filter { Set($0.members.map(\.paneID)) == pair }
        if !configured.isEmpty {
            guard configured.contains(where: { link in
                link.members.allSatisfy { member in
                    let pane = member.paneID == source.id ? source : target
                    let process = member.paneID == source.id ? sourceProcess : targetProcess
                    return member.hostID == pane.profile.id && (member.pid == 0 ||
                        (member.provider == process.provider && (member.sessionID == nil
                            ? matches(member, process: process) : member.sessionID == process.sessionID)))
                }
            }) else { throw RemoteCatalogError.failed("The linked conversation changed. Review and reconnect the pair before messaging.") }
        }
        guard workspace.panes[source.id] === source, workspace.panes[targetID] === target,
              source.profile == sourceProfile, target.profile == targetProfile,
              targetProcess.transport != "unavailable" else {
            throw RemoteCatalogError.failed("Recipient has no supported native messaging socket. Terminal injection is unavailable for messages.")
        }
        guard try receipts.claim(intent: request.messageID.uuidString, action: "send", fingerprint: fingerprint) else {
            guard try receipts.read(intent: request.messageID.uuidString, action: "send")?.fingerprint == fingerprint else {
                throw RemoteCatalogError.failed("Message ID conflicts with an existing request.")
            }
            return try await receipt(request.messageID, workspace: workspace) ?? [:]
        }
        // Recheck after the durable claim and before the one allowed submission.
        let sourceNow = try await endpoint(source), targetNow = try await endpoint(target)
        guard sourceNow == sourceProcess, targetNow == targetProcess,
              workspace.panes[source.id] === source, workspace.panes[targetID] === target,
              source.profile == sourceProfile, target.profile == targetProfile,
              source.contentKind == .terminal, target.contentKind == .terminal else {
            throw RemoteCatalogError.failed("Pane or native recipient session changed. The claimed message will not be replayed.")
        }
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(targetProcess))
        var result: [String: Any] = ["message_id": request.messageID.uuidString.lowercased(),
            "source_pane_id": source.id.uuidString.lowercased(), "pane_id": targetID.uuidString.lowercased(),
            "provider": targetProcess.provider, "transport": targetProcess.transport,
            "source_authentication": "unverified", "submitting_client_id": submittingClientID,
            "status": "outcome_unknown", "replay_permitted": false]
        do {
            let delivered = try await nativeRequest(target, packet: ["operation": "send", "expected": expected,
                "messageID": request.messageID.uuidString.lowercased(), "targetPaneID": targetID.uuidString.lowercased(),
                "text": request.text, "submittingClientID": submittingClientID, "source": ["hostID": sourceProfile.id.uuidString.lowercased(),
                    "paneID": source.id.uuidString.lowercased(), "sessionID": sourceProcess.sessionID]])
            for (key, value) in delivered { result[key] = value }
        } catch {
            // The durable claim precedes every write. Transport loss never replays a message.
            result["error"] = error.localizedDescription
        }
        try receipts.complete(intent: request.messageID.uuidString, action: "send", fingerprint: fingerprint,
            result: JSONSerialization.data(withJSONObject: result, options: .sortedKeys))
        RelayRecoveryStore.shared.record(kind: "message_\(result["status"] as? String ?? "outcome_unknown")",
            paneID: source.id, profile: sourceProfile, links: [
                .init(from: "pane:\(source.id)", to: "message:\(request.messageID)", kind: "submitted"),
                .init(from: "message:\(request.messageID)", to: "pane:\(targetID)", kind: "addressed_to")
            ])
        return result
    }
}
