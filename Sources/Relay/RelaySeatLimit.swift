import Foundation
import SwiftUI

/// A Claude pane's agent was refused with a seat/usage limit (HTTP 429).
/// relayd's status line reads the refusal row from the conversation's
/// transcript and sends it as a "SeatLimit" agent event; Claude itself fires
/// no Stop hook for that turn.
struct RelaySeatLimitEvent: Codable, Equatable, Sendable {
    var paneID: UUID
    var host: String
    /// five_hour, seven_day, seven_day_<model>, model or unknown
    var kind: String
    /// "Fable" for a model-specific limit.
    var model: String?
    var resetsAt: Date?
    /// The transcript row's own ID.
    var rowID: String
    var sessionID: String?
    var text: String
    var occurredAt: Date
    /// The pane's account label when the event arrived.
    var account: String?

    /// The relayd event's fields; nil for anything malformed. A pane worker
    /// started before relayd learned SeatLimit keeps only `message`,
    /// `session_id` and `occurred_at` in its journal; the window and reset are
    /// then read from Claude's own notice text.
    static func parse(_ event: [String: Any], paneID: UUID, host: String, account: String?) -> Self? {
        guard event["hook_event_name"] as? String == "SeatLimit" else { return nil }
        let text = String((event["message"] as? String ?? "").prefix(300))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let raw = event["occurred_at"] as? String ?? ""
        guard let at = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return nil }
        let fromText = textLimit(text)
        var kind = event["limit_kind"] as? String ?? fromText?.kind ?? ""
        if event["limit_kind"] == nil, fromText == nil { return nil }
        guard kind.range(of: #"^[a-z0-9_]{1,40}$"#, options: .regularExpression) != nil else { return nil }
        if kind == "unknown", let fromText { kind = fromText.kind }
        let row = (event["seat_limit_id"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 80 ? nil : $0 }
            ?? "text:" + String(raw.prefix(60))
        let reset = (event["resets_at"] as? NSNumber).map(\.doubleValue)
            .flatMap { $0 > 0 && $0 < 253_402_300_800 ? Date(timeIntervalSince1970: $0) : nil }
            ?? resetFromText(text, after: at)
        let model = (event["limit_model"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 40 ? nil : $0 } ?? fromText?.model
        let session = (event["session_id"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 128 ? nil : $0 }
        return .init(paneID: paneID, host: host, kind: kind, model: model, resetsAt: reset, rowID: row, sessionID: session,
                     text: text, occurredAt: at, account: account)
    }

    /// "You've hit your session/5-hour/weekly limit", "You've reached your Fable limit".
    static func textLimit(_ text: String) -> (kind: String, model: String?)? {
        guard let match = text.range(of: #"(?i)you'?ve (hit|reached) your (.{1,40}?) limit"#, options: .regularExpression) else { return nil }
        var name = String(text[match])
        for prefix in ["you've hit your ", "you've reached your ", "youve hit your ", "youve reached your "] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        name = String(name.dropLast(" limit".count)).trimmingCharacters(in: .whitespaces)
        switch name.lowercased() {
        case "session", "5-hour", "five-hour": return ("five_hour", nil)
        case "weekly": return ("seven_day", nil)
        default: return ("model", name)
        }
    }

    /// "resets 3:10pm (Europe/Copenhagen)", "resets 9am (…)", "resets Nov 22,
    /// 9am (…)" or "resets Nov 5 at 1am (…)": the first such time after `after`.
    static func resetFromText(_ text: String, after: Date) -> Date? {
        let pattern = #"resets (?:([A-Z][a-z]{2}) (\d{1,2})(?:,| at) )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?: \(([A-Za-z_]+(?:/[A-Za-z_+\-]+)*)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
        var calendar = Calendar(identifier: .gregorian)
        if let zone = group(6) {
            guard let tz = TimeZone(identifier: zone) else { return nil }
            calendar.timeZone = tz
        } else {
            calendar.timeZone = TimeZone(identifier: "UTC")!
        }
        guard let hour12 = group(3).flatMap(Int.init), (1...12).contains(hour12) else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        guard minute < 60 else { return nil }
        let hour = hour12 % 12 + (group(5)?.lowercased() == "pm" ? 12 : 0)
        var parts = calendar.dateComponents([.year, .month, .day], from: after)
        parts.hour = hour; parts.minute = minute; parts.second = 0
        if let month = group(1) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let index = months.firstIndex(of: month.lowercased()), let day = group(2).flatMap(Int.init),
                  (1...31).contains(day) else { return nil }
            parts.month = index + 1; parts.day = day
            guard var date = calendar.date(from: parts) else { return nil }
            if date <= after { date = calendar.date(byAdding: .year, value: 1, to: date) ?? date }
            return date
        }
        guard var date = calendar.date(from: parts) else { return nil }
        if date <= after { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    /// "weekly", "5-hour", "Fable": how the notification names the limit.
    var limitName: String {
        if kind == "five_hour" { return "5-hour" }
        if kind == "seven_day" { return "weekly" }
        if kind.hasPrefix("seven_day_") {
            return "weekly " + (model ?? kind.dropFirst("seven_day_".count).capitalized)
        }
        return model ?? "usage"
    }

    /// One limit occurrence of one pane: its window and that window's reset.
    /// Claude writes a new refusal row for each retry inside the window.
    var occurrenceKey: String {
        let reset = resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "row:" + rowID
        return [paneID.uuidString.lowercased(), kind, model ?? "", reset].joined(separator: "|")
    }

    /// A refusal is news only shortly after Claude wrote it. relayd sends it
    /// within seconds; an older row is a resumed conversation's history (it
    /// may name another account) or a replay.
    static let freshness: TimeInterval = 30 * 60

    /// Whether the refusal still describes a current limit.
    func current(now: Date) -> Bool {
        if let resetsAt { return resetsAt > now }
        return now.timeIntervalSince(occurredAt) < 6 * 3600
    }
}

/// What Relay knows about the account a move would go to.
enum RelaySeatLimitTargetHealth: Equatable, Sendable {
    case available
    /// Known to be at a limit itself: never a move target.
    case limited(String)
    /// No usable reading: offered to the user, never moved to automatically.
    case unknown(String)
}

/// Pure decisions: which account to offer, why a move cannot run, and whether
/// Relay may move the pane itself.
enum RelaySeatLimitPolicy {
    /// Mythos Claude panes stay on personal (user rule); Sapropel is a
    /// protected session. Matched by the pane ID's first eight hex digits.
    static let pinnedPanes: [String: String?] = [
        "19b7955f": "personal", "08f63258": "personal", "6930ef7e": "personal", "767dc718": nil,
    ]

    /// Why the pane is protected from automatic moves, if it is.
    static func protection(_ pane: UUID, protectedList: [String]) -> String? {
        let id = pane.uuidString.lowercased()
        if let entry = pinnedPanes[String(id.prefix(8))] {
            return entry.map { "this pane must stay on \($0)" } ?? "this pane is a protected session"
        }
        if protectedList.contains(id) { return "this pane is protected in Relay's maintenance settings" }
        return nil
    }

    /// The account a pinned pane must stay on.
    static func pinnedAccount(_ pane: UUID) -> String? {
        pinnedPanes[String(pane.uuidString.lowercased().prefix(8))] ?? nil
    }

    /// The other account: the quota failover's source/target pair, else the
    /// host's only other Claude account. Never a guess.
    static func otherAccount(current: String?, registry: [RelayAgentAccount]?,
                             settings: RelayClaudeQuotaSettings) -> Result<RelayAgentAccount, Refusal> {
        guard let registry else { return .failure(.init("this host's Claude account list has not been read yet", retryable: true)) }
        guard let current else { return .failure(.init("Relay does not know which Claude account this pane uses")) }
        let accounts = registry.filter { $0.provider == "claude" && $0.isValid }
        let label: String?
        if current == settings.source { label = settings.target }
        else if current == settings.target { label = settings.source }
        else {
            let others = accounts.filter { $0.label != current }
            label = others.count == 1 ? others[0].label : nil
        }
        guard let label else { return .failure(.init("there is no single other Claude account on this host to move to")) }
        guard let account = accounts.first(where: { $0.label == label }), account.label != current else {
            return .failure(.init("this host has no Claude account named \(label)"))
        }
        return .success(account)
    }

    struct Refusal: Error, Equatable {
        let text: String
        var retryable = false
        init(_ text: String, retryable: Bool = false) { self.text = text; self.retryable = retryable }
    }

    struct Decision: Equatable {
        var target: RelayAgentAccount?
        /// Why neither the user's button nor Relay can move the pane.
        var moveRefusal: String?
        /// A note shown beside an available move (e.g. unknown usage).
        var note: String?
        /// Relay moves the pane itself now.
        var autoMove = false
        /// Why Relay does not move it itself although automatic moves are on.
        var autoHold: String?
        /// The hold may clear by itself (an account list or usage reading
        /// not yet available): the automatic lane keeps checking.
        var retryable = false
    }

    static func decide(target: Result<RelayAgentAccount, Refusal>, health: RelaySeatLimitTargetHealth,
                       pinned: String?, protection: String?, ruleHold: String?, automatic: Bool) -> Decision {
        var decision = Decision()
        switch target {
        case .failure(let refusal):
            decision.moveRefusal = refusal.text
            decision.retryable = refusal.retryable
            return decision
        case .success(let account):
            decision.target = account
        }
        if let pinned, decision.target?.label != pinned {
            decision.moveRefusal = (protection ?? "this pane must stay on \(pinned)") + "; Relay will not move it"
            return decision
        }
        switch health {
        case .limited(let reason):
            decision.moveRefusal = reason
            return decision
        case .unknown(let reason):
            decision.note = reason
        case .available:
            break
        }
        // A protected pane's offer says so whether or not automatic moves are on.
        if let protection { decision.autoHold = protection + "; it is never moved automatically"; return decision }
        guard automatic else { return decision }
        if let ruleHold { decision.autoHold = ruleHold }
        else if case .unknown(let reason) = health {
            decision.autoHold = "automatic moves need a current usage reading: " + reason
            decision.retryable = true
        }
        else { decision.autoMove = true }
        return decision
    }

    /// A workspace or host routing rule that names the pane's current account
    /// is the user's choice of account for it: no automatic move away.
    static func ruleHold(rules: RelayAgentAccountRules, host: String, workspace: UUID?, current: String?) -> String? {
        guard let current else { return nil }
        if let workspace, rules.workspaces[RelayAgentAccountRules.workspaceKey(workspace)]?["claude"] == current {
            return "agent_account_rules assign this workspace to \(current); it is not moved automatically"
        }
        if rules.hosts[host]?["claude"] == current {
            return "agent_account_rules assign this host to \(current); it is not moved automatically"
        }
        return nil
    }

    /// The target's usage reading as move evidence. A window at 100% or an
    /// earlier seat-limit refusal of that account (until its reset) is a limit.
    @MainActor static func health(usage: RelayAgentAccountUsage?, knownLimit: RelaySeatLimitLedger.Limit?, label: String,
                       now: Date) -> RelaySeatLimitTargetHealth {
        if let knownLimit, knownLimit.reset > now {
            return .limited("\(label) is also at its \(knownLimit.name) limit until " + RelaySeatLimitText.time(knownLimit.reset))
        }
        switch RelayClaudeQuotaScheduler.reading(usage, now: now, displayingUnreportedFiveHour: true) {
        case .failure(let unusable):
            return .unknown("\(label)'s usage is unknown (\(unusable.text))")
        case .success(let quota):
            if let full = quota.windows.first(where: { $0.value.used >= 100 }) {
                let name = full.key == "five_hour" ? "5-hour" : "weekly"
                return .limited("\(label) is also at its \(name) limit until " + RelaySeatLimitText.time(full.value.reset))
            }
            return .available
        }
    }
}

enum RelaySeatLimitText {
    static func time(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }

    /// "Claude in api-work hit the business weekly limit (resets Nov 22 09:00)."
    static func headline(_ event: RelaySeatLimitEvent, pane: String) -> String {
        let account = event.account.map { $0 + " " } ?? ""
        let reset = event.resetsAt.map { " (resets " + time($0) + ")" } ?? ""
        return "Claude in \(pane) hit the \(account)\(event.limitName) limit\(reset)."
    }
}

/// Durable once-per-occurrence record and the accounts known to be limited.
struct RelaySeatLimitLedger: Codable, Equatable, Sendable {
    struct Limit: Codable, Equatable, Sendable {
        var reset: Date
        var name: String
    }
    var version = 1
    /// Occurrence and row keys → when they may be forgotten.
    var seen: [String: Date] = [:]
    /// "host|label" → a limit that account hit.
    var limits: [String: Limit] = [:]

    static func accountKey(host: String, label: String) -> String { host + "|" + label }

    /// True exactly once per limit occurrence of a pane, and never for a
    /// refusal that no longer describes a current limit (a replayed event or
    /// a resumed transcript's old row).
    mutating func admit(_ event: RelaySeatLimitEvent, now: Date) -> Bool {
        seen = seen.filter { $0.value > now }
        guard event.current(now: now), now.timeIntervalSince(event.occurredAt) < RelaySeatLimitEvent.freshness else { return false }
        let occurrence = event.occurrenceKey
        let row = "row|" + event.paneID.uuidString.lowercased() + "|" + event.rowID
        guard seen[occurrence] == nil, seen[row] == nil else { return false }
        let forget = max(event.resetsAt ?? now.addingTimeInterval(6 * 3600), now).addingTimeInterval(86_400)
        seen[occurrence] = forget
        seen[row] = forget
        if seen.count > 2048 {
            for key in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - 2048).map(\.key) { seen[key] = nil }
        }
        // A model-specific limit does not stop the account's other models.
        if let account = event.account, event.kind != "model" {
            limits = limits.filter { $0.value.reset > now }
            limits[Self.accountKey(host: event.host, label: account)] =
                .init(reset: event.resetsAt ?? now.addingTimeInterval(3600), name: event.limitName)
        }
        return true
    }

    func limit(host: String, label: String, now: Date) -> Limit? {
        limits[Self.accountKey(host: host, label: label)].flatMap { $0.reset > now ? $0 : nil }
    }
}

/// Receives seat-limit events, notifies once per occurrence, offers the move
/// and, when the user turned automatic moves on, moves the pane through the
/// existing account move with all of its checks. Nothing here selects or
/// focuses a pane; only clicking the notification does.
@MainActor final class RelaySeatLimitCoordinator: ObservableObject {
    static let shared = RelaySeatLimitCoordinator()

    struct Offer: Identifiable, Equatable {
        var id: UUID { event.paneID }
        var event: RelaySeatLimitEvent
        var paneName: String
        var decision: RelaySeatLimitPolicy.Decision
        /// The latest move progress or result.
        var status: String?
        var moving = false
        var inboxID: String?
    }

    @Published private(set) var offers: [UUID: Offer] = [:]
    private(set) var ledger: RelaySeatLimitLedger
    private let url: URL?
    private weak var workspace: WorkspaceModel?
    private struct Intent: Equatable { let pane: UUID; let label: String; let dir: String; let account: String?; let session: String? }
    /// One exact intent per pane: a limit hits every pane of an account at once.
    private var intents: [UUID: Intent] = [:]
    private var refreshes: [String: Task<Void, Never>] = [:]
    private var autoTasks: [UUID: Task<Void, Never>] = [:]
    var autoRetryInterval: TimeInterval = 30
    var autoAttempts = 40
    /// Tests replace the move and the usage refresh.
    var mover: @MainActor (PaneModel, WorkspaceModel, RelayAgentAccount, RelayAgentAccountMoveOrigin) async -> RelayAgentAccountMove.Outcome = {
        pane, workspace, target, origin in
        await RelayAgentAccountMove.shared.move(pane, in: workspace, to: target, origin: origin, inputGranted: origin == .user)
    }
    var refreshUsage: @MainActor (ConnectionProfile) async -> Void = { profile in
        _ = try? await RelayAgentAccountDirectory.shared.refreshUsage(profile, provider: "claude")
    }
    var automaticEnabled: () -> Bool = { RelayPreferences.shared.seatLimitAutoMove }
    var notify: @MainActor (AgentInboxEvent) -> String? = { AgentIntelligenceStore.shared.record($0) }

    init(url: URL? = nil) {
        let testing = RelayLaunchMode.isRunningTests
        self.url = url ?? (testing ? nil : RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/AgentAccounts/seat-limits-v1.json"))
        if let path = self.url, let data = try? Data(contentsOf: path), data.count <= 1 << 20,
           let decoded = try? JSONDecoder().decode(RelaySeatLimitLedger.self, from: data) {
            ledger = decoded
        } else {
            ledger = .init()
        }
    }

    func install(workspace: WorkspaceModel) { self.workspace = workspace }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        SecureFiles.restrictToOwner(url)
    }

    /// A pane's agent event named "SeatLimit".
    func observe(_ raw: [String: Any], pane: PaneModel, workspace: WorkspaceModel? = nil, now: Date = Date()) {
        guard pane.kind == .claude || pane.agentAccount?.recorded?.provider == "claude" else { return }
        let host = RelayAgentAccountDirectory.hostKey(pane.profile)
        let account = pane.agentAccount?.recorded.flatMap { $0.provider == "claude" ? $0.label : nil }
        guard let event = RelaySeatLimitEvent.parse(raw, paneID: pane.id, host: host, account: account),
              ledger.admit(event, now: now) else { return }
        save()
        if let workspace { self.workspace = workspace }
        let offer = Offer(event: event, paneName: pane.displayName, decision: evaluate(event, pane: pane, now: now))
        offers[pane.id] = offer
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Readings older than two minutes are not move evidence.
            await self.refresh(pane.profile)
            guard var current = self.offers[pane.id], current.event == event else { return }
            current.decision = self.evaluate(event, pane: pane, now: Date())
            // The banner reads this offer while the entry is recorded.
            self.offers[pane.id] = current
            let inboxID = self.notify(self.inboxEvent(current))
            self.offers[pane.id]?.inboxID = inboxID
            if current.decision.autoMove || self.automaticEnabled() && current.decision.retryable { self.startAutomatic(pane.id) }
        }
    }

    /// Tests replace the host facts (registry, usage, rules) behind a decision.
    var decider: (@MainActor (RelaySeatLimitEvent, PaneModel, Date) -> RelaySeatLimitPolicy.Decision)?

    func evaluate(_ event: RelaySeatLimitEvent, pane: PaneModel, now: Date) -> RelaySeatLimitPolicy.Decision {
        if let decider { return decider(event, pane, now) }
        let directory = RelayAgentAccountDirectory.shared
        let registry = directory.registeredAccounts(for: pane.profile, provider: "claude")
        let current = pane.agentAccount?.recorded.flatMap { $0.provider == "claude" ? $0.label : nil } ?? event.account
        let target = RelaySeatLimitPolicy.otherAccount(current: current, registry: registry,
                                                       settings: RelayPreferences.shared.claudeQuotaFailover)
        var health = RelaySeatLimitTargetHealth.unknown("no account")
        if case .success(let account) = target {
            health = RelaySeatLimitPolicy.health(usage: directory.usage(for: pane.profile, account: account),
                knownLimit: ledger.limit(host: event.host, label: account.label, now: now), label: account.label, now: now)
        }
        let workspaceID = workspace.flatMap { model in model.tabID(containingPane: pane.id).flatMap(model.workspaceID(forTab:)) }
        return RelaySeatLimitPolicy.decide(target: target, health: health, pinned: RelaySeatLimitPolicy.pinnedAccount(pane.id),
            protection: RelaySeatLimitPolicy.protection(pane.id, protectedList: RelayPreferences.shared.maintenanceProtectedPanes),
            ruleHold: RelaySeatLimitPolicy.ruleHold(rules: RelayAgentAccountRouting.shared.rules, host: event.host,
                                                    workspace: workspaceID, current: current),
            automatic: automaticEnabled())
    }

    /// The inbox entry: the pane link is the entry itself.
    func inboxEvent(_ offer: Offer) -> AgentInboxEvent {
        var detail = RelaySeatLimitText.headline(offer.event, pane: offer.paneName)
        if let refusal = offer.decision.moveRefusal {
            detail += " Relay cannot move it: " + refusal + "."
        } else if let target = offer.decision.target {
            detail += " Move to \(target.label)?"
            if let note = offer.decision.note { detail += " (" + note + ")" }
            if offer.decision.autoMove { detail += " Moving it automatically when the move's checks allow." }
            else if let hold = offer.decision.autoHold { detail += " Not moved automatically: " + hold + "." }
            else if !automaticEnabled() { detail += " You can let Relay move such panes automatically." }
        }
        return AgentInboxEvent(paneID: offer.event.paneID, host: offer.event.host, provider: .claude, kind: .attention,
            title: Self.inboxTitlePrefix + offer.event.limitName + (offer.event.account.map { " (\($0))" } ?? ""),
            detail: detail, occurredAt: offer.event.occurredAt,
            sourceID: "seat-limit:" + offer.event.occurrenceKey, alert: .needsInput)
    }

    static let inboxTitlePrefix = "Seat limit: "

    /// The offer behind an inbox item, for the banner's actions. The banner is
    /// posted while the item is recorded, before its ID is returned.
    func offer(for item: AgentInboxItem) -> Offer? {
        guard item.kind == .attention, item.title.hasPrefix(Self.inboxTitlePrefix) else { return nil }
        return offers[item.paneID]
    }

    /// Exact authority for one automatic move, checked twice by the mover:
    /// before anything is read, and against the native agent it inspected.
    func authorizes(_ pane: UUID, target: RelayAgentAccount, proof: RelayAgentMaintenanceProbe? = nil) -> Bool {
        guard let intent = intents[pane], target.provider == "claude", target.label == intent.label,
              target.dir == intent.dir, automaticEnabled() else { return false }
        guard let proof else { return true }
        guard proof.valid(for: pane), proof.provider == "claude" else { return false }
        if let session = intent.session, proof.sessionID != session { return false }
        // Still on the account that hit the limit: a replayed event never
        // moves a pane that is already elsewhere.
        if let account = intent.account, let pane = workspace?.panes[pane], let dir = proof.configDir {
            return RelayAgentAccountDirectory.shared.label(for: pane.profile, provider: "claude", observedDirectory: dir) == account
        }
        return intent.account == nil
    }

    // MARK: Actions (each one the user's click, except the automatic lane)

    /// The notification's "Move to …": the user's own move, same checks and
    /// receipts as the Agent Accounts menu.
    func moveNow(_ paneID: UUID) {
        guard var offer = offers[paneID], !offer.moving else { return }
        guard let workspace, let pane = workspace.panes[paneID] else {
            offer.status = "The pane is no longer open."; offers[paneID] = offer; return
        }
        offer.decision = evaluate(offer.event, pane: pane, now: Date())
        guard let target = offer.decision.target, offer.decision.moveRefusal == nil else {
            offer.status = "Relay cannot move it: " + (offer.decision.moveRefusal ?? "no other account") + "."
            offers[paneID] = offer; return
        }
        autoTasks[paneID]?.cancel()
        offer.moving = true
        offer.status = "Moving to \(target.label)…"
        offers[paneID] = offer
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.mover(pane, workspace, target, .user)
            self.finished(paneID, target: target, outcome: outcome, automatic: false)
        }
    }

    /// The notification's offer to turn automatic moves on.
    func enableAutomatic() {
        RelayPreferences.shared.seatLimitAutoMove = true
        for id in Array(offers.keys) {
            guard var offer = offers[id], let pane = workspace?.panes[id] else { continue }
            offer.decision = evaluate(offer.event, pane: pane, now: Date())
            offers[id] = offer
            if offer.decision.autoMove || offer.decision.retryable { startAutomatic(id) }
        }
    }

    func dismiss(_ paneID: UUID) {
        autoTasks[paneID]?.cancel()
        autoTasks[paneID] = nil
        offers[paneID] = nil
    }

    func startAutomatic(_ paneID: UUID) {
        guard autoTasks[paneID] == nil else { return }
        autoTasks[paneID] = Task { @MainActor [weak self] in
            await self?.runAutomatic(paneID)
            self?.autoTasks[paneID] = nil
        }
    }

    /// One move() per attempt. Only a deferred outcome (nothing was sent) is
    /// tried again; refused, held and unknown outcomes end the lane.
    func runAutomatic(_ paneID: UUID) async {
        var last = "automatic moves are off"
        for attempt in 0..<autoAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(autoRetryInterval * 1e9))
                if let profile = workspace?.panes[paneID]?.profile { await refresh(profile) }
            }
            guard !Task.isCancelled, var offer = offers[paneID], !offer.moving, offer.event.current(now: Date()) else { return }
            guard let workspace, let pane = workspace.panes[paneID] else {
                offer.status = "The pane is no longer open."; offers[paneID] = offer; return
            }
            offer.decision = evaluate(offer.event, pane: pane, now: Date())
            guard offer.decision.autoMove, let target = offer.decision.target else {
                last = offer.decision.moveRefusal ?? offer.decision.autoHold ?? "automatic moves are off"
                if offer.decision.retryable, automaticEnabled() {
                    offer.status = "Waiting to move automatically: " + last + "."
                    offers[paneID] = offer
                    continue
                }
                stopped(paneID, reason: last)
                return
            }
            offer.moving = true
            offer.status = "Moving to \(target.label) automatically…"
            offers[paneID] = offer
            intents[paneID] = .init(pane: paneID, label: target.label, dir: target.dir, account: offer.event.account, session: offer.event.sessionID)
            let outcome = await mover(pane, workspace, target, .seatLimit)
            intents[paneID] = nil
            if outcome.state == "deferred" {
                guard var waiting = offers[paneID] else { return }
                waiting.moving = false
                last = outcome.displayMessage
                waiting.status = "Waiting to move automatically: " + last
                offers[paneID] = waiting
                continue
            }
            finished(paneID, target: target, outcome: outcome, automatic: true)
            return
        }
        stopped(paneID, reason: "still not possible after \(autoAttempts) checks: " + last)
    }

    /// The automatic lane ended without a move: the card and the inbox say why.
    private func stopped(_ paneID: UUID, reason: String) {
        guard var offer = offers[paneID] else { return }
        offer.moving = false
        offer.status = "Not moved automatically: " + reason
        offers[paneID] = offer
        _ = notify(AgentInboxEvent(paneID: paneID, host: offer.event.host, provider: .claude, kind: .failure,
            title: "Seat limit: \(offer.paneName) was not moved",
            detail: RelaySeatLimitText.headline(offer.event, pane: offer.paneName) + " Relay did not move it automatically: " + reason,
            sourceID: "seat-limit-stopped:" + offer.event.occurrenceKey, alert: .needsInput))
    }

    /// One usage refresh per host at a time; panes on one host share it.
    private func refresh(_ profile: ConnectionProfile) async {
        let host = RelayAgentAccountDirectory.hostKey(profile)
        if let running = refreshes[host] { await running.value; return }
        let task = Task { @MainActor [refreshUsage] in await refreshUsage(profile) }
        refreshes[host] = task
        await task.value
        refreshes[host] = nil
    }

    private func finished(_ paneID: UUID, target: RelayAgentAccount, outcome: RelayAgentAccountMove.Outcome, automatic: Bool) {
        guard var offer = offers[paneID] else { return }
        offer.moving = false
        if outcome.state == "verified" {
            offers[paneID] = nil
            let how = automatic ? "Relay moved" : "Moved"
            _ = notify(AgentInboxEvent(paneID: paneID, host: offer.event.host, provider: .claude, kind: .completion,
                title: "\(how) \(offer.paneName) to \(target.label)",
                detail: "\(how) Claude in \(offer.paneName) to \(target.label) after it hit the " +
                    (offer.event.account.map { $0 + " " } ?? "") + offer.event.limitName + " limit; the same conversation continues there.",
                sourceID: "seat-limit-moved:" + offer.event.occurrenceKey, alert: automatic ? .done : nil))
            return
        }
        offers[paneID] = offer
        if automatic { stopped(paneID, reason: "the move was \(outcome.state): " + outcome.displayMessage); return }
        offers[paneID]?.status = "Move \(outcome.state): " + outcome.displayMessage
    }

    // Test support
    func resetForTesting() {
        ledger = .init(); offers = [:]; intents = [:]
        autoTasks.values.forEach { $0.cancel() }; autoTasks = [:]
    }
    func setIntentForTesting(pane: UUID, target: RelayAgentAccount) {
        intents[pane] = .init(pane: pane, label: target.label, dir: target.dir, account: nil, session: nil)
    }
}

/// The sidebar's seat-limit offers: the pane link, the move, and the offer to
/// move such panes automatically. Rendering never selects a pane.
struct RelaySeatLimitOffersView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var coordinator = RelaySeatLimitCoordinator.shared
    @ObservedObject private var preferences = RelayPreferences.shared

    var body: some View {
        let offers = coordinator.offers.values.sorted { $0.event.occurredAt > $1.event.occurredAt }
        if !offers.isEmpty {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                ForEach(offers) { offer in row(offer) }
            }
            .padding(.bottom, RelayTheme.spacing(6))
            .accessibilityIdentifier("relay.sidebar.seat-limits")
        }
    }

    private func row(_ offer: RelaySeatLimitCoordinator.Offer) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
            Button {
                workspace.revealPane(offer.event.paneID, origin: .user)
            } label: {
                Label(RelaySeatLimitText.headline(offer.event, pane: offer.paneName), systemImage: "gauge.with.dots.needle.100percent")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .help("Go to the pane")
            if let refusal = offer.decision.moveRefusal {
                Text("Cannot move: " + refusal).font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.coral)
            } else if let hold = offer.decision.autoHold {
                Text("Not moved automatically: " + hold).font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
            } else if let note = offer.decision.note {
                Text(note).font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
            }
            if let status = offer.status {
                Text(status).font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted).lineLimit(3)
            }
            HStack(spacing: RelayTheme.spacing(6)) {
                if let target = offer.decision.target, offer.decision.moveRefusal == nil {
                    Button("Move to \(target.label)") { coordinator.moveNow(offer.event.paneID) }
                        .disabled(offer.moving)
                }
                if !preferences.seatLimitAutoMove {
                    Button("Move automatically from now on") { coordinator.enableAutomatic() }
                }
                Button("Dismiss") { coordinator.dismiss(offer.event.paneID) }
            }
            .buttonStyle(RelayQuietButtonStyle())
            .font(RelayTheme.font(size: 10, weight: .medium))
        }
        .padding(.horizontal, RelayTheme.spacing(8))
        .padding(.vertical, RelayTheme.spacing(5))
        .background(RelayTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
    }
}
