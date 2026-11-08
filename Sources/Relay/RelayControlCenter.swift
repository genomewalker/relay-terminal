import Combine
import Foundation
import SwiftUI

/// CC-S1: the Monitoring window's read-only Control section.
///
/// One view of every workspace → tab → pane from canonical ownership, with
/// Miko's recent exchanges, Shepherd reports, context-rotation state and
/// Claude account failover state. It is built only while the section shows
/// (RelayPaneHealthFeed), never calls RelayPaneHealthCoordinator.snapshot()
/// (which reads every pane's screen). This file only builds and shows state.
/// CC-S2's actions live in RelayControlCenterActions.swift; every one of them
/// calls an existing entry point and none is reachable from a tool or a route.
struct RelayControlCenterState: Equatable {
    struct ContextRoll: Equatable {
        /// supported, not_enrolled, unavailable or unverified.
        let state: String
        let reason: String
    }

    struct MikoExchange: Equatable {
        /// Miko's exchange id. For an agent ask this is the agent's request_id without dashes.
        let exchangeID: String
        /// The asking agent's own request_id (its ask and receipt calls), when the exchange is an agent ask.
        let requestID: String?
        let origin: String
        /// completed, failed, stopped, running or waiting_for_approval.
        let status: String
        /// A completed exchange whose handoff was sent but not yet confirmed.
        var awaitingConfirmation = false
        /// A completed exchange whose typed command is not confirmed to have run.
        var typedUnconfirmed = false
    }

    struct ShepherdNote: Equatable {
        let kind: String
        let text: String
    }

    struct EventCount: Equatable {
        let event: String
        let count: Int
    }

    struct AuditLine: Equatable {
        let event: String
        let at: Date
    }

    struct PaneFailover: Equatable {
        /// The failover journal's state for this pane (moving, away, returning, refused…), if it has a record.
        var journalState: String?
        var journalDetail: String?
        var notice: String?
        var latest: AuditLine?
        var counts: [EventCount] = []
    }

    /// One allowance reading. `actual_dashboard` is the provider's own account
    /// reading; `estimated_tokens` is an estimate and is never shown as actual.
    struct UsageReading: Equatable {
        let provenance: String
        let scope: String
        let window: String
        let usedPercent: Double
        let source: String?
        let readAt: String?
    }

    /// Item 6: usage and context-budget supervision, read-only.
    struct Supervision: Equatable {
        let enabled: String
        let enrollment: String
        let refreshCapability: String
        let lifecycle: String
        let promptEmpty: String
        /// Every reason management is blocked, verbatim from its source.
        let blocked: [String]
        let usage: [UsageReading]
        /// "management unavailable", or what is enrolled. Never "supervised" or "OK".
        let management: String
        /// Item 5: why Miko thinks this pane is expensive, and why it cannot (or will not yet) manage it.
        var signals: [String] = []
        var holds: [String] = []
        /// There is no per-chat allowance source; this says so and no percent is derived.
        var perChat: String = RelayBudgetSupervisor.perChatUnavailable
        var roll: RelayBudgetRollReceipt? = nil
    }

    /// The native capacity coordinator's cached status for a pane (no new read).
    struct CapacitySummary: Equatable {
        let state: String
        let reason: String
        let supported: Bool
        let managed: Bool
        let enabled: Bool
        let ready: Bool
        let contextEnabled: Bool
        let thresholdTokens: Int64
        let measuredTokens: Int64?
        let contextDue: Bool
        let operation: String?
        /// Accounts this pane's provider can be moved to (registered labels).
        let registeredAccounts: [String]
    }

    /// The harness's pending action card, as shown to the user.
    struct PendingCard: Equatable {
        let id: UUID
        let title: String
        let rows: [String]
        let literal: String?
        let blockedReason: String?
        let expiresAt: Date
        let origin: String
        /// The card's pane, when it targets one.
        let paneID: String?
    }

    struct Pane: Equatable {
        let id: String
        let name: String
        let hostKey: String
        let host: String
        let agent: String
        let phase: String
        let connection: String
        let account: String?
        let summary: String
        let context: ContextRoll
        let supervision: Supervision
        let miko: [MikoExchange]
        let shepherd: [ShepherdNote]
        let failover: PaneFailover
        var capacity: CapacitySummary? = nil
        var card: PendingCard? = nil
        var triage: RelayTaskTriage? = nil
    }

    struct Tab: Equatable {
        let id: String
        let name: String
        let panes: [Pane]
    }

    struct Workspace: Equatable {
        let id: String
        let name: String
        let isInbox: Bool
        let tabs: [Tab]
        /// Owned tabs this window does not show (another window, or a stale owner record).
        let otherWindowTabs: Int
    }

    struct Host: Equatable {
        let key: String
        let name: String
        let enabled: Bool
        /// This host's registered Claude accounts ("label · dir"); nil until its account list has been read.
        let accounts: [String]?
        /// Panes on this host per current account label.
        let current: [EventCount]
        /// The scheduler's latest waiting reason for this host, verbatim.
        let deferral: String?
        let usage: [String]
        let counts: [EventCount]
        let latest: AuditLine?
    }

    var workspaces: [Workspace] = []
    /// Tabs in this window with no ownership record, or whose owner record is missing.
    var unowned: [Tab] = []
    var hosts: [Host] = []
    /// Audit entries for panes not open in this window.
    var otherPanesAudit: [EventCount] = []
    var auditNote: String?
    var failoverSummary = ""
    var problem: String?
    var mikoPaused = false
    var callerPaused = false
    /// The assistant caller's audit permission; false stops Miko's tools and failover moves it started.
    var assistantCallerPermitted = true
    var pendingCard: PendingCard?
    var mikoBusy = false
    /// Item 5 notices still unresolved, newest first.
    var notices: [RelayBudgetNotice] = []
    var accountNoticePercent = RelayBudgetSupervisor.defaultAccountNoticePercent

    /// Queued agent asks live only in the side-panel server. They are not
    /// listed here, so an empty history must never be read as "none pending".
    static let askDisclosure = "Agent asks accepted by the side-panel server (queued or awaiting Miko) are not listed here; "
        + "an empty history does not mean no ask is pending. An ask made while Miko is busy is refused, not queued."

    static let empty = RelayControlCenterState()

    /// Whether the tree shows this pane (so its card renders under it, not at the top).
    func hasPane(_ id: String?) -> Bool {
        guard let id else { return false }
        return (workspaces.flatMap(\.tabs) + unowned).contains { $0.panes.contains { $0.id == id } }
    }

    // MARK: Inputs

    struct PaneInput {
        var row: RelaySidePanelState.Pane
        var hostKey: String
        var isClaude: Bool
        /// The pane's account reading from the provider, if any.
        var accountUsage: RelayAgentAccountUsage? = nil
        /// Token-based estimates; there is no live producer in this tree.
        var estimates: [UsageReading] = []
        /// prompt_empty from an existing health fact; the Control section never reads a screen for it.
        var promptEmpty: Bool? = nil
        var plans: [AgentTaskPlan] = []
    }

    struct TabInput {
        var id: UUID
        var name: String
        var panes: [PaneInput]
    }

    struct Inputs {
        var ownership: WorkspaceOwnershipSnapshot
        var tabs: [TabInput]
        var health: [RelayPaneHealthCoordinator.PaneOverview] = []
        var exchanges: [RelayAssistantExchange] = []
        var cardPending = false
        var busy = false
        var reports: [RelayShepherdReport] = []
        var settings = RelayClaudeQuotaSettings()
        /// hostKey → the host's registered Claude accounts; absent until read.
        var accounts: [String: [RelayAgentAccount]] = [:]
        var deferrals: [String: String] = [:]
        var usageLines: [String: [String]] = [:]
        var notices: [UUID: String] = [:]
        var problem: String?
        var journal: [RelayClaudeQuotaEngine.Record] = []
        var journalNote: String?
        var audit = RelayQuotaAuditDigest()
        var mikoPaused = false
        var callerPaused = false
        var assistantCallerPermitted = true
        var pendingCard: RelayAssistantActionCard?
        var pendingCardOrigin: RelayAssistantOrigin?
        var capacity: [UUID: RelayCapacityManagement.Status] = [:]
        var assessments: [UUID: RelayBudgetAssessment] = [:]
        var rolls: [UUID: RelayBudgetRollReceipt] = [:]
        var budgetNotices: [RelayBudgetNotice] = []
        var accountNoticePercent = RelayBudgetSupervisor.defaultAccountNoticePercent
        var sampledAt = Date()
    }

    static let rememberedPerPane = 3

    static func build(_ input: Inputs) -> RelayControlCenterState {
        var state = RelayControlCenterState()
        let health = Dictionary(input.health.map { ($0.paneID.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let journal = Dictionary(input.journal.map { ($0.pane, $0) }, uniquingKeysWith: { _, last in last })
        let notices = Dictionary(uniqueKeysWithValues: input.notices.map { ($0.key.uuidString.lowercased(), $0.value) })
        var openPanes = Set<UUID>()

        func pane(_ item: PaneInput) -> Pane {
            let row = item.row
            let id = UUID(uuidString: row.id)
            if let id { openPanes.insert(id) }
            var failover = PaneFailover()
            if let id, let record = journal[id] {
                failover.journalState = record.state.rawValue
                failover.journalDetail = record.detail
            }
            failover.notice = notices[row.id.lowercased()]
            if let id, let digest = input.audit.panes[id] {
                failover.latest = digest.latest
                failover.counts = Self.sorted(digest.counts)
            }
            let overview = health[row.id.lowercased()]
            return Pane(id: row.id, name: row.name, hostKey: item.hostKey, host: row.host, agent: row.agent,
                phase: row.phase, connection: row.connection, account: row.accountDisplay ?? row.account,
                summary: row.summary,
                context: overview.map { Self.contextRoll($0) }
                    ?? ContextRoll(state: "unverified", reason: "Not observed by pane health"),
                supervision: Self.supervision(item, overview: overview, assessment: id.flatMap { input.assessments[$0] },
                                              roll: id.flatMap { input.rolls[$0] }),
                miko: id.map { Self.exchanges(input, pane: $0) } ?? [],
                shepherd: id.map { pane in input.reports.filter { $0.paneID == pane }.suffix(rememberedPerPane)
                    .map { ShepherdNote(kind: $0.kind, text: $0.text) } } ?? [],
                failover: failover,
                capacity: id.flatMap { input.capacity[$0] }.map { Self.capacitySummary($0) },
                card: id.flatMap { Self.card(for: $0, input) },
                triage: RelayTaskTriage.build(paneID: row.id, host: row.host, directory: row.directory,
                    provider: row.agent, connection: row.connection, phase: row.phase, plans: item.plans,
                    healthState: overview?.observationState ?? "unknown",
                    blockers: Self.blockedReasons(context: overview?.context, overview: overview)
                        + (id.flatMap { Self.card(for: $0, input)?.blockedReason }.map { [$0] } ?? []),
                    pendingDecision: id.flatMap { Self.card(for: $0, input)?.title },
                    receipts: input.exchanges.flatMap(\.messages).filter { $0.recipientPaneID == id }
                        .suffix(10).map { .init(id: $0.id.uuidString.lowercased(),
                            recipientPaneID: $0.recipientPaneID.uuidString.lowercased(),
                            status: $0.status, readAcknowledged: $0.readAcknowledged) },
                    now: input.sampledAt))
        }
        func tab(_ item: TabInput) -> Tab {
            Tab(id: item.id.uuidString.lowercased(), name: item.name, panes: item.panes.map(pane))
        }

        let shown = Dictionary(input.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<UUID>()
        for record in input.ownership.orderedWorkspaces {
            let owned = input.ownership.tabIDs(in: record.id)
            let tabs = owned.compactMap { shown[$0] }
            placed.formUnion(tabs.map(\.id))
            state.workspaces.append(Workspace(id: record.id.uuidString.lowercased(), name: record.name,
                isInbox: record.isInbox, tabs: tabs.map(tab), otherWindowTabs: owned.count - tabs.count))
        }
        state.unowned = input.tabs.filter { !placed.contains($0.id) }.map(tab)

        // Hosts: every host with a pane here, a setting or a scheduler reason.
        let allPanes = input.tabs.flatMap(\.panes)
        var hostKeys = Set(allPanes.map(\.hostKey)).union(input.settings.hosts.keys).union(input.deferrals.keys)
        hostKeys.formUnion(input.usageLines.keys)
        var mappedPanes = Set<UUID>()
        for key in hostKeys.sorted(by: { $0 == "local" ? true : ($1 == "local" ? false : $0 < $1) }) {
            let panes = allPanes.filter { $0.hostKey == key }
            let ids = Set(panes.compactMap { UUID(uuidString: $0.row.id) })
            mappedPanes.formUnion(ids)
            var counts: [String: Int] = [:]
            var latest: AuditLine?
            for id in ids {
                guard let digest = input.audit.panes[id] else { continue }
                counts.merge(digest.counts, uniquingKeysWith: +)
                if latest == nil || digest.latest.at > latest!.at { latest = digest.latest }
            }
            var current: [String: Int] = [:]
            for pane in panes where pane.isClaude { current[pane.row.account ?? "unlabelled", default: 0] += 1 }
            state.hosts.append(Host(key: key, name: key == "local" ? "This Mac" : key,
                enabled: input.settings.hosts[key] ?? true,
                accounts: input.accounts[key].map { $0.map { $0.label + " · " + ($0.dir.isEmpty ? "default" : $0.dir) } },
                current: Self.sorted(current), deferral: input.deferrals[key], usage: input.usageLines[key] ?? [],
                counts: Self.sorted(counts), latest: latest))
        }
        var other: [String: Int] = [:]
        for (id, digest) in input.audit.panes where !mappedPanes.contains(id) && !openPanes.contains(id) {
            other.merge(digest.counts, uniquingKeysWith: +)
        }
        state.otherPanesAudit = Self.sorted(other)
        state.auditNote = [input.audit.note, input.journalNote].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        let s = input.settings
        state.failoverSummary = (s.enabled ? "On" : "Off") + ": \(s.source) → \(s.target), one direction; "
            + "5-hour \(Int(s.threshold))%, weekly \(Int(s.weeklyThreshold))%, target ceiling \(Int(s.targetCeiling))%"
        state.problem = input.problem
        state.mikoPaused = input.mikoPaused
        state.callerPaused = input.callerPaused
        state.assistantCallerPermitted = input.assistantCallerPermitted
        state.mikoBusy = input.busy
        state.pendingCard = input.pendingCard.map { Self.pendingCard($0, origin: input.pendingCardOrigin) }
        state.notices = input.budgetNotices.sorted { $0.at > $1.at }
        state.accountNoticePercent = input.accountNoticePercent
        return state
    }

    private static func sorted(_ counts: [String: Int]) -> [EventCount] {
        counts.map { EventCount(event: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.event < $1.event : $0.count > $1.count }
    }

    /// Miko's recent exchanges asked by or for this pane, newest last. The
    /// harness keeps its exchanges in memory only; "queued" is not visible here.
    static func exchanges(_ input: Inputs, pane: UUID) -> [MikoExchange] {
        let lastID = input.exchanges.last?.id
        return input.exchanges.compactMap { exchange -> MikoExchange? in
            let origin: String
            var requestID: String?
            switch exchange.origin {
            case .agent(let id, _) where id == pane:
                origin = "agent ask"
                requestID = Self.dashed(exchange.requestID)
            case .supervisor(let id, _) where id == pane:
                origin = "supervisor"
            default:
                return nil
            }
            let state = status(exchange, isLast: exchange.id == lastID, cardPending: input.cardPending, busy: input.busy)
            return MikoExchange(exchangeID: exchange.requestID, requestID: requestID, origin: origin, status: state,
                awaitingConfirmation: state == "completed" && exchange.awaitingConfirmation,
                typedUnconfirmed: state == "completed" && exchange.typedUnconfirmed)
        }.suffix(rememberedPerPane).map { $0 }
    }

    /// The same states the agent's receipt reports, from the harness alone.
    static func status(_ exchange: RelayAssistantExchange, isLast: Bool, cardPending: Bool, busy: Bool) -> String {
        if isLast, cardPending { return "waiting_for_approval" }
        if isLast, busy { return "running" }
        if exchange.failed { return exchange.stoppedByUser ? "stopped" : "failed" }
        if exchange.reply.range(of: #"(^|\n)Stopped (at|after) "#, options: .regularExpression) != nil { return "stopped" }
        return "completed"
    }

    static func dashed(_ hex: String) -> String? {
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let c = Array(hex)
        let parts = [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]].map { String($0) }
        return UUID(uuidString: parts.joined(separator: "-")).map { $0.uuidString.lowercased() }
    }

    /// Context rotation as pane health reports it. Reason text is the native report's own where it has one.
    static func contextRoll(_ pane: RelayPaneHealthCoordinator.PaneOverview) -> ContextRoll {
        guard let context = pane.context else {
            let reason: String
            switch pane.observationState {
            case "exited": reason = "Ended"
            case "not_checked": reason = "Awaiting native check"
            case "stale": reason = "Check expired"
            case "connection_unavailable": reason = "Connection unavailable"
            case "unavailable": reason = "Identity unavailable"
            default: reason = "No native context report"
            }
            return ContextRoll(state: "unverified", reason: reason)
        }
        if !context.supported {
            return ContextRoll(state: "unavailable", reason: context.unavailable ?? "Native context rotation is not supported")
        }
        if !context.enabled {
            return ContextRoll(state: "not_enrolled", reason: context.state == "human_takeover" ? "Paused by you" : "Not enrolled (" + context.state + ")")
        }
        if context.lifecycle == "unavailable" {
            return ContextRoll(state: "unavailable", reason: context.unavailable ?? "Rotation unavailable")
        }
        return ContextRoll(state: "supported", reason: "Enabled" + (context.lifecycle.map { " (" + $0 + ")" } ?? ""))
    }

    static func supervision(_ item: PaneInput, overview: RelayPaneHealthCoordinator.PaneOverview?,
                            assessment: RelayBudgetAssessment? = nil, roll: RelayBudgetRollReceipt? = nil) -> Supervision {
        let context = overview?.context
        var blocked = blockedReasons(context: context, overview: overview)
        var usage: [UsageReading] = []
        if let reading = item.accountUsage {
            if reading.status != "ok" {
                blocked.append("usage " + reading.status + (reading.reason.map { ": " + $0 } ?? ""))
            }
            for window in reading.windows ?? [] {
                usage.append(UsageReading(provenance: "actual_dashboard", scope: "account " + reading.label + " (all chats on it)",
                    window: window.displayName, usedPercent: window.usedPercent, source: reading.source, readAt: reading.readAt))
            }
        }
        usage += item.estimates
        let manageable = context.map { $0.supported && $0.enabled && $0.lifecycle != "unavailable"
            && $0.refreshCapability == "supported" } ?? false
        // Supervision stays "pending" until its automatic behavior is proven live;
        // any hold the supervisor reports keeps the pane at "management unavailable".
        let held = !(assessment?.holds.isEmpty ?? true)
        return Supervision(
            enabled: context.map { $0.enabled ? "true" : "false" } ?? "unknown",
            enrollment: context.map { $0.enabled ? "enrolled" : "not_enrolled" } ?? "unknown",
            refreshCapability: context?.refreshCapability ?? "unknown",
            lifecycle: context?.lifecycle ?? "unknown",
            promptEmpty: item.promptEmpty.map { $0 ? "true" : "false" } ?? "not read here (needs a screen read)",
            blocked: blocked, usage: usage,
            management: manageable && !held ? "context rotation enrolled; Miko supervision pending (automatic behavior not yet proven live)"
                : "management unavailable",
            signals: assessment?.signals ?? [], holds: assessment?.holds ?? [],
            perChat: usage.contains { $0.provenance == "estimated_tokens" }
                ? RelayBudgetSupervisor.perChatUnavailable + "; estimated_tokens readings above are estimates, not actual usage"
                : RelayBudgetSupervisor.perChatUnavailable,
            roll: roll)
    }

    static func capacitySummary(_ status: RelayCapacityManagement.Status) -> CapacitySummary {
        CapacitySummary(state: status.state, reason: status.reason, supported: status.supported, managed: status.managed,
            enabled: status.enabled, ready: status.ready, contextEnabled: status.settings.contextEnabled,
            thresholdTokens: status.settings.thresholdTokens, measuredTokens: status.decision?.measuredTokens,
            contextDue: status.decision?.contextDue ?? false,
            operation: status.operation.map { RelayBudgetSupervisor.receiptText($0) },
            registeredAccounts: status.registeredAccounts)
    }

    static func pendingCard(_ card: RelayAssistantActionCard, origin: RelayAssistantOrigin?) -> PendingCard {
        let who: String
        switch origin {
        case .agent(_, let label)?: who = "pane agent ask (" + label + ")"
        case .supervisor(_, let label)?: who = "supervisor (" + label + ")"
        default: who = "you"
        }
        return PendingCard(id: card.id, title: card.title, rows: card.rows.map { $0.label + ": " + $0.value },
            literal: card.literal, blockedReason: card.blockedReason, expiresAt: card.expiresAt, origin: who,
            paneID: card.paneID?.uuidString.lowercased())
    }

    /// A card sits under the pane it targets, or under the pane whose agent proposed it.
    static func card(for pane: UUID, _ input: Inputs) -> PendingCard? {
        guard let card = input.pendingCard else { return nil }
        var owner = card.paneID
        if owner == nil {
            switch input.pendingCardOrigin {
            case .agent(let id, _)?, .supervisor(let id, _)?: owner = id
            default: break
            }
        }
        return owner == pane ? pendingCard(card, origin: input.pendingCardOrigin) : nil
    }

    /// What a failover audit event means. The code itself is always shown verbatim beside this.
    static func explain(_ event: String) -> String {
        if event == "deferred_account_mapping" {
            return "Transient: this host's account list did not yet map the source and target labels; failover waits and retries."
        }
        if event == "deferred_registry_loading" { return "Transient: this host's account list is still loading." }
        if event.hasPrefix("deferred_quota_") {
            return "Refused by design: no fresh, complete 5-hour and weekly reading for the source account."
        }
        if event.hasPrefix("deferred_target_") { return "Refused by design: the target account's reading is not usable." }
        if event == "deferred_usage_read_failed" { return "Claude usage could not be read on this host." }
        if event == "deferred_native_identity" { return "The pane's native agent identity could not be verified." }
        if event == "deferred_screen_unavailable" { return "The pane's screen could not be checked for idleness." }
        if event == "deferred_combined_native_lane" { return "Another native operation was in progress." }
        return event.hasPrefix("deferred") ? "Deferred." : "Failover event."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Per-pane counts and the latest entry of quota-failover-v1.json.audit.jsonl.
struct RelayQuotaAuditDigest: Equatable {
    struct PaneDigest: Equatable {
        var counts: [String: Int] = [:]
        var latest: RelayControlCenterState.AuditLine
    }

    var panes: [UUID: PaneDigest] = [:]
    var entries = 0
    var note: String?

    /// Parses JSON lines `{pane, event, at}`. A line that does not decode is
    /// counted and skipped (an interrupted last append is one such line).
    static func parse(_ data: Data, truncatedHead: Bool = false) -> RelayQuotaAuditDigest {
        struct Entry: Decodable { var pane: UUID; var event: String; var at: Date }
        var digest = RelayQuotaAuditDigest()
        var skipped = 0
        var lines = data.split(separator: 10, omittingEmptySubsequences: true)
        if truncatedHead, !lines.isEmpty { lines.removeFirst() }
        let decoder = JSONDecoder()
        for line in lines {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)) else { skipped += 1; continue }
            digest.entries += 1
            let line = RelayControlCenterState.AuditLine(event: entry.event, at: entry.at)
            var pane = digest.panes[entry.pane] ?? PaneDigest(latest: line)
            pane.counts[entry.event, default: 0] += 1
            if entry.at >= pane.latest.at { pane.latest = line }
            digest.panes[entry.pane] = pane
        }
        var notes: [String] = []
        if truncatedHead { notes.append("Counts cover only the newest part of the failover audit.") }
        if skipped > 0 { notes.append("\(skipped) unreadable audit line(s) skipped.") }
        digest.note = notes.isEmpty ? nil : notes.joined(separator: " ")
        return digest
    }
}

/// Reads the failover journal and audit files directly, read-only. It never
/// uses RelayClaudeQuotaJournal, whose load() takes the scheduler's exclusive
/// lock. The audit is re-parsed only when its size or modification date changes.
final class RelayControlCenterFiles {
    static let tailLimit = 4 << 20
    let journalURL: URL
    var auditURL: URL { URL(fileURLWithPath: journalURL.path + ".audit.jsonl") }
    private var auditKey: (Int, Date)?
    private var auditDigest = RelayQuotaAuditDigest()
    private(set) var auditParses = 0

    init(journalURL: URL = RelayStateProfile.applicationSupportRoot
            .appendingPathComponent("Relay/AgentAccounts/quota-failover-v1.json")) {
        self.journalURL = journalURL
    }

    func audit() -> RelayQuotaAuditDigest {
        guard let values = try? auditURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else {
            auditKey = nil
            auditDigest = RelayQuotaAuditDigest()
            return auditDigest
        }
        let key = (size, values.contentModificationDate ?? .distantPast)
        if let auditKey, auditKey == key { return auditDigest }
        auditKey = key
        auditParses += 1
        guard let handle = try? FileHandle(forReadingFrom: auditURL) else {
            auditDigest = RelayQuotaAuditDigest(note: "The failover audit could not be read.")
            return auditDigest
        }
        defer { try? handle.close() }
        let offset = max(0, size - Self.tailLimit)
        let data = ((try? handle.seek(toOffset: UInt64(offset))).map { _ in try? handle.readToEnd() } ?? nil) ?? Data()
        auditDigest = RelayQuotaAuditDigest.parse(data, truncatedHead: offset > 0)
        return auditDigest
    }

    func journal() -> ([RelayClaudeQuotaEngine.Record], String?) {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return ([], nil) }
        guard let size = try? journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1 << 20,
              let data = try? Data(contentsOf: journalURL),
              let disk = try? RelayClaudeQuotaEngine.Disk.decode(data) else {
            return ([], "The failover journal could not be read.")
        }
        return (disk.records, nil)
    }
}

extension RelayControlCenterState {
    /// Gathers inputs from the live models. Reads only in-memory state and the
    /// two failover files; never a pane's screen.
    @MainActor static func live(workspace: WorkspaceModel?, files: RelayControlCenterFiles) -> RelayControlCenterState {
        guard let workspace else { return .empty }
        let tabs = workspace.tabs.map { tab in
            TabInput(id: tab.id, name: tab.name, panes: workspace.paneIDs(inTab: tab.id).compactMap { id in
                workspace.panes[id].map { pane in
                    PaneInput(row: workspace.sidePanelPane(pane), hostKey: RelayAgentAccountDirectory.hostKey(pane.profile),
                              isClaude: pane.kind == .claude, accountUsage: Self.accountUsage(pane), plans: pane.taskPlans)
                }
            })
        }
        let directory = RelayAgentAccountDirectory.shared
        var accounts: [String: [RelayAgentAccount]] = [:]
        for pane in workspace.panes.values {
            let key = RelayAgentAccountDirectory.hostKey(pane.profile)
            if accounts[key] == nil, let registered = directory.registeredAccounts(for: pane.profile, provider: "claude") {
                accounts[key] = registered
            }
        }
        let scheduler = RelayClaudeQuotaScheduler.shared
        let harness = workspace.haikuAssistantStorage
        let (journal, journalNote) = files.journal()
        return build(Inputs(
            ownership: workspace.ownership, tabs: tabs,
            health: RelayPaneHealthCoordinator.shared.hostOverviews().flatMap(\.livePanes),
            exchanges: harness?.exchanges ?? [], cardPending: harness?.pendingCard != nil, busy: harness?.isBusy ?? false,
            reports: RelayMikoShepherdCoordinator.shared.reports,
            settings: RelayPreferences.shared.claudeQuotaFailover, accounts: accounts,
            deferrals: scheduler.deferrals, usageLines: scheduler.usageLines, notices: scheduler.notices,
            problem: scheduler.problem, journal: journal, journalNote: journalNote, audit: files.audit(),
            mikoPaused: RelayMikoSupervision.shared.isDisabled("*"), callerPaused: scheduler.paused,
            assistantCallerPermitted: RelayCallerControl.shared.permitted(RelayCallerControl.assistantCaller),
            pendingCard: harness?.pendingCard, pendingCardOrigin: harness?.pendingCardOrigin,
            capacity: RelayCapacityManagementCoordinator.shared.statuses,
            assessments: RelayBudgetSupervisor.shared.assessments, rolls: RelayBudgetSupervisor.shared.rolls,
            budgetNotices: Array(RelayBudgetSupervisor.shared.notices.values),
            accountNoticePercent: RelayBudgetSupervisor.shared.accountNoticePercent))
    }
}

extension RelayControlCenterState {
    @MainActor static func accountUsage(_ pane: PaneModel) -> RelayAgentAccountUsage? {
        guard pane.kind == .claude || pane.kind == .codex, let label = pane.agentAccountLabel else { return nil }
        let directory = RelayAgentAccountDirectory.shared
        let provider = pane.kind == .claude ? "claude" : "codex"
        return directory.account(for: pane.profile, provider: provider, label: label)
            .flatMap { directory.usage(for: pane.profile, account: $0) }
    }
}

typealias RelayControlCenterFeed = RelayPaneHealthFeed<RelayControlCenterState>
extension RelayPaneHealthFeed where Value == RelayControlCenterState {
    /// Refreshes only while the Control section's window shows: on becoming
    /// visible, on a pane-health, failover or Shepherd change, and on the slow tick.
    static func control(workspace: WorkspaceModel, files: RelayControlCenterFiles = .init()) -> RelayPaneHealthFeed<Value> {
        return RelayPaneHealthFeed(initial: .empty,
            source: { [weak workspace] in RelayControlCenterState.live(workspace: workspace, files: files) },
            changes: {
                Publishers.Merge4(
                    RelayPaneHealthCoordinator.shared.$revision.dropFirst().map { _ in () },
                    RelayClaudeQuotaScheduler.shared.objectWillChange.map { _ in () },
                    RelayMikoShepherdCoordinator.shared.$reports.dropFirst().map { _ in () },
                    RelayBudgetSupervisor.shared.objectWillChange.map { _ in () })
                    .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
                    .receive(on: DispatchQueue.main).eraseToAnyPublisher()
            },
            ticks: {
                Timer.publish(every: tickInterval, tolerance: 1, on: .main, in: .common).autoconnect()
                    .map { _ in () }.eraseToAnyPublisher()
            })
    }
}

/// The Control section. Reading is here; every action is a control from
/// RelayControlCenterActions.swift that calls an existing entry point.
struct RelayControlCenterView: View {
    @StateObject private var feed: RelayControlCenterFeed
    @StateObject private var actions: RelayControlCenterActions

    init(workspace: WorkspaceModel) {
        _feed = StateObject(wrappedValue: .control(workspace: workspace))
        _actions = StateObject(wrappedValue: RelayControlCenterActions(workspace: workspace))
    }

    var body: some View {
        let state = feed.value
        VStack(alignment: .leading, spacing: RelayTheme.spacing(10)) {
            Text("Control").font(RelayTheme.font(size: 12, weight: .semibold))
            Text("Miko: " + (state.mikoPaused ? "paused (all Miko tools off)" : "not paused")
                 + " · Assistant caller: " + (state.assistantCallerPermitted ? "not paused" : "paused (Miko tools off)")
                 + " · Failover: " + (state.callerPaused ? "paused (failover stopped)" : "not paused")
                 + " · Miko " + (state.mikoBusy ? "is busy" : "is idle"))
                .foregroundStyle(RelayTheme.textMuted)
            RelayControlTopActions(state: state, actions: actions)
            RelayTaskTriageView(state: state)
            Text(RelayControlCenterState.askDisclosure).foregroundStyle(RelayTheme.textMuted)
            Text(RelayBudgetSupervisor.gateNote).foregroundStyle(RelayTheme.textMuted)
            if let card = state.pendingCard, card.paneID == nil || !state.hasPane(card.paneID) {
                RelayControlCardView(card: card, actions: actions)
            }
            ForEach(state.notices, id: \.paneID) { notice in
                Text("Management unavailable for \(notice.name): " + (notice.signals + notice.holds).joined(separator: "; "))
                    .foregroundStyle(RelayTheme.coral)
            }
            if let problem = state.problem { Text(problem).foregroundStyle(RelayTheme.coral) }
            failover(state)
            ForEach(state.workspaces, id: \.id) { workspace in
                VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                    Text(workspace.name + (workspace.isInbox ? " (Inbox)" : "")).fontWeight(.semibold)
                    if workspace.otherWindowTabs > 0 {
                        Text("\(workspace.otherWindowTabs) owned tab(s) not shown in this window").foregroundStyle(RelayTheme.textMuted)
                    }
                    ForEach(workspace.tabs, id: \.id) { tabView($0) }
                }
            }
            if !state.unowned.isEmpty {
                Text("Tabs without a workspace owner").fontWeight(.semibold)
                ForEach(state.unowned, id: \.id) { tabView($0) }
            }
        }
        .font(RelayTheme.font(size: 11))
        .textSelection(.enabled)
        .padding(RelayTheme.spacing(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("relay.monitoring.control")
        .background(RelayWindowVisibilityReader(feed: feed).frame(width: 0, height: 0))
        .onAppear { actions.changed = { [weak feed] in feed?.refreshNow() } }
        .onDisappear { feed.setVisible(false) }
    }

    private func failover(_ state: RelayControlCenterState) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
            Text("Claude account failover: " + state.failoverSummary).fontWeight(.medium)
            ForEach(state.hosts, id: \.key) { host in
                VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                    Text(host.name + (host.enabled ? "" : " (failover off for this host)"))
                    Text("Accounts: " + (host.accounts.map { $0.isEmpty ? "none registered" : $0.joined(separator: ", ") } ?? "not read yet"))
                        .foregroundStyle(RelayTheme.textMuted)
                    if !host.current.isEmpty {
                        Text("Claude panes by account: " + host.current.map { "\($0.event) \($0.count)" }.joined(separator: ", "))
                            .foregroundStyle(RelayTheme.textMuted)
                    }
                    if let deferral = host.deferral { Text("Waiting: " + deferral).foregroundStyle(RelayTheme.textMuted) }
                    ForEach(host.usage, id: \.self) { Text($0).foregroundStyle(RelayTheme.textMuted) }
                    ForEach(host.counts, id: \.event) { count in
                        Text("\(count.event) × \(count.count): " + RelayControlCenterState.explain(count.event))
                            .foregroundStyle(RelayTheme.textMuted)
                    }
                    if let latest = host.latest {
                        Text("Latest: \(latest.event) at \(latest.at.formatted(date: .abbreviated, time: .standard))")
                            .foregroundStyle(RelayTheme.textMuted)
                    }
                }
            }
            if !state.otherPanesAudit.isEmpty {
                Text("Panes not open here: " + state.otherPanesAudit.map { "\($0.event) × \($0.count)" }.joined(separator: ", "))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            if let note = state.auditNote { Text(note).foregroundStyle(RelayTheme.textMuted) }
        }
    }

    private func tabView(_ tab: RelayControlCenterState.Tab) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
            Text("  " + tab.name)
            ForEach(tab.panes, id: \.id) { pane in
                VStack(alignment: .leading, spacing: RelayTheme.spacing(1)) {
                    Text("    \(pane.id.prefix(8)) \(pane.name) · \(pane.agent) · \(pane.phase) · \(pane.host) · \(pane.connection)"
                         + (pane.account.map { " · " + $0 } ?? ""))
                    Text("      Context rotation: \(pane.context.state) (\(pane.context.reason))").foregroundStyle(RelayTheme.textMuted)
                    supervisionView(pane.supervision)
                    capacityView(pane.capacity)
                    if !pane.summary.isEmpty { Text("      " + pane.summary).lineLimit(1).foregroundStyle(RelayTheme.textMuted) }
                    if let card = pane.card { RelayControlCardView(card: card, actions: actions) }
                    RelayControlPaneActions(pane: pane, actions: actions)
                    ForEach(pane.miko, id: \.exchangeID) { exchange in
                        Text("      Miko \(exchange.origin): \(exchange.status)\(exchange.awaitingConfirmation ? " (awaiting confirmation)" : "")\(exchange.typedUnconfirmed ? " (typed, not confirmed)" : "") · request_id \(exchange.requestID ?? "–") · exchange \(exchange.exchangeID)")
                            .foregroundStyle(RelayTheme.textMuted)
                    }
                    ForEach(Array(pane.shepherd.enumerated()), id: \.offset) { _, note in
                        Text("      Shepherd \(note.kind): \(note.text)").lineLimit(2).foregroundStyle(RelayTheme.textMuted)
                    }
                    paneFailover(pane.failover)
                }
            }
        }
    }

    @ViewBuilder private func capacityView(_ c: RelayControlCenterState.CapacitySummary?) -> some View {
        if let c {
            Text("      Native policy: \(c.state): \(c.reason) · enabled=\(c.enabled) managed=\(c.managed) supported=\(c.supported)"
                 + " · context policy \(c.contextEnabled ? "on" : "off"), threshold \(c.thresholdTokens) tokens"
                 + (c.measuredTokens.map { " · measured \($0) tokens" } ?? " · measured tokens not reported")
                 + (c.contextDue ? " · refresh due" : "") + (c.operation.map { " · operation " + $0 } ?? ""))
                .foregroundStyle(RelayTheme.textMuted)
        }
    }

    @ViewBuilder private func supervisionView(_ s: RelayControlCenterState.Supervision) -> some View {
        Text("      Budget: \(s.management) · enabled=\(s.enabled) · \(s.enrollment) · refresh_capability=\(s.refreshCapability)"
             + " · lifecycle=\(s.lifecycle) · prompt_empty=\(s.promptEmpty)")
            .foregroundStyle(s.management == "management unavailable" ? RelayTheme.coral : RelayTheme.textMuted)
        ForEach(s.blocked, id: \.self) { Text("        blocked: " + $0).foregroundStyle(RelayTheme.textMuted) }
        ForEach(s.holds, id: \.self) { Text("        notice (does not stop native automatic requests): " + $0).foregroundStyle(RelayTheme.coral) }
        ForEach(s.signals, id: \.self) { Text("        signal: " + $0).foregroundStyle(RelayTheme.coral) }
        ForEach(Array(s.usage.enumerated()), id: \.offset) { _, u in
            Text(Self.usageText(u)).foregroundStyle(RelayTheme.textMuted)
        }
        Text("        " + s.perChat).foregroundStyle(RelayTheme.textMuted)
        if let roll = s.roll {
            Text("        Last roll (\(roll.label)): " + roll.receipt
                 + " · " + roll.checks.joined(separator: " · ")).foregroundStyle(RelayTheme.textMuted)
        }
    }

    static func usageText(_ u: RelayControlCenterState.UsageReading) -> String {
        let percent = String(format: "%.2f", u.usedPercent)
        var text = "        " + u.window + ": " + percent + "% [" + u.provenance + "] " + u.scope
        if let source = u.source { text += " · " + source }
        if let readAt = u.readAt { text += " · read " + readAt }
        return text
    }

    @ViewBuilder private func paneFailover(_ failover: RelayControlCenterState.PaneFailover) -> some View {
        if let state = failover.journalState {
            Text("      Failover: \(state)" + (failover.journalDetail.map { " – " + $0 } ?? "")).foregroundStyle(RelayTheme.textMuted)
        }
        if let notice = failover.notice { Text("      " + notice).foregroundStyle(RelayTheme.coral) }
        if let latest = failover.latest {
            Text("      Failover last: \(latest.event) at \(latest.at.formatted(date: .abbreviated, time: .standard))"
                 + " (" + failover.counts.map { "\($0.event) × \($0.count)" }.joined(separator: ", ") + ")")
                .foregroundStyle(RelayTheme.textMuted)
        }
    }
}
