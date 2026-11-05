import AppKit
import Foundation

// Cross-host pane links requested by a remote pane are PROPOSALS, never
// creations. The remote relay-mcp proves its pane with a single-use relayd
// attestation bound to the operation, the source pane, the target pane and the
// proposal id. This type spends it on the source pane's own host, rejects any
// mismatch between the attested pane and the claimed source, shows a native
// confirmation naming both panes and both hosts, and calls
// RelayPaneMessaging.connect only on the user's Allow. It adds no authority to
// the installation-wide `.layout` grant and never reads it.

enum RelayPaneLinkStatus: String, Sendable {
    case pending, approved, denied, expired
}

/// A snapshot of one pane as the confirmation shows it. `instance` is the
/// identity of the live pane object, so a closed and reopened pane with the
/// same id does not pass for the one that was confirmed.
struct RelayPaneLinkPane: Equatable {
    let id: UUID
    let displayName: String
    let profile: ConnectionProfile
    let instance: AnyHashable
    let isAgentTerminal: Bool

    var hostLabel: String {
        profile.host.isEmpty || profile.host == profile.name ? profile.name : "\(profile.name) (\(profile.host))"
    }

    @MainActor init?(_ pane: PaneModel?) {
        guard let pane else { return nil }
        id = pane.id
        displayName = pane.displayName
        profile = pane.profile
        instance = AnyHashable(ObjectIdentifier(pane))
        isAgentTerminal = pane.contentKind == .terminal
    }

    init(id: UUID, displayName: String, profile: ConnectionProfile, instance: AnyHashable = 0, isAgentTerminal: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.profile = profile
        self.instance = instance
        self.isAgentTerminal = isAgentTerminal
    }
}

struct RelayPaneLinkPrompt: Equatable {
    let source: RelayPaneLinkPane
    let target: RelayPaneLinkPane
    let timeout: TimeInterval

    var title: String { "Allow an agent to link two panes across hosts?" }

    /// Names both panes and both hosts, and what the link allows.
    var text: String {
        "Requested by the agent in the source pane.\n\n" +
        "Source pane: \(source.displayName)\nSource host: \(source.hostLabel)\n\n" +
        "Target pane: \(target.displayName)\nTarget host: \(target.hostLabel)\n\n" +
        "Allow lets these two panes send messages to each other through Relay (saved messaging link). " +
        "It does not restart either agent or grant any other permission. " +
        "Deny is the default; with no answer this request expires as denied in \(Int(timeout)) seconds."
    }
}

enum RelayPaneLinkDecision: Equatable {
    case allow, deny, timedOut, unavailable
}

/// Injectable so tests can supply a fake. There is no implementation that
/// answers on its own.
@MainActor
protocol RelayPaneLinkConfirming: AnyObject {
    func confirm(_ prompt: RelayPaneLinkPrompt, timeout: TimeInterval) async -> RelayPaneLinkDecision
}

/// The native confirmation: a sheet with Deny (the default button) and Allow.
@MainActor
final class RelayPaneLinkAlertConfirmer: RelayPaneLinkConfirming {
    typealias Presenter = (NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool
    private let present: Presenter

    init(present: Presenter? = nil) {
        self.present = present ?? { alert, completion in
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ??
                    NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  window.attachedSheet == nil else { return false }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: completion)
            return true
        }
    }

    private final class Once {
        var done = false
    }

    func confirm(_ prompt: RelayPaneLinkPrompt, timeout: TimeInterval) async -> RelayPaneLinkDecision {
        guard timeout > 0 else { return .timedOut }
        let alert = RelayTheme.alert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.text
        alert.addButton(withTitle: "Deny")   // first button: the default (Return)
        alert.addButton(withTitle: "Allow")
        alert.buttons[1].keyEquivalent = ""  // Allow is never a key equivalent
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<RelayPaneLinkDecision, Never>) in
            let finish: @MainActor (RelayPaneLinkDecision) -> Void = { decision in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: decision)
            }
            let shown = present(alert) { response in
                Task { @MainActor in finish(response == .alertSecondButtonReturn ? .allow : .deny) }
            }
            guard shown else { finish(.unavailable); return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !once.done else { return }
                finish(.timedOut)
                if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
            }
        }
    }
}

@MainActor
final class RelayPaneLinkProposals {
    static let path = "/api/pane-link-proposals"
    static let prefix = "relay-pane-link-proposal-v1"
    /// Stands in for the target of a status read; a reserved id, not a pane.
    static let statusInboxID = "a5515700-0000-4000-8000-00000000b0c6"
    static let expiry: TimeInterval = 120
    static let tableLimit = 64
    static let rateLimit = 5
    static let rateWindow: TimeInterval = 600
    static let retention: TimeInterval = 3600
    static let bodyLimit = 4 << 10

    typealias Redeem = @MainActor (ConnectionProfile, [String: Any]) async throws -> [String: Any]
    /// Creates the link. The third argument is the commit guard: the connector must run it
    /// at its commit boundary with no await between it and the write, and write nothing if
    /// it returns false.
    typealias Connect = @MainActor (UUID, UUID, @escaping @MainActor () -> Bool) async throws -> Void

    struct Refusal: Error {
        let status: Int
        let message: String
    }

    struct Entry {
        let id: UUID
        let source: RelayPaneLinkPane
        let target: RelayPaneLinkPane
        let caller: String
        let deadline: Date
        var status: RelayPaneLinkStatus = .pending
        var reason: String?
        var decided: Date?
        /// Set once Allow is being applied, so nothing else can resolve or expire it.
        var applying = false
    }

    private let confirmer: RelayPaneLinkConfirming
    private let lookup: @MainActor (UUID) -> RelayPaneLinkPane?
    private let redeem: Redeem
    private let connect: Connect
    private let policyPermits: @MainActor (String) -> Bool
    private let now: () -> Date
    private(set) var entries: [UUID: Entry] = [:]
    private var stamps: [UUID: [Date]] = [:]
    private var resolutions: [UUID: Task<Void, Never>] = [:]
    private var queueTail: Task<Void, Never>?

    init(confirmer: RelayPaneLinkConfirming,
         lookup: @escaping @MainActor (UUID) -> RelayPaneLinkPane?,
         redeem: Redeem? = nil,
         connect: @escaping Connect,
         policyPermits: @escaping @MainActor (String) -> Bool,
         now: @escaping () -> Date = Date.init) {
        self.confirmer = confirmer
        self.lookup = lookup
        self.redeem = redeem ?? { profile, packet in try await RelayPaneMessaging.shared.daemonRequest(profile: profile, packet: packet) }
        self.connect = connect
        self.policyPermits = policyPermits
        self.now = now
    }

    static func canonicalText(op: String, source: UUID, target: UUID?, proposal: UUID) -> String {
        let s = source.uuidString.lowercased(), p = proposal.uuidString.lowercased()
        if op == "status" { return prefix + "\nstatus\n" + s + "\n" + p }
        return prefix + "\npropose\n" + s + "\n" + (target?.uuidString.lowercased() ?? "") + "\n" + p
    }

    /// Tests await the confirmation of one proposal.
    func resolution(of id: UUID) async { await resolutions[id]?.value }

    func handle(body: Data, caller: String) async -> (status: Int, value: [String: Any]) {
        guard caller != RelayCallerControl.assistantCaller else { return (403, ["error": "Miko cannot propose pane links."]) }
        do { return (200, try await run(body: body, caller: caller)) }
        catch let refusal as Refusal { return (refusal.status, ["error": refusal.message]) }
        catch { return (403, ["error": "The pane-link proof could not be verified."]) }
    }

    private func canonicalUUID(_ value: Any?) -> UUID? {
        guard let text = value as? String, let id = UUID(uuidString: text), text == id.uuidString.lowercased() else { return nil }
        return id
    }

    private func run(body: Data, caller: String) async throws -> [String: Any] {
        guard body.count <= Self.bodyLimit,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let op = object["op"] as? String, op == "propose" || op == "status",
              Set(object.keys) == (op == "propose"
                ? ["op", "proposal_id", "attestation_id", "source_pane_id", "target_pane_id"]
                : ["op", "proposal_id", "attestation_id", "source_pane_id"]),
              let proposalID = canonicalUUID(object["proposal_id"]),
              let sourceID = canonicalUUID(object["source_pane_id"]),
              let attestation = object["attestation_id"] as? String,
              attestation.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else {
            throw Refusal(status: 400, message: "Invalid pane-link proposal request.")
        }
        var targetID: UUID?
        if op == "propose" {
            guard let id = canonicalUUID(object["target_pane_id"]), id != sourceID else {
                throw Refusal(status: 400, message: "A proposal needs two distinct panes.")
            }
            targetID = id
        }
        guard policyPermits(caller) else { throw Refusal(status: 403, message: "This Relay caller is paused.") }
        guard let source = lookup(sourceID), source.isAgentTerminal, source.profile.backend == .relay else {
            throw Refusal(status: 403, message: "The source pane is not an open agent terminal in this Relay window.")
        }
        // Spend the proof first. Everything after it is about the PROVEN pane, so a
        // forged source can neither probe targets nor consume another pane's rate limit.
        let reply: [String: Any]
        do {
            reply = try await redeem(source.profile, ["operation": "attest_consume", "attestation_id": attestation,
                "source_pane_id": sourceID.uuidString.lowercased(),
                "pane_id": targetID?.uuidString.lowercased() ?? Self.statusInboxID,
                "message_id": proposalID.uuidString.lowercased(),
                "text": Self.canonicalText(op: op, source: sourceID, target: targetID, proposal: proposalID)])
        } catch {
            throw Refusal(status: 403, message: "The pane-link proof could not be verified: " + String(error.localizedDescription.prefix(160)))
        }
        guard reply["authority"] as? String == "relayd", let proof = reply["source"] as? [String: Any],
              proof["authentication"] as? String == "source_host_attested",
              proof["attestationID"] as? String == attestation,
              proof["paneID"] as? String == sourceID.uuidString.lowercased() else {
            throw Refusal(status: 403, message: "The pane-link proof did not match the claimed source pane.")
        }
        // The pane may have closed or been replaced during the round trip.
        guard lookup(sourceID) == source else { throw Refusal(status: 403, message: "The source pane changed during verification.") }
        if op == "status" { return try statusReply(proposalID: proposalID, sourceID: sourceID, caller: caller) }
        guard let targetID else { throw Refusal(status: 400, message: "A proposal needs a target pane.") }
        return try admit(proposalID: proposalID, source: source, targetID: targetID, caller: caller)
    }

    private func statusReply(proposalID: UUID, sourceID: UUID, caller: String) throws -> [String: Any] {
        expireStale()
        guard let entry = entries[proposalID], entry.source.id == sourceID, entry.caller == caller else {
            throw Refusal(status: 404, message: "No pane-link proposal from this pane has that id.")
        }
        return Self.reply(entry)
    }

    /// Whether linking these two panes crosses hosts, the same condition under which
    /// RelayPaneMessaging.connect leaves the same-daemon path for the legacy cross-host one.
    static func crossesHosts(_ a: RelayPaneLinkPane, _ b: RelayPaneLinkPane) -> Bool {
        a.profile.connectionKey != b.profile.connectionKey
    }

    /// A cross-host link requested through the Mac's own pane-link route. The caller token
    /// is the proposer's identity; there is no relayd attestation. Same table, rate limit,
    /// confirmation and commit guard as a remote proposal. Nothing is saved here.
    func proposeLocal(proposalID: UUID, sourceID: UUID, targetID: UUID, caller: String) -> (status: Int, value: [String: Any]) {
        do {
            guard sourceID != targetID else { throw Refusal(status: 400, message: "A proposal needs two distinct panes.") }
            guard policyPermits(caller) else { throw Refusal(status: 403, message: "This Relay caller is paused.") }
            guard let source = lookup(sourceID), source.isAgentTerminal else {
                throw Refusal(status: 403, message: "The source pane is not an open agent terminal in this Relay window.")
            }
            return (202, try admit(proposalID: proposalID, source: source, targetID: targetID, caller: caller))
        } catch let refusal as Refusal { return (refusal.status, ["error": refusal.message]) }
        catch { return (403, ["error": "The pane-link proposal could not be created."]) }
    }

    /// The proposer reads its own proposal's status; nobody else's.
    func statusLocal(proposalID: UUID, caller: String) -> (status: Int, value: [String: Any]) {
        do {
            expireStale()
            guard let entry = entries[proposalID], entry.caller == caller else {
                throw Refusal(status: 404, message: "No pane-link proposal from this caller has that id.")
            }
            return (200, Self.reply(entry))
        } catch let refusal as Refusal { return (refusal.status, ["error": refusal.message]) }
        catch { return (403, ["error": "The pane-link proposal could not be read."]) }
    }

    private func admit(proposalID: UUID, source: RelayPaneLinkPane, targetID: UUID, caller: String) throws -> [String: Any] {
        let sourceID = source.id
        expireStale()
        if let existing = entries[proposalID] {
            guard existing.source.id == sourceID, existing.caller == caller else {
                throw Refusal(status: 403, message: "That proposal id belongs to another caller.")
            }
            guard existing.target.id == targetID else {
                throw Refusal(status: 409, message: "That proposal id was already used for different content.")
            }
            return Self.reply(existing)   // idempotent retry: same proposal, same status
        }
        guard let target = lookup(targetID), target.isAgentTerminal else {
            throw Refusal(status: 404, message: "The target pane is not an open agent terminal in this Relay window.")
        }
        let pair: Set<UUID> = [sourceID, targetID]
        guard !entries.values.contains(where: { $0.status == .pending && Set([$0.source.id, $0.target.id]) == pair }) else {
            throw Refusal(status: 409, message: "A confirmation for this pair is already pending.")
        }
        let current = now()
        let recent = (stamps[sourceID] ?? []).filter { current.timeIntervalSince($0) < Self.rateWindow }
        guard recent.count < Self.rateLimit else {
            stamps[sourceID] = recent
            throw Refusal(status: 429, message: "Too many link proposals from this pane; try again later.")
        }
        guard entries.count < Self.tableLimit else { throw Refusal(status: 429, message: "Too many pane-link proposals are held.") }
        stamps[sourceID] = recent + [current]
        let entry = Entry(id: proposalID, source: source, target: target, caller: caller,
                          deadline: current.addingTimeInterval(Self.expiry))
        entries[proposalID] = entry
        // One prompt at a time: later proposals wait their turn but their clock is already running.
        let previous = queueTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.resolve(proposalID)
        }
        queueTail = task
        resolutions[proposalID] = task
        return Self.reply(entry)
    }

    /// Lazily expires pending proposals past their deadline and drops old decided ones.
    private func expireStale() {
        let current = now()
        for (id, entry) in entries {
            if entry.status == .pending, !entry.applying, current >= entry.deadline {
                finish(id, .expired, reason: "timed_out")
            } else if entry.status != .pending, let decided = entry.decided,
                      current.timeIntervalSince(decided) > Self.retention {
                entries[id] = nil
                resolutions[id] = nil
            }
        }
    }

    private func finish(_ id: UUID, _ status: RelayPaneLinkStatus, reason: String) {
        entries[id]?.status = status
        entries[id]?.reason = reason
        entries[id]?.decided = now()
        entries[id]?.applying = false
    }

    private func resolve(_ id: UUID) async {
        guard let entry = entries[id], entry.status == .pending else { return }
        let remaining = entry.deadline.timeIntervalSince(now())
        guard remaining > 0 else { finish(id, .expired, reason: "timed_out"); return }
        let decision = await confirmer.confirm(.init(source: entry.source, target: entry.target, timeout: Self.expiry), timeout: remaining)
        // Only a still-pending, not-yet-applying proposal can be resolved, and only once.
        guard let live = entries[id], live.status == .pending, !live.applying else { return }
        switch decision {
        case .deny: finish(id, .denied, reason: "user_denied")
        case .unavailable: finish(id, .denied, reason: "no_confirmation_window")
        case .timedOut: finish(id, .expired, reason: "timed_out")
        case .allow:
            guard now() < live.deadline else { finish(id, .expired, reason: "allowed_after_expiry"); return }
            entries[id]?.applying = true
            // Revalidate after the asynchronous confirmation: both panes must be the
            // same live panes on the same host profiles, and policy must still permit.
            guard lookup(live.source.id) == live.source, lookup(live.target.id) == live.target,
                  policyPermits(live.caller) else {
                finish(id, .denied, reason: "panes_changed_or_policy_revoked")
                return
            }
            // connect awaits endpoint discovery before it commits, so the check above can go
            // stale. The same comparison runs again at the commit boundary, inside connect.
            final class Flag { var set = false }
            let refused = Flag()
            let commitGuard: @MainActor () -> Bool = { [self] in
                let same = lookup(live.source.id) == live.source && lookup(live.target.id) == live.target &&
                    policyPermits(live.caller)
                if !same { refused.set = true }
                return same
            }
            do {
                try await connect(live.source.id, live.target.id, commitGuard)
                finish(id, refused.set ? .denied : .approved,
                       reason: refused.set ? "panes_changed_or_policy_revoked" : "user_allowed")
            } catch {
                finish(id, .denied, reason: refused.set ? "panes_changed_or_policy_revoked" : "link_not_created")
            }
        }
    }

    static func reply(_ entry: Entry) -> [String: Any] {
        var value: [String: Any] = ["proposal_id": entry.id.uuidString.lowercased(),
            "source_pane_id": entry.source.id.uuidString.lowercased(),
            "target_pane_id": entry.target.id.uuidString.lowercased(),
            "status": entry.applying ? RelayPaneLinkStatus.pending.rawValue : entry.status.rawValue]
        if let reason = entry.reason { value["reason"] = reason }
        return value
    }
}
