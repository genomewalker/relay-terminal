import Foundation

/// CC-S2 item 5: Miko-owned usage and context-budget supervision.
///
/// This is an owner of the observation, the user's notice and the verification,
/// not a second decider. It starts no roll. The native capacity coordinator
/// submits `capacity_observe` when the native policy says a lane is due, exactly
/// as before; this supervisor neither gates nor adds that submission, and its holds
/// are notices only. It runs from the coordinator's native observation (one status read
/// per pane per minute); it has no timer, no model turn and no per-message wakeup.
///
/// Nothing here switches a model or an account, bypasses a user disable or an
/// approval card, or reads a screen. `promptEmpty` is whatever the injected
/// source reports; the live source reports "unknown".
struct RelayBudgetAssessment: Equatable {
    /// Why this pane looks expensive, each with its provenance.
    var signals: [String] = []
    /// One stable key per signal (no numbers), so a persistent condition notifies once.
    var signalKeys: [String] = []
    /// Every reason management is unavailable or held, verbatim from its source.
    var holds: [String] = []
    /// Per-chat allowance usage has no defensible source in this tree.
    var perChat = RelayBudgetSupervisor.perChatUnavailable
    var expensive: Bool { !signals.isEmpty }
    var managementUnavailable: Bool { !holds.isEmpty }
}

struct RelayBudgetRollReceipt: Equatable {
    let at: Date
    /// The native operation's own `state: reason`.
    let receipt: String
    /// True only when the native operation reported "completed" with a non-empty receipt and the
    /// plan's id is the id of the request Relay sent. It does NOT mean the task resumed.
    let completed: Bool
    /// What may be shown. The native schema carries no field that proves the task resumed, so
    /// this never says it did.
    let label: String
    let checks: [String]
}

struct RelayBudgetNotice: Equatable {
    let paneID: UUID
    let name: String
    let signals: [String]
    let signalKeys: [String]
    let holds: [String]
    let at: Date

    /// An account total alone never titles a specific pane as costly.
    var accountOnly: Bool { !signalKeys.isEmpty && signalKeys.allSatisfy { $0.hasPrefix("account_usage") } }
    var title: String {
        accountOnly ? "Relay: account usage is high (account total, all chats); \(name) cannot be managed"
            : "Relay: \(name) is costly and cannot be managed"
    }
}

/// What one pane's assessment reads. Built by the caller from existing
/// native observations only.
struct RelayBudgetObservation {
    var paneID: UUID
    var paneName: String
    var status: RelayCapacityManagement.Status?
    var overview: RelayPaneHealthCoordinator.PaneOverview?
    /// nil is unknown. The live source never reads a screen, so it is nil there.
    var promptEmpty: Bool?
    var mikoPaused: Bool
    var approvalPending: Bool
    var accountUsage: [RelayControlCenterState.UsageReading]
    var now: Date
}

@MainActor final class RelayBudgetSupervisor: ObservableObject {
    static let shared = RelayBudgetSupervisor()
    nonisolated static let perChatUnavailable = "per-chat usage unavailable (no per-chat source; account totals are not attributed to this chat)"
    /// A rise of this fraction of the native token threshold between two
    /// native observations, inside `riseWindow`, counts as fast. Notice only.
    static let riseFraction = 0.25
    static let riseWindow: TimeInterval = 600
    /// Shown in Control: the gate is not limited to context.
    nonisolated static let gateNote = "Native automatic management runs as before. Miko's holds and signals below are notices only: "
        + "they are shown and notified, and they do not stop Relay's native automatic requests. Miko adds no roll path of its own. "
        + "Fast rise is a notice-only heuristic."
    static let noticeKey = "relay.miko.budget.account-notice-percent"
    nonisolated static let defaultAccountNoticePercent = 40.0

    @Published private(set) var assessments: [UUID: RelayBudgetAssessment] = [:]
    @Published private(set) var rolls: [UUID: RelayBudgetRollReceipt] = [:]
    @Published private(set) var notices: [UUID: RelayBudgetNotice] = [:]
    /// Notices already shown, by pane, so a persistent condition notifies once.
    private var notified: [UUID: String] = [:]
    private var lastTokens: [UUID: (tokens: Int64, at: Date)] = [:]

    var promptEmpty: (PaneModel) -> Bool?
    var mikoPaused: () -> Bool
    var approvalPending: (PaneModel, WorkspaceModel?) -> Bool
    var overview: (PaneModel) -> RelayPaneHealthCoordinator.PaneOverview?
    var accountUsage: (PaneModel) -> [RelayControlCenterState.UsageReading]
    var notify: (RelayBudgetNotice) -> Void
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        promptEmpty = { $0.runtime.budgetPromptEmpty() }
        mikoPaused = { RelayMikoSupervision.shared.isDisabled("*") }
        approvalPending = { pane, workspace in
            guard let harness = workspace?.haikuAssistantStorage, let card = harness.pendingCard else { return false }
            if card.paneID == pane.id { return true }
            switch harness.pendingCardOrigin {
            case .agent(let id, _)?, .supervisor(let id, _)?: return id == pane.id
            default: return false
            }
        }
        overview = { pane in
            RelayPaneHealthCoordinator.shared.hostOverviews().flatMap(\.livePanes)
                .first { $0.paneID == pane.id.uuidString.lowercased() }
        }
        accountUsage = { pane in RelayBudgetSupervisor.readings(RelayControlCenterState.accountUsage(pane)) }
        notify = { notice in RelayAttentionNotifier.shared.postBudgetNotice(notice) }
    }

    /// The user's account-usage notice level, in percent. It only decides when
    /// to tell the user; it never starts an action.
    var accountNoticePercent: Double {
        get {
            let value = defaults.object(forKey: Self.noticeKey) as? Double ?? Self.defaultAccountNoticePercent
            return min(max(value, 1), 100)
        }
        set {
            defaults.set(min(max(newValue, 1), 100), forKey: Self.noticeKey)
            objectWillChange.send()
        }
    }

    nonisolated static func readings(_ usage: RelayAgentAccountUsage?) -> [RelayControlCenterState.UsageReading] {
        guard let usage, usage.status == "ok" else { return [] }
        return (usage.windows ?? []).map {
            .init(provenance: "actual_dashboard", scope: "account " + usage.label + " (all chats on it)",
                  window: $0.displayName, usedPercent: $0.usedPercent, source: usage.source, readAt: usage.readAt)
        }
    }

    // MARK: Assessment (pure)

    /// Every reason Miko cannot manage or roll this pane right now. Empty means
    /// nothing here holds it; the native path still applies its own checks.
    nonisolated static func holds(_ o: RelayBudgetObservation) -> [String] {
        var holds: [String] = []
        if o.mikoPaused { holds.append("Miko is paused by you (Miko decides and rolls nothing; native automatic requests are unaffected)") }
        if o.approvalPending { holds.append("held for approval: an action card for this pane awaits Run or Cancel") }
        holds += RelayControlCenterState.blockedReasons(context: o.overview?.context, overview: o.overview)
        if let status = o.status {
            if !status.supported { holds.append("capacity supported=false") }
            if !status.enabled { holds.append("capacity enabled=false (state \(status.state))") }
            else if !status.managed { holds.append("capacity managed=false") }
            if bool(status.entry?["opt_out"]) == true { holds.append("disabled by you for this pane (opt_out)") }
            if bool(status.entry?["human_takeover"]) == true { holds.append("disabled by your input in this pane (human takeover)") }
        } else {
            holds.append("capacity status not read")
        }
        switch o.promptEmpty {
        case true?: break
        case false?: holds.append("prompt not empty (an unsent draft is present)")
        case nil: holds.append("prompt_empty unknown (native prompt evidence unavailable)")
        }
        return holds
    }

    func assess(_ o: RelayBudgetObservation) -> RelayBudgetAssessment {
        var result = RelayBudgetAssessment()
        let threshold = o.status?.settings.thresholdTokens
        if let tokens = o.status?.decision?.measuredTokens, tokens > 0 {
            if let threshold, tokens >= threshold {
                result.signals.append("long context: \(tokens) measured tokens (native threshold \(threshold))")
                result.signalKeys.append("long_context")
            }
            if let threshold, let last = lastTokens[o.paneID], tokens > last.tokens,
               o.now.timeIntervalSince(last.at) <= Self.riseWindow, o.now > last.at,
               Double(tokens - last.tokens) >= Double(threshold) * Self.riseFraction {
                result.signals.append("fast rise: +\(tokens - last.tokens) tokens in \(Int(o.now.timeIntervalSince(last.at))) s (notice-only heuristic)")
                result.signalKeys.append("fast_rise")
            }
            lastTokens[o.paneID] = (tokens, o.now)
        }
        if o.status?.decision?.contextDue == true {
            result.signals.append("native policy: context refresh is due")
            result.signalKeys.append("context_due")
        }
        for reading in o.accountUsage where reading.usedPercent >= accountNoticePercent {
            result.signals.append(String(format: "account usage %@ %.2f%% [actual_dashboard] %@; not attributed to this chat",
                                         reading.window, reading.usedPercent, reading.scope))
            result.signalKeys.append("account_usage:" + reading.window)
        }
        result.holds = Self.holds(o)
        return result
    }

    nonisolated private static func bool(_ json: RelayPaneHealthJSON?) -> Bool? {
        if case .bool(let value)? = json { return value }
        return nil
    }

    // MARK: Observation

    /// Records one native observation of `pane` and tells the user when it is
    /// expensive and cannot be managed. Returns the holds the caller must honor
    /// before it submits a roll.
    @discardableResult
    func observe(pane: PaneModel, workspace: WorkspaceModel?, status: RelayCapacityManagement.Status?, now: Date) -> RelayBudgetAssessment {
        let observation = RelayBudgetObservation(paneID: pane.id, paneName: pane.displayName, status: status,
            overview: overview(pane), promptEmpty: promptEmpty(pane), mikoPaused: mikoPaused(),
            approvalPending: approvalPending(pane, workspace), accountUsage: accountUsage(pane), now: now)
        let assessment = assess(observation)
        assessments[pane.id] = assessment
        if assessment.expensive, assessment.managementUnavailable {
            let notice = RelayBudgetNotice(paneID: pane.id, name: observation.paneName, signals: assessment.signals,
                                           signalKeys: assessment.signalKeys, holds: assessment.holds, at: now)
            // Latest numbers are kept for display; only stable categories decide whether to notify.
            notices[pane.id] = notice
            // fast_rise comes and goes with the sampling, so it never re-notifies by itself.
            let key = (assessment.signalKeys.filter { $0 != "fast_rise" }.sorted() + ["|"] + assessment.holds.sorted()).joined(separator: "\n")
            if notified[pane.id] != key {
                notified[pane.id] = key
                notify(notice)
            }
        } else {
            // Resolved: the condition no longer holds, so the notice is gone.
            notices[pane.id] = nil
            notified[pane.id] = nil
        }
        return assessment
    }

    func forget(_ paneID: UUID) {
        assessments[paneID] = nil
        notices[paneID] = nil
        notified[paneID] = nil
        lastTokens[paneID] = nil
        rolls[paneID] = nil
    }

    // MARK: Verification

    /// Records the roll the native coordinator submitted. `operationID` is the id Relay put in
    /// the request; the verdict never says the task resumed.
    func recordRoll(pane: PaneModel, before: RelayCapacityManagement.Status, after: RelayCapacityManagement.Status,
                    operationID: String, now: Date) {
        let (completed, label, checks) = Self.verify(paneID: pane.id, before: before, after: after, operationID: operationID)
        rolls[pane.id] = RelayBudgetRollReceipt(at: now, receipt: after.operation.map { Self.receiptText($0) } ?? (after.state + ": " + after.reason),
                                                completed: completed, label: label, checks: checks)
    }

    nonisolated static func receiptText(_ operation: RelayPaneHealthJSON) -> String {
        let state = operation["state"]?.string ?? "unknown"
        let reason = operation["reason"]?.string ?? ""
        return reason.isEmpty ? state : state + ": " + reason
    }

    nonisolated static let completedLabel = "operation reported completed; resumption unverified"

    /// Completion is accepted only with authoritative, non-empty identity and a receipt tied to
    /// the submitted operation. Nothing in the native schema proves the task resumed, so even a
    /// fully correlated completion is labelled "resumption unverified".
    nonisolated static func verify(paneID: UUID, before: RelayCapacityManagement.Status,
                                   after: RelayCapacityManagement.Status, operationID: String) -> (Bool, String, [String]) {
        var checks: [String] = []
        var ok = true
        func check(_ passed: Bool, _ pass: String, _ fail: String) {
            checks.append(passed ? "ok: " + pass : "NOT verified: " + fail)
            if !passed { ok = false }
        }
        func text(_ json: RelayPaneHealthJSON?) -> String? {
            guard let value = json?.string, !value.isEmpty else { return nil }
            return value
        }
        let id = paneID.uuidString.lowercased()
        check(text(before.source?["pane"]) == id && text(after.source?["pane"]) == id,
              "identity: same pane before and after", "identity: pane absent or different")
        let provider = text(before.source?["provider"])
        check(provider != nil && text(after.source?["provider"]) == provider,
              "identity: same non-empty provider", "identity: provider absent, empty or different")
        check(text(before.source?["binding"]) != nil && text(after.source?["binding"]) != nil,
              "identity: binding reported before and after", "identity: binding absent or empty")
        let operation = after.operation
        check(text(operation?["state"]) == "completed", "operation state completed",
              "operation state \(text(operation?["state"]) ?? "absent")")
        check(text(operation?["receipt"]) != nil, "receipt present", "receipt absent, empty or not a string")
        check(!operationID.isEmpty && text(operation?["plan"]?["id"]) == operationID,
              "plan id equals the submitted operation id", "plan id absent or not the submitted operation id")
        let beforeSession = text(before.source?["session"])
        check(beforeSession != nil && text(operation?["plan"]?["source"]?["session"]) == beforeSession,
              "plan source is the pre-roll session", "plan source session absent or different")
        return (ok, ok ? completedLabel : "operation not confirmed complete: " + checks.filter { $0.hasPrefix("NOT") }.joined(separator: "; "), checks)
    }
}

extension RelayControlCenterState {
    /// The reasons pane health gives for management being blocked, verbatim.
    /// Shared by the Control section's display and the supervisor's holds.
    static func blockedReasons(context: RelayPaneContextObservation?,
                               overview: RelayPaneHealthCoordinator.PaneOverview?) -> [String] {
        var blocked: [String] = []
        if let overview, context == nil {
            blocked.append("observation=" + overview.observationState + ": " + contextRoll(overview).reason)
        } else if overview == nil {
            blocked.append("Not observed by pane health")
        }
        if let context {
            if !context.supported { blocked.append("supported=false") }
            if !context.enabled { blocked.append("enabled=false (state " + context.state + ")") }
            if let capability = context.refreshCapability, capability != "supported" {
                blocked.append("refresh_capability=" + capability)
            } else if context.refreshCapability == nil { blocked.append("refresh_capability not reported") }
            if context.lifecycle == "unavailable" { blocked.append("lifecycle=unavailable") }
            if let reason = context.unavailable { blocked.append(reason) }
        }
        return blocked
    }
}
