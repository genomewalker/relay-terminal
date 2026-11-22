import Foundation

/// A restored Relay terminal pane that may attach before its tab is shown.
struct RelayBackgroundAttachCandidate: Equatable, Sendable {
    let paneID: UUID
    let hostKey: String
    let isLocal: Bool
    let isTerminal: Bool
    let requiresExistingWorker: Bool
    let connecting: Bool
    /// The grid the pane's snapshot log was saved at.
    let savedViewport: RelayViewport?
    /// Already started, but its node reconnected and holds the pane's route
    /// until the pane is shown or sent input (cb9f8636).
    var waitingAfterReconnect = false
    /// Started and connected, but its saved screen was cut short at restore,
    /// so it cannot be read until the worker sends a fresh screen.
    var screenCutShort = false
}

/// What the pooled node connection for one host reports right now.
struct RelayBackgroundAttachNode: Equatable, Sendable {
    let phase: NetworkTransportSnapshot.Phase
    let generation: Int
    let heartbeatCurrent: Bool
}

/// After a relaunch a remote pane attaches only when its tab is laid out, so
/// panes in tabs not yet opened stay "Connecting". This policy attaches them
/// in the background, one at a time per host. On dandy-07 (2026-10-30
/// 04:06:15Z) opening one tab attached four panes together; their replays
/// held the shared SSH link long enough to miss three heartbeats, and the
/// restart reattached every pane on the node.
struct RelayBackgroundAttachPolicy {
    /// Minimum time between two background attaches on one host.
    static let gapNanoseconds: UInt64 = 1_500_000_000
    /// An attach that has not left "Connecting" by then stops holding its host.
    static let attachTimeoutNanoseconds: UInt64 = 20_000_000_000
    /// A node that restarted gets this long to settle before the next attach.
    static let settleAfterRestartNanoseconds: UInt64 = 15_000_000_000
    /// Minimum time between two wakes on one host. Wakes replay whole saved
    /// screens (2.8-6.6 MB on dandy-07); the 2026-11-22 12:52Z drop ended a
    /// wave of about 30 such replays at the 1.5 s attach gap.
    static let wakeGapNanoseconds: UInt64 = 5_000_000_000
    /// A node that reconnects this soon after a wake on its host may have been
    /// dropped by the wakes themselves; that host's waiting panes are then
    /// left to be shown or sent input, so a reconnect cannot loop.
    static let wakeDropWindowNanoseconds: UInt64 = 120_000_000_000

    private struct HostState {
        var inFlight: UUID?
        var inFlightSince: UInt64 = 0
        var lastStart: UInt64?
        var generation: Int?
        var quietUntil: UInt64 = 0
        var lastWake: UInt64?
        /// The node generation in which this host's waiting panes are not woken.
        var wakesHeldInGeneration: Int?
    }

    private var hosts: [String: HostState] = [:]
    private(set) var attempted: Set<UUID> = []
    /// Panes asked once for a fresh screen while cut short. Forgotten when the
    /// pane is seen readable, so a later cut-short restore asks again.
    private(set) var refreshed: Set<UUID> = []

    mutating func forgetRefresh(_ paneID: UUID) { refreshed.remove(paneID) }
    mutating func forgetRefreshes() { refreshed.removeAll() }

    /// Local workers need the same background attachment as remote workers.
    /// Only an existing worker is ever attached: a Hello without
    /// require_existing_worker would start a new shell on the host. Without a
    /// saved grid the Hello would carry the 120×36 default and the worker
    /// would resize the running program to it, so such a pane waits for its tab.
    ///
    /// A started pane whose node reconnected in place is also eligible: its
    /// route waits until shown, so without a wake a hidden pane stayed
    /// "Reconnecting" for good. On dandy-07 (2026-11-22 12:52Z) the node
    /// reconnected within a second, and 68 hidden agent panes, all attached
    /// before it, never attached again while every not-yet-started pane did.
    /// Woken one at a time per host, their screens are still not resent at once.
    static func eligible(_ candidate: RelayBackgroundAttachCandidate) -> Bool {
        guard candidate.isTerminal else { return false }
        if candidate.waitingAfterReconnect || candidate.screenCutShort { return true }
        return candidate.requiresExistingWorker && candidate.connecting && candidate.savedViewport != nil
    }

    /// Eligible and not yet handled: a first start happens once per pane, a
    /// wake whenever a reconnect leaves the pane waiting again.
    func pending(_ candidate: RelayBackgroundAttachCandidate) -> Bool {
        guard Self.eligible(candidate) else { return false }
        if candidate.screenCutShort, !candidate.waitingAfterReconnect { return !refreshed.contains(candidate.paneID) }
        guard candidate.waitingAfterReconnect else { return !attempted.contains(candidate.paneID) }
        let host = hosts[candidate.hostKey]
        return host?.generation == nil || host?.wakesHeldInGeneration != host?.generation
    }

    var isIdle: Bool { hosts.values.allSatisfy { $0.inFlight == nil } }

    /// Panes to start now, at most one per host, in `candidates` order.
    /// `settled` reports whether a started pane has left "Connecting".
    mutating func next(
        _ candidates: [RelayBackgroundAttachCandidate],
        nodes: [String: RelayBackgroundAttachNode],
        settled: (UUID) -> Bool,
        now: UInt64
    ) -> [RelayBackgroundAttachCandidate] {
        var byHost: [String: [RelayBackgroundAttachCandidate]] = [:]
        var hostOrder: [String] = []
        for candidate in candidates where pending(candidate) {
            if byHost[candidate.hostKey] == nil { hostOrder.append(candidate.hostKey) }
            byHost[candidate.hostKey, default: []].append(candidate)
        }
        for key in hosts.keys where byHost[key] == nil { hostOrder.append(key) }
        var chosen: [RelayBackgroundAttachCandidate] = []
        for key in hostOrder {
            var state = hosts[key] ?? HostState()
            defer { hosts[key] = state }
            let node = nodes[key]
            if let node {
                if let known = state.generation, known != node.generation {
                    state.quietUntil = now &+ Self.settleAfterRestartNanoseconds
                    if let wake = state.lastWake, now &- wake < Self.wakeDropWindowNanoseconds {
                        state.wakesHeldInGeneration = node.generation
                    }
                }
                state.generation = node.generation
            }
            if let inFlight = state.inFlight {
                guard settled(inFlight) || now &- state.inFlightSince >= Self.attachTimeoutNanoseconds else { continue }
                state.inFlight = nil
            }
            let wakesHeld = state.generation != nil && state.wakesHeldInGeneration == state.generation
            guard let candidate = byHost[key]?.first(where: { !(wakesHeld && $0.waitingAfterReconnect) }),
                  now >= state.quietUntil else { continue }
            if let last = state.lastStart, now &- last < Self.gapNanoseconds { continue }
            if candidate.waitingAfterReconnect, let wake = state.lastWake, now &- wake < Self.wakeGapNanoseconds { continue }
            // No node yet: the first attach opens the host's shared link. A
            // node whose last pane left is stopped and restarts only when a
            // pane joins it, so it is treated the same: on dandy-07
            // (2026-10-30 08:14Z) waiting for it to become ready left 19
            // panes in "Connecting" until the app relaunched.
            if let node, node.phase != .inactive, node.phase != .ready || !node.heartbeatCurrent { continue }
            if candidate.screenCutShort { refreshed.insert(candidate.paneID) } else { attempted.insert(candidate.paneID) }
            state.inFlight = candidate.paneID
            state.inFlightSince = now
            state.lastStart = now
            if candidate.waitingAfterReconnect { state.lastWake = now }
            chosen.append(candidate)
        }
        return chosen
    }
}

/// Runs the policy for every restored workspace until no restored Relay pane
/// is left waiting for its tab. It never starts a worker, never restarts a
/// node and never touches a pane that is already attaching.
@MainActor final class RelayBackgroundAttachScheduler {
    static let shared = RelayBackgroundAttachScheduler()
    static let tickMilliseconds = 250
    /// The shown tabs lay out and claim their own panes first.
    static let firstPassDelayMilliseconds = 2000

    private final class WeakWorkspace { weak var value: WorkspaceModel?; init(_ value: WorkspaceModel) { self.value = value } }
    private var workspaces: [WeakWorkspace] = []
    private var policy = RelayBackgroundAttachPolicy()
    private var savedViewports: [UUID: RelayViewport?] = [:]
    private var task: Task<Void, Never>?
    /// A host that has had waiting panes and no attach this long is
    /// recorded, then at most once per repeat interval, with its node state.
    static let waitingReportNanoseconds: UInt64 = 30_000_000_000
    static let waitingRepeatNanoseconds: UInt64 = 60_000_000_000
    private var heldSince: [String: UInt64] = [:]
    private var lastWaitingReport: [String: UInt64] = [:]

    /// Tests replace the remembered workspaces with their own panes.
    var panes: (@MainActor () -> [PaneModel])?
    var nodes: () -> [NetworkTransportSnapshot] = { RelayNodeTransportPool.shared.networkSnapshots() }
    var uptime: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    var savedViewport: (UUID) -> RelayViewport? = { TerminalSnapshotStore.shared.savedViewport(paneID: $0) }
    /// The grid the pane's tab would give it now, if it can be computed.
    /// Preferred to the saved grid, which can be stale (RelayHiddenPaneGrid).
    var layoutViewport: (@MainActor (PaneModel) -> RelayViewport?)?
    private var owners: [UUID: WeakWorkspace] = [:]
    var start: @MainActor (PaneModel, RelayViewport) -> Void = { pane, viewport in
        pane.runtime.startInBackground(viewport: viewport)
    }
    /// Whether a started hidden pane's route waits after a node reconnect.
    var waiting: @MainActor (PaneModel) -> Bool = { $0.runtime.isWaitingUntilShownAfterReconnect }
    var wake: @MainActor (PaneModel) -> Void = { $0.runtime.wakeWaitingRouteInBackground() }
    /// Whether a started hidden pane's restored screen was cut short.
    var cutShort: @MainActor (PaneModel) -> Bool = { pane in
        pane.kind != .shell &&
            !RelayHiddenScreenRefresh.excluded(pane.id, protected: RelayPreferences.shared.maintenanceProtectedPanes) &&
            pane.runtime.hiddenScreenCutShort
    }
    /// Asks for one fresh screen; it may decline (busy agent, draft, approval).
    var refresh: @MainActor (PaneModel) async -> Bool = { await RelayHiddenScreenRefresh.refresh($0) }
    /// Refreshes still running; each holds its host until it returns.
    private var refreshing: Set<UUID> = []
    /// A pane was asked and is still cut short (its agent was busy, or the
    /// screen did not arrive): the loop is run again after this delay.
    static let refreshRetryMilliseconds = 60_000
    private(set) var refreshRetryDue = false
    /// Woken panes still on their way to "Connected"; they hold their host.
    private var woken: Set<UUID> = []
    private var nodeReadyObserver: NSObjectProtocol?
    var record: (String, [String: String]) -> Void = { RelayDiagnostics.shared.record(category: "pane", name: $0, details: $1) }

    func remember(_ workspace: WorkspaceModel) {
        guard !RelayLaunchMode.isRunningTests else { return }
        workspaces.removeAll { $0.value == nil }
        if !workspaces.contains(where: { $0.value === workspace }) { workspaces.append(.init(workspace)) }
        if nodeReadyObserver == nil {
            // A node that reconnects leaves its hidden panes waiting; the
            // loop has usually ended by then, so each ready restarts it.
            nodeReadyObserver = NotificationCenter.default.addObserver(forName: .relayNodeReady, object: nil,
                queue: .main) { [weak self] _ in
                Task { @MainActor in self?.run(after: Self.firstPassDelayMilliseconds) }
            }
        }
        run(after: Self.firstPassDelayMilliseconds)
    }

    private func run(after delayMilliseconds: Int) {
        guard task == nil, !workspaces.isEmpty else { return }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            while !Task.isCancelled {
                guard let self, self.step() else { break }
                try? await Task.sleep(for: .milliseconds(Self.tickMilliseconds))
            }
            guard let self else { return }
            self.task = nil
            if self.refreshRetryDue {
                self.policy.forgetRefreshes()
                self.run(after: Self.refreshRetryMilliseconds)
            }
        }
    }

    /// One pass. Returns whether a pane is still waiting or attaching.
    @discardableResult
    func step() -> Bool {
        let now = uptime()
        let current: [PaneModel]
        if let panes {
            current = Self.attachOrder(panes())
        } else {
            owners.removeAll(keepingCapacity: true)
            var hidden: [PaneModel] = []
            for workspace in workspaces.compactMap(\.value) {
                for pane in Self.hiddenPanes(workspace) {
                    owners[pane.id] = WeakWorkspace(workspace)
                    hidden.append(pane)
                }
            }
            current = Self.attachOrder(hidden)
        }
        var byID: [UUID: PaneModel] = [:]
        var candidates: [RelayBackgroundAttachCandidate] = []
        for pane in current {
            byID[pane.id] = pane
            if waiting(pane) {
                candidates.append(Self.candidate(pane, savedViewport: nil, waitingAfterReconnect: true))
                continue
            }
            if pane.connectionState == .connected {
                if cutShort(pane) {
                    var candidate = Self.candidate(pane, savedViewport: nil)
                    candidate.screenCutShort = true
                    candidates.append(candidate)
                } else {
                    policy.forgetRefresh(pane.id)
                }
                continue
            }
            // Read a log header only for a pane that could use it, once.
            guard RelayBackgroundAttachPolicy.eligible(Self.candidate(pane, savedViewport: .default)),
                  !policy.attempted.contains(pane.id) else { continue }
            let viewport: RelayViewport?
            if let cached = savedViewports[pane.id] { viewport = cached } else {
                viewport = savedViewport(pane.id)
                savedViewports[pane.id] = .some(viewport)
            }
            candidates.append(Self.candidate(pane, savedViewport: viewport))
        }
        var nodeStates: [String: RelayBackgroundAttachNode] = [:]
        for snapshot in nodes() {
            nodeStates[snapshot.id] = .init(phase: snapshot.phase, generation: snapshot.generation,
                heartbeatCurrent: snapshot.isCurrent(at: now))
        }
        woken = woken.filter { byID[$0].map { $0.connectionState != .connected } ?? false }
        refreshRetryDue = candidates.contains { $0.screenCutShort && !policy.pending($0) && !refreshing.contains($0.paneID) }
        let chosen = policy.next(candidates, nodes: nodeStates,
            settled: { [woken, refreshing] id in
                guard let pane = byID[id] else { return true }
                if refreshing.contains(id) { return false }
                return woken.contains(id) ? pane.connectionState == .connected : pane.connectionState != .connecting
            }, now: now)
        for candidate in chosen {
            guard let pane = byID[candidate.paneID] else { continue }
            if candidate.waitingAfterReconnect {
                record("background-wake", ["pane_id": pane.id.uuidString.lowercased(), "profile": pane.profile.name])
                woken.insert(pane.id)
                wake(pane)
                continue
            }
            if candidate.screenCutShort {
                record("background-screen-refresh", ["pane_id": pane.id.uuidString.lowercased(), "profile": pane.profile.name])
                refreshing.insert(pane.id)
                Task { @MainActor [weak self, refresh] in
                    _ = await refresh(pane)
                    self?.refreshing.remove(pane.id)
                }
                continue
            }
            guard let saved = candidate.savedViewport else { continue }
            let layout = layoutViewport.map { $0(pane) } ??
                owners[pane.id]?.value.flatMap { RelayHiddenPaneGrid.viewport(for: pane.id, in: $0) }
            let viewport = layout ?? saved
            RelayDiagnostics.shared.record(category: "pane", name: "background-attach", details: [
                "pane_id": pane.id.uuidString.lowercased(), "profile": pane.profile.name,
                "viewport": "\(viewport.columns)x\(viewport.rows)",
                "saved_viewport": "\(saved.columns)x\(saved.rows)",
                "source": layout == nil ? "saved" : "layout",
            ])
            start(pane, viewport)
        }
        recordHeldHosts(candidates, nodes: nodeStates, started: Set(chosen.map(\.hostKey)), now: now)
        return !policy.isIdle || candidates.contains(where: policy.pending)
    }

    /// Agents before shells, then by pane ID. This runs every tick over every
    /// hidden pane, so each pane's key is computed once and the ID order
    /// compares raw bytes: `uuidString` is their uppercase hex with hyphens
    /// at fixed places, which orders the same without building strings.
    static func attachOrder(_ panes: [PaneModel]) -> [PaneModel] {
        // Plain integers, so the sort moves no references.
        var keys: [(shell: Bool, high: UInt64, low: UInt64, index: Int)] = []
        keys.reserveCapacity(panes.count)
        for (index, pane) in panes.enumerated() {
            let id = orderKey(pane.id)
            keys.append((pane.kind == .shell, id.0, id.1, index))
        }
        keys.sort { lhs, rhs in
            if lhs.shell != rhs.shell { return !lhs.shell }
            if lhs.high != rhs.high { return lhs.high < rhs.high }
            return lhs.low < rhs.low
        }
        return keys.map { panes[$0.index] }
    }

    /// The UUID's 16 bytes as two big-endian halves: tuple order is byte order.
    nonisolated static func orderKey(_ id: UUID) -> (UInt64, UInt64) {
        withUnsafeBytes(of: id.uuid) { bytes in
            (UInt64(bigEndian: bytes.loadUnaligned(as: UInt64.self)),
             UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
        }
    }

    nonisolated static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        orderKey(lhs) < orderKey(rhs)
    }

    /// The 2026-10-30 08:14Z stall left no trace of why its host was held.
    private func recordHeldHosts(_ candidates: [RelayBackgroundAttachCandidate],
        nodes: [String: RelayBackgroundAttachNode], started: Set<String>, now: UInt64) {
        var waiting: [String: Int] = [:]
        for candidate in candidates where policy.pending(candidate) {
            waiting[candidate.hostKey, default: 0] += 1
        }
        for key in Set(heldSince.keys).union(waiting.keys) {
            guard let count = waiting[key], !started.contains(key) else { heldSince[key] = nil; continue }
            let since = heldSince[key] ?? now
            heldSince[key] = since
            guard now &- since >= Self.waitingReportNanoseconds,
                  lastWaitingReport[key].map({ now &- $0 >= Self.waitingRepeatNanoseconds }) ?? true else { continue }
            lastWaitingReport[key] = now
            let node = nodes[key]
            record("background-attach-waiting", [
                "host": key, "waiting": String(count), "held_seconds": String((now &- since) / 1_000_000_000),
                "node_phase": node.map { "\($0.phase)" } ?? "none",
                "heartbeat_current": node.map { String($0.heartbeatCurrent) } ?? "none",
            ])
        }
    }

    /// A pane in a shown tab attaches through its own layout, at the grid
    /// the window gives it, never at a saved one.
    static func hiddenPanes(_ workspace: WorkspaceModel) -> [PaneModel] {
        let shown = Set(workspace.selectedTab?.allPaneIDs ?? [])
        return workspace.panes.values.filter { !shown.contains($0.id) }
    }

    static func candidate(_ pane: PaneModel, savedViewport: RelayViewport?,
        waitingAfterReconnect: Bool = false) -> RelayBackgroundAttachCandidate {
        RelayBackgroundAttachCandidate(
            paneID: pane.id, hostKey: pane.profile.connectionKey,
            isLocal: pane.profile.kind == .local || pane.profile.backend != .relay,
            isTerminal: pane.contentKind == .terminal && pane.profile.backend == .relay,
            requiresExistingWorker: pane.requiresExistingWorker,
            connecting: pane.connectionState == .connecting,
            savedViewport: savedViewport,
            waitingAfterReconnect: waitingAfterReconnect
        )
    }
}
