import Combine
import Foundation

@MainActor protocol RelayShepherdPushTransport: AnyObject {
    func revalidate(_ target: RelayShepherdPushTarget) async throws -> Bool
    func send(_ envelope: RelayShepherdPushEnvelope, allowed: @escaping @MainActor () -> Bool) async throws -> Data
}

@MainActor final class RelayShepherdPushController: ObservableObject {
    static let shared = RelayShepherdPushController(
        url: RelayLaunchMode.isRunningTests ? nil : RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/ShepherdPush/ledger.json"),
        monitoring: { RelayMikoShepherdCoordinator.settings }, paused: {
            RelayMikoShepherdCoordinator.paused || RelayMikoSupervision.shared.isDisabled("relay_message_pane")
        })
    @Published private(set) var ledger = RelayShepherdPushLedger()
    @Published private(set) var storageError: String?
    private let url: URL?
    private let monitoring: @MainActor () -> RelayShepherdSettings
    private let paused: @MainActor () -> Bool
    private let injectedTransport: (any RelayShepherdPushTransport)?
    private let audit: @MainActor (RelayShepherdPushEnvelope) throws -> Void
    private var pending: [String: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var configurationEpoch = 0
    private final class WeakWorkspace { weak var value: WorkspaceModel?; init(_ value: WorkspaceModel) { self.value = value } }
    private var workspaces: [WeakWorkspace] = []

    init(url: URL?, monitoring: @escaping @MainActor () -> RelayShepherdSettings,
         paused: @escaping @MainActor () -> Bool, transport: (any RelayShepherdPushTransport)? = nil,
         audit: (@MainActor (RelayShepherdPushEnvelope) throws -> Void)? = nil) {
        self.url = url; self.monitoring = monitoring; self.paused = paused; injectedTransport = transport
        self.audit = audit ?? { envelope in
            guard !RelayLaunchMode.isRunningTests else { return }
            try RelayCallerControl.shared.recordAssistantAction(operation: "shepherd_report", requestID: envelope.messageID,
                request: RelayShepherdPushWire.prefix, tabID: nil, paneID: UUID(uuidString: envelope.target.paneID),
                outcome: "reserved_before_transport", path: "owner-submitted/shepherd")
        }
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= RelayShepherdPushLedger.wireLimit else { throw RelayShepherdWire.invalid }
                ledger = try RelayShepherdPushLedger.decode(Data(contentsOf: url))
            } catch { storageError = "Shepherd push ledger could not be read. Push is stopped; UI reports continue." }
        }
    }
    func remember(_ workspace: WorkspaceModel) {
        workspaces.removeAll { $0.value == nil }
        if !workspaces.contains(where: { $0.value === workspace }) { workspaces.append(.init(workspace)) }
    }
    private func workspace(for target: RelayShepherdPushTarget) -> WorkspaceModel? {
        workspaces.compactMap(\.value).first { workspace in
            workspace.panes[UUID(uuidString: target.paneID)!]?.profile.connectionKey == target.hostKey &&
            workspace.panes[UUID(uuidString: target.linkPaneID)!]?.profile.connectionKey == target.linkHostKey
        }
    }
    private func persist() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ledger)
        guard data.count <= RelayShepherdPushLedger.wireLimit else { throw RelayShepherdWire.invalid }
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func configure(_ settings: RelayShepherdPushSettings, origin: RelayShepherdPushLedger.Origin) throws {
        guard storageError == nil else { throw RelayShepherdWire.invalid }
        let before = ledger
        do { try ledger.configure(settings, origin: origin); try persist(); configurationEpoch += 1 }
        catch { ledger = before; throw error }
    }
    func setCap(_ cap: Int, origin: RelayShepherdPushLedger.Origin) throws {
        var settings = ledger.settings; settings.messagesPerHour = cap
        try configure(settings, origin: origin)
    }
    func clearTarget(origin: RelayShepherdPushLedger.Origin) throws {
        var settings = ledger.settings; settings.target = nil
        try configure(settings, origin: origin)
    }
    func observe(_ report: RelayShepherdReport, now: Date = Date()) {
        guard storageError == nil else { return }
        guard ledger.entries.count < RelayShepherdPushLedger.entryLimit else {
            storageError = "The retained push ledger is full. Push stopped without evicting uncertain UUIDs; UI reports continue."
            return
        }
        let envelope = ledger.observe(report, monitoring: monitoring(), paused: paused(), now: now.timeIntervalSince1970)
        do { try persist() }
        catch {
            storageError = "The push reservation could not be persisted. Nothing was submitted; push is stopped."
            return
        }
        guard let envelope else { return }
        let previous = tail
        let task = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            await self.deliver(envelope)
            self.pending.removeValue(forKey: envelope.messageID)
        }
        pending[envelope.messageID] = task; tail = task
    }
    private func deliver(_ envelope: RelayShepherdPushEnvelope) async {
        func allowed() -> Bool {
            storageError == nil && ledger.mayDispatch(envelope, monitoring: monitoring(), paused: paused())
        }
        var status = "outcome_unknown"
        var detail = "Transport outcome uncertain; the same UUID will never be replayed."
        do {
            guard allowed() else { throw RelayShepherdPushFailure.stale }
            let transport: any RelayShepherdPushTransport
            if let injectedTransport { transport = injectedTransport }
            else {
                guard !RelayLaunchMode.isRunningTests else { throw RelayShepherdPushFailure.stale }
                transport = RelayShepherdDaemonPushTransport(resolve: { [weak self] in self?.workspace(for: $0) })
            }
            guard try await transport.revalidate(envelope.target), allowed() else { throw RelayShepherdPushFailure.stale }
            try audit(envelope)
            guard allowed() else { throw RelayShepherdPushFailure.stale }
            let data = try await transport.send(envelope, allowed: { [self] in
                storageError == nil && ledger.takeAdmission(envelope, monitoring: monitoring(), paused: paused())
            })
            let receipt = try RelayShepherdPushReceipt.decode(data, envelope: envelope)
            // Provider admission and a socket write are never called a read or
            // processed report. Unknown outcomes stop the registration too.
            status = receipt.status; detail = receipt.detail
        } catch RelayShepherdPushFailure.stale {
            status = "stale_or_changed_target"; detail = "Target, saved link, conversation, endpoint, pause or opt-out changed. No fallback or retry."
        } catch {
            status = "outcome_unknown"; detail = "Owner/Miko report outcome uncertain or refused: \(String(String(describing: error).prefix(1200))). No retry; retain UUID \(envelope.messageID)."
        }
        if ledger.finish(envelope.messageID, status: status, detail: detail) {
            do { try persist() }
            catch { storageError = "Push outcome could not be persisted. The durable reservation remains uncertain and will not be replayed." }
        }
    }
    func drain() async { for task in Array(pending.values) { await task.value } }
    var state: [String: Any] {
        ["authentication": RelayShepherdPushWire.authentication, "target_pane_id": ledger.settings.target?.paneID ?? NSNull(),
         "messages_per_hour": ledger.settings.messagesPerHour, "blocked_registration": ledger.blockedRegistration ?? NSNull(),
         "storage_error": storageError ?? NSNull(),
         "deliveries": visibleEntries.suffix(20).map { entry in
            ["message_id": entry.messageID, "pane_id": entry.targetID ?? "", "status": entry.status,
             "detail": entry.detail, "replay_permitted": false] as [String: Any]
         }, "cap_notices": ledger.capNoticeHours.sorted().suffix(20).map { hour in
            ["hour": hour, "text": "Hourly report message cap reached; UI/state reports continue."] as [String: Any]
         }]
    }
    var statusText: String {
        if let storageError { return storageError }
        let target = ledger.settings.target?.paneID ?? "None"
        var lines = ["Report pane: \(target)", "Owner/Miko-submitted (no app, Run, kernel or pane attestation)."]
        if let binding = ledger.settings.target {
            lines.append("Pinned \(binding.recipient.provider) conversation \(binding.recipient.sessionID), process \(binding.recipient.pid) · \(binding.hostKey)")
        }
        if ledger.blockedRegistration != nil { lines.append("Delivery stopped; review and register the report pane again in Settings.") }
        lines += visibleEntries.suffix(5).map { "\($0.messageID) · \($0.status) · \($0.detail)" }
        lines += ledger.capNoticeHours.sorted().suffix(1).map { "Hour \($0): message cap reached. UI/state reports continue." }
        return lines.joined(separator: "\n")
    }
    private var visibleEntries: [RelayShepherdPushLedger.Entry] {
        var failed: Set<String> = []
        return ledger.entries.filter { entry in
            guard entry.attempted, entry.status != "not_submitted_after_registration_stop" else { return false }
            if entry.completed && !["accepted_by_provider", "written_to_socket"].contains(entry.status) {
                return failed.insert(entry.registrationID ?? entry.messageID).inserted
            }
            return true
        }
    }

    struct Choice: Identifiable {
        let paneID: UUID, linkPaneID: UUID
        let hostKey: String, linkHostKey: String, linkID: String, revision: String, scope: String, label: String
        var id: String { paneID.uuidString + ":" + linkID + ":" + linkPaneID.uuidString }
    }
    func choices(workspace: WorkspaceModel?) async -> [Choice] {
        if let workspace { remember(workspace) }
        var choices: [String: Choice] = [:]
        for workspace in workspaces.compactMap(\.value) {
            guard let links = try? await RelayPaneMessaging.shared.savedLinks(workspace: workspace) else { continue }
            for link in links {
                guard let id = link["id"] as? String,
                      let members = link["members"] as? [[String: Any]], members.count == 2,
                      let left = (members[0]["paneID"] as? String).flatMap(UUID.init(uuidString:)),
                      let right = (members[1]["paneID"] as? String).flatMap(UUID.init(uuidString:)), left != right else { continue }
                for (target, anchor) in [(left, right), (right, left)] {
                    guard let pane = workspace.panes[target], let source = workspace.panes[anchor],
                          pane.profile.backend == .relay, pane.contentKind == .terminal,
                          pane.kind == .claude || pane.kind == .codex else { continue }
                    let scope = link["authority"] as? String == "relayd" ? "node" : "desktop"
                    guard scope == "node" || link["state"] as? String == "membership_saved" else { continue }
                    let choice = Choice(paneID: target, linkPaneID: anchor, hostKey: pane.profile.connectionKey,
                        linkHostKey: source.profile.connectionKey, linkID: id, revision: link["updated_at"] as? String ?? "",
                        scope: scope, label: pane.displayName + " · linked via " + source.displayName + " · " + String(target.uuidString.prefix(8)))
                    choices[choice.id] = choice
                }
            }
        }
        return choices.values.sorted { $0.label < $1.label }
    }
    func register(_ choice: Choice, origin: RelayShepherdPushLedger.Origin) async throws {
        guard origin == .userSettings else { throw RelayShepherdWire.invalid }
        // Stop old admission immediately, before asynchronous discovery.
        try clearTarget(origin: origin)
        let epoch = configurationEpoch
        guard let workspace = workspaces.compactMap(\.value).first(where: {
            $0.panes[choice.paneID]?.profile.connectionKey == choice.hostKey &&
            $0.panes[choice.linkPaneID]?.profile.connectionKey == choice.linkHostKey
        }) else { throw RelayShepherdPushFailure.stale }
        let port = RelayAssistantDaemonMessaging(workspace: workspace)
        let recipient = try await port.recipient(choice.paneID)
        guard try await port.linkScope(choice.linkPaneID, choice.paneID) == choice.scope else { throw RelayShepherdPushFailure.stale }
        let revision = try await port.prepareShepherdLink(here: choice.linkPaneID, target: choice.paneID,
            scope: choice.scope, linkID: choice.linkID, expectedRevision: choice.revision)
        guard configurationEpoch == epoch else { throw RelayShepherdPushFailure.stale }
        let target = RelayShepherdPushTarget(registrationID: UUID().uuidString.lowercased(),
            paneID: choice.paneID.uuidString.lowercased(), linkPaneID: choice.linkPaneID.uuidString.lowercased(),
            hostKey: choice.hostKey, linkHostKey: choice.linkHostKey, linkID: choice.linkID, linkRevision: revision,
            scope: choice.scope, recipient: .init(provider: recipient.provider, sessionID: recipient.sessionID, pid: recipient.pid,
                start: recipient.start, socketIdentity: recipient.socketIdentity, transport: recipient.transport))
        let checker = RelayShepherdDaemonPushTransport(resolve: { [weak self] in self?.workspace(for: $0) })
        guard try await checker.revalidate(target), configurationEpoch == epoch else { throw RelayShepherdPushFailure.stale }
        var settings = ledger.settings; settings.target = target
        try configure(settings, origin: origin)
    }
}

enum RelayShepherdPushFailure: Error { case stale }

@MainActor final class RelayShepherdDaemonPushTransport: RelayShepherdPushTransport {
    let resolve: @MainActor (RelayShepherdPushTarget) -> WorkspaceModel?
    init(resolve: @escaping @MainActor (RelayShepherdPushTarget) -> WorkspaceModel?) { self.resolve = resolve }
    func revalidate(_ target: RelayShepherdPushTarget) async throws -> Bool {
        guard target.valid, let workspace = resolve(target),
              let id = UUID(uuidString: target.paneID), let anchor = UUID(uuidString: target.linkPaneID),
              let pane = workspace.panes[id], pane.profile.connectionKey == target.hostKey,
              workspace.panes[anchor]?.profile.connectionKey == target.linkHostKey else { return false }
        let port = RelayAssistantDaemonMessaging(workspace: workspace)
        guard try await port.linkScope(anchor, id) == target.scope else { return false }
        let recipient = try await port.recipient(id)
        guard recipient == RelayAssistantRecipient(provider: target.recipient.provider, sessionID: target.recipient.sessionID,
            pid: target.recipient.pid, start: target.recipient.start, socketIdentity: target.recipient.socketIdentity,
            transport: target.recipient.transport) else { return false }
        // The daemon also compares the saved revision under its communication
        // lock immediately before the existing durable claim/native delivery.
        return resolve(target) != nil
    }
    func send(_ envelope: RelayShepherdPushEnvelope, allowed: @escaping @MainActor () -> Bool) async throws -> Data {
        guard envelope.valid, let workspace = resolve(envelope.target),
              let id = UUID(uuidString: envelope.target.paneID), let pane = workspace.panes[id],
              pane.profile.connectionKey == envelope.target.hostKey else { throw RelayShepherdPushFailure.stale }
        let response = try await RelayPaneMessaging.shared.daemonRequest(profile: pane.profile,
            packet: envelope.packet, beforeTransport: allowed)
        return try JSONSerialization.data(withJSONObject: response)
    }
}
