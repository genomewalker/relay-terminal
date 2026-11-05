import Foundation

/// Delivers relayd's question-thread notices to agent panes. relayd records each
/// notice and sends it only on this app's request. The app owns the draft check:
/// a notice is delivered only into a pane with no typed text or composer state.
@MainActor final class RelayQuestionNoticeDelivery {
    static let interval: Duration = .seconds(5)

    private weak var workspace: WorkspaceModel?
    private var task: Task<Void, Never>?
    private var schedules: [String: RelayQuestionNotices.Schedule] = [:]

    init(workspace: WorkspaceModel?) {
        self.workspace = workspace
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let workspace = self.workspace else { return }
                await self.tick(workspace)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// One pass: each due host pulls queued notices for its agent panes, then
    /// delivers or holds each. Hosts with no bound pane, or a run of empty
    /// pulls, are pulled less often; see RelayQuestionNotices.Schedule.
    func tick(_ workspace: WorkspaceModel, now: Date = Date()) async {
        let hosts = RelayQuestionNotices.hosts(workspace)
        schedules = schedules.filter { key, _ in hosts.contains { $0.profile.connectionKey == key } }
        for host in hosts {
            let key = host.profile.connectionKey
            var schedule = schedules[key] ?? RelayQuestionNotices.Schedule()
            let panes = Set(host.paneIDs), activity = RelayQuestionNotices.activity[key]
            guard schedule.due(panes: panes, activity: activity, now: now) else { continue }
            let woken = schedule.woken(panes: panes, activity: activity)
            let reply = try? await RelayPaneMessaging.shared.pullQuestionNotices(profile: host.profile, paneIDs: host.paneIDs)
            let notices = reply?["notices"] as? [[String: Any]]
            schedule.pulled(panes: panes, woken: woken, notices: notices?.count, bound: reply?["bound"] as? [String], at: now)
            schedules[key] = schedule
            for notice in notices ?? [] {
                guard let raw = notice["pane_id"] as? String, let paneID = UUID(uuidString: raw),
                      let messageID = notice["message_id"] as? String,
                      let pane = workspace.panes[paneID] else { continue }
                switch RelayQuestionNotices.action(draftPresent: RelayQuestionNotices.draftPresent(pane)) {
                case .deliver:
                    _ = try? await RelayPaneMessaging.shared.sendQuestionNotice(profile: host.profile, paneID: paneID, messageID: messageID)
                case .holdDraft:
                    _ = try? await RelayPaneMessaging.shared.ackQuestionNoticeHeld(profile: host.profile, paneID: paneID, messageID: messageID)
                }
            }
        }
    }
}

enum RelayQuestionNotices {
    enum Action: Equatable {
        case deliver
        case holdDraft
    }

    struct Host {
        let profile: ConnectionProfile
        let paneIDs: [UUID]
    }

    /// Each pull is a durable host job, so a host is pulled only as often as
    /// it can matter. 5 s while notices may arrive; 30 s after three empty
    /// pulls; and when relayd reports no bound pane on the host, only a
    /// recheck every 2 min for a bind made elsewhere. A notice, a send or
    /// bind from this app to the host, or a change in its agent panes
    /// returns it to 5 s at once. A daemon that does not report bound panes
    /// is never treated as idle.
    struct Schedule: Equatable {
        static let active: TimeInterval = 5
        static let quiet: TimeInterval = 30
        static let unbound: TimeInterval = 120
        static let quietAfterEmptyPulls = 3

        var lastPull: Date?
        var panes: Set<UUID> = []
        var emptyPulls = 0
        var noBoundPanes = false

        var interval: TimeInterval {
            noBoundPanes ? Self.unbound : emptyPulls >= Self.quietAfterEmptyPulls ? Self.quiet : Self.active
        }

        /// A first pull, changed agent panes, or activity since the last pull.
        func woken(panes: Set<UUID>, activity: Date?) -> Bool {
            guard let lastPull, panes == self.panes else { return true }
            return activity.map { $0 >= lastPull } ?? false
        }

        func due(panes: Set<UUID>, activity: Date?, now: Date) -> Bool {
            guard let lastPull, !woken(panes: panes, activity: activity) else { return true }
            // A second of slack so the 5 s loop does not skip a due pull.
            return now.timeIntervalSince(lastPull) >= interval - 1
        }

        /// `notices` is nil when the pull failed. A failure counts as an empty
        /// pull but never marks the host unbound.
        mutating func pulled(panes: Set<UUID>, woken: Bool, notices: Int?, bound: [String]?, at now: Date) {
            lastPull = now
            self.panes = panes
            emptyPulls = (notices ?? 0) > 0 || woken ? 0 : emptyPulls + 1
            noBoundPanes = notices == 0 && bound?.isEmpty == true
        }
    }

    /// Communication operations from this app that can start question
    /// traffic on a host: they return its notice pull to 5 s.
    static let wakingOperations: Set<String> = ["send", "deliver_signed", "link", "question_bind", "question_notice_send"]
    @MainActor private(set) static var activity: [String: Date] = [:]
    @MainActor static func noteActivity(hostKey: String, at now: Date = Date()) { activity[hostKey] = now }

    /// Any composer text, attachment, pending send, or a prompt that is not confirmed empty is a draft.
    static func draftPresent(composerDraft: String, attachments: Int, submitting: Bool,
                             nativeDeliveryHeld: Bool, promptConfirmedEmpty: Bool) -> Bool {
        !composerDraft.isEmpty || attachments > 0 || submitting || nativeDeliveryHeld || !promptConfirmedEmpty
    }

    static func action(draftPresent: Bool) -> Action {
        draftPresent ? .holdDraft : .deliver
    }

    @MainActor static func draftPresent(_ pane: PaneModel) -> Bool {
        let composer = pane.composerStateIfCreated
        return draftPresent(composerDraft: composer?.draft ?? "", attachments: composer?.attachmentQueue.attachments.count ?? 0,
                            submitting: composer?.submitting ?? false, nativeDeliveryHeld: composer?.nativeDeliveryHeld ?? false,
                            promptConfirmedEmpty: pane.runtime.agentMaintenanceTerminalPromptIsEmpty)
    }

    /// Agent terminals on each Relay host, grouped by host.
    @MainActor static func hosts(_ workspace: WorkspaceModel) -> [Host] {
        var grouped: [String: (ConnectionProfile, [UUID])] = [:]
        for pane in workspace.panes.values where pane.contentKind == .terminal && pane.profile.backend == .relay
            && (pane.kind == .claude || pane.kind == .codex) {
            grouped[pane.profile.connectionKey, default: (pane.profile, [])].1.append(pane.id)
        }
        return grouped.values.map { Host(profile: $0.0, paneIDs: $0.1) }
    }

    static func pullPacket(paneIDs: [UUID]) -> [String: Any] {
        ["operation": "question_notices", "panes": paneIDs.map { $0.uuidString.lowercased() }]
    }

    static func sendPacket(paneID: UUID, messageID: String) -> [String: Any] {
        ["operation": "question_notice_send", "pane_id": paneID.uuidString.lowercased(), "message_id": messageID]
    }

    static func heldPacket(paneID: UUID, messageID: String) -> [String: Any] {
        ["operation": "question_notice_ack", "pane_id": paneID.uuidString.lowercased(), "message_id": messageID, "outcome": "held_draft"]
    }
}
