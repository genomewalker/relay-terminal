import Foundation
import SwiftUI

/// CC-S2: the Control section's actions.
///
/// Every action is a user click that calls an entry point that already exists
/// and keeps that entry point's refusals:
///   - Run / Cancel      -> RelayAssistantHarness.runCard() / cancelCard()
///   - Pause / Resume    -> RelayMikoSupervision.setMikoPaused(_:) (the Settings toggle's own call)
///   - Context roll      -> RelayCapacityManagementCoordinator.userAction("capacity_manual_refresh")
///                          (the panel's "Checked context refresh")
///   - Account move      -> RelayAgentAccountMove.move(... origin: .user ...)
///                          (the Agent Accounts menu's own call)
///   - Enroll/Pause/Resume planning, context policy -> the capacity panel's native operations
/// There is no tool, route or Miko-visible path to this type. A card Run is the
/// only way an action card proceeds, as in Miko's own panel; a pane-origin
/// request is still a card and still waits here for the user.
@MainActor final class RelayControlCenterActions: ObservableObject {
    /// Shown beside the control that produced them: the existing path's own receipt or refusal.
    @Published private(set) var receipts: [String: String] = [:]
    @Published private(set) var working: Set<String> = []
    weak var workspace: WorkspaceModel?
    var supervision: RelayMikoSupervision
    var mover: RelayAgentAccountMove
    var capacity: RelayCapacityManagementCoordinator
    var budget: RelayBudgetSupervisor
    /// Asks the visible feed to refresh once after an action.
    var changed: () -> Void = {}

    init(workspace: WorkspaceModel?, supervision: RelayMikoSupervision = .shared, mover: RelayAgentAccountMove = .shared,
         capacity: RelayCapacityManagementCoordinator = .shared, budget: RelayBudgetSupervisor = .shared) {
        self.workspace = workspace
        self.supervision = supervision
        self.mover = mover
        self.capacity = capacity
        self.budget = budget
    }

    static let cardKey = "card"
    static let pauseKey = "pause"
    static func key(_ pane: String, _ action: String) -> String { pane + "." + action }

    private func finish(_ key: String, _ text: String?) {
        receipts[key] = text
        working.remove(key)
        changed()
    }

    // MARK: Item 1: cards

    /// The same call as the Run button in Miko's panel, for the card that was shown. If the
    /// harness's current card is a different one (the shown card expired or was resolved and
    /// another arrived), nothing runs and the section refreshes.
    @discardableResult func runCard(id: UUID) -> Bool {
        defer { changed() }
        guard let harness = workspace?.haikuAssistantStorage, harness.pendingCard?.id == id else { return false }
        harness.runCard()
        return true
    }

    @discardableResult func cancelCard(id: UUID) -> Bool {
        defer { changed() }
        guard let harness = workspace?.haikuAssistantStorage, harness.pendingCard?.id == id else { return false }
        harness.cancelCard()
        return true
    }

    // MARK: Item 2: pause

    func setMikoPaused(_ paused: Bool) {
        do {
            try supervision.setMikoPaused(paused)
            finish(Self.pauseKey, nil)
        } catch { finish(Self.pauseKey, "Miko pause could not be saved: " + error.localizedDescription) }
    }

    // MARK: Item 3: context roll and the native planning controls

    private func pane(_ id: String) -> PaneModel? {
        UUID(uuidString: id).flatMap { workspace?.panes[$0] }
    }

    @discardableResult
    func nativeAction(_ operation: String, paneID: String, label: String) async -> String {
        let key = Self.key(paneID, label)
        guard let pane = pane(paneID) else { finish(key, "Refused: that pane is not open here."); return "Refused" }
        guard !working.contains(key) else { return "Already running" }
        working.insert(key)
        let text = await capacity.userAction(operation, pane: pane)
        finish(key, text)
        return text
    }

    /// The panel's "Checked context refresh" for one exact pane. The receipt is the native one.
    @discardableResult func roll(paneID: String) async -> String {
        await nativeAction("capacity_manual_refresh", paneID: paneID, label: "roll")
    }

    @discardableResult func setContextPolicy(paneID: String, contextEnabled: Bool, thresholdTokens: Int64) async -> String {
        let key = Self.key(paneID, "policy")
        guard let pane = pane(paneID) else { finish(key, "Refused: that pane is not open here."); return "Refused" }
        working.insert(key)
        let text = await capacity.userContextPolicy(pane: pane, contextEnabled: contextEnabled, thresholdTokens: thresholdTokens)
        finish(key, text)
        return text
    }

    // MARK: Item 4: account migration

    /// Accounts this pane's provider can move to, excluding the one it is on.
    func targets(paneID: String) -> [RelayAgentAccount] {
        guard let pane = pane(paneID), let provider = RelayAgentAccountMovePolicy.movableProvider(pane.kind),
              pane.profile.backend == .relay else { return [] }
        let current = pane.agentAccount?.recorded
        return (RelayAgentAccountDirectory.shared.registeredAccounts(for: pane.profile, provider: provider) ?? [])
            .filter { $0.label != current?.label }
    }

    /// The Agent Accounts menu's own call: user origin, same refusals, same receipt.
    @discardableResult func move(paneID: String, to target: RelayAgentAccount) async -> RelayAgentAccountMove.Outcome? {
        let key = Self.key(paneID, "move")
        guard let workspace, let pane = pane(paneID) else { finish(key, "Refused: that pane is not open here."); return nil }
        guard !working.contains(key) else { return nil }
        working.insert(key)
        let outcome = await mover.move(pane, in: workspace, to: target, origin: .user, inputGranted: true)
        finish(key, outcome.state + ": " + outcome.message)
        return outcome
    }

    // MARK: Item 5: the user's notice level

    func setAccountNoticePercent(_ percent: Double) {
        budget.accountNoticePercent = percent
        changed()
    }
}

/// The pending action card with Run and Cancel.
struct RelayControlCardView: View {
    let card: RelayControlCenterState.PendingCard
    @ObservedObject var actions: RelayControlCenterActions

    var body: some View {
        let expired = Date() >= card.expiresAt
        VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
            Text("      Pending approval (\(card.origin)): \(card.title)").foregroundStyle(RelayTheme.coral)
            ForEach(card.rows, id: \.self) { Text("        " + $0).foregroundStyle(RelayTheme.textMuted) }
            if let literal = card.literal { Text("        " + literal).lineLimit(3).foregroundStyle(RelayTheme.textMuted) }
            if let blocked = card.blockedReason { Text("        Run is blocked: " + blocked).foregroundStyle(RelayTheme.coral) }
            if expired { Text("        Expired: Run can only expire it.").foregroundStyle(RelayTheme.textMuted) }
            HStack {
                Button("Cancel") { actions.cancelCard(id: card.id) }.accessibilityIdentifier("relay.control.card.cancel")
                Button(expired ? "Expire" : "Run") { actions.runCard(id: card.id) }
                    .disabled(card.blockedReason != nil).accessibilityIdentifier("relay.control.card.run")
            }
        }
    }
}

/// Per-pane controls: roll, planning enrollment, account move, context policy.
struct RelayControlPaneActions: View {
    let pane: RelayControlCenterState.Pane
    @ObservedObject var actions: RelayControlCenterActions
    @State private var thresholdTokens: Int64 = 0

    var body: some View {
        let id = pane.id
        VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
            if let capacity = pane.capacity {
                if capacity.supported || capacity.managed {
                    HStack {
                        Button("Roll context") { Task { await actions.roll(paneID: id) } }
                            .disabled(actions.working.contains(RelayControlCenterActions.key(id, "roll")))
                            .accessibilityIdentifier("relay.control.roll")
                        Button("Enroll") { Task { await actions.nativeAction("capacity_enroll", paneID: id, label: "plan") } }
                        Button("Pause auto") { Task { await actions.nativeAction("capacity_pause", paneID: id, label: "plan") } }
                        Button("Resume auto") { Task { await actions.nativeAction("capacity_resume", paneID: id, label: "plan") } }
                    }.padding(.leading, 24)
                    Stepper("Host context threshold: \(thresholdValue(capacity)) tokens",
                            value: Binding(get: { thresholdValue(capacity) }, set: { thresholdTokens = $0 }),
                            in: 10_000...2_000_000, step: 10_000).padding(.leading, 24)
                    HStack {
                        Button(capacity.contextEnabled ? "Turn host context policy off" : "Turn host context policy on") {
                            Task { await actions.setContextPolicy(paneID: id, contextEnabled: !capacity.contextEnabled,
                                                                 thresholdTokens: thresholdValue(capacity)) }
                        }
                        Button("Apply threshold") {
                            Task { await actions.setContextPolicy(paneID: id, contextEnabled: capacity.contextEnabled,
                                                                 thresholdTokens: thresholdValue(capacity)) }
                        }.disabled(thresholdValue(capacity) == capacity.thresholdTokens)
                    }.padding(.leading, 24)
                } else {
                    Text("      Roll unavailable: \(capacity.state): \(capacity.reason)").foregroundStyle(RelayTheme.textMuted)
                }
            } else {
                Text("      Roll unavailable: no native capacity status has been read for this pane yet").foregroundStyle(RelayTheme.textMuted)
            }
            let targets = actions.targets(paneID: id)
            if !targets.isEmpty {
                Menu("Move to account…") {
                    ForEach(targets, id: \.label) { target in
                        Button(target.label) { Task { await actions.move(paneID: id, to: target) } }
                    }
                }.fixedSize().padding(.leading, 24)
            }
            ForEach(["roll", "plan", "policy", "move"], id: \.self) { action in
                if let text = actions.receipts[RelayControlCenterActions.key(id, action)] {
                    Text("      \(action): " + text).foregroundStyle(RelayTheme.textMuted)
                }
            }
        }
    }

    private func thresholdValue(_ capacity: RelayControlCenterState.CapacitySummary) -> Int64 {
        thresholdTokens == 0 ? capacity.thresholdTokens : thresholdTokens
    }
}

/// Pause and the account-usage notice level.
struct RelayControlTopActions: View {
    let state: RelayControlCenterState
    @ObservedObject var actions: RelayControlCenterActions

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
            HStack {
                Button(state.mikoPaused ? "Resume Miko" : "Pause Miko") { actions.setMikoPaused(!state.mikoPaused) }
                    .accessibilityIdentifier("relay.control.pause")
                Stepper("Tell me at account usage \(Int(state.accountNoticePercent))%",
                        value: Binding(get: { state.accountNoticePercent }, set: { actions.setAccountNoticePercent($0) }),
                        in: 5...100, step: 5)
            }
            if let text = actions.receipts[RelayControlCenterActions.pauseKey] { Text(text).foregroundStyle(RelayTheme.coral) }
        }
    }
}
