import AppKit
import SwiftUI
import UserNotifications

/// What an inbox event asks of the user. Only these events mark a pane and can
/// raise a macOS banner; other inbox rows (peer traffic, subagents) stay in
/// the inbox.
enum RelayAttentionAlert: String, Codable, Sendable {
    case done
    case needsInput = "needs_input"
    case error
    /// A failed agent tool. Agents usually recover, so a pane waiting on the
    /// user still shows that first.
    case toolFailed = "tool_failed"

    /// The marker a pane shows when it has several unread alerts.
    var rank: Int {
        switch self {
        case .error: 0
        case .needsInput: 1
        case .toolFailed: 2
        case .done: 3
        }
    }

    /// Order in the sidebar inbox: a pane waiting on the user comes first.
    var inboxRank: Int {
        switch self {
        case .needsInput: 0
        case .error: 1
        case .toolFailed: 2
        case .done: 3
        }
    }

    /// Counted on the Dock badge: the pane cannot go on without the user.
    var needsUser: Bool { self == .error || self == .needsInput }

    var label: String {
        switch self {
        case .done: "Done"
        case .needsInput: "Needs input"
        case .error: "Error"
        case .toolFailed: "Tool failed"
        }
    }

    var symbol: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .needsInput: "exclamationmark.circle.fill"
        case .error: "xmark.octagon.fill"
        case .toolFailed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .done: RelayTheme.mint
        case .needsInput: RelayTheme.coral
        case .error, .toolFailed: RelayTheme.red
        }
    }

    /// Done and failed tools are routine; they banner without a sound.
    var playsSound: Bool { needsUser }
}

/// Banner rules, kept free of AppKit so they can be tested. A banner is shown
/// only while Relay is not frontmost, for an event at most `freshness` old (a
/// reconnect can deliver older events for the first time), at most once per
/// pane and alert per `paneInterval` (failed agent tools, which come in runs:
/// once per pane per `toolFailureInterval`), and at most `burstLimit` item
/// banners per `burstWindow`. The excess is reported later as one summary
/// banner, in addition to those: at most `burstLimit` + 1 per window.
struct RelayAttentionBannerPolicy {
    enum Decision: Equatable {
        case banner
        case coalesce
        case skip(String)
    }

    static let freshness: TimeInterval = 600
    static let paneInterval: TimeInterval = 60
    static let toolFailureInterval: TimeInterval = 600
    static let burstWindow: TimeInterval = 30
    static let burstLimit = 4

    private var lastBanner: [String: Date] = [:]
    private var recent: [Date] = []
    private(set) var coalesced = 0

    /// A pane outside focus is skipped before anything is counted, so it
    /// takes no place in the repeat interval or the burst.
    mutating func decide(paneID: UUID, alert: RelayAttentionAlert, occurredAt: Date,
                         now: Date, appActive: Bool, inFocus: Bool = true) -> Decision {
        if appActive { return .skip("Relay is frontmost") }
        guard inFocus else { return .skip("outside focus") }
        guard now.timeIntervalSince(occurredAt) <= Self.freshness else { return .skip("stale") }
        let key = paneID.uuidString + ":" + alert.rawValue
        let interval = alert == .toolFailed ? Self.toolFailureInterval : Self.paneInterval
        if let last = lastBanner[key], now.timeIntervalSince(last) < interval { return .skip("repeat") }
        lastBanner[key] = now
        if lastBanner.count > 1_024 {
            lastBanner = lastBanner.filter { now.timeIntervalSince($0.value) < Self.toolFailureInterval }
        }
        recent.removeAll { now.timeIntervalSince($0) >= Self.burstWindow }
        guard recent.count < Self.burstLimit else {
            coalesced += 1
            return .coalesce
        }
        recent.append(now)
        return .banner
    }

    mutating func takeCoalesced() -> Int {
        defer { coalesced = 0 }
        return coalesced
    }
}

/// Turns new inbox alerts into pane markers, a Dock badge and, while Relay is
/// in the background, macOS banners. Clicking a banner shows its pane.
@MainActor
final class RelayAttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RelayAttentionNotifier()

    private weak var workspace: WorkspaceModel?
    private var policy = RelayAttentionBannerPolicy()
    private var authorized: Bool?
    private var summaryTask: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    /// Focus changes seen, so tests can observe that focus reaches the badge.
    private(set) var focusChangeCount = 0

    init(workspace: WorkspaceModel? = nil) {
        self.workspace = workspace
        super.init()
    }

    /// Banners need a bundled app; tests and `swift run` get markers only.
    private static var bannersAvailable: Bool {
        !RelayLaunchMode.isRunningTests && Bundle.main.bundleURL.pathExtension == "app" &&
            Bundle.main.bundleIdentifier != nil
    }

    func install(workspace: WorkspaceModel) {
        self.workspace = workspace
        let store = AgentIntelligenceStore.shared
        store.onRecord = { [weak self] item in self?.recorded(item) ?? false }
        store.onPublish = { [weak self] in self?.updateDockBadge() }
        guard !RelayLaunchMode.isRunningTests else { return }
        // Returning to Relay counts as looking at the pane already in front.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let pane = self?.workspace?.activePaneID { AgentIntelligenceStore.shared.markPaneRead(pane) }
            }
        }
        if Self.bannersAvailable { UNUserNotificationCenter.current().delegate = self }
        updateDockBadge()
    }

    /// Called once per new inbox item. Returns true when the user is already
    /// looking at the pane, so the item is recorded as read.
    private func recorded(_ item: AgentInboxItem) -> Bool {
        let appActive = NSApp?.isActive ?? false
        if appActive, workspace?.activePaneID == item.paneID { return true }
        guard let alert = item.alert, let decision = bannerDecision(item, appActive: appActive) else { return false }
        switch decision {
        case .banner: post(item, alert: alert)
        case .coalesce: scheduleSummary()
        case .skip: break
        }
        return false
    }

    /// The banner policy's answer for a new item, or nil without an alert.
    /// A pane outside focus is skipped.
    func bannerDecision(_ item: AgentInboxItem, appActive: Bool, now: Date = Date()) -> RelayAttentionBannerPolicy.Decision? {
        guard let alert = item.alert else { return nil }
        return policy.decide(paneID: item.paneID, alert: alert, occurredAt: item.occurredAt,
                             now: now, appActive: appActive, inFocus: workspace?.isInFocus(paneID: item.paneID) ?? true)
    }

    private func paneName(_ id: UUID) -> String {
        workspace?.panes[id].map { $0.displayName } ?? "a pane"
    }

    private func post(_ item: AgentInboxItem, alert: RelayAttentionAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.label + " · " + paneName(item.paneID)
        content.body = item.title
        content.threadIdentifier = item.paneID.uuidString.lowercased()
        content.userInfo = ["pane_id": item.paneID.uuidString.lowercased()]
        if alert.playsSound { content.sound = .default }
        deliver(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
    }

    private func scheduleSummary() {
        guard summaryTask == nil else { return }
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RelayAttentionBannerPolicy.burstWindow))
            guard let self else { return }
            self.summaryTask = nil
            let count = self.policy.takeCoalesced()
            guard count > 0, !(NSApp?.isActive ?? false) else { return }
            let content = UNMutableNotificationContent()
            content.title = "Relay"
            content.body = count == 1 ? "1 more pane has an update." : "\(count) more panes have updates."
            self.deliver(UNNotificationRequest(identifier: "relay-attention-summary-" + UUID().uuidString,
                                               content: content, trigger: nil))
        }
    }

    /// CC-S2: tells the user an expensive pane cannot be managed, with the exact reasons.
    /// Banners need a bundled app; the same notice is always shown in the Control section.
    func postBudgetNotice(_ notice: RelayBudgetNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = (notice.signals + notice.holds).joined(separator: "; ")
        content.userInfo = ["pane_id": notice.paneID.uuidString.lowercased()]
        deliver(UNNotificationRequest(identifier: "relay-budget-" + notice.paneID.uuidString.lowercased(),
                                      content: content, trigger: nil))
    }

    private func deliver(_ request: UNNotificationRequest) {
        guard Self.bannersAvailable else { return }
        Task { [weak self] in
            guard let self, await self.authorize() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Asks once, at the first banner; macOS remembers the answer.
    private func authorize() async -> Bool {
        if let authorized { return authorized }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorized = granted
        return granted
    }

    /// Focus changed: the Dock badge counts only panes in focus.
    func focusChanged() {
        focusChangeCount += 1
        updateDockBadge()
    }

    /// How many panes need the user: input or a reported error. While
    /// focusing, only panes in focus count; one in no focused workspace does not.
    func badgeCount(inbox: AgentIntelligenceStore = .shared) -> Int {
        let inside = workspace?.panesInFocus()
        return inbox.panesNeedingUser { inside?.contains($0) ?? true }
    }

    /// The Dock shows `badgeCount`.
    private func updateDockBadge() {
        guard !RelayLaunchMode.isRunningTests, let application = NSApp else { return }
        let count = badgeCount()
        let label = count > 0 ? String(count) : nil
        if application.dockTile.badgeLabel != label { application.dockTile.badgeLabel = label }
    }

    private func open(_ paneID: UUID) {
        NSApp?.activate(ignoringOtherApps: true)
        guard let workspace, workspace.panes[paneID] != nil else { return }
        _ = try? workspace.selectWorkspacePane(paneID)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["pane_id"] as? String,
              let paneID = UUID(uuidString: raw) else {
            await MainActor.run { _ = NSApp?.activate(ignoringOtherApps: true) }
            return
        }
        await MainActor.run { self.open(paneID) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Frontmost Relay shows the pane markers instead.
        []
    }
}
