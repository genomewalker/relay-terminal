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
        // Proof ID minted by the sender's own relayd. Not part of message identity.
        var sourceAttestation: String? = nil
        // Envelope signed by the sender's relayd; verified only by the
        // recipient host's relayd. Not part of message identity.
        var sourceSignature: String? = nil
        // Why the sender's own relay-mcp could not mint a proof. Diagnostic
        // text for the receipt only; it never affects authentication.
        var sourceProofError: String? = nil
    }
    private let receipts = RelayClaudeRotationActionStore(directory:
        RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/PaneMessages"))
    private let links: RelayClaudeRotationActionStore
    /// Profile-shared in-flight markers, one file per message being sent by
    /// any Relay instance on this profile (see `InFlightMarkers`).
    private let inFlight: InFlightMarkers
    /// `linksDirectory` is for tests only; production uses the default store.
    init(linksDirectory: URL? = nil) {
        let directory = linksDirectory ??
            RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/PaneMessageLinks")
        links = RelayClaudeRotationActionStore(directory: directory)
        inFlight = InFlightMarkers(directory: directory.appendingPathComponent("InFlight", isDirectory: true))
    }
    /// Tests only: runs inside the janitor's fence, after the decision and
    /// before the first retire.
    var janitorWindowForTesting: (() -> Void)?
    /// Tests only: replaces the host round trip of `nativeRequest` (endpoint discovery).
    var nativeRequestOverride: (@MainActor (PaneModel, [String: Any]) async throws -> [String: Any])?
    private var activeDeliveries: [UUID: Set<UUID>] = [:]
    /// This instance's shared-marker attempt for each delivery in flight.
    private var markerAttempts: [UUID: UUID] = [:]
    // Client-side locator only. Membership and receipts live on the daemon.
    private var daemonLinkOwners: [String: ConnectionProfile] = [:]

    /// Replaceable in tests: the caller policy owner and the daemon transport.
    var callerControl: RelayCallerControl = .shared
    var communicationTransport: @MainActor (ConnectionProfile, [String: Any]) async throws -> (value: [String: Any]?, stderr: Data)
        = RelayHostExecution.communicationRequest

    /// `attach` makes sure this host's daemon holds the local caller policy
    /// first; it costs nothing once attached for this transport and policy.
    func daemonRequest(profile: ConnectionProfile, packet: [String: Any], attach: Bool = true,
                       beforeTransport: (@MainActor () -> Bool)? = nil) async throws -> [String: Any] {
        if attach { try await callerControl.attachDaemon(profile: profile) }
        if let beforeTransport, !beforeTransport() { throw RelayShepherdPushFailure.stale }
        if let operation = packet["operation"] as? String, RelayQuestionNotices.wakingOperations.contains(operation) {
            RelayQuestionNotices.noteActivity(hostKey: profile.connectionKey)
        }
        let result = try await communicationTransport(profile, packet)
        guard let value = result.value else {
            throw RemoteCatalogError.failed(String(data: result.stderr, encoding: .utf8) ?? "The communication daemon is unavailable")
        }
        return value
    }

    private func daemonProfiles(_ workspace: WorkspaceModel) -> [ConnectionProfile] {
        var seen: Set<String> = []
        return workspace.panes.values.map(\.profile).filter { $0.backend == .relay && seen.insert($0.connectionKey).inserted }
    }

    /// Called only from the side panel route, which admits the owner UI and the
    /// in-app assistant. Scoped external callers never reach this point.
    func bindQuestionThread(paneID: UUID, threadID: String, realm: String, ttl: String?,
                            workspace: WorkspaceModel) async throws -> [String: Any] {
        let pane = try questionPane(paneID, workspace: workspace)
        return try await daemonRequest(profile: pane.profile, packet: RelayQuestionThreadInput.bindPacket(
            paneID: paneID, threadID: threadID, realm: realm, ttl: ttl))
    }

    /// Polled on RelayQuestionNotices.Schedule: an owner read that needs no
    /// caller policy, so it never attaches or refreshes.
    func pullQuestionNotices(profile: ConnectionProfile, paneIDs: [UUID]) async throws -> [String: Any] {
        try await daemonRequest(profile: profile, packet: RelayQuestionNotices.pullPacket(paneIDs: paneIDs), attach: false)
    }

    func sendQuestionNotice(profile: ConnectionProfile, paneID: UUID, messageID: String) async throws -> [String: Any] {
        try await daemonRequest(profile: profile, packet: RelayQuestionNotices.sendPacket(paneID: paneID, messageID: messageID))
    }

    func ackQuestionNoticeHeld(profile: ConnectionProfile, paneID: UUID, messageID: String) async throws -> [String: Any] {
        try await daemonRequest(profile: profile, packet: RelayQuestionNotices.heldPacket(paneID: paneID, messageID: messageID))
    }

    func unbindQuestionThread(paneID: UUID, workspace: WorkspaceModel) async throws -> [String: Any] {
        let pane = try questionPane(paneID, workspace: workspace)
        return try await daemonRequest(profile: pane.profile, packet: RelayQuestionThreadInput.unbindPacket(paneID: paneID))
    }

    private func questionPane(_ id: UUID, workspace: WorkspaceModel) throws -> PaneModel {
        guard let pane = workspace.panes[id], pane.contentKind == .terminal, pane.profile.backend == .relay else {
            throw RemoteCatalogError.failed("Question threads bind only to Relay-managed agent terminals.")
        }
        return pane
    }

    func disconnect(linkID: String, workspace: WorkspaceModel, beforeRetire: (() throws -> Void)? = nil) async throws -> [String: String] {
        if daemonLinkOwners[linkID] == nil { _ = try await savedLinks(workspace: workspace) }
        if let owner = daemonLinkOwners[linkID] {
            try await callerControl.attachDaemon(profile: owner)
            try beforeRetire?()
            let result = try await daemonRequest(profile: owner, packet: ["operation": "unlink", "link_id": linkID], attach: false)
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
        try beforeRetire?()
        let removed = try links.retire(intent: linkID, action: "link")
        return ["link_id": linkID, "status": removed ? "retired" : "not_found",
                "history": "retained", "message_receipts": "retained"]
    }

    // Native endpoints are host/kernel observations. A lazy or reconnecting
    // renderer does not determine whether the unchanged agent socket is live.
    // Endpoint discovery and pre-send revalidation remain authoritative.
    /// `commitGuard` runs at the commit boundary with no await between it and the
    /// link write (the daemon request or the local store write). It returns false
    /// if what the caller approved is no longer what would be saved. The default
    /// keeps every existing caller's behaviour.
    func connect(panes ids: [UUID], workspace: WorkspaceModel, automatic: Bool = false,
                 commitGuard: @escaping @MainActor () -> Bool = { true }) async throws -> Link {
        guard ids.count == 2, Set(ids).count == 2 else { throw RemoteCatalogError.failed("Select two distinct agent panes.") }
        defer { RelayAgentMaintenance.shared.requestRepair(ids) }
        // Before any link is written, so a hand-made link is never auto-owned.
        if !automatic { RelayAutoLinker.shared.noteManualLink(ids[0], ids[1]) }
        if let source = workspace.panes[ids[0]], let target = workspace.panes[ids[1]],
           let profile = Self.sharedDaemonProfile([source, target]) {
            let result = try await daemonRequest(profile: profile, packet: ["operation": "link",
                "source_pane_id": source.id.uuidString.lowercased(), "pane_id": target.id.uuidString.lowercased()],
                beforeTransport: { commitGuard() })
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
        let id = Self.canonicalLinkID(members)
        // Janitor at admission: synchronous, so nothing suspends between the
        // sweep, the records read below and the commit. It only retires
        // confirmed-obsolete links; if none qualifies the limit still applies.
        retireObsoleteLinks(workspace: workspace, reason: "admission")
        let records = try links.records(limit: 64)
        let prior = try links.read(intent: id, action: "link")
        if prior == nil, records.count >= 64 { throw RemoteCatalogError.failed("Saved pane link limit reached.") }
        let link = Link(id: id, members: members, transport: errors.isEmpty ? "relay_native_socket" : "unavailable",
            resolutionErrors: errors.isEmpty ? nil : errors)
        guard commitGuard() else { throw RemoteCatalogError.failed("The panes changed before the link was saved; nothing was written.") }
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

    /// The saved-link ID of a pair: stable across process restarts. Members
    /// are ordered by pane ID, as `connect` builds them.
    nonisolated static func canonicalLinkID(_ members: [Link.Member]) -> String {
        let identity = members.sorted { $0.paneID.uuidString < $1.paneID.uuidString }
            .map { "\($0.paneID):\($0.hostID)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Pane-link janitor rule (pure). A link is obsolete only when it is
    /// well-formed, carries no message in flight, and either
    /// (a) a member pane is held nowhere in this profile (`knownPaneIDs` is
    ///     the authoritative set; closed panes are not in it, offline,
    ///     reconnecting or lazy panes are) and every such member has a
    ///     closed-pane archive (`closedPaneIDs`): positive evidence that it
    ///     was closed, not merely not yet committed by its instance, or
    /// (b) it is an older generation of a pair whose current link exists:
    ///     the same rule `connect` applies to the pair it links.
    nonisolated static func obsoleteLinks(_ links: [Link], knownPaneIDs: Set<UUID>, closedPaneIDs: Set<UUID>,
                                          inFlightPairs: Set<Set<UUID>>) -> [String] {
        let byID = Dictionary(links.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return links.compactMap { link in
            let pair = Set(link.members.map(\.paneID))
            guard link.members.count == 2, pair.count == 2 else { return nil }
            guard !inFlightPairs.contains(pair) else { return nil }
            let missing = pair.subtracting(knownPaneIDs)
            if !missing.isEmpty { return missing.isSubset(of: closedPaneIDs) ? link.id : nil }
            let canonical = canonicalLinkID(link.members)
            guard link.id != canonical, let current = byID[canonical],
                  Set(current.members.map(\.paneID)) == pair,
                  link.members.allSatisfy({ member in current.members.contains {
                      $0.paneID == member.paneID && $0.hostID == member.hostID } }) else { return nil }
            return link.id
        }
    }

    /// The pane-link janitor. Retires (never deletes, creates or edits) only
    /// confirmed-obsolete local links; history and message receipts are kept.
    /// Does nothing unless the workspace can state authoritatively which panes
    /// exist. Synchronous: no suspension between reading and retiring.
    ///
    /// One transaction, lock order (outer to inner):
    ///   1. shared-workspace lock (`withPaneLinkJanitorFence`, non-blocking):
    ///      pending count, committed snapshot and closed-pane archives are
    ///      read, and no instance can commit, preserve or restore until the
    ///      last retire is done;
    ///   2. in-flight marker lock (`InFlightMarkers.withLock`, non-blocking):
    ///      no instance can mark a new delivery until the last retire is done;
    ///      if another holder has it, the sweep is skipped;
    ///   3. pane-link store lock (per `records` / `retire` call).
    /// A delivery takes only lock 2, briefly, and waits for it at most
    /// `InFlightMarkers.writerWait`; a commit takes only lock 1. The sweep
    /// waits for no lock: it skips instead.
    @discardableResult
    func retireObsoleteLinks(workspace: WorkspaceModel, reason: String) -> [String] {
        var status = "skipped_unverified_workspace"
        let swept = workspace.withPaneLinkJanitorFence { evidence -> [String]? in
            do {
                return try inFlight.withLock { markedPairs -> [String]? in
                    sweep(evidence: evidence, markedPairs: markedPairs, reason: reason, status: &status)
                }
            } catch InFlightMarkers.Failure.busy {
                status = "in_flight_busy"
                return nil
            } catch {
                status = "in_flight_unverifiable"
                return nil
            }
        } ?? nil
        guard let swept else {
            RelayDiagnostics.shared.record(category: "communication", name: "pane-link-janitor",
                details: ["reason": reason, "status": status])
            return []
        }
        return swept
    }

    /// The decision and retires, run only inside the fence and marker lock.
    private func sweep(evidence: WorkspaceModel.PaneLinkJanitorEvidence, markedPairs: Set<Set<UUID>>,
                       reason: String, status: inout String) -> [String]? {
        let records: [RelayClaudeRotationActionStore.Record]
        do { records = try links.records(limit: 64) } catch {
            status = "store_unreadable"
            return nil
        }
        // Unresolved (incomplete) and undecodable records are never candidates.
        let saved = records.compactMap { record -> Link? in
            guard record.completed, let bytes = record.result else { return nil }
            return try? JSONDecoder().decode(Link.self, from: bytes)
        }
        let obsolete = Self.obsoleteLinks(saved, knownPaneIDs: evidence.known, closedPaneIDs: evidence.closed,
            inFlightPairs: Set(activeDeliveries.values).union(markedPairs))
        janitorWindowForTesting?()
        var retired: [String] = []
        for id in obsolete where (try? links.retire(intent: id, action: "link")) == true { retired.append(id) }
        if !retired.isEmpty || reason != "periodic" {
            RelayDiagnostics.shared.record(category: "communication", name: "pane-link-janitor",
                details: ["reason": reason, "status": "swept", "retired": String(retired.count),
                          "kept": String(saved.count - retired.count)])
        }
        return retired
    }

    /// Tests only: mark a message between `pair` as in flight, as `send` does.
    func beginDeliveryForTesting(_ messageID: UUID, pair: Set<UUID>) throws { try beginDelivery(messageID, pair: pair) }
    func endDeliveryForTesting(_ messageID: UUID) { endDelivery(messageID) }
    var activeDeliveryCountForTesting: Int { activeDeliveries.count }

    /// Marks a delivery in flight for this instance and, through the
    /// profile-shared marker, for every other instance's janitor. The marker
    /// is written first. If it cannot be written, the send is refused before
    /// any side effect: no endpoint lookup, no receipt, no delivery. Other
    /// janitors therefore never see an unmarked delivery.
    private func beginDelivery(_ messageID: UUID, pair: Set<UUID>) throws {
        let attempt = UUID()
        do { try inFlight.mark(messageID, attempt: attempt, pair: pair) } catch {
            RelayDiagnostics.shared.record(category: "communication", name: "pane-link-in-flight-marker",
                details: ["status": "unwritten_send_refused"])
            throw RemoteCatalogError.failed("Relay could not record this message as in flight, so it was not sent. "
                + "Nothing was delivered; retrying with the same message ID is safe.")
        }
        activeDeliveries[messageID] = pair
        markerAttempts[messageID] = attempt
    }

    /// A marker that cannot be removed stays and keeps protecting the pair
    /// (fail closed) until this process exits or the marker ages out.
    private func endDelivery(_ messageID: UUID) {
        activeDeliveries.removeValue(forKey: messageID)
        guard let attempt = markerAttempts.removeValue(forKey: messageID) else { return }
        if !inFlight.clear(messageID, attempt: attempt) {
            RelayDiagnostics.shared.record(category: "communication", name: "pane-link-in-flight-marker",
                details: ["status": "uncleared"])
        }
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
        if let nativeRequestOverride { return try await nativeRequestOverride(pane, packet) }
        var validatedPacket = packet
        // Without an attached renderer, require the daemon's kernel-validated
        // binding in addition to socket/session discovery. A manifest alone
        // must never let a recycled process inherit another pane's identity.
        validatedPacket["requireAuthenticatedBinding"] = pane.connectionState != .connected
        let encoded = try JSONSerialization.data(withJSONObject: validatedPacket, options: .sortedKeys).base64EncodedString()
        let rootPID = pane.profile.kind == .local ? Int(pane.networkForegroundPID ?? 0) : 0
        let command = RelayHostExecution.daemonCommand(profile: pane.profile, arguments: [
            "pane-messaging", "--pane", pane.id.uuidString.lowercased(),
            "--root-pid", String(rootPID), "--request", encoded])
        let result = try await RelayHostExecution.capture(profile: pane.profile, command: command,
            timeout: 30, maximumBytes: 64 << 10)
        guard result.exitCode == 0,
              let value = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw RemoteCatalogError.failed("Native messaging outcome unavailable; job \(result.jobID). Do not replay.")
        }
        return value
    }

    struct PrivateSecretSource: Equatable {
        let sessionID: UUID
        let pid: Int
        let start: String
        let provider: String
    }

    /// Redeem a host-owned, single-use attestation over the exact secret-tool
    /// arguments, and verify that it is still the same native conversation.
    func redeemPrivateSecretProof(pane: PaneModel, attestation: String, requestID: UUID,
                                  tool: String, arguments: String) async throws -> PrivateSecretSource {
        guard ["relay_request_secret", "relay_secret_receipt"].contains(tool),
              attestation.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil,
              arguments.utf8.count <= 4096 else { throw RemoteCatalogError.failed("Invalid private request proof") }
        let profile = pane.profile
        let before = try await endpoint(pane)
        guard let session = UUID(uuidString: before.sessionID) else { throw RemoteCatalogError.failed("Private request session unavailable") }
        guard let text = RelayPrivateSecretProofPolicy.canonical(tool: tool, arguments: arguments) else {
            throw RemoteCatalogError.failed("Invalid private request")
        }
        let reply = try await daemonRequest(profile: profile, packet: ["operation": "attest_consume", "attestation_id": attestation,
            "source_pane_id": pane.id.uuidString.lowercased(), "pane_id": RelayPrivateSecretProofPolicy.inbox,
            "message_id": requestID.uuidString.lowercased(), "text": text])
        guard RelayPrivateSecretProofPolicy.verifies(reply, attestation: attestation, paneID: pane.id, sessionID: before.sessionID),
              pane.profile.connectionKey == profile.connectionKey,
              try await endpoint(pane) == before else { throw RemoteCatalogError.failed("Private request identity changed") }
        return PrivateSecretSource(sessionID: session, pid: before.pid, start: before.start, provider: before.provider)
    }

    func privateSecretSourceIsCurrent(_ pane: PaneModel, expected: PrivateSecretSource) async -> Bool {
        guard let current = try? await endpoint(pane) else { return false }
        return UUID(uuidString: current.sessionID) == expected.sessionID && current.pid == expected.pid &&
            current.start == expected.start && current.provider == expected.provider
    }

    private func endpoint(_ pane: PaneModel) async throws -> Endpoint {
        let result = try await nativeRequest(pane, packet: ["operation": "discover"])
        guard let object = result["endpoint"] as? [String: Any] else {
            throw RemoteCatalogError.failed(result["error"] as? String ?? "No exact live agent session is bound to this pane.")
        }
        return try JSONDecoder().decode(Endpoint.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The one relayd that can save a pair itself, without the host-wide peer
    /// inventory: two distinct Relay terminals on the same daemon connection.
    nonisolated static func sharedDaemonProfile(_ panes: [PaneModel]) -> ConnectionProfile? {
        guard panes.count == 2, panes[0].id != panes[1].id,
              panes.allSatisfy({ $0.contentKind == .terminal && $0.profile.backend == .relay }),
              panes[0].profile.connectionKey == panes[1].profile.connectionKey else { return nil }
        return panes[0].profile
    }

    /// The transport of a relayd discover reply, or nil when the pane has no
    /// verified messaging endpoint.
    nonisolated static func verifiedDaemonTransport(_ reply: [String: Any]) -> String? {
        guard let endpoint = reply["endpoint"] as? [String: Any],
              let transport = endpoint["transport"] as? String,
              !transport.isEmpty, transport != "unavailable" else { return nil }
        return transport
    }

    /// True once relayd has verified an endpoint for both panes of a pair.
    nonisolated static func daemonPairVerified(_ requested: Set<UUID>, transports: [UUID: String]) -> Bool {
        requested.count == 2 && requested.allSatisfy { transports[$0] != nil }
    }

    /// The link sheet's relayd evidence. Only the latest check counts: a
    /// failure withdraws an earlier success, and a reply from a superseded
    /// check is dropped so it cannot restore one.
    struct DaemonPairCheck {
        private(set) var transports: [UUID: String] = [:]
        private(set) var failures: [UUID: String] = [:]
        private var generation = 0

        mutating func begin() -> Int { generation += 1; return generation }

        mutating func record(_ id: UUID, check: Int, result: Result<String, Error>) {
            guard check == generation else { return }
            switch result {
            case .success(let transport): transports[id] = transport; failures[id] = nil
            case .failure(let error): transports[id] = nil; failures[id] = error.localizedDescription
            }
        }
    }

    /// Runs the per-pane check relayd's own link operation runs. Unlike the
    /// peer inventory, which lists Claude session records only, it resolves
    /// Codex app-server endpoints too.
    func daemonEndpointTransport(_ pane: PaneModel) async throws -> String {
        let reply = try await daemonRequest(profile: pane.profile, packet: ["operation": "discover",
            "pane_id": pane.id.uuidString.lowercased()])
        guard let transport = Self.verifiedDaemonTransport(reply) else {
            throw RemoteCatalogError.failed(reply["error"] as? String ?? "No verified messaging endpoint on this host.")
        }
        return transport
    }

    // Spends the sender's single-use proof on its own host, over the captured
    // host connection, after this message's durable claim. relayd re-observes
    // the same source conversation; this only cross-checks the pane and session.
    private func redeemAttestation(_ id: String, request: Request, targetID: UUID, profile: ConnectionProfile,
                                   sourceProcess: Endpoint) async throws -> [String: Any] {
        guard profile.backend == .relay, id.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else {
            throw RemoteCatalogError.failed("Source attestation is unavailable for this host.")
        }
        let reply = try await daemonRequest(profile: profile, packet: ["operation": "attest_consume", "attestation_id": id,
            "source_pane_id": request.sourcePaneID.uuidString.lowercased(), "pane_id": targetID.uuidString.lowercased(),
            "message_id": request.messageID.uuidString.lowercased(), "text": request.text])
        guard reply["authority"] as? String == "relayd", let source = reply["source"] as? [String: Any],
              source["authentication"] as? String == "source_host_attested", source["attestationID"] as? String == id,
              source["paneID"] as? String == request.sourcePaneID.uuidString.lowercased(),
              let session = source["sessionID"] as? String, session == sourceProcess.sessionID,
              source["socketPath"] == nil else {
            throw RemoteCatalogError.failed("Source attestation did not match the sending conversation.")
        }
        return source
    }

    enum SignedDelivery {
        case delivered([String: Any])
        case declined(String)
    }

    /// Refusals relayd returns from deliver_signed before it claims a receipt,
    /// so the message was certainly not delivered and another path is safe.
    /// A message-identity conflict is deliberately absent: an earlier delivery
    /// of different content must never be followed by a second one.
    nonisolated static func signedDeliveryDeclinedBeforeWrite(_ message: String) -> Bool {
        let declines = ["signing host is not trusted on this host", "signed envelope required",
                        "malformed signed envelope", "signed envelope host certificate malformed",
                        "signing host key is not Ed25519", "session certificate", "message signature invalid",
                        "signed statement", "unknown daemon communication operation",
                        "the target pane has no verified native communication endpoint"]
        return !message.contains("conflicts with a previous request") && declines.contains { message.contains($0) }
    }

    /// Delivers through the recipient host's relayd, which verifies the
    /// sender's signature and builds the sender identity itself. An untrusted
    /// signing host is pinned and pushed once, then delivery is retried once.
    private func deliverSigned(_ signature: String, request: Request, targetID: UUID,
                               sourceProfile: ConnectionProfile, targetProfile: ConnectionProfile) async throws -> SignedDelivery {
        let packet: [String: Any] = ["operation": "deliver_signed", "source_signature": signature,
            "source_pane_id": request.sourcePaneID.uuidString.lowercased(), "pane_id": targetID.uuidString.lowercased(),
            "message_id": request.messageID.uuidString.lowercased(), "text": request.text]
        do {
            return .delivered(try await daemonRequest(profile: targetProfile, packet: packet))
        } catch let first where Self.signedDeliveryDeclinedBeforeWrite(first.localizedDescription) {
            guard first.localizedDescription.contains("signing host is not trusted on this host") else {
                return .declined(first.localizedDescription)
            }
            do {
                try await nodeTrust.trust(source: sourceProfile, onto: targetProfile)
            } catch {
                return .declined(error.localizedDescription)
            }
            do {
                return .delivered(try await daemonRequest(profile: targetProfile, packet: packet))
            } catch let second where Self.signedDeliveryDeclinedBeforeWrite(second.localizedDescription) {
                return .declined(second.localizedDescription)
            }
        }
    }

    var nodeTrust: RelayNodeTrust { RelayNodeTrust.shared }

    /// This Mac cannot observe a remote sender's process; only the sender host's
    /// relayd can prove it (a redeemed attestation, or a signature its recipient
    /// relayd verified, which returns before this check). A remote submission
    /// without that proof is refused with a receipt and never written as a claim.
    nonisolated static func rejectsUnprovenRemoteSource(sourceIsLocal: Bool, sourceAuthentication: String) -> Bool {
        !sourceIsLocal && sourceAuthentication != "source_host_attested"
    }

    /// Bounded, single-line copy of a broker-supplied diagnostic.
    nonisolated static func receiptDiagnostic(_ text: String) -> String {
        String(String(text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : Character($0) }).prefix(512))
    }

    func send(_ request: Request, targetID: UUID, workspace: WorkspaceModel, submittingClientID: String,
              callerToken: String? = nil) async throws -> [String: Any] {
        guard request.sourcePaneID != targetID, !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.utf8.count <= 16384,
              !request.text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 }) else {
            throw RemoteCatalogError.failed("Use distinct source and target panes and a message of 1–16384 bytes.")
        }
        if let source = workspace.panes[request.sourcePaneID], let target = workspace.panes[targetID],
           source.profile.backend == .relay, target.profile.backend == .relay,
           source.profile.connectionKey == target.profile.connectionKey {
            var packet: [String: Any] = ["operation": "send",
                "source_pane_id": request.sourcePaneID.uuidString.lowercased(), "pane_id": targetID.uuidString.lowercased(),
                "message_id": request.messageID.uuidString.lowercased(), "text": request.text, "client_id": submittingClientID]
            // relayd ignores a forwarded client_id; it attributes only a credential
            // it can check against the caller policy imported by attachDaemon.
            if let callerToken, submittingClientID != "legacy-unattributed" { packet["client_token"] = callerToken }
            return try await daemonRequest(profile: source.profile, packet: packet)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // A retried send carries a freshly minted proof; identity excludes it.
        let identity = Request(sourcePaneID: request.sourcePaneID, messageID: request.messageID, text: request.text)
        let fingerprint = SHA256.hash(data: try encoder.encode(identity) + Data(targetID.uuidString.utf8))
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
        try beginDelivery(request.messageID, pair: Set([source.id, targetID]))
        defer { endDelivery(request.messageID) }
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
        func finish(_ result: [String: Any]) throws -> [String: Any] {
            try receipts.complete(intent: request.messageID.uuidString, action: "send", fingerprint: fingerprint,
                result: JSONSerialization.data(withJSONObject: result, options: .sortedKeys))
            RelayRecoveryStore.shared.record(kind: "message_\(result["status"] as? String ?? "outcome_unknown")",
                paneID: source.id, profile: sourceProfile, links: [
                    .init(from: "pane:\(source.id)", to: "message:\(request.messageID)", kind: "submitted"),
                    .init(from: "message:\(request.messageID)", to: "pane:\(targetID)", kind: "addressed_to")
                ])
            return result
        }
        var signatureError: String?
        if let signature = request.sourceSignature, targetProfile.backend == .relay {
            do {
                switch try await deliverSigned(signature, request: request, targetID: targetID,
                                               sourceProfile: sourceProfile, targetProfile: targetProfile) {
                case .delivered(let receipt):
                    var result: [String: Any] = ["provider": targetProcess.provider, "transport": targetProcess.transport,
                        "verified_by": "recipient_relayd", "replay_permitted": false]
                    for (key, value) in receipt { result[key] = value }
                    return try finish(result)
                case .declined(let reason):
                    signatureError = reason
                }
            } catch {
                // The recipient may have claimed and delivered it. Never try another path.
                return try finish(["message_id": request.messageID.uuidString.lowercased(),
                    "source_pane_id": source.id.uuidString.lowercased(), "pane_id": targetID.uuidString.lowercased(),
                    "provider": targetProcess.provider, "transport": targetProcess.transport,
                    "source_authentication": "unconfirmed", "submitting_client_id": submittingClientID,
                    "status": "outcome_unknown", "replay_permitted": false, "error": error.localizedDescription])
            }
        }
        var sender: [String: Any] = ["hostID": sourceProfile.id.uuidString.lowercased(),
            "paneID": source.id.uuidString.lowercased(), "sessionID": sourceProcess.sessionID]
        var sourceAuthentication = "unverified", attestationError: String?
        if let attestation = request.sourceAttestation {
            do {
                sender = try await redeemAttestation(attestation, request: request, targetID: targetID,
                                                     profile: sourceProfile, sourceProcess: sourceProcess)
                sourceAuthentication = "source_host_attested"
            } catch { attestationError = error.localizedDescription }
        }
        var result: [String: Any] = ["message_id": request.messageID.uuidString.lowercased(),
            "source_pane_id": source.id.uuidString.lowercased(), "pane_id": targetID.uuidString.lowercased(),
            "provider": targetProcess.provider, "transport": targetProcess.transport,
            "source_authentication": sourceAuthentication, "submitting_client_id": submittingClientID,
            "status": "outcome_unknown", "replay_permitted": false]
        if let attestationError { result["source_attestation_error"] = attestationError }
        if let signatureError { result["source_signature_error"] = signatureError }
        if let proofError = request.sourceProofError { result["source_proof_error"] = Self.receiptDiagnostic(proofError) }
        if Self.rejectsUnprovenRemoteSource(sourceIsLocal: sourceProfile.kind == .local,
                                             sourceAuthentication: sourceAuthentication) {
            // The claim is durable and nothing was written: the same ID returns
            // this receipt. Fix the sender host's proof, then use a new ID.
            result["status"] = "rejected_unverified_source"
            result["delivered"] = false
            result["error"] = "Remote sender is not attested by its own host's relayd; the message was not delivered. " +
                "Check source_attestation_error/source_proof_error, fix the sending host, and resend with a new message_id."
            return try finish(result)
        }
        do {
            let delivered = try await nativeRequest(target, packet: ["operation": "send", "expected": expected,
                "messageID": request.messageID.uuidString.lowercased(), "targetPaneID": targetID.uuidString.lowercased(),
                "text": request.text, "submittingClientID": submittingClientID, "source": sender])
            for (key, value) in delivered { result[key] = value }
        } catch {
            // The durable claim precedes every write. Transport loss never replays a message.
            result["error"] = error.localizedDescription
        }
        return try finish(result)
    }
    /// In-flight caller-sourced messages on this instance. They have no pane
    /// pair, so they take no shared in-flight marker: the janitor only
    /// understands two-pane markers and a caller send protects no link.
    private var activeCallerDeliveries: Set<UUID> = []

    /// Recipient decision for a caller send. Only the recipient's kind matters:
    /// the host (this Mac or a relayd host) is not a criterion, because the
    /// delivery below is the same host-channel `nativeRequest` a pane-sourced
    /// message to that pane already uses.
    nonisolated static func callerRecipientRefusal(contentKind: PaneContentKind) -> String? {
        contentKind == .terminal ? nil : "The recipient must be an existing terminal."
    }

    /// A message from a registered caller that has no pane. Same claim, receipt,
    /// endpoint recheck and native delivery as `send`; only the sender differs.
    /// The caller was already resolved and unpaused by the route. Local and
    /// remote recipients are served alike. The recipient's relayd cannot verify
    /// where the caller identity came from: it is a claim at the same trust level
    /// as a claimed pane label.
    func sendAsCaller(messageID: UUID, text: String, sender: RelayCallerSender.Sender, targetID: UUID,
                      workspace: WorkspaceModel) async throws -> [String: Any] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16384,
              !text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 10 && $0.value != 9 }) else {
            throw RemoteCatalogError.failed("Use a message of 1–16384 bytes.")
        }
        guard let target = workspace.panes[targetID], Self.callerRecipientRefusal(contentKind: target.contentKind) == nil else {
            throw RemoteCatalogError.failed("The recipient must be an existing terminal.")
        }
        struct Identity: Codable { let callerID: String; let messageID: UUID; let text: String }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let fingerprint = SHA256.hash(data: try encoder.encode(Identity(callerID: sender.id, messageID: messageID, text: text))
                                      + Data(targetID.uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        if let prior = try receipts.read(intent: messageID.uuidString, action: "send") {
            guard prior.fingerprint == fingerprint else { throw RemoteCatalogError.failed("Message ID conflicts with an existing request.") }
            return try await receipt(messageID, workspace: workspace) ?? [:]
        }
        guard !activeCallerDeliveries.contains(messageID), activeDeliveries[messageID] == nil else {
            throw RemoteCatalogError.failed("This message is in flight. Check its receipt; do not replay.")
        }
        activeCallerDeliveries.insert(messageID)
        defer { activeCallerDeliveries.remove(messageID) }
        let targetProfile = target.profile
        let targetProcess = try await endpoint(target)
        guard workspace.panes[targetID] === target, target.profile == targetProfile, targetProcess.transport != "unavailable" else {
            throw RemoteCatalogError.failed("Recipient has no supported native messaging socket. Terminal injection is unavailable for messages.")
        }
        guard try receipts.claim(intent: messageID.uuidString, action: "send", fingerprint: fingerprint) else {
            guard try receipts.read(intent: messageID.uuidString, action: "send")?.fingerprint == fingerprint else {
                throw RemoteCatalogError.failed("Message ID conflicts with an existing request.")
            }
            return try await receipt(messageID, workspace: workspace) ?? [:]
        }
        let targetNow = try await endpoint(target)
        guard targetNow == targetProcess, workspace.panes[targetID] === target, target.profile == targetProfile,
              target.contentKind == .terminal else {
            throw RemoteCatalogError.failed("Pane or native recipient session changed. The claimed message will not be replayed.")
        }
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(targetProcess))
        var result: [String: Any] = ["message_id": messageID.uuidString.lowercased(),
            "source_caller_id": sender.id, "source_caller_label": sender.label,
            "pane_id": targetID.uuidString.lowercased(), "provider": targetProcess.provider, "transport": targetProcess.transport,
            "source_authentication": RelayCallerSender.authentication, "submitting_client_id": sender.id,
            "status": "outcome_unknown", "replay_permitted": false]
        do {
            let delivered = try await nativeRequest(target, packet: ["operation": "send", "expected": expected,
                "messageID": messageID.uuidString.lowercased(), "targetPaneID": targetID.uuidString.lowercased(),
                "text": text, "submittingClientID": sender.id,
                "source": RelayCallerSender.source(sender, hostID: targetProfile.id)])
            for (key, value) in delivered { result[key] = value }
        } catch {
            // The durable claim precedes every write. Transport loss never replays a message.
            result["error"] = error.localizedDescription
        }
        try receipts.complete(intent: messageID.uuidString, action: "send", fingerprint: fingerprint,
            result: JSONSerialization.data(withJSONObject: result, options: .sortedKeys))
        RelayRecoveryStore.shared.record(kind: "message_\(result["status"] as? String ?? "outcome_unknown")",
            paneID: targetID, profile: targetProfile, links: [
                .init(from: "caller:\(sender.id)", to: "message:\(messageID)", kind: "submitted"),
                .init(from: "message:\(messageID)", to: "pane:\(targetID)", kind: "addressed_to")
            ])
        return result
    }
}

/// Question-thread inputs, checked identically by the Miko step and the
/// /api/question-threads route, so no caller can skip the checks.
enum RelayQuestionThreadInput {
    static let idPattern = #"^[A-Za-z0-9_:.-]{1,128}$"#

    static func validID(_ value: String?) -> String? {
        guard let value, value.range(of: idPattern, options: .regularExpression) != nil else { return nil }
        return value
    }

    static func validTTL(_ value: String) -> Bool {
        guard value.range(of: #"^[0-9]{2,6}$"#, options: .regularExpression) != nil, let seconds = Int(value) else { return false }
        return (30...86400).contains(seconds)
    }

    /// The request body the route decodes.
    struct Binding: Decodable {
        let paneID: UUID
        let threadID: String?
        let realm: String?
        let ttl: String?
    }

    /// Who may use the question-thread route. The route serves the owner UI
    /// (no credential) and the in-app assistant. A registered external caller is
    /// refused, because the route cannot tell which pane that caller holds.
    @MainActor static func admits(caller: String?) -> Bool {
        caller == "legacy-unattributed" || caller == RelayCallerControl.assistantCaller
    }

    /// The daemon packet for a bind. The source is the target pane. This is a
    /// shape the daemon checks, not an authentication: the route's admission
    /// above is what limits who can send it.
    static func bindPacket(paneID: UUID, threadID: String, realm: String, ttl: String?) -> [String: Any] {
        var packet: [String: Any] = ["operation": "question_bind", "source_pane_id": paneID.uuidString.lowercased(),
                                     "pane_id": paneID.uuidString.lowercased(), "thread_id": threadID, "realm": realm]
        if let ttl { packet["ttl"] = ttl }
        return packet
    }

    static func unbindPacket(paneID: UUID) -> [String: Any] {
        ["operation": "question_unbind", "source_pane_id": paneID.uuidString.lowercased(), "pane_id": paneID.uuidString.lowercased()]
    }

    /// The route's refusal for a question-thread request body, or nil when it may proceed.
    static func rejection(method: String, body: Data) -> RelaySidePanelHTTPResponse? {
        guard method == "POST" else { return nil }
        guard let input = try? JSONDecoder().decode(Binding.self, from: body) else {
            return .text("Question thread request is malformed", status: 400, reason: "Bad Request")
        }
        guard validID(input.threadID) != nil, validID(input.realm) != nil else {
            return .text("threadID and realm must be 1 to 128 characters from A-Z a-z 0-9 _ : . -", status: 400, reason: "Bad Request")
        }
        if let ttl = input.ttl, !validTTL(ttl) {
            return .text("ttl must be an integer number of seconds from 30 to 86400", status: 400, reason: "Bad Request")
        }
        return nil
    }
}

/// Profile-shared record of deliveries in flight, so that a janitor in one
/// Relay instance never retires a link another instance is delivering over.
/// One `<messageID>.<attemptID>.json` per delivery attempt (owner pid, pair,
/// start time), written and read under `.lock` (flock). The attempt ID is
/// minted per `mark` and known only to that attempt, so two instances sending
/// the same message ID (an idempotent retry, or a conflicting pair) each hold
/// their own marker, and an attempt's cleanup removes only its own.
///
/// Fail closed: the janitor's read throws (and the sweep retires nothing) if
/// any marker-named file cannot be proven to be either a live marker or a
/// dead one: unreadable, oversize, undecodable, a bad name, or not exactly
/// two distinct panes. A well-formed marker whose owner process is gone, or
/// that is older than `maximumAge`, no longer protects and is removed.
final class InFlightMarkers: @unchecked Sendable {
    enum Failure: Error { case busy, unverifiable(String), unwritable }
    struct Marker: Codable { let pair: [UUID]; let pid: Int32; let created: Date }
    static let maximumAge: TimeInterval = 3600
    static let maximumMarkers = 1024
    static let maximumMarkerBytes = 4096
    /// How long a writer (a send, or its cleanup) waits for the lock.
    static let writerWait: TimeInterval = 0.1
    let directory: URL
    init(directory: URL) { self.directory = directory }

    private func url(_ id: UUID, _ attempt: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).\(attempt.uuidString.lowercased()).json")
    }

    /// `<UUID>.<UUID>.json`
    static func isMarkerName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let parts = name.dropLast(5).split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { UUID(uuidString: String($0)) != nil }
    }

    /// Janitor read. Never waits: throws `.busy` if the lock is held.
    func withLock<T>(_ body: (Set<Set<UUID>>) throws -> T) throws -> T {
        try locked(wait: 0) {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".json") }
            guard names.count <= Self.maximumMarkers else { throw Failure.unverifiable("too_many") }
            var pairs: Set<Set<UUID>> = []
            for name in names {
                let file = directory.appendingPathComponent(name)
                guard Self.isMarkerName(name) else { throw Failure.unverifiable("name") }
                var info = stat()
                guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_size <= Self.maximumMarkerBytes else { throw Failure.unverifiable("file") }
                guard let data = try? Data(contentsOf: file), data.count <= Self.maximumMarkerBytes
                else { throw Failure.unverifiable("unreadable") }
                guard let marker = try? JSONDecoder().decode(Marker.self, from: data)
                else { throw Failure.unverifiable("undecodable") }
                let pair = Set(marker.pair)
                guard marker.pair.count == 2, pair.count == 2, marker.pid > 0
                else { throw Failure.unverifiable("pair") }
                if Self.isLive(marker) { pairs.insert(pair) } else { try? FileManager.default.removeItem(at: file) }
            }
            return try body(pairs)
        }
    }

    static func isLive(_ marker: Marker, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(marker.created) < maximumAge else { return false }
        return kill(marker.pid, 0) == 0 || errno == EPERM
    }

    /// Writes a new marker for this attempt. Never replaces another file:
    /// an existing name (only possible if an attempt ID is reused) is refused.
    func mark(_ id: UUID, attempt: UUID = UUID(), pair: Set<UUID>, pid: Int32 = getpid(),
              created: Date = Date()) throws {
        let data = try JSONEncoder().encode(Marker(pair: pair.sorted { $0.uuidString < $1.uuidString },
                                                   pid: pid, created: created))
        try locked(wait: Self.writerWait) {
            let file = url(id, attempt)
            // Exclusive create. Not `.atomic` (Foundation refuses both); a
            // reader takes the same lock, so it never sees a partial marker.
            try data.write(to: file, options: .withoutOverwriting)
            guard chmod(file.path, 0o600) == 0 else { throw Failure.unwritable }
        }
    }

    /// Returns false if the marker could not be removed.
    @discardableResult
    func clear(_ id: UUID, attempt: UUID) -> Bool {
        (try? locked(wait: Self.writerWait) { () -> Bool in
            do { try FileManager.default.removeItem(at: url(id, attempt)); return true }
            catch CocoaError.fileNoSuchFile { return true }
            catch { return false }
        }) ?? false
    }

    /// Non-blocking flock, retried every 2 ms for at most `wait` seconds.
    private func locked<T>(wait: TimeInterval, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent(".lock").path,
                             O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unwritable }
        defer { Darwin.close(fd) }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw Failure.unwritable }
            guard Date() < deadline else { throw Failure.busy }
            usleep(2000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
