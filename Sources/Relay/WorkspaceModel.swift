import AppKit
import Foundation

struct AgentInspectorSelection: Hashable, Sendable {
    let paneID: UUID
    let subagentID: String
}

enum TabMovePlacement: String, Codable, Equatable, Sendable {
    case before
    case after
}

/// Why a layout operation was refused. Nothing is partially applied.
enum WorkspaceLayoutError: Error, LocalizedError, Equatable {
    case unknownPane, unknownTab, samePane
    case differentSession
    case floatingPane
    case rPresentationBound
    case alreadyStacked, notStacked
    case lastPaneInTab

    var errorDescription: String? {
        switch self {
        case .unknownPane: "That pane is no longer in this workspace."
        case .unknownTab: "That tab is no longer in this workspace."
        case .samePane: "Choose a different pane."
        case .differentSession: "Panes can move only between tabs of the same session."
        case .floatingPane: "Dock the floating pane before stacking or moving it."
        case .rPresentationBound: "This pane is part of an R workspace. Move the R console and its panels together, or close the R workspace first."
        case .alreadyStacked: "That pane is already in this stack."
        case .notStacked: "That pane is not in a stack."
        case .lastPaneInTab: "This is the only pane in its tab. Move the tab into a group instead."
        }
    }
}

struct ClosedPaneRecovery: Codable, Identifiable, Sendable {
    var id = UUID()
    var closedAt = Date()
    let pane: PaneSnapshot
    let tab: TabSnapshot
    let tabIndex: Int
    let floatingPlacement: FloatingPanePlacement?
}

private struct TabPresentationState {
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?
}

private struct SupervisorAdvisoryRequestKey: Equatable {
    let identity: RelaySupervisedSessionID
    let stage: RelaySupervisorStage
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var tabs: [TabModel] = [] {
        didSet {
            let open = Set(tabs.map(\.id))
            for tab in oldValue where !open.contains(tab.id) { noteDeparture(tab.allPaneIDs, from: tab, via: "tabs") }
            for tab in tabs where tab.onPanesLeft == nil { observeDepartures(tab) }
            reconcileOwnership()
        }
    }
    /// Panes that left a tab since the last save, where from and by which
    /// code path. A save reports any that is in no tab and was not closed.
    private var paneDepartures: [UUID: PaneDeparture] = [:]
    /// Panes closed (or replaced) with a close record since the last save.
    private var closedSinceSave: Set<UUID> = []
    @Published private(set) var navigationState = WorkspaceNavigationState.load()
    /// Workspaces in focus, as chosen; empty when not focusing. Never saved:
    /// focus ends when Relay quits, so it cannot hide a waiting pane for days.
    @Published private(set) var focusedWorkspaces: [UUID] = []
    /// The navigator's hold and row expansion. Apart from the workspace, so
    /// the pointer crossing the list redraws only the navigator.
    let navigatorHoldState = WorkspaceNavigatorHold()
    /// Navigator row ranks held while the pointer is over the list or a drag
    /// runs; nil when rows follow the chosen order.
    var navigatorHold: [UUID: Int]? {
        get { navigatorHoldState.ranks }
        set { navigatorHoldState.ranks = newValue }
    }
    /// The inbox rows shown when the hold began. The inbox sits above the
    /// workspace rows, so a row coming or going would move them under the
    /// pointer; while held only the user's own dismissal removes a row.
    var inboxHold: [AttentionInboxEntry]? {
        get { navigatorHoldState.inbox }
        set { navigatorHoldState.inbox = newValue }
    }
    /// When the pointer left the held list; a brief exit keeps the hold.
    var navigatorPointerLeftAt: Date?
    /// The store the held rows came from, so a focus change retakes them.
    private var inboxHoldSource: AgentIntelligenceStore?
    /// Waiting panes the user dismissed from the inbox, by the wait dismissed
    /// (`PaneModel.waitIdentity`); a new wait lists them again. Not saved.
    @Published private(set) var dismissedAttention: [UUID: String] = [:]
    @Published var selectedTabID: UUID? {
        willSet {
            guard newValue != selectedTabID, let tab = selectedTab else { return }
            if let paneID = tab.chrome.anchor?.paneID {
                pluginPresentations[paneID]?.suspendForWorkspaceCover()
            }
            tab.chrome.suspendPresentation()
            tabPresentationStates[tab.id] = TabPresentationState(
                focusedPaneID: activePaneID,
                zoomedPaneID: zoomedPaneID
            )
        }
        didSet {
            guard selectedTabID != oldValue else { return }
            if let tab = selectedTab {
                // A temporary selection (`withoutNavigationEffects`) is never
                // remembered, published or shown.
                if navigationEffectsSuspended == 0 {
                    let workspaceID = ownership.owner(of: tab.id)
                    navigationState = WorkspaceNavigationState.updating {
                        $0.remember(tabID: tab.id, sessionID: tab.sessionID)
                        $0.noteUse([(.tab, tab.id), (.session, tab.sessionID)])
                        if let workspaceID {
                            $0.remember(tabID: tab.id, sessionID: workspaceID)
                            $0.visibleWorkspace = workspaceID
                        }
                    }
                    if let workspaceID { visibleWorkspaceID = workspaceID }
                }
            }
            // Keep a tab's presentation separate from the remote session. A
            // switch must not unzoom it or select its first shell on return.
            let paneIDs = Set(selectedTab?.allPaneIDs ?? [])
            RelayHostAgentMonitor.shared.setVisibleSessions(Set(paneIDs.map { $0.uuidString.lowercased() }),
                workspace: ObjectIdentifier(self))
            let state = selectedTabID.flatMap { tabPresentationStates[$0] }
            zoomedPaneID = state?.zoomedPaneID.flatMap { paneIDs.contains($0) ? $0 : nil }
            activePaneID = zoomedPaneID
                ?? state?.focusedPaneID.flatMap { paneIDs.contains($0) ? $0 : nil }
                ?? selectedTab?.layout.paneIDs.first
            tabPresentationStates = tabPresentationStates.filter { id, _ in
                tabs.contains { $0.id == id }
            }
            if !networkVisible, selectedTab?.chrome.visible == true {
                selectedTab?.chrome.resumePresentation()
                if let paneID = selectedTab?.chrome.anchor?.paneID {
                    pluginPresentations[paneID]?.resumeAfterWorkspaceCover()
                }
            }
        }
    }
    @Published var activePaneID: UUID? {
        didSet {
            guard activePaneID != oldValue else { return }
            paneShown(activePaneID)
            updateTerminalFocusOwnership()
            if let pane = activePane {
                selectedTab?.chrome.activeContextChanged(WorkspaceContextAnchor(
                    paneID: pane.id, profile: pane.profile, directory: pane.directory))
            }
        }
    }
    @Published var isConnectionSheetPresented = false
    @Published var isQuickNavigatePresented = false {
        didSet { updateTerminalFocusOwnership() }
    }
    private weak var quickNavigateOriginPane: PaneModel?
    private var quickNavigateOriginTabID: UUID?
    private var quickNavigateOriginWorkspaceID: UUID?
    private var quickNavigateChoseDestination = false
    private var quickNavigateAction: (() -> Void)?
    @Published var isHostLauncherPresented = false
    @Published var isPaneLinkPresented = false
    @Published var isFleetBoardPresented = false {
        didSet { updateTerminalFocusOwnership() }
    }
    /// The board's status chip when it opens; set by `presentFleetBoard`.
    private(set) var fleetBoardInitialFilter: RelayFleetFilter = .all
    /// What the window shows. Entering full screen may hide it for the
    /// duration (`sidebarAutoHidden`); that is not the user's choice, so the
    /// saved workspace keeps the visibility the user set.
    @Published var sidebarVisible = false {
        didSet { if !applyingFullScreenSidebar { sidebarAutoHidden = false } }
    }
    /// True while full screen hides a sidebar the user left visible.
    private(set) var sidebarAutoHidden = false
    private var applyingFullScreenSidebar = false
    /// The sidebar visibility the user chose, as saved and restored.
    var savedSidebarVisible: Bool { sidebarVisible || sidebarAutoHidden }
    /// Panes the user opened, for Go to pane. Programmatic selection is not recorded.
    @Published private(set) var paneVisits = PaneVisitHistory()
    @Published var networkVisible = false {
        didSet {
            guard networkVisible != oldValue else { return }
            if networkVisible {
                if let paneID = selectedTab?.chrome.anchor?.paneID {
                    pluginPresentations[paneID]?.suspendForWorkspaceCover()
                }
                selectedTab?.chrome.suspendPresentation()
            } else {
                selectedTab?.chrome.resumePresentation()
                if let paneID = selectedTab?.chrome.anchor?.paneID {
                    pluginPresentations[paneID]?.resumeAfterWorkspaceCover()
                }
            }
            updateTerminalFocusOwnership()
        }
    }
    let paneLinkSelection = PaneLinkSelection()

    func showNetwork() {
        networkVisible = true
        // Navigation is deliberate; hidden terminals must not retain input.
        NSApp?.keyWindow?.makeFirstResponder(nil)
    }

    func hideNetwork() {
        guard networkVisible else { return }
        networkVisible = false
        guard let paneID = activePaneID, let pane = panes[paneID] else { return }
        Task { @MainActor in
            await Task.yield()
            guard !self.networkVisible, !self.paneLinkSelection.active,
                  self.activePaneID == paneID, self.panes[paneID] === pane else { return }
            pane.focus()
        }
    }
    @Published var isFullScreen = false
    @Published var zoomedPaneID: UUID?
    @Published var draftProfile = ConnectionProfile()
    @Published var renameTarget: WorkspaceRenameTarget?
    @Published var renameDraft = ""
    @Published var agentInspector: AgentInspectorSelection?
    @Published var intelligencePanelVisible = false
    @Published var assistantVisible = false
    @Published var haikuAssistantVisible = false
    @Published var haikuAssistantDraft = ""
    var haikuAssistantStorage: RelayAssistantHarness?
    /// The MCP control route the assistant's Change actions run through.
    weak var assistantActionExecutor: (any RelayAssistantActionExecutor)?
    /// Folders the Relay assistant resolved uniquely on a host (by connection
    /// key); with existing pane directories, the only admitted starting directories.
    var assistantResolvedDirectories: [String: Set<String>] = [:]

    /// A new tab or split may start only in a directory some workspace pane on
    /// that host already uses, or one the assistant resolved there.
    func admitsStartingDirectory(_ directory: String, profile: ConnectionProfile) -> Bool {
        panes.values.contains { $0.profile.connectionKey == profile.connectionKey && $0.directory == directory } ||
            assistantResolvedDirectories[profile.connectionKey]?.contains(directory) == true
    }
    private var assistantStorage: RelayAssistantController?
    var assistantController: RelayAssistantController {
        if let assistantStorage { return assistantStorage }
        let controller = RelayAssistantController(workspace: self)
        assistantStorage = controller
        return controller
    }
    @Published var energyMonitorMode = false
    @Published var performancePanelVisible = false
    @Published var performancePanelSection = "Performance"
    @Published var terminationTargetID: UUID?
    @Published var operationError: String?
    @Published private(set) var sessionNames: [UUID: String] = [:]
    @Published private(set) var pinnedSessionIDs = WorkspacePinStore.load(.session)
    @Published private(set) var pinnedTabIDs = WorkspacePinStore.load(.tab)
    /// Tabs whose close is waiting on native confirmation (for example an
    /// unsaved-editor prompt). Agents may not move or anchor to them.
    private(set) var tabsAwaitingCloseConfirmation: Set<UUID> = []
    @Published private(set) var pinnedPaneIDs = WorkspacePinStore.load(.pane)
    @Published private(set) var recentlyClosedPaneCount = 0
    @Published var isRecoveryPresented = false
    @Published private(set) var recoveringTabIDs: Set<UUID> = []
    @Published private(set) var recoveringConversationPaneIDs: Set<UUID> = []
    @Published private(set) var paneCloseEvent = 0
    @Published private(set) var lastClosedPaneWasRemote = false
    // Rewritten by the 5 s supervisor loop with a fresh `observedAt` each time.
    // No view reads them, so publishing invalidated every WorkspaceModel
    // observer twice per tick (the idle-CPU and hitch source in the 0.5.36
    // profile). Readers (Performance sampler, decision backend) pull on demand.
    private(set) var supervisorRecommendations: [UUID: RelaySupervisorRecommendation] = [:]
    private(set) var supervisorAdvisories: [UUID: RelaySupervisorAdvisory] = [:]
    @Published private(set) var supervisorReceipts: [UUID: RelaySupervisorActionReceipt] = [:]

    let profileStore = ProfileStore()
    let activityIndex = WorkspaceActivityIndex()
    private(set) var panes: [UUID: PaneModel] = [:]
    private var floatingRPaneTabs: [UUID: UUID] = [:]
    private var floatingRPrimaryEditors: [UUID: UUID] = [:]
    var savedRPresentations: [RWorkspacePresentation] = []
    var captureRPresentations: (() -> [RWorkspacePresentation])?
    /// Shows the floating R workspace that holds a pane. Set by the window layer.
    var revealFloatingRPane: ((UUID) -> Void)?
    /// Starts an editor without waiting for its view to be drawn, so a
    /// restored editor in a hidden tab connects. Tests replace it.
    var startEditorRuntime: (PaneModel) -> Void = { pane in
        guard !RelayLaunchMode.isRunningTests else { return }
        pane.editorRuntime.startIfNeeded()
    }

    /// Terminals reattach through their own subscriptions when a node is ready
    /// again. An editor whose start failed meanwhile has none, so start it here.
    func restartDisconnectedEditors(connectionKey: String) {
        for pane in panes.values where pane.contentKind == .editor && pane.profile.connectionKey == connectionKey {
            if case .disconnected = pane.connectionState { startEditorRuntime(pane) }
        }
    }

    func persistRPresentation() { persistWorkspace() }

    func rPresentationTabID(consoleID: UUID) -> UUID? {
        tabs.first(where: { $0.allPaneIDs.contains(consoleID) })?.id ?? floatingRPaneTabs[consoleID]
    }
    private let editorInputRequests = AgentInputRequests()
    private let workspaceKey = "relay.workspace.v1"
    let sharedWorkspaceStore: RelaySharedWorkspaceStore
    private var workspaceBaseline: WorkspaceSnapshot?
    private var organizationBaseline: WorkspaceOrganizationSnapshot?
    /// Which workspace owns each tab. Tabs keep their legacy `sessionID` as
    /// birth identity and for the `sessions` compatibility projection.
    @Published private(set) var ownership = WorkspaceOwnershipSnapshot.empty
    /// What this renderer last submitted, like `workspaceBaseline`.
    private var ownershipBaseline: WorkspaceOwnershipSnapshot?
    private var ownershipReady = false
    /// False only while init restores: a failed restore discards its panes.
    private var monitorsStoredPanes = false
    /// False after an unreadable or newer ownership file: never overwrite it.
    private var ownershipWritable = true
    private var tabAdmission: WorkspaceTabAdmission?
    /// The shown workspace (see `selectedWorkspaceID`), mirrored to the
    /// persisted navigation state.
    @Published private var visibleWorkspaceID: UUID?
    /// The tab selected before an empty workspace was shown. Used only to
    /// return to it and as the legacy session source for New Tab; never as
    /// the target of a pane or tab command.
    private var rememberedTabID: UUID?
    /// Depth of `withoutNavigationEffects`; while positive, selection changes
    /// write no navigation preference and do not change the shown workspace.
    private var navigationEffectsSuspended = 0
    /// Set while `revealPane` runs; see `paneShown`.
    private var revealingPaneID: UUID?
    /// The open migration preview, from the sheet or an agent's staged plan.
    /// Applied by the user's button, or by an agent quoting its ID and checksum.
    @Published private(set) var migrationPreview: WorkspaceMigrationPreview?
    /// The plan behind `migrationPreview`, its inbox name, and whether an
    /// agent staged it for the user to review.
    @Published private(set) var migrationPlan: (plan: WorkspaceMigrationPlan, name: String?, staged: Bool, digest: String)?
    @Published var isMigrationPresented = false
    /// Set when a failed migration step left saved state this renderer could
    /// not read back. Saves are held, so nothing overwrites it unsettled.
    private var migrationUnsettled = false
    /// The pane-link janitor's store. Tests get none unless they inject one,
    /// so no test workspace sweeps another test's links.
    var paneLinkJanitor: RelayPaneMessaging? = RelayLaunchMode.isRunningTests ? nil : .shared
    private var paneLinkJanitorTask: Task<Void, Never>?
    private var paneLinkJanitorSavedPaneIDs: Set<UUID> = []
    /// Groups, saved views and navigation. Presentation only.
    lazy var organization: WorkspaceOrganizationController = {
        let controller = WorkspaceOrganizationController(workspace: self)
        controller.onChange = { [weak self] in self?.persistWorkspace() }
        return controller
    }()
    private var workspaceSaveCanClose = true
    @Published private(set) var workspacePersistenceIssue: String?
    @Published private(set) var workspacePendingChanges = 0
    private var persistenceTask: Task<Void, Never>?
    /// Committed workspace saves. `persistWorkspace` is a trailing debounce,
    /// so rapid selections (and their visits) share one save.
    private(set) var workspaceSaveCount = 0
    private var supervisorTask: Task<Void, Never>?
    private var supervisorAdvisoryTask: Task<Void, Never>?
    private var supervisorAdvisoryRequestKey: SupervisorAdvisoryRequestKey?
    private var sessionSupervisor = RelaySessionSupervisor()
    private var supervisorActionBroker = RelaySupervisorActionBroker()
    private var supervisorActionExecutor = RelaySupervisorActionExecutor()
    private let supervisorAuditStore = RelaySupervisorAuditStore.shared
    private var presentationFocusTask: Task<Void, Never>?
    private var didShutdown = false
    private var recentlyClosedPanes: [ClosedPaneRecovery] = []
    private var tabPresentationStates: [UUID: TabPresentationState] = [:]
    // Retained above transient sheets/tabs so dispatched outcomes remain
    // reachable even when their presenter or originating tab disappears.
    private var pluginPresentations: [UUID: PluginToolPresentation] = [:]
    private var retiredPluginPresentations: [UUID: [PluginToolPresentation]] = [:]

    private let recoveryStore: RelayRecoveryStore
    /// Nil uses the shared host agent monitor.
    private let agentMonitorService: RelayHostAgentMonitor?

    /// `workspaceDirectory` and `recoveryStore` override the profile's stores,
    /// and `agentMonitor` the shared host agent monitor, for tests.
    init(restoreSavedWorkspace: Bool = true, workspaceDirectory: URL? = nil,
         recoveryStore: RelayRecoveryStore = .shared, agentMonitor: RelayHostAgentMonitor? = nil) {
        self.recoveryStore = recoveryStore
        agentMonitorService = agentMonitor
        sharedWorkspaceStore = RelaySharedWorkspaceStore(directory: workspaceDirectory ??
            RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/Workspace", isDirectory: true))
        paneLinkSelection.connectPair = { [weak self] ids, generation in
            guard let self else { return }
            Task { @MainActor in
                do {
                    guard ids.allSatisfy({ self.panes[$0]?.contentKind == .terminal }) else {
                        throw RemoteCatalogError.failed("A selected pane is no longer available.")
                    }
                    let link = try await RelayPaneMessaging.shared.connect(panes: ids, workspace: self)
                    self.paneLinkSelection.recordMembership(PaneLinkMembership(id: link.id,
                        paneIDs: link.members.map(\.paneID), unavailable: link.transport == "unavailable"))
                    guard link.transport != "unavailable" else {
                        let failures = link.members.compactMap { member -> String? in
                            guard let reason = link.resolutionErrors?[member.paneID.uuidString.lowercased()]
                                ?? link.resolutionErrors?[member.paneID.uuidString] ?? member.unavailable else { return nil }
                            return self.paneLinkSelection.label(for: member.paneID) + ": " + reason
                        }
                        throw RemoteCatalogError.failed(failures.isEmpty
                            ? "The link was saved, but a pane is unavailable. Retry when both panes are ready."
                            : failures.joined(separator: "\n"))
                    }
                    self.paneLinkSelection.finishPair(ids, generation: generation, failure: nil)
                } catch {
                    self.paneLinkSelection.finishPair(ids, generation: generation, failure: error.localizedDescription)
                }
                self.updateTerminalFocusOwnership()
                if !self.paneLinkSelection.active, let id = self.activePaneID {
                    self.panes[id]?.runtime.focus()
                }
            }
        }
        paneLinkSelection.describePane = { [weak self] id in
            self?.paneLinkLabel(for: id) ?? "Unavailable pane"
        }
        paneLinkSelection.refreshLinks = { [weak self] in self?.refreshPaneLinkMemberships() }
        paneLinkSelection.removeLink = { [weak self] id in self?.removePaneLink(id) }
        paneLinkSelection.reviewDetachedLinks = { [weak self] in self?.reviewDetachedPaneLinks() }
        paneLinkSelection.confirmDetachedLinks = { [weak self] in self?.confirmDetachedPaneLinks() }
        recentlyClosedPanes = recoveryStore.loadClosedPanes()
        recentlyClosedPaneCount = recentlyClosedPanes.count
        let shouldRestore = restoreSavedWorkspace && !RelayLaunchMode.isSafeMode
        if !(shouldRestore && restoreWorkspace()), workspacePersistenceIssue == nil {
            ownershipReady = true
            newTab(profile: .local)
        }
        // Every pane, restored or opened later, needs the kernel harness
        // identity: a shell where `claude` was typed is otherwise never
        // promoted, since completed shell commands disable banner detection.
        monitorsStoredPanes = true
        panes.values.forEach { $0.startAgentMonitoring(monitor: agentMonitorService) }
#if DEBUG
        if RelaySupervisorAcceptanceFixture.isEnabled {
            sessionSupervisor = RelaySessionSupervisor(
                configuration: RelaySupervisorAcceptanceFixture.configuration
            )
            panes.values
                .filter { $0.contentKind == .terminal && $0.profile.backend == .relay }
                .forEach { $0.installSupervisorAcceptanceFixture() }
        }
#endif
        panes.values.forEach { RelaySurfacePublication.shared.restore($0) }
        RelayBackgroundAttachScheduler.shared.remember(self)
        startSupervisorMonitoring()
        startPaneLinkJanitor()
    }

    private func startSupervisorMonitoring() {
        guard !RelayLaunchMode.isRunningTests, supervisorTask == nil else { return }
        refreshSupervisorRecommendations()
        supervisorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.refreshSupervisorRecommendations()
            }
        }
    }

    func refreshSupervisorRecommendations(now: Date = Date()) {
        if !RelayLaunchMode.isRunningTests { RelayClaudeQuotaScheduler.shared.tick(self, now: now) }
        RelayCapacityManagementCoordinator.shared.tick(self, now: now)
        RelayAgentMaintenance.shared.tick(self, now: now)
        if !RelayLaunchMode.isRunningTests { RelayContextRotation.shared.tick(self, now: now) }
        var current: [UUID: RelaySupervisorRecommendation] = [:]
        var telemetryByPane: [UUID: RelaySupervisorTelemetry] = [:]
        for pane in panes.values where pane.contentKind == .terminal && pane.kind != .shell {
            let telemetry = pane.supervisorTelemetry(now: now)
            telemetryByPane[pane.id] = telemetry
            current[pane.id] = sessionSupervisor.evaluate(telemetry)
        }
        supervisorRecommendations = current
        supervisorAdvisories = supervisorAdvisories.filter { paneID, advisory in
            current[paneID]?.identity == advisory.identity &&
                (current[paneID]?.stage ?? .observe) > .observe
        }
        refreshSupervisorAdvisory(recommendations: current, telemetryByPane: telemetryByPane)
    }

    private func refreshSupervisorAdvisory(
        recommendations: [UUID: RelaySupervisorRecommendation],
        telemetryByPane: [UUID: RelaySupervisorTelemetry]
    ) {
        guard RelayPreferences.shared.intelligenceEnabled,
              let recommendation = recommendations.values
                .filter({ $0.stage > .observe })
                .max(by: { $0.stage < $1.stage }),
              let telemetry = telemetryByPane[recommendation.identity.paneID] else {
            supervisorAdvisoryTask?.cancel()
            supervisorAdvisoryTask = nil
            supervisorAdvisoryRequestKey = nil
            return
        }
        let requestKey = SupervisorAdvisoryRequestKey(
            identity: recommendation.identity, stage: recommendation.stage
        )
        if supervisorAdvisoryTask != nil, supervisorAdvisoryRequestKey == requestKey { return }
        supervisorAdvisoryTask?.cancel()
        supervisorAdvisoryRequestKey = requestKey
        supervisorAdvisoryTask = Task { @MainActor [weak self] in
            let advisory = await RelaySupervisorIntelligenceService.shared.advise(
                recommendation: recommendation,
                telemetry: telemetry
            )
            guard let self else { return }
            if self.supervisorAdvisoryRequestKey == requestKey {
                self.supervisorAdvisoryTask = nil
                self.supervisorAdvisoryRequestKey = nil
            }
            guard !Task.isCancelled, let advisory,
                  let current = self.supervisorRecommendations[advisory.identity.paneID],
                  current.identity == advisory.identity,
                  current.observedAt == advisory.deterministicObservedAt,
                  Date().timeIntervalSince(advisory.deterministicObservedAt) >= 0,
                  Date().timeIntervalSince(advisory.deterministicObservedAt) <= 30,
                  advisory.suggestedStage <= current.stage else { return }
            self.supervisorAdvisories[advisory.identity.paneID] = advisory
        }
    }

    @discardableResult
    func proposeSupervisorAction(paneID: UUID, now: Date = Date()) -> RelaySupervisorActionReceipt? {
        guard let recommendation = supervisorRecommendations[paneID],
              let receipt = supervisorActionBroker.propose(recommendation, now: now) else { return nil }
        guard recordSupervisorAudit(.proposed, receipt: receipt, reason: .userReview, now: now) else {
            operationError = "Relay could not persist the supervisor proposal audit record."
            return nil
        }
        supervisorReceipts[receipt.id] = receipt
        return receipt
    }

    @discardableResult
    func resolveSupervisorAction(
        receiptID: UUID, approve: Bool, now: Date = Date()
    ) -> RelaySupervisorActionReceipt? {
        guard let pending = supervisorReceipts[receiptID],
              let pane = panes[pending.identity.paneID] else { return nil }
        let currentIdentity = pane.supervisorTelemetry(now: now).identity
        guard let resolved = supervisorActionBroker.resolve(
            receiptID, approve: approve, currentIdentity: currentIdentity, now: now
        ) else { return nil }
        let audit: (RelaySupervisorAuditKind, RelaySupervisorAuditReason) = switch resolved.state {
        case .approved: (.approved, .userReview)
        case .rejected: (.rejected, .userReview)
        case .expired: (.expired, .expired)
        case .staleIdentity: (.staleIdentity, .staleIdentity)
        case .proposed: (.executionRejected, .notApproved)
        }
        guard recordSupervisorAudit(audit.0, receipt: resolved, reason: audit.1, now: now) else {
            operationError = "Relay could not persist the supervisor decision audit record."
            return nil
        }
        supervisorReceipts[receiptID] = resolved
        return resolved
    }

    @discardableResult
    func approveAndExecuteSupervisorAction(
        receiptID: UUID, now: Date = Date()
    ) -> RelaySupervisorExecutionClaim? {
        guard let receipt = resolveSupervisorAction(receiptID: receiptID, approve: true, now: now),
              let pane = panes[receipt.identity.paneID] else { return nil }
        let telemetry = pane.supervisorTelemetry(now: now)
        var capabilities = Set<RelaySupervisorExecutionCapability>()
        if pane.profile.backend == .relay,
           pane.contentKind == .terminal,
           pane.kind != .shell,
           telemetry.isReachable,
           pane.runtime.canSendSupervisorInterrupt {
            capabilities.insert(.gracefulInterrupt)
        }
        let result = supervisorActionExecutor.claim(
            receipt,
            currentIdentity: telemetry.identity,
            isReachable: telemetry.isReachable,
            capabilities: capabilities,
            now: now
        )
        switch result {
        case .success(let claim):
            guard recordSupervisorAudit(
                .executionDispatched, receipt: receipt, reason: .userReview, now: now
            ) else {
                operationError = "Relay could not persist the supervisor dispatch audit record. The action was not executed."
                return nil
            }
            guard claim.command == .gracefulInterrupt,
                  pane.runtime.sendSupervisorInterrupt() else {
                _ = recordSupervisorAudit(
                    .executionFailed, receipt: receipt, reason: .transportUnavailable, now: now
                )
                operationError = "The approved interrupt was not sent because the pane transport is no longer available."
                return nil
            }
            _ = recordSupervisorAudit(
                .executionSucceeded, receipt: receipt, reason: .userReview, now: now
            )
            return claim
        case .failure(let rejection):
            _ = recordSupervisorAudit(
                .executionRejected,
                receipt: receipt,
                reason: Self.supervisorAuditReason(rejection),
                now: now
            )
            operationError = Self.supervisorExecutionMessage(rejection)
            return nil
        }
    }

    private func recordSupervisorAudit(
        _ kind: RelaySupervisorAuditKind,
        receipt: RelaySupervisorActionReceipt,
        reason: RelaySupervisorAuditReason,
        now: Date
    ) -> Bool {
        supervisorAuditStore.record(RelaySupervisorAuditEvent(
            id: UUID(), receiptID: receipt.id, identity: receipt.identity,
            stage: receipt.stage, kind: kind, reason: reason, occurredAt: now
        ))
    }

    private static func supervisorAuditReason(
        _ rejection: RelaySupervisorExecutionRejection
    ) -> RelaySupervisorAuditReason {
        switch rejection {
        case .alreadyConsumed: .alreadyConsumed
        case .notApproved: .notApproved
        case .expired: .expired
        case .staleIdentity: .staleIdentity
        case .unreachable: .unreachable
        case .unsupportedStage: .unsupportedStage
        case .missingCapability: .missingCapability
        }
    }

    private static func supervisorExecutionMessage(
        _ rejection: RelaySupervisorExecutionRejection
    ) -> String {
        switch rejection {
        case .alreadyConsumed: "This supervisor approval was already used."
        case .notApproved: "The supervisor action is not approved."
        case .expired: "The supervisor approval expired before execution."
        case .staleIdentity: "The supervised session changed; the approval was not executed."
        case .unreachable: "The supervised session is offline; the approval was not queued."
        case .unsupportedStage: "This Relay build cannot safely execute that supervisor stage."
        case .missingCapability: "The live pane does not expose the required supervisor capability."
        }
    }

    var selectedTab: TabModel? {
        tabs.first { $0.id == selectedTabID }
    }

    var activePane: PaneModel? {
        activePaneID.flatMap { panes[$0] }
    }

    var selectedPanes: [PaneModel] {
        selectedTab?.allPaneIDs.compactMap { panes[$0] } ?? []
    }

    func pluginPresentation(paneID: UUID, profile: ConnectionProfile,
                            directory: String?) -> PluginToolPresentation {
        pruneRetiredPluginPresentations()
        if let existing = pluginPresentations[paneID] { return existing }
        let presentation = PluginToolPresentation()
        let tab = tabs.first { $0.allPaneIDs.contains(paneID) }
        let context = tab.flatMap { executionContext(tabID: $0.id) }
        presentation.captureOnce(id: paneID, profile: context?.profile ?? profile, directory: context?.directory ?? directory)
        pluginPresentations[paneID] = presentation
        return presentation
    }

    /// Closing a pane retires its exact captured presentation. Undo may reuse
    /// the pane UUID, but it must receive a fresh capture and authorization
    /// lease. Dispatched mutations and their outcomes stay reachable here.
    private func retirePluginPresentation(for paneID: UUID) {
        guard let presentation = pluginPresentations.removeValue(forKey: paneID) else { return }
        presentation.suspendForWorkspaceCover()
        guard presentation.operationLifetime.running || presentation.resultStamp != nil ||
                presentation.result != nil || presentation.error != nil else { return }
        retiredPluginPresentations[paneID, default: []].append(presentation)
        pruneRetiredPluginPresentations()
    }

    func retiredPluginPresentation(for paneID: UUID) -> PluginToolPresentation? {
        pruneRetiredPluginPresentations()
        return retiredPluginPresentations[paneID]?.last
    }

    private func pruneRetiredPluginPresentations() {
        for paneID in Array(retiredPluginPresentations.keys) {
            guard var values = retiredPluginPresentations[paneID] else { continue }
            let running = values.filter { $0.operationLifetime.running }
            let completed = values.filter { !$0.operationLifetime.running }.suffix(4)
            values = running + completed
            if values.isEmpty { retiredPluginPresentations.removeValue(forKey: paneID) }
            else { retiredPluginPresentations[paneID] = values }
        }
        let completed = retiredPluginPresentations.values.flatMap { $0 }
            .filter { !$0.operationLifetime.running }
        guard completed.count > 32 else { return }
        var excess = completed.count - 32
        for paneID in Array(retiredPluginPresentations.keys) where excess > 0 {
            guard var values = retiredPluginPresentations[paneID] else { continue }
            while excess > 0,
                  let index = values.firstIndex(where: { !$0.operationLifetime.running }) {
                values.remove(at: index); excess -= 1
            }
            if values.isEmpty { retiredPluginPresentations.removeValue(forKey: paneID) }
            else { retiredPluginPresentations[paneID] = values }
        }
    }

    /// AppKit resigns the terminal first responder when Relay is hidden,
    /// minimized, or leaves the active Space. Rendering resume and keyboard
    /// ownership are separate operations: once presentation is usable again,
    /// return first-responder status to exactly the workspace's active pane.
    func applicationPresentationChanged(visible: Bool) {
        presentationFocusTask?.cancel()
        presentationFocusTask = nil
        guard visible, let paneID = activePaneID else { return }
        presentationFocusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  RelayApplicationActivityState.allowsContinuousUpdates,
                  let self,
                  self.activePaneID == paneID,
                  let pane = self.panes[paneID] else { return }
            // A Codex browser panel can legitimately own a different PTY grid
            // while Relay is in the background. Every pane visible in the
            // selected tab must reclaim its native measured grid on return;
            // focusing only the active pane leaves sibling TUIs rendering at
            // the browser width until an unrelated divider move.
            self.selectedPanes.forEach { $0.runtime.reclaimNativeViewportOwnership() }
            guard self.selectedTab?.chrome.presentationActive != true else {
                self.presentationFocusTask = nil
                return
            }
            pane.focus()
            self.presentationFocusTask = nil
        }
    }

    func presentQuickNavigate() {
        guard !isQuickNavigatePresented else { return }
        quickNavigateOriginPane = activePane
        quickNavigateOriginTabID = selectedTabID
        quickNavigateOriginWorkspaceID = selectedWorkspaceID
        quickNavigateChoseDestination = false
        dockWillTakeFocus()
        isQuickNavigatePresented = true
    }

    /// Opens the fleet board. Opening it acknowledges nothing.
    func presentFleetBoard(filter: RelayFleetFilter = .all) {
        fleetBoardInitialFilter = filter
        guard !isFleetBoardPresented else { return }
        dockWillTakeFocus()
        isFleetBoardPresented = true
    }

    /// The fleet board closed: the chosen (or unchanged) active pane gets
    /// the keyboard back. Focus repair must not call selectPane.
    func fleetBoardDidDismiss() {
        updateTerminalFocusOwnership()
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.isFleetBoardPresented, !self.isQuickNavigatePresented,
                  !self.networkVisible, !self.paneLinkSelection.active,
                  let id = self.activePaneID else { return }
            self.panes[id]?.focus()
        }
    }

    /// A user's choice of a pane from Go to pane or the fleet board: shows
    /// its tab and records the visit.
    func goToPane(_ id: UUID, inTab tab: UUID) {
        networkVisible = false
        selectTab(tab)
        selectPane(id, origin: .user)
    }

    func quickNavigateDidChooseDestination() {
        quickNavigateChoseDestination = true
        isQuickNavigatePresented = false
    }

    /// Navigation actions run after the overview sheet has dismissed. They
    /// own the next focus transfer instead of restoring the terminal first.
    func quickNavigateDidChooseAction(_ action: @escaping () -> Void) {
        quickNavigateAction = action
        isQuickNavigatePresented = false
    }

    /// Focus repair must not call selectPane: that would acknowledge alerts.
    func quickNavigateDidDismiss() {
        let action = quickNavigateAction
        quickNavigateAction = nil
        let chosen = quickNavigateChoseDestination
        let originStillSelected = quickNavigateOriginTabID == selectedTabID &&
            quickNavigateOriginWorkspaceID == selectedWorkspaceID &&
            quickNavigateOriginPane?.id == activePaneID &&
            quickNavigateOriginPane === activePane
        let target = chosen ? activePane : (originStillSelected ? quickNavigateOriginPane : nil)
        quickNavigateOriginPane = nil
        quickNavigateOriginTabID = nil
        quickNavigateOriginWorkspaceID = nil
        quickNavigateChoseDestination = false
        updateTerminalFocusOwnership()
        if let action {
            action()
            return
        }
        Task { @MainActor [weak self, weak target] in
            await Task.yield()
            guard let self, let target, !self.isQuickNavigatePresented,
                  !self.networkVisible, !self.paneLinkSelection.active,
                  self.activePaneID == target.id, self.panes[target.id] === target else { return }
            target.focus()
        }
    }

    func dockWillTakeFocus() {
        presentationFocusTask?.cancel()
        presentationFocusTask = nil
        selectedPanes.forEach { $0.runtime.cancelFocusRecoveryForExternalFocus() }
        NSApp?.keyWindow?.makeFirstResponder(nil)
    }

    func inspectAgent(paneID: UUID, subagentID: String) {
        intelligencePanelVisible = false
        agentInspector = AgentInspectorSelection(paneID: paneID, subagentID: subagentID)
    }

    func closeAgentInspector() {
        agentInspector = nil
    }

    func closeAssistant() {
        assistantVisible = false
        let target = activePaneID
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.assistantVisible, !self.networkVisible,
                  !self.paneLinkSelection.active, self.activePaneID == target,
                  let target else { return }
            self.panes[target]?.focus()
        }
    }

    func toggleIntelligencePanel() {
        if !intelligencePanelVisible { agentInspector = nil }
        intelligencePanelVisible.toggle()
    }

    func closeIntelligencePanel() {
        intelligencePanelVisible = false
    }

    func togglePerformancePanel() {
        if !performancePanelVisible {
            performancePanelSection = energyMonitorMode ? "Energy" : "Performance"
        }
        performancePanelVisible.toggle()
    }

    func closePerformancePanel() {
        performancePanelVisible = false
    }

    func openInboxItem(_ item: AgentInboxItem) {
        AgentIntelligenceStore.shared.markRead(item.id)
        guard panes[item.paneID] != nil else { return }
        revealPane(item.paneID, origin: .user)
        if let agentID = item.agentID,
           panes[item.paneID]?.subagents.contains(where: { $0.id == agentID || $0.threadID == agentID }) == true {
            let resolvedID = panes[item.paneID]?.subagents.first(where: {
                $0.id == agentID || $0.threadID == agentID
            })?.id ?? agentID
            inspectAgent(paneID: item.paneID, subagentID: resolvedID)
        }
    }

    var terminationTarget: PaneModel? {
        terminationTargetID.flatMap { panes[$0] }
    }

    func requestTerminatePane(_ paneID: UUID) {
        guard let pane = panes[paneID], pane.profile.backend == .relay else { return }
        terminationTargetID = paneID
    }

    func cancelTermination() {
        terminationTargetID = nil
    }

    func confirmTermination() {
        guard let paneID = terminationTargetID, let pane = panes[paneID] else { return }
        terminationTargetID = nil
        pane.userRequestedTermination = true
        Task {
            do {
                try await RemotePaneControlService.terminate(profile: pane.profile, paneID: paneID)
                guard panes[paneID] != nil else { return }
                revealPane(paneID, origin: .programmatic)
                closeActivePane()
            } catch {
                pane.userRequestedTermination = false
                operationError = error.localizedDescription
            }
        }
    }

    func revealPane(_ paneID: UUID, origin: PaneSelectionOrigin) {
        // Floating R panels belong to a tab without being in its layout.
        guard let tabID = tabID(containingPane: paneID) else { return }
        revealingPaneID = paneID
        defer { revealingPaneID = nil }
        if networkVisible || selectedTabID != tabID { selectTab(tabID) }
        selectPane(paneID, origin: origin)
        networkVisible = false
        panes[paneID]?.focus()
    }

    func sidePanelState() -> RelaySidePanelState {
        let sessions = Dictionary(grouping: tabs, by: \.sessionID)
        let orderedSessionIDs = tabs.reduce(into: [UUID]()) { result, tab in
            if !result.contains(tab.sessionID) { result.append(tab.sessionID) }
        }
        return RelaySidePanelState(
            selectedPaneID: activePaneID?.uuidString.lowercased(),
            terminalFontFamily: RelayPreferences.shared.resolvedFontFamily,
            terminalFontSize: RelayPreferences.shared.fontSize,
            sessions: orderedSessionIDs.compactMap { sessionID in
                guard let sessionTabs = sessions[sessionID], let firstTab = sessionTabs.first else {
                    return nil
                }
                return RelaySidePanelState.Session(
                    id: sessionID.uuidString.lowercased(),
                    name: sessionDisplayName(sessionID, fallback: firstTab.name),
                    pinned: isSessionPinned(sessionID),
                    tabs: sessionTabs.map { tab in
                        RelaySidePanelState.Tab(
                            id: tab.id.uuidString.lowercased(),
                            name: tab.name,
                            pinned: isTabPinned(tab.id),
                            selected: tab.id == selectedTabID,
                            workspaceID: workspaceID(forTab: tab.id)?.uuidString.lowercased(),
                            broadcast: RelayAutoLinker.shared.broadcastGrants(tab: tab.id, workspace: workspaceID(forTab: tab.id)),
                            panes: (tab.allPaneIDs + floatingRPaneTabs.filter {
                                $0.value == tab.id && !tab.allPaneIDs.contains($0.key)
                            }.map(\.key).sorted { $0.uuidString < $1.uuidString }).compactMap { paneID in
                                panes[paneID].map(sidePanelPane)
                            }
                        )
                    }
                )
            }
        )
    }

    /// One pane's side-panel row; also the Control section's row source.
    func sidePanelPane(_ pane: PaneModel) -> RelaySidePanelState.Pane {
        return RelaySidePanelState.Pane(
            id: pane.id.uuidString.lowercased(),
            name: pane.displayName,
            host: pane.profile.kind == .local ? "This Mac" : pane.profile.name,
            directory: pane.directory,
            contentKind: pane.contentKind.rawValue,
            terminalAvailable: pane.contentKind == .terminal &&
                pane.profile.backend == .relay,
            agent: pane.kind.rawValue,
            phase: pane.phase.rawValue,
            connection: pane.connectionStatusLabel,
            selected: pane.id == activePaneID,
            summary: pane.activitySummary,
            backend: pane.profile.backend.rawValue,
            closeBehavior: pane.contentKind == .editor ? "not_supported_via_mcp" :
                (pane.profile.backend == .relay ? "detach_persistent_session" : "stop_nonpersistent_process"),
            account: pane.agentAccountLabel,
            accountMismatch: pane.agentAccount?.mismatch == true ? true : nil,
            accountDisplay: pane.agentAccountDisplay
        )
    }

    func paneIDs(inTab tabID: UUID) -> [UUID] {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return [] }
        return tab.allPaneIDs + floatingRPaneTabs
            .filter { $0.value == tabID && !tab.allPaneIDs.contains($0.key) }
            .map(\.key)
            .sorted { $0.uuidString < $1.uuidString }
    }

    func tabID(containingPane paneID: UUID) -> UUID? {
        tabs.first { $0.allPaneIDs.contains(paneID) }?.id ?? floatingRPaneTabs[paneID]
    }

    func sidePanelDetail(for paneID: UUID) -> RelaySidePanelPaneDetail? {
        guard let pane = panes[paneID] else { return nil }
        return RelaySidePanelPaneDetail(
            id: pane.id.uuidString.lowercased(),
            context: Array(pane.recentConversationContext.suffix(20)),
            activities: pane.agentActivities.suffix(12).map {
                RelaySidePanelState.Activity(
                    id: $0.id.uuidString.lowercased(), label: $0.label,
                    phase: $0.phase.rawValue, occurredAt: $0.occurredAt
                )
            },
            subagents: pane.subagents.suffix(100).map {
                RelaySidePanelState.Subagent(
                    id: $0.id, label: $0.label,
                    provider: $0.provider.rawValue, phase: $0.phase.rawValue,
                    updates: $0.updates.suffix(5).map(\.message)
                )
            },
            plans: pane.taskPlans
        )
    }

    @discardableResult
    func sidePanelReveal(_ paneID: UUID) -> Bool {
        guard let pane = panes[paneID] else { return false }
        revealPane(paneID, origin: .programmatic)
        activateSelectedWorkspacePane(pane)
        return true
    }

    func sidePanelViewport(_ paneID: UUID) -> String? {
        panes[paneID]?.runtime.sidePanelViewportText()
    }

    func sessionDisplayName(_ sessionID: UUID, fallback: String) -> String {
        sessionNames[sessionID] ?? fallback
    }

    func isSessionPinned(_ sessionID: UUID) -> Bool { pinnedSessionIDs.contains(sessionID) }
    func isTabPinned(_ tabID: UUID) -> Bool { pinnedTabIDs.contains(tabID) }
    func isPanePinned(_ paneID: UUID) -> Bool { pinnedPaneIDs.contains(paneID) }

    func togglePanePin(_ paneID: UUID) {
        guard panes[paneID] != nil else { return }
        if !pinnedPaneIDs.insert(paneID).inserted { pinnedPaneIDs.remove(paneID) }
        WorkspacePinStore.save(pinnedPaneIDs, kind: .pane)
    }

    /// Also forgets a closed pane's dismissed attention.
    private func removePanePin(_ paneID: UUID) {
        dismissedAttention.removeValue(forKey: paneID)
        guard pinnedPaneIDs.remove(paneID) != nil else { return }
        WorkspacePinStore.save(pinnedPaneIDs, kind: .pane)
    }

    func toggleSessionPin(_ sessionID: UUID) {
        if !pinnedSessionIDs.insert(sessionID).inserted { pinnedSessionIDs.remove(sessionID) }
        WorkspacePinStore.save(pinnedSessionIDs, kind: .session)
    }

    func toggleTabPin(_ tabID: UUID) {
        if !pinnedTabIDs.insert(tabID).inserted { pinnedTabIDs.remove(tabID) }
        WorkspacePinStore.save(pinnedTabIDs, kind: .tab)
    }

    func orderedTabs(in sessionID: UUID) -> [TabModel] {
        let matching = tabs.filter { $0.sessionID == sessionID }
        return matching.filter { pinnedTabIDs.contains($0.id) } +
            matching.filter { !pinnedTabIDs.contains($0.id) }
    }

    /// Reorder tabs using their visual order while keeping pinned tabs as the
    /// leading group. Crossing that boundary pins or unpins the dragged tab,
    /// so the dropped position remains stable instead of snapping elsewhere.
    func moveTab(_ sourceID: UUID, relativeTo targetID: UUID, placement: TabMovePlacement) {
        guard sourceID != targetID,
              let source = tabs.first(where: { $0.id == sourceID }),
              let target = tabs.first(where: { $0.id == targetID }),
              source.sessionID == target.sessionID else { return }

        let sessionID = source.sessionID
        var visualOrder = orderedTabs(in: sessionID)
        guard let sourceIndex = visualOrder.firstIndex(where: { $0.id == sourceID }) else { return }
        let sourceWasPinned = pinnedTabIDs.contains(sourceID)
        visualOrder.remove(at: sourceIndex)
        guard let targetIndex = visualOrder.firstIndex(where: { $0.id == targetID }) else { return }
        let insertionIndex = targetIndex + (placement == .after ? 1 : 0)
        visualOrder.insert(source, at: insertionIndex)

        let pinnedRemaining = visualOrder.reduce(into: 0) { count, tab in
            if tab.id != sourceID, pinnedTabIDs.contains(tab.id) { count += 1 }
        }
        let shouldPin: Bool
        if insertionIndex < pinnedRemaining {
            shouldPin = true
        } else if insertionIndex > pinnedRemaining {
            shouldPin = false
        } else {
            shouldPin = sourceWasPinned
        }
        if shouldPin {
            pinnedTabIDs.insert(sourceID)
        } else {
            pinnedTabIDs.remove(sourceID)
        }
        WorkspacePinStore.save(pinnedTabIDs, kind: .tab)

        // Replace only this session's slots so other sessions retain their
        // relative order even if their tabs are interleaved in the snapshot.
        var reordered = tabs
        var visualIndex = 0
        for index in reordered.indices where reordered[index].sessionID == sessionID {
            reordered[index] = visualOrder[visualIndex]
            visualIndex += 1
        }
        tabs = reordered
        persistWorkspace()
    }

    func renameTab(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              let index = tabs.firstIndex(where: { $0.id == id }) else {
            throw PluginError.invalid("Tab name must contain 1–80 characters and target an existing tab")
        }
        tabs[index].name = trimmed
        persistWorkspace()
    }

    func tabDisplayName(_ tab: TabModel, fallback: String) -> String {
        let trimmed = tab.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback : trimmed
        let peers = orderedTabs(in: tab.sessionID).filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
        guard peers.count > 1 else { return base }

        let directories = peers.map { candidate -> String? in
            guard let paneID = candidate.allPaneIDs.first,
                  let directory = panes[paneID]?.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !directory.isEmpty else { return nil }
            let component = TerminalPathSyntax.lastComponent(directory)
            return component.isEmpty ? nil : component
        }
        if let index = peers.firstIndex(where: { $0.id == tab.id }),
           let directory = directories[index],
           Set(directories.compactMap { $0 }).count == peers.count {
            return "\(base) · \(directory)"
        }
        let index = peers.firstIndex(where: { $0.id == tab.id }) ?? 0
        return "\(base) \(index + 1)"
    }

    func beginRenameSession(_ sessionID: UUID, fallback: String) {
        renameDraft = sessionDisplayName(sessionID, fallback: fallback)
        renameTarget = .session(sessionID)
    }

    func beginRenameTab(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        renameDraft = tab.name
        renameTarget = .tab(tabID)
    }

    func beginRenamePane(_ paneID: UUID) {
        guard let pane = panes[paneID] else { return }
        renameDraft = pane.displayName
        renameTarget = .pane(paneID)
    }

    func cancelRename() {
        renameTarget = nil
        renameDraft = ""
    }

    func commitRename() {
        guard let renameTarget else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch renameTarget {
        case .session(let id): sessionNames[id] = name
        case .tab(let id): tabs.first(where: { $0.id == id })?.name = name
        case .pane(let id): panes[id]?.customName = name
        }
        self.renameTarget = nil
        renameDraft = ""
        persistWorkspace()
    }

    func presentConnectionSheet(prefilling profile: ConnectionProfile? = nil) {
        isHostLauncherPresented = false
        draftProfile = profile ?? ConnectionProfile()
        isConnectionSheetPresented = true
    }

    func presentHostLauncher() {
        profileStore.refreshSSHConfig()
        isHostLauncherPresented = true
    }

    func setFullScreen(_ fullScreen: Bool) {
        guard isFullScreen != fullScreen else { return }
        applyingFullScreenSidebar = true
        defer { applyingFullScreenSidebar = false }
        if fullScreen {
            // Hide only a visible sidebar; a restore into full screen keeps
            // the saved choice, which comes back when full screen ends.
            if RelayPreferences.shared.hideSidebarInFullScreen && sidebarVisible {
                sidebarAutoHidden = true
                sidebarVisible = false
            }
        } else if sidebarAutoHidden {
            sidebarVisible = true
            sidebarAutoHidden = false
        }
        isFullScreen = fullScreen
    }

    func newTab(profile: ConnectionProfile, origin: WorkspaceTabOrigin = .human) {
        let pane = PaneModel(profile: profile)
        RelayCapacityManagementCoordinator.shared.didCreate(pane)
        storePane(pane)
        let tab = TabModel(sessionID: UUID(), name: profile.name, firstPane: pane.id)
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        withTabAdmission(tabAdmission(for: origin)) { tabs.append(tab) }
        selectedTabID = tab.id
        activePaneID = pane.id
        if profile.kind == .ssh { profileStore.markUsed(profile) }
        isHostLauncherPresented = false
        persistWorkspace()
        Task { @MainActor [weak self, weak pane] in
            await Task.yield()
            guard let self, let pane, self.selectedTabID == tab.id,
                  self.activePaneID == pane.id, self.panes[pane.id] === pane,
                  !self.networkVisible, !self.paneLinkSelection.active else { return }
            pane.focus()
        }
    }

    func attachRemoteSession(profile: ConnectionProfile, remote: RemoteSessionRecord, inNewWindow: Bool = false) {
        let attached = remote.panes.compactMap { UUID(uuidString: $0.paneID) }.contains { panes[$0] != nil }
        if let sessionID = remote.workspaceID.flatMap(UUID.init(uuidString:)), attached,
           RecoveryWindowRegistry.shared.focus(sessionID: sessionID) {
            isHostLauncherPresented = false
            if let pane = remote.panes.compactMap({ UUID(uuidString: $0.paneID) }).first(where: { panes[$0] != nil }) { revealPane(pane, origin: .programmatic) }
            return
        }
        let destination = inNewWindow ? RecoveryWindowRegistry.shared.openWindow(workspace: self) : NSApp?.keyWindow
        if let sessionID = remote.workspaceID.flatMap(UUID.init(uuidString:)) {
            RecoveryWindowRegistry.shared.record(sessionID: sessionID, replacing: true, window: destination)
        }
        if let existingPane = remote.panes.compactMap({ UUID(uuidString: $0.paneID) })
            .first(where: { panes[$0] != nil }) {
            for remotePane in remote.panes {
                guard let paneID = UUID(uuidString: remotePane.paneID) else { continue }
                panes[paneID]?.directory = remotePane.directory
            }
            isHostLauncherPresented = false
            revealPane(existingPane, origin: .programmatic)
            return
        }

        let sessionID = remote.workspaceID.flatMap(UUID.init(uuidString:)) ?? UUID()
        if let snapshot = remote.workspaceSnapshot,
           attachRemoteWorkspaceSnapshot(snapshot, profile: profile, sessionID: sessionID, remote: remote) {
            return
        }
        let groupedTabs = Dictionary(grouping: remote.panes.filter(\.recoverable)) {
            $0.tabID ?? $0.paneID
        }
        var attachedTabs: [TabModel] = []
        for (remoteTabID, remotePanes) in groupedTabs.sorted(by: { $0.key < $1.key }) {
            guard let firstRemotePane = remotePanes.first,
                  let firstPaneID = UUID(uuidString: firstRemotePane.paneID) else { continue }
            let tabID = UUID(uuidString: remoteTabID) ?? UUID()
            var paneIDs: [UUID] = []
            for remotePane in remotePanes {
                guard let paneID = UUID(uuidString: remotePane.paneID) else { continue }
                let pane = PaneModel(
                    id: paneID,
                    profile: profile,
                    requiresExistingWorker: true,
                    remoteParentSessionID: remotePane.parentPaneID,
                    customName: remotePane.title,
                    directory: remotePane.directory
                )
                pane.assignRemoteHierarchy(workspaceSessionID: sessionID, tabID: tabID)
                storePane(pane)
                paneIDs.append(paneID)
            }
            guard !paneIDs.isEmpty else { continue }
            let tab = TabModel(
                id: tabID,
                sessionID: sessionID,
                name: firstRemotePane.title ?? "Remote",
                firstPane: firstPaneID
            )
            for paneID in paneIDs.dropFirst() {
                tab.layout = tab.layout.splitting(tab.layout.paneIDs.last ?? firstPaneID, axis: .horizontal, with: paneID)
            }
            tab.balanceSplits()
            attachedTabs.append(tab)
        }
        guard !attachedTabs.isEmpty else { return }
        tabs.append(contentsOf: attachedTabs)
        sessionNames[sessionID] = remote.label
        selectedTabID = attachedTabs[0].id
        activePaneID = attachedTabs[0].layout.paneIDs.first
        if profile.kind == .ssh { profileStore.markUsed(profile) }
        isHostLauncherPresented = false
        persistWorkspace()
    }

    /// Recreates one catalogued relay pane that is still alive remotely but no
    /// longer appears in the local layout. It is attached directly; no nested
    /// terminal command is launched and the remote process keeps one PTY writer.
    @discardableResult
    func attachRemotePane(
        profile: ConnectionProfile,
        remotePane: RemoteCatalogPane,
        workspaceID: String?,
        sessionLabel: String,
        intoSessionID: UUID? = nil
    ) -> Bool {
        guard remotePane.recoverable,
              let paneID = UUID(uuidString: remotePane.paneID) else { return false }
        if let pane = panes[paneID] {
            guard pane.profile.id == profile.id, pane.profile.backend == .relay else { return false }
            isHostLauncherPresented = false
            revealPane(paneID, origin: .programmatic)
            // Catalog recovery is an explicit viewer reconnect. Renderer
            // status may still say connected after a failed native surface
            // attachment; it must not suppress the requested recovery.
            pane.runtime.reconnectRetainedPane()
            recoveryStore.record(kind: "viewer_reconnect_requested", paneID: paneID,
                profile: pane.profile, directory: pane.directory)
            return true
        }

        let tabID = remotePane.tabID.flatMap(UUID.init(uuidString:)) ?? UUID()
        // A pane joining an open tab takes that tab's session, as
        // recoverRemoteTab requires, never the session that happens to be selected.
        let sessionID = tabs.first(where: { $0.id == tabID })?.sessionID
            ?? intoSessionID ?? workspaceID.flatMap(UUID.init(uuidString:)) ?? UUID()
        let pane = PaneModel(
            id: paneID,
            profile: profile,
            contentKind: PaneContentKind(rawValue: remotePane.contentKind) ?? .terminal,
            requiresExistingWorker: true,
            remoteParentSessionID: remotePane.parentPaneID,
            customName: remotePane.title,
            directory: remotePane.directory
        )
        pane.assignRemoteHierarchy(workspaceSessionID: sessionID, tabID: tabID)
        storePane(pane)

        if let tab = tabs.first(where: { $0.id == tabID }) {
            // Do not rearrange an active working layout during recovery.
            tab.floatingPanes.append(.initial(
                paneID: paneID,
                index: tab.floatingPanes.count
            ))
        } else {
            let tab = TabModel(
                id: tabID,
                sessionID: sessionID,
                name: remotePane.title ?? "Recovered",
                firstPane: paneID
            )
            tabs.append(tab)
        }

        sessionNames[sessionID] = sessionNames[sessionID] ?? sessionLabel
        selectedTabID = tabID
        activePaneID = paneID
        if profile.kind == .ssh { profileStore.markUsed(profile) }
        isHostLauncherPresented = false
        persistWorkspace()
        Task { @MainActor in
            await Task.yield()
            pane.focus()
        }
        return true
    }

    /// Recover a single tab from retained host records, including a partially
    /// attached tab. Existing pane objects retain their drafts and runtimes.
    @discardableResult
    func recoverRemoteTab(profile: ConnectionProfile, remote: RemoteSessionRecord, tabID: UUID) -> [UUID] {
        guard let sessionID = remote.workspaceID.flatMap(UUID.init(uuidString:)) else { return [] }
        let records = remote.panes.filter {
            $0.recoverable && $0.tabID.flatMap(UUID.init(uuidString:)) == tabID
                && $0.workspaceID.flatMap(UUID.init(uuidString:)) == sessionID
        }
        let savedTab = remote.workspaceSnapshot?.tabs.first { $0.id == tabID && ($0.sessionID ?? $0.id) == sessionID }
        var target = tabs.first { $0.id == tabID }
        guard target == nil || target?.sessionID == sessionID else {
            operationError = "This tab belongs to a different saved session."
            return []
        }
        let recordIDs = records.compactMap { UUID(uuidString: $0.paneID) }
        guard Set(recordIDs).count == records.count else {
            operationError = "The host returned inconsistent pane identities."
            return []
        }
        for id in recordIDs where panes[id] != nil {
            guard panes[id]?.profile.connectionKey == profile.connectionKey,
                  tabs.first(where: { $0.allPaneIDs.contains(id) })?.id == tabID else {
                operationError = "A saved pane is already attached to a different tab or host."
                return []
            }
        }
        var added: [UUID] = []
        for record in records {
            guard let id = UUID(uuidString: record.paneID), panes[id] == nil else { continue }
            let pane = PaneModel(id: id, profile: profile,
                                 contentKind: PaneContentKind(rawValue: record.contentKind) ?? .terminal,
                                 requiresExistingWorker: true, remoteParentSessionID: record.parentPaneID,
                                 customName: record.title, directory: record.directory)
            pane.assignRemoteHierarchy(workspaceSessionID: sessionID, tabID: tabID)
            storePane(pane)
            if let target {
                target.floatingPanes.append(.initial(paneID: id, index: target.floatingPanes.count))
            } else {
                let tab = TabModel(id: tabID, sessionID: sessionID, name: savedTab?.name ?? record.title ?? "Recovered", firstPane: id)
                tabs.append(tab)
                target = tab
            }
            added.append(id)
        }
        guard let target else {
            operationError = "No retained panes are available for this tab."
            return []
        }
        if let savedTab, let snapshot = remote.workspaceSnapshot {
            let desired = savedTab.layout.paneIDs + (savedTab.floatingPanes ?? []).map(\.paneID)
            for saved in snapshot.panes where desired.contains(saved.id) && panes[saved.id] == nil && saved.contentKind == .editor {
                guard saved.hasValidBirthHierarchy else { continue }
                // Restore editors only when their original console is retained
                // on this host and belongs to this tab.
                guard let parent = saved.remoteParentSessionID.flatMap(UUID.init(uuidString:)),
                      target.allPaneIDs.contains(parent), panes[parent]?.profile.connectionKey == profile.connectionKey else { continue }
                let pane = PaneModel(id: saved.id, profile: profile, contentKind: .editor,
                                     remoteParentSessionID: saved.remoteParentSessionID,
                                     editorRequest: saved.editorRequest, customName: saved.customName, directory: saved.directory)
                saved.restoreBirthHierarchy(on: pane, fallbackWorkspaceSessionID: sessionID, fallbackTabID: tabID)
                storePane(pane)
                target.floatingPanes.append(.initial(paneID: saved.id, index: target.floatingPanes.count))
                added.append(saved.id)
            }
            if Set(desired).count == desired.count,
               Set(target.allPaneIDs) == Set(desired),
               desired.allSatisfy({ panes[$0] != nil }) {
                rememberArrangement(target)
                target.floatingPanes = savedTab.floatingPanes ?? []
                target.restoreLayout(legacy: savedTab.layout, visible: savedTab.visibleLayout, stacks: savedTab.stacks)
                target.splitRatios = savedTab.splitRatios ?? [:]
                restoreRLayout(savedTab, in: target)
            }
            let unavailable = desired.filter { panes[$0] == nil }.count
            if unavailable > 0 { operationError = "Recovered retained panes. \(unavailable) saved panels have no available session record." }
        }
        for index in target.floatingPanes.indices { target.floatingPanes[index].minimized = false }
        selectedTabID = tabID
        zoomedPaneID = nil
        if !target.allPaneIDs.contains(activePaneID ?? UUID()) { activePaneID = target.layout.paneIDs.first }
        sessionNames[sessionID] = sessionNames[sessionID] ?? remote.label
        isHostLauncherPresented = false
        persistWorkspace()
        return added
    }

    /// Reconnect only the current layout. Restoring closed panes remains a
    /// separate explicit action, so refresh cannot resurrect old shell panels.
    func reconnectPanels(in tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }), !recoveringTabIDs.contains(tabID) else { return }
        let ids = tab.allPaneIDs
        recoveringTabIDs.insert(tabID)
        operationError = nil
        Task { @MainActor in
            defer { self.recoveringTabIDs.remove(tabID) }
            for id in ids {
                guard self.tabs.contains(where: { $0 === tab }),
                      tab.allPaneIDs.contains(id), let pane = self.panes[id],
                      pane.contentKind == .terminal else { continue }
                if pane.connectionState == .connecting { continue }
                if !(await pane.runtime.reconnectExistingPaneRoute()) {
                    self.operationError = "Some panels could not reconnect. Use Restore to reopen a saved conversation."
                }
            }
        }
    }

    func recoverPanels(in tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }), !recoveringTabIDs.contains(tabID) else { return }
        let sessionID = tab.sessionID
        var profiles: [ConnectionProfile] = []
        for id in tab.allPaneIDs {
            if let profile = panes[id]?.profile, !profiles.contains(where: { $0.connectionKey == profile.connectionKey }) { profiles.append(profile) }
        }
        recoveringTabIDs.insert(tabID)
        operationError = nil
        Task { @MainActor in
            defer { self.recoveringTabIDs.remove(tabID) }
            for profile in profiles {
                do {
                    let catalog = try await RemoteCatalogService.load(profile: profile)
                    guard self.tabs.contains(where: { $0 === tab && $0.sessionID == sessionID }) else { return }
                    if let remote = catalog.sessions.first(where: { $0.workspaceID.flatMap(UUID.init(uuidString:)) == sessionID }) {
                        self.recoverRemoteTab(profile: profile, remote: remote, tabID: tabID)
                    } else {
                        self.operationError = "No saved session record was found on \(profile.name). Existing panels are still available."
                    }
                } catch { self.operationError = "Could not read saved panels on \(profile.name): \(error.localizedDescription)" }
            }
            guard self.tabs.contains(where: { $0 === tab }) else { return }
            for index in tab.floatingPanes.indices { tab.floatingPanes[index].minimized = false }
            self.zoomedPaneID = nil
            self.selectedTabID = tabID
            self.persistWorkspace()
            for id in tab.allPaneIDs {
                guard let pane = self.panes[id], pane.contentKind == .terminal else { continue }
                switch pane.connectionState {
                case .connected, .connecting: continue
                default:
                    if !(await pane.runtime.reconnectExistingPaneRoute()) {
                        self.operationError = "Some panels could not reconnect to their retained session. Open the panel's connection details to recover them."
                    }
                }
            }
        }
    }

    private func attachRemoteWorkspaceSnapshot(
        _ snapshot: WorkspaceSnapshot,
        profile: ConnectionProfile,
        sessionID: UUID,
        remote: RemoteSessionRecord
    ) -> Bool {
        let recoverableTerminalIDs = Set(remote.panes.filter(\.recoverable).compactMap { UUID(uuidString: $0.paneID) })
        var savedPanes: [UUID: PaneSnapshot] = [:]
        for saved in snapshot.panes {
            guard saved.hasValidBirthHierarchy else { return false }
            guard savedPanes.updateValue(saved, forKey: saved.id) == nil else { return false }
        }
        let sessionTabs = snapshot.tabs.filter { ($0.sessionID ?? $0.id) == sessionID }
        guard !sessionTabs.isEmpty else { return false }
        let requiredIDs = Set(sessionTabs.flatMap { tab in
            tab.layout.paneIDs + (tab.floatingPanes ?? []).map(\.paneID)
        })
        guard requiredIDs.allSatisfy({ id in
            guard let saved = savedPanes[id] else { return false }
            return saved.contentKind == .editor || recoverableTerminalIDs.contains(id)
        }) else { return false }

        for paneID in requiredIDs {
            guard let saved = savedPanes[paneID] else { return false }
            let remotePane = remote.panes.first { UUID(uuidString: $0.paneID) == paneID }
            let pane = PaneModel(
                id: paneID,
                profile: profile,
                contentKind: saved.contentKind ?? .terminal,
                requiresExistingWorker: (saved.contentKind ?? .terminal) == .terminal,
                remoteParentSessionID: remotePane?.parentPaneID ?? saved.remoteParentSessionID,
                editorRequest: saved.editorRequest,
                customName: remotePane?.title ?? saved.customName,
                directory: remotePane?.directory ?? saved.directory
            )
            saved.restoreBirthHierarchy(on: pane, hostWorkspaceSessionID: remotePane?.workspaceID, hostTabID: remotePane?.tabID)
            storePane(pane)
        }

        let restoredTabs = sessionTabs.compactMap { saved -> TabModel? in
            guard let first = saved.layout.paneIDs.first else { return nil }
            let tab = TabModel(
                id: saved.id,
                sessionID: sessionID,
                name: saved.name,
                firstPane: first,
                floatingPanes: saved.floatingPanes ?? []
            )
            tab.restoreLayout(legacy: saved.layout, visible: saved.visibleLayout, stacks: saved.stacks)
            tab.splitRatios = saved.splitRatios ?? [:]
            restoreRLayout(saved, in: tab)
            if tab.splitRatios.isEmpty { tab.balanceSplits() }
            for paneID in tab.allPaneIDs {
                if let pane = panes[paneID] {
                    savedPanes[paneID]?.restoreBirthHierarchy(on: pane, fallbackWorkspaceSessionID: sessionID, fallbackTabID: tab.id)
                }
            }
            return tab
        }
        guard !restoredTabs.isEmpty else {
            for paneID in requiredIDs {
                panes.removeValue(forKey: paneID)
                removePanePin(paneID)
            floatingRPaneTabs.removeValue(forKey: paneID)
            floatingRPrimaryEditors = floatingRPrimaryEditors.filter { $0.key != paneID && $0.value != paneID }
                activityIndex.remove(paneID)
            }
            return false
        }
        tabs.append(contentsOf: restoredTabs)
        sessionNames[sessionID] = snapshot.sessionNames?[sessionID] ?? remote.label
        selectedTabID = snapshot.selectedTabID.flatMap { selected in
            restoredTabs.contains(where: { $0.id == selected }) ? selected : nil
        } ?? restoredTabs[0].id
        activePaneID = snapshot.activePaneID.flatMap { requiredIDs.contains($0) ? $0 : nil }
            ?? restoredTabs.first(where: { $0.id == selectedTabID })?.layout.paneIDs.first
        if profile.kind == .ssh { profileStore.markUsed(profile) }
        isHostLauncherPresented = false
        persistWorkspace()
        return true
    }

    /// ⌘T and the rail +: a human tab goes to the shown workspace (even an
    /// empty one); an agent tab keeps its captured scope.
    func newTabInActiveSession(profile: ConnectionProfile? = nil, directory: String? = nil, origin: WorkspaceTabOrigin = .human) {
        // With an empty workspace shown, the remembered tab only supplies the
        // legacy session; the tab is still filed by the origin's scope.
        guard let source = selectedTab ?? rememberedTabID.flatMap({ id in tabs.first { $0.id == id } }) ?? tabs.first else {
            withTabAdmission(tabAdmission(for: origin)) { newTab(profile: profile ?? .local, origin: origin) }
            return
        }
        withTabAdmission(tabAdmission(for: origin)) {
            newTab(inSession: source.sessionID, profile: profile, directory: directory, origin: origin)
        }
    }

    func newTab(inSession sessionID: UUID) {
        let sessionTabs = tabs.filter { $0.sessionID == sessionID }
        guard let sourceTab = sessionTabs.first,
              let sourcePaneID = (selectedTab?.sessionID == sessionID ? activePaneID : sourceTab.allPaneIDs.first),
              let sourcePane = panes[sourcePaneID] else { return }
        newTab(inSession: sessionID, profile: sourcePane.profile)
    }

    func newTab(inSession sessionID: UUID, profile: ConnectionProfile?, directory: String? = nil,
                origin: WorkspaceTabOrigin = .human) {
        let sessionTabs = tabs.filter { $0.sessionID == sessionID }
        guard let sourceTab = sessionTabs.first,
              let sourcePaneID = (selectedTab?.sessionID == sessionID ? activePaneID : sourceTab.allPaneIDs.first),
              let sourcePane = panes[sourcePaneID] else { return }
        let targetProfile = profile ?? sourcePane.profile
        let parentSessionID = targetProfile.kind == .ssh && targetProfile.backend == .relay &&
            sourcePane.profile.kind == .ssh && sourcePane.profile.connectionKey == targetProfile.connectionKey
            ? (sourcePane.contentKind == .terminal ? sourcePane.id.uuidString.lowercased() : sourcePane.remoteParentSessionID)
            : nil
        let pane = PaneModel(profile: targetProfile, remoteParentSessionID: parentSessionID, startDirectory: directory)
        storePane(pane)
        let ordinal = sessionTabs.count + 1
        let tab = TabModel(
            sessionID: sessionID,
            name: ordinal == 1 ? targetProfile.name : "\(targetProfile.name) \(ordinal)",
            firstPane: pane.id
        )
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        // A human session switcher or "new tab in session" files the tab with
        // its source tab, even when that legacy session has no workspace.
        withTabAdmission(origin == .human ? tabAdmission(forSourcePane: sourcePaneID) : tabAdmission(for: origin)) { tabs.append(tab) }
        selectedTabID = tab.id
        activePaneID = pane.id
        if targetProfile.kind == .ssh { profileStore.markUsed(targetProfile) }
        persistWorkspace()
        Task { @MainActor [weak self, weak pane] in
            await Task.yield()
            guard let self, let pane, self.selectedTabID == tab.id,
                  self.activePaneID == pane.id, self.panes[pane.id] === pane,
                  !self.networkVisible, !self.paneLinkSelection.active else { return }
            pane.focus()
        }
    }

    func connectDraft(saveProfile: Bool) {
        let profile = draftProfile
        if saveProfile && profile.kind == .ssh { profileStore.save(profile) }
        newTab(profile: profile)
        isConnectionSheetPresented = false
    }

    func splitActive(axis: SplitAxis, profile: ConnectionProfile? = nil, directory: String? = nil) {
        guard let tab = selectedTab, let active = activePane,
              tab.allPaneIDs.contains(active.id) else { return }
        // Floating panes are not leaves of the tiled layout. Dock the source
        // before splitting it, otherwise splitting() silently leaves the tree
        // unchanged and the newly focused pane has no visible host.
        if tab.floatingPanes.contains(where: { $0.paneID == active.id }) {
            dockFloatingPane(active.id)
        }
        guard tab.layout.paneIDs.contains(active.id) else { return }
        let splitProfile = profile ?? active.profile
        let parentSessionID = splitProfile.kind == .ssh && splitProfile.backend == .relay &&
            active.profile.kind == .ssh && active.profile.connectionKey == splitProfile.connectionKey
            ? active.id.uuidString.lowercased()
            : nil
        let pane = PaneModel(profile: splitProfile, remoteParentSessionID: parentSessionID, startDirectory: directory)
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        storePane(pane)
        tab.layout = tab.layout.splitting(active.id, axis: axis, with: pane.id)
        tab.reconcileSplitRatios()
        zoomedPaneID = nil
        activePaneID = pane.id
        persistWorkspace()
    }

    /// Plugin activation is scoped to the captured console, never another tab.
    /// Reuses its editor and preserves every other terminal in the layout.
    /// Native R workspaces own their editor without adding a leaf to the tab.
    func prepareFloatingRWorkspace(consoleID: UUID) throws -> PaneModel {
        guard let tab = selectedTab, selectedTabOwnsRPane(consoleID),
              let console = panes[consoleID], console.contentKind == .terminal,
              console.profile.kind == .local || console.profile.backend == .relay else {
            throw PluginError.invalid("Select a local or Relay SSH R console.")
        }
        if console.profile.kind == .local && console.directory == nil {
            throw PluginError.invalid("Return to the shell prompt first so Relay can identify the local project directory")
        }
        let parent = consoleID.uuidString.lowercased()
        if let id = floatingRPrimaryEditors[consoleID], let editor = panes[id] { return editor }
        if let editor = panes.values.first(where: {
            $0.contentKind == .editor && $0.remoteParentSessionID == parent
                && tab.allPaneIDs.contains($0.id)
        }) {
            floatingRPrimaryEditors[consoleID] = editor.id
            return editor
        }
        let editor = PaneModel(profile: console.profile, contentKind: .editor, remoteParentSessionID: parent)
        editor.directory = console.directory
        editor.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        floatingRPaneTabs[editor.id] = tab.id
        floatingRPrimaryEditors[consoleID] = editor.id
        storePane(editor)
        persistWorkspace()
        return editor
    }

    /// Makes a floating editor of `consoleID` its R workspace's primary when
    /// that workspace has none yet, so presenting it draws this editor.
    @discardableResult
    func adoptFloatingRPrimaryEditor(_ paneID: UUID, consoleID: UUID) -> Bool {
        guard floatingRPrimaryEditors[consoleID] == nil, floatingRPaneTabs[paneID] != nil,
              let pane = panes[paneID], pane.contentKind == .editor,
              pane.remoteParentSessionID == consoleID.uuidString.lowercased() else { return false }
        floatingRPrimaryEditors[consoleID] = paneID
        return true
    }

    func addFloatingRPanel(consoleID: UUID, contentKind: PaneContentKind) throws -> PaneModel {
        guard let tab = selectedTab, selectedTabOwnsRPane(consoleID),
              let console = panes[consoleID], console.contentKind == .terminal else {
            throw PluginError.invalid("The original R console is unavailable in this tab")
        }
        let pane = PaneModel(profile: console.profile, contentKind: contentKind,
                             remoteParentSessionID: consoleID.uuidString.lowercased())
        pane.directory = console.directory
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        floatingRPaneTabs[pane.id] = tab.id
        storePane(pane)
        persistWorkspace()
        return pane
    }

    func closeFloatingRPanel(_ paneID: UUID, consoleID: UUID) -> Bool {
        guard paneID != consoleID, floatingRPaneTabs[paneID] != nil,
              !floatingRPrimaryEditors.values.contains(paneID), let pane = panes[paneID] else { return false }
        if pane.contentKind == .editor, !pane.editorRuntime.confirmDiscardChanges() { return false }
        retirePluginPresentation(for: paneID)
        pane.stopRuntime()
        panes.removeValue(forKey: paneID)
        removePanePin(paneID)
        floatingRPaneTabs.removeValue(forKey: paneID)
        activityIndex.remove(paneID)
        if activePaneID == paneID { activePaneID = consoleID }
        return true
    }

    func rWorkspaceTerminalCandidates(consoleID: UUID) -> [PaneModel] {
        guard let tab = tabs.first(where: {
            $0.allPaneIDs.contains(consoleID) || floatingRPaneTabs[consoleID] == $0.id
        }) else { return [] }
        return tab.allPaneIDs.compactMap { panes[$0] }.filter {
            $0.contentKind == .terminal && $0.id != consoleID
        }
    }

    private func selectedTabOwnsRPane(_ id: UUID) -> Bool {
        guard let tab = selectedTab else { return false }
        return tab.allPaneIDs.contains(id) || floatingRPaneTabs[id] == tab.id
    }

    func activateRWorkspace(consoleID: UUID) throws {
        guard let tab = selectedTab, tab.allPaneIDs.contains(consoleID),
              let console = panes[consoleID], console.contentKind == .terminal,
              (console.profile.kind == .local || console.profile.backend == .relay),
              tab.layout.paneIDs.contains(consoleID) else {
            throw PluginError.invalid("Select a docked local or Relay SSH R console.")
        }
        if console.profile.kind == .local && console.directory == nil {
            throw PluginError.invalid("Return to the shell prompt first so Relay can identify the local project directory")
        }
        let parent = consoleID.uuidString.lowercased()
        let existing = tab.allPaneIDs.compactMap { panes[$0] }.first {
            $0.contentKind == .editor && $0.remoteParentSessionID == parent
        }
        let editor: PaneModel
        if let existing {
            editor = existing
            // A linked editor keeps its chosen tiled or floating placement.
            activePaneID = editor.id
            return
        } else {
            editor = PaneModel(profile: console.profile, contentKind: .editor, remoteParentSessionID: parent)
            editor.directory = console.directory
            editor.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
            storePane(editor)
        }
        tab.layout = tab.layout.splitting(consoleID, axis: .vertical, with: editor.id, newPaneFirst: true)
        activePaneID = editor.id
        persistWorkspace()
    }

    func openEditorForActive() {
        guard let tab = selectedTab,
              let active = activePane,
              active.profile.kind == .local || active.profile.backend == .relay,
              active.directory != nil else { return }
        let parentSessionID = active.contentKind == .terminal
            ? active.id.uuidString.lowercased()
            : active.remoteParentSessionID
        let pane = PaneModel(
            profile: active.profile,
            contentKind: .editor,
            remoteParentSessionID: parentSessionID,
            directory: active.directory
        )
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        storePane(pane)
        tab.floatingPanes.append(.initial(paneID: pane.id, index: tab.floatingPanes.count))
        activePaneID = pane.id
        persistWorkspace()
    }

    func openRemoteFile(_ open: RemoteFileOpenRequest) {
        // Route asynchronous opens to their originating tab, even if the user
        // switched tabs while the remote event was in flight.
        guard let parentID = UUID(uuidString: open.parentSessionID),
              let tab = tabs.first(where: { $0.allPaneIDs.contains(parentID) }) else { return }
        selectedTabID = tab.id
        if let existingID = tab.allPaneIDs.first(where: { id in
            guard let pane = panes[id] else { return false }
            return pane.contentKind == .editor && pane.profile.connectionKey == open.profile.connectionKey
                && pane.remoteParentSessionID == open.parentSessionID
        }), let editor = panes[existingID] {
            activePaneID = existingID
            editor.editorRuntime.open(open.request)
            editor.focus()
            persistWorkspace()
            return
        }
        guard activePaneID != nil else { return }
        let pane = PaneModel(
            profile: open.profile,
            contentKind: .editor,
            remoteParentSessionID: open.parentSessionID,
            editorRequest: open.request
        )
        pane.directory = panes[parentID]?.directory
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        storePane(pane)
        tab.floatingPanes.append(.initial(paneID: pane.id, index: tab.floatingPanes.count))
        self.activePaneID = pane.id
        persistWorkspace()
    }

    func swapTiledPanes(_ firstID: UUID, _ secondID: UUID) {
        guard firstID != secondID,
              let tab = selectedTab,
              tab.layout.paneIDs.contains(firstID),
              tab.layout.paneIDs.contains(secondID) else { return }
        tab.layout = tab.layout.swapping(firstID, secondID)
        activePaneID = firstID
        persistWorkspace()
        Task { @MainActor in
            await Task.yield()
            panes[firstID]?.focus()
        }
    }

    func movePane(_ paneID: UUID, to targetID: UUID, placement: PaneDropPlacement) {
        guard paneID != targetID, let tab = selectedTab, tab.layout.paneIDs.contains(targetID) else { return }
        let wasStacked = tab.stack(containing: paneID) != nil
        let wasTiled = tab.layout.paneIDs.contains(paneID) || wasStacked
        if placement == .center, wasTiled, !wasStacked {
            swapTiledPanes(paneID, targetID)
            return
        }
        let baseLayout: PaneLayout
        if wasStacked {
            guard tab.detachTiledPane(paneID), tab.layout.paneIDs.contains(targetID) else { return }
            baseLayout = tab.layout
        } else if wasTiled {
            guard let removed = tab.layout.removing(paneID) else { return }
            baseLayout = removed
        } else if let floatingIndex = tab.floatingPanes.firstIndex(where: { $0.paneID == paneID }) {
            tab.floatingPanes.remove(at: floatingIndex)
            baseLayout = tab.layout
        } else {
            return
        }
        let effectivePlacement = placement == .center ? .trailing : placement
        let axis: SplitAxis = effectivePlacement == .top || effectivePlacement == .bottom ? .vertical : .horizontal
        let first = effectivePlacement == .leading || effectivePlacement == .top
        tab.layout = baseLayout.splitting(targetID, axis: axis, with: paneID, newPaneFirst: first)
        tab.reconcileSplitRatios()
        activePaneID = paneID
        zoomedPaneID = nil
        persistWorkspace()
        panes[paneID]?.focus()
    }

    func newFloatingPane(profile: ConnectionProfile? = nil) {
        guard let tab = selectedTab, let active = activePane else { return }
        let paneProfile = profile ?? active.profile
        let parentSessionID = paneProfile.kind == .ssh && paneProfile.backend == .relay
            ? active.id.uuidString.lowercased()
            : nil
        let pane = PaneModel(profile: paneProfile, remoteParentSessionID: parentSessionID)
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        storePane(pane)
        tab.floatingPanes.append(.initial(paneID: pane.id, index: tab.floatingPanes.count))
        activePaneID = pane.id
        persistWorkspace()
        Task { @MainActor in
            await Task.yield()
            pane.focus()
        }
    }

    func updateFloatingPane(
        _ paneID: UUID,
        originX: Double? = nil,
        originY: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) {
        guard let tab = selectedTab,
              let index = tab.floatingPanes.firstIndex(where: { $0.paneID == paneID }) else { return }
        if let originX { tab.floatingPanes[index].originX = originX }
        if let originY { tab.floatingPanes[index].originY = originY }
        if let width { tab.floatingPanes[index].width = width }
        if let height { tab.floatingPanes[index].height = height }
        persistWorkspace()
    }

    private func rememberArrangement(_ tab: TabModel) {
        guard tab.savedArrangement == nil else { return }
        tab.savedArrangement = PaneArrangementSnapshot(
            layout: tab.layout, floating: tab.floatingPanes, ratios: tab.splitRatios,
            active: activePaneID,
            results: Dictionary(uniqueKeysWithValues: tab.allPaneIDs.compactMap { id in
                guard let pane = panes[id], pane.contentKind == .editor else { return nil }
                return (id, pane.editorRuntime.showsRResults)
            }))
    }

    func minimizeFloatingPane(_ id: UUID) {
        guard let tab = selectedTab,
              let index = tab.floatingPanes.firstIndex(where: { $0.paneID == id }) else { return }
        tab.floatingPanes[index].minimized = true
        if zoomedPaneID == id { zoomedPaneID = nil }
        if activePaneID == id, let next = tab.layout.paneIDs.first { selectPane(next, origin: .programmatic) }
        persistWorkspace()
    }

    func arrangeFloatingPanes(cascade: Bool) {
        guard let tab = selectedTab else { return }
        let visible = tab.floatingPanes.indices.filter { !tab.floatingPanes[$0].isMinimized }
        guard !visible.isEmpty, tab.canvasSize.width > 0, tab.canvasSize.height > 0 else { return }
        let columns = Int(ceil(sqrt(Double(visible.count))))
        let rows = Int(ceil(Double(visible.count) / Double(columns)))
        let width = (tab.canvasSize.width - 24 - Double(columns - 1) * 12) / Double(columns)
        let height = (tab.canvasSize.height - 24 - Double(rows - 1) * 12) / Double(rows)
        guard cascade || (width >= 380 && height >= 260) else {
            operationError = "Not enough room to tile these panes without overlap. Minimize some panes, enlarge the window, or use Cascade."
            return
        }
        rememberArrangement(tab)
        zoomedPaneID = nil
        for (position, index) in visible.enumerated() {
            let offset = Double(position) * min(28, max(0, (tab.canvasSize.height - 284) / Double(max(1, visible.count - 1))))
            tab.floatingPanes[index].originX = cascade ? 12 + offset : 12 + Double(position % columns) * (width + 12)
            tab.floatingPanes[index].originY = cascade ? 12 + offset : 12 + Double(position / columns) * (height + 12)
            tab.floatingPanes[index].width = cascade ? min(620, max(380, tab.canvasSize.width - 24 - offset)) : width
            tab.floatingPanes[index].height = cascade ? min(410, max(260, tab.canvasSize.height - 24 - offset)) : height
        }
        persistWorkspace()
    }

    func restorePaneArrangement() {
        guard let tab = selectedTab, let saved = tab.savedArrangement else { return }
        guard Set(tab.allPaneIDs) == Set(saved.layout.paneIDs + saved.floating.map(\.paneID)) else {
            operationError = "The panes in this tab have changed. The saved layout cannot be restored safely."
            return
        }
        tab.layout = saved.layout
        tab.reconcileStacks()
        if let id = tab.rLayoutEditorID { panes[id]?.editorRuntime.externalRResults = false }
        tab.rLayoutEditorID = nil
        tab.floatingPanes = saved.floating
        tab.splitRatios = saved.ratios
        for (id, visible) in saved.results { panes[id]?.editorRuntime.showsRResults = visible }
        tab.savedArrangement = nil
        zoomedPaneID = nil
        activePaneID = saved.active ?? tab.layout.paneIDs.first
        persistWorkspace()
    }

    @discardableResult
    func arrangeRWorkspace(consoleID requestedConsoleID: UUID? = nil) -> Bool {
        guard let tab = selectedTab, let active = activePane else {
            operationError = "Select an R console before opening the R workspace."
            return false
        }
        operationError = nil
        guard !tab.chrome.hasDraft else {
            operationError = "Finish or close the current context draft before opening R results."
            return false
        }
        let consoleID = requestedConsoleID ?? (active.contentKind == .editor
            ? active.remoteParentSessionID.flatMap(UUID.init(uuidString:)) : active.id)
        guard let consoleID, tab.layout.paneIDs.contains(consoleID) else {
            operationError = "Select a docked R console or its linked editor first."
            return false
        }
        do { try activateRWorkspace(consoleID: consoleID) }
        catch { operationError = error.localizedDescription; return false }
        guard let editor = activePane, editor.contentKind == .editor,
              let console = panes[consoleID] else { return false }
        // R is an additive companion to the selected console. Existing splits,
        // floating panes, zoom state and their geometry belong to the user.
        editor.editorRuntime.showsRResults = true
        editor.editorRuntime.externalRResults = true
        tab.rLayoutEditorID = editor.id
        tab.chrome.reveal(.rWorkspace, initial: WorkspaceContextAnchor(
            paneID: consoleID, profile: console.profile, directory: console.directory))
        editor.editorRuntime.connectRWorkspaceWhenReady()
        persistWorkspace()
        return true
    }

    func toggleActivePaneZoom() {
        guard let activePaneID else { return }
        panes[activePaneID]?.runtime.beginExplicitGeometryTransition()
        zoomedPaneID = zoomedPaneID == activePaneID ? nil : activePaneID
        panes[activePaneID]?.focus()
    }

    func togglePaneZoom(_ paneID: UUID) {
        selectPane(paneID, origin: .programmatic)
        toggleActivePaneZoom()
    }

    func toggleActivePaneFloating() {
        guard let paneID = activePaneID, let tab = selectedTab else { return }
        if tab.floatingPanes.contains(where: { $0.paneID == paneID }) {
            dockFloatingPane(paneID)
        } else {
            floatTiledPane(paneID)
        }
    }

    func floatTiledPane(_ paneID: UUID) {
        guard let tab = selectedTab,
              tab.layout.paneIDs.count > 1 || tab.stack(containing: paneID) != nil,
              tab.layout.paneIDs.contains(paneID) || tab.stack(containing: paneID) != nil,
              tab.detachTiledPane(paneID) else { return }
        tab.floatingPanes.append(.initial(paneID: paneID, index: tab.floatingPanes.count))
        tab.reconcileSplitRatios()
        activePaneID = paneID
        zoomedPaneID = nil
        persistWorkspace()
    }

    func dockFloatingPane(_ paneID: UUID) {
        guard let tab = selectedTab,
              let floatingIndex = tab.floatingPanes.firstIndex(where: { $0.paneID == paneID }),
              let targetID = tab.layout.paneIDs.first else { return }
        tab.floatingPanes.remove(at: floatingIndex)
        tab.layout = tab.layout.splitting(targetID, axis: .horizontal, with: paneID)
        tab.reconcileSplitRatios()
        activePaneID = paneID
        zoomedPaneID = nil
        persistWorkspace()
        panes[paneID]?.focus()
    }

    /// An ended terminal needs a new worker identity, rather than another
    /// attach to its immutable recovery binding. Keep the layout position and
    /// retain the ended pane in recovery history without restarting its worker.
    func requestResumeSavedConversation(_ paneID: UUID) {
        Task { @MainActor in
            do { _ = try await self.resumeSavedConversation(paneID) }
            catch { self.operationError = "Could not resume saved conversation: \(error.localizedDescription)" }
        }
    }

    func resumeSavedConversation(_ paneID: UUID) async throws -> UUID {
        guard let old = panes[paneID], old.contentKind == .terminal,
              old.profile.backend == .relay, (old.remoteExitCode != nil || old.phase == .exited),
              !recoveringConversationPaneIDs.contains(paneID) else {
            throw RemoteCatalogError.failed("Select an ended pane with a saved provider conversation")
        }
        recoveringConversationPaneIDs.insert(paneID)
        defer { recoveringConversationPaneIDs.remove(paneID) }
        operationError = nil
        let plan = try await RelaySavedConversationRecovery.plan(profile: old.profile, paneID: paneID)
        guard panes[paneID] === old, old.remoteExitCode != nil || old.phase == .exited else {
            throw RemoteCatalogError.failed("The pane changed during recovery")
        }
        var profile = old.profile
        profile.command = try plan.command(profile: profile)
        guard let replacement = restartExitedPane(paneID, profile: profile, directory: plan.directory) else {
            throw RemoteCatalogError.failed("The pane changed during recovery")
        }
        recoveryStore.recordRestore(source: paneID, destination: replacement, plan: plan, profile: profile)
        return replacement
    }

    func reconnectPane(_ paneID: UUID) {
        guard let pane = panes[paneID], pane.contentKind == .terminal else { return }
        selectPane(paneID, origin: .programmatic)
        pane.runtime.restart()
    }

    @discardableResult
    func restartExitedPane(_ paneID: UUID, profile: ConnectionProfile? = nil, directory: String? = nil) -> UUID? {
        guard let old = panes[paneID], old.contentKind == .terminal,
              old.profile.backend == .relay, (old.remoteExitCode != nil || old.phase == .exited),
              let tab = tabs.first(where: { $0.allPaneIDs.contains(paneID) }) else { return nil }
        let replacement = PaneModel(
            profile: profile ?? old.profile,
            customName: old.customName,
            directory: directory ?? old.directory
        )
        replacement.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        rememberClosedPane(paneID, in: tab)
        storePane(replacement)
        if let index = tab.floatingPanes.firstIndex(where: { $0.paneID == paneID }) {
            let placement = tab.floatingPanes[index]
            tab.floatingPanes[index] = FloatingPanePlacement(
                paneID: replacement.id,
                originX: placement.originX, originY: placement.originY,
                width: placement.width, height: placement.height,
                minimized: placement.minimized
            )
        } else {
            tab.layout = tab.layout.swapping(paneID, replacement.id)
        }
        if zoomedPaneID == paneID { zoomedPaneID = replacement.id }
        if agentInspector?.paneID == paneID { agentInspector = nil }
        retirePluginPresentation(for: paneID)
        old.stopRuntime()
        panes.removeValue(forKey: paneID)
        removePanePin(paneID)
        activityIndex.remove(paneID)
        selectedTabID = tab.id
        activePaneID = replacement.id
        persistWorkspace()
        return replacement.id
    }

    func closeActivePane() {
        guard let tab = selectedTab, let activePaneID else { return }
        if tab.allPaneIDs.count > 1, let pane = panes[activePaneID], pane.contentKind == .editor,
           !pane.editorRuntime.confirmDiscardChanges() { return }
        rememberClosedPane(activePaneID, in: tab)
        if agentInspector?.paneID == activePaneID { agentInspector = nil }
        if zoomedPaneID == activePaneID { zoomedPaneID = nil }
        if let floatingIndex = tab.floatingPanes.firstIndex(where: { $0.paneID == activePaneID }) {
            tab.floatingPanes.remove(at: floatingIndex)
            retirePluginPresentation(for: activePaneID)
            panes[activePaneID]?.composerStateIfCreated?.paneClosed()
            panes[activePaneID]?.stopRuntime()
            panes.removeValue(forKey: activePaneID)
            removePanePin(activePaneID)
            activityIndex.remove(activePaneID)
            self.activePaneID = tab.allPaneIDs.first
            persistWorkspace()
            return
        }
        if tab.layout.paneIDs.count == 1 && tab.stack(containing: activePaneID) == nil {
            closeTab(tab.id)
            return
        }
        // A showing stack member hands its slot to the next member.
        tab.detachTiledPane(activePaneID)
        tab.reconcileSplitRatios()
        retirePluginPresentation(for: activePaneID)
        panes[activePaneID]?.composerStateIfCreated?.paneClosed()
        panes[activePaneID]?.stopRuntime()
        panes.removeValue(forKey: activePaneID)
        removePanePin(activePaneID)
        activityIndex.remove(activePaneID)
        self.activePaneID = tab.layout.paneIDs.first
        persistWorkspace()
    }

    var canReopenClosedPane: Bool { recentlyClosedPaneCount > 0 }

    var recoveryEntries: [ClosedPaneRecovery] {
        recoveryStore.loadClosedPanes().filter { panes[$0.pane.id] == nil }
    }

    var exitedRecoveryPanes: [PaneModel] {
        panes.values.filter { $0.contentKind == .terminal && ($0.phase == .exited || $0.remoteExitCode != nil) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func reopenRecoveryEntry(_ entry: ClosedPaneRecovery) {
        recentlyClosedPanes.removeAll { $0.id == entry.id }
        recentlyClosedPanes.append(entry)
        reopenLastClosedPane()
    }

    func resumeRecoveryEntry(_ entry: ClosedPaneRecovery) async throws {
        let source = entry.pane
        let plan = try await RelaySavedConversationRecovery.plan(profile: source.profile, paneID: source.id)
        var profile = source.profile
        profile.command = try plan.command(profile: profile)
        let pane = PaneModel(profile: profile, directory: plan.directory)
        let tab: TabModel
        if let existing = tabs.first(where: { $0.id == entry.tab.id }) {
            tab = existing
            if let target = tab.layout.paneIDs.first {
                tab.layout = tab.layout.splitting(target, axis: .horizontal, with: pane.id)
                tab.reconcileSplitRatios()
            } else { tab.layout = .pane(pane.id) }
        } else {
            tab = TabModel(id: entry.tab.id, sessionID: entry.tab.sessionID ?? entry.tab.id,
                name: entry.tab.name, firstPane: pane.id)
            tabs.insert(tab, at: min(entry.tabIndex, tabs.count))
        }
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        storePane(pane)
        selectedTabID = tab.id
        activePaneID = pane.id
        // Keep the archive until the user sees a successful restore. Launch
        // submission alone cannot prove the provider opened its conversation.
        recoveryStore.recordRestore(source: source.id, destination: pane.id, plan: plan, profile: profile)
        persistWorkspace()
    }

    func reopenLastClosedPane(in tabID: UUID? = nil) {
        while let index = recentlyClosedPanes.lastIndex(where: { tabID == nil || $0.tab.id == tabID }) {
            let recovery = recentlyClosedPanes.remove(at: index)
            recentlyClosedPaneCount = recentlyClosedPanes.count
            guard panes[recovery.pane.id] == nil else { continue }

            let saved = recovery.pane
            guard saved.hasValidBirthHierarchy else {
                operationError = "The saved pane's original session identity could not be verified."
                continue
            }
            let pane = PaneModel(
                id: saved.id,
                profile: saved.profile,
                contentKind: saved.contentKind ?? .terminal,
                remoteParentSessionID: saved.remoteParentSessionID,
                editorRequest: saved.editorRequest,
                customName: saved.customName,
                directory: saved.directory
            )
            let sessionID = recovery.tab.sessionID ?? recovery.tab.id
            saved.restoreBirthHierarchy(on: pane, fallbackWorkspaceSessionID: sessionID, fallbackTabID: recovery.tab.id)
            storePane(pane)

            let restoredTab: TabModel
            if let existing = tabs.first(where: { $0.id == recovery.tab.id }) {
                restoredTab = existing
                if let placement = recovery.floatingPlacement {
                    existing.floatingPanes.append(placement)
                } else if let layoutWithoutPane = recovery.tab.layout.removing(saved.id),
                          layoutWithoutPane == existing.layout {
                    existing.layout = recovery.tab.layout
                    existing.splitRatios = recovery.tab.splitRatios ?? [:]
                } else if let target = existing.layout.paneIDs.first {
                    existing.layout = existing.layout.splitting(
                        target, axis: .horizontal, with: saved.id
                    )
                    existing.reconcileSplitRatios()
                } else {
                    existing.layout = .pane(saved.id)
                }
            } else {
                let tab = TabModel(
                    id: recovery.tab.id,
                    sessionID: sessionID,
                    name: recovery.tab.name,
                    firstPane: saved.id
                )
                let index = min(recovery.tabIndex, tabs.count)
                tabs.insert(tab, at: index)
                restoredTab = tab
            }

            selectedTabID = restoredTab.id
            activePaneID = saved.id
            zoomedPaneID = nil
            recoveryStore.removeClosedPane(recovery.id)
            recoveryStore.record(kind: "pane_reopened", paneID: saved.id, profile: saved.profile,
                links: [.init(from: "pane:\(saved.id)", to: "tab:\(restoredTab.id)", kind: "belongs_to")])
            persistWorkspace()
            Task { @MainActor in
                await Task.yield()
                pane.focus()
            }
            return
        }
    }

    private func rememberClosedPane(_ paneID: UUID, in tab: TabModel) {
        guard let pane = panes[paneID],
              let tabIndex = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let paneSnapshot = PaneSnapshot(pane: pane)
        let recovery = ClosedPaneRecovery(
            pane: paneSnapshot,
            tab: tabSnapshot(tab),
            tabIndex: tabIndex,
            floatingPlacement: tab.floatingPanes.first(where: { $0.paneID == paneID })
        )
        recoveryStore.saveClosedPane(recovery)
        closedSinceSave.insert(paneID)
        recentlyClosedPanes.append(recovery)
        if recentlyClosedPanes.count > 20 {
            recentlyClosedPanes.removeFirst(recentlyClosedPanes.count - 20)
        }
        lastClosedPaneWasRemote = pane.contentKind == .terminal && pane.profile.backend == .relay
        recentlyClosedPaneCount = recentlyClosedPanes.count
        // Monotonic close signal for the undo toast: the buffer count
        // saturates at 20 (21st close computes 20 -> 20, no change) and
        // decreases on undo, so it cannot distinguish "pane closed" from
        // "pane reopened".
        paneCloseEvent &+= 1
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let ids = tabs[index].allPaneIDs + floatingRPaneTabs.filter { $0.value == id }.map(\.key)
        guard whileAwaitingCloseConfirmation([id], {
            ids.allSatisfy { id in
                guard let pane = panes[id], pane.contentKind == .editor else { return true }
                return pane.editorRuntime.confirmDiscardChanges()
            }
        }) else { return }
        if let zoomedPaneID, ids.contains(zoomedPaneID) { self.zoomedPaneID = nil }
        for paneID in ids {
            rememberClosedPane(paneID, in: tabs[index])
            if agentInspector?.paneID == paneID { agentInspector = nil }
            retirePluginPresentation(for: paneID)
            panes[paneID]?.composerStateIfCreated?.paneClosed()
            panes[paneID]?.stopRuntime()
            panes.removeValue(forKey: paneID)
            removePanePin(paneID)
            floatingRPaneTabs.removeValue(forKey: paneID)
            floatingRPrimaryEditors = floatingRPrimaryEditors.filter { $0.key != paneID && $0.value != paneID }
            activityIndex.remove(paneID)
        }
        tabs.remove(at: index)
        organization.pruneClosedTabs()
        pinnedTabIDs.remove(id)
        WorkspacePinStore.save(pinnedTabIDs, kind: .tab)
        if tabs.isEmpty {
            newTab(profile: .local)
        } else if selectedTabID == id {
            // Only move selection when the closed tab was the selected one;
            // closing a background tab from its context menu must not yank
            // the user away from the tab they are working in.
            let nextIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[nextIndex].id
        }
        persistWorkspace()
    }

    /// Close confirmation may run a nested modal loop. While it does, the
    /// tabs are marked so agents cannot move them or anchor new tabs to them.
    func whileAwaitingCloseConfirmation(_ tabIDs: Set<UUID>, _ confirm: () -> Bool) -> Bool {
        let added = tabIDs.subtracting(tabsAwaitingCloseConfirmation)
        tabsAwaitingCloseConfirmation.formUnion(added)
        defer { tabsAwaitingCloseConfirmation.subtract(added) }
        return confirm()
    }

    func closeSession(_ sessionID: UUID) {
        let closingTabs = tabs.filter { $0.sessionID == sessionID }
        guard !closingTabs.isEmpty else { return }
        let closingTabIDs = Set(closingTabs.map(\.id))
        let closingPaneIDs = closingTabs.flatMap(\.allPaneIDs) + floatingRPaneTabs.filter { closingTabIDs.contains($0.value) }.map(\.key)
        guard whileAwaitingCloseConfirmation(closingTabIDs, {
            closingPaneIDs.allSatisfy { id in
                guard let pane = panes[id], pane.contentKind == .editor else { return true }
                return pane.editorRuntime.confirmDiscardChanges()
            }
        }) else { return }
        for paneID in closingPaneIDs {
            if let tab = closingTabs.first(where: { $0.allPaneIDs.contains(paneID) }) {
                rememberClosedPane(paneID, in: tab)
            }
            if agentInspector?.paneID == paneID { agentInspector = nil }
            retirePluginPresentation(for: paneID)
            panes[paneID]?.composerStateIfCreated?.paneClosed()
            panes[paneID]?.stopRuntime()
            panes.removeValue(forKey: paneID)
            removePanePin(paneID)
            floatingRPaneTabs.removeValue(forKey: paneID)
            floatingRPrimaryEditors = floatingRPrimaryEditors.filter { $0.key != paneID && $0.value != paneID }
            activityIndex.remove(paneID)
        }
        tabs.removeAll { closingTabIDs.contains($0.id) }
        organization.pruneClosedTabs()
        sessionNames.removeValue(forKey: sessionID)
        pinnedSessionIDs.remove(sessionID)
        pinnedTabIDs.subtract(closingTabIDs)
        WorkspacePinStore.save(pinnedSessionIDs, kind: .session)
        WorkspacePinStore.save(pinnedTabIDs, kind: .tab)
        if tabs.isEmpty {
            newTab(profile: .local)
            return
        }
        if let selected = selectedTabID, closingTabIDs.contains(selected) {
            let next = tabs[0]
            selectedTabID = next.id
            activePaneID = next.layout.paneIDs.first
            zoomedPaneID = nil
        }
        persistWorkspace()
    }

    func selectTab(_ id: UUID, origin: PaneSelectionOrigin = .programmatic) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        // An explicit tab click always shows that tab's workspace, even when
        // the ID is already selected.
        if let owner = ownership.owner(of: id) { showWorkspace(owner) }
        organization.noteSelection(.tab(id))
        selectedTabID = id
        if origin == .user, let paneID = activePaneID { recordPaneVisit(paneID) }
        persistWorkspace()
        // The previous tab's Ghostty surface can remain the AppKit first
        // responder briefly after SwiftUI hides it. Wait for the selected
        // surface to mount, then transfer keyboard focus explicitly.
        if let paneID = activePaneID, let pane = panes[paneID] {
            Task { @MainActor in
                await Task.yield()
                guard !self.networkVisible, !self.paneLinkSelection.active, self.selectedTabID == id, self.activePaneID == paneID else { return }
                pane.focus()
            }
        }
    }

    /// Records a Go to pane visit. Callers pass `.user` only for a click,
    /// key command or navigator choice; restore, focus repair, agents, Miko
    /// and MCP tools pass `.programmatic`.
    func selectPane(_ id: UUID, origin: PaneSelectionOrigin) {
        // Late callbacks from durable views in another tab must not corrupt
        // selection. Explicit cross-tab navigation reveals its owner first.
        guard panes[id] != nil, let selectedTabID, let tab = selectedTab,
              tab.allPaneIDs.contains(id) || floatingRPaneTabs[id] == selectedTabID else { return }
        organization.noteSelection(.pane(id))
        if origin == .user { recordPaneVisit(id) }
        // A floating R pane is drawn only inside its R workspace.
        if floatingRPaneTabs[id] != nil { revealFloatingRPane?(id) }
        // Re-selecting the pane already in front reads alerts that arrived since.
        paneShown(id)
        // A hidden stack member is shown in its stack's slot before selection.
        if tab.hiddenStackPaneIDs.contains(id) { selectStackMember(id) }
        if let tab = selectedTab,
           let index = tab.floatingPanes.firstIndex(where: { $0.paneID == id }),
           tab.floatingPanes[index].isMinimized {
            tab.floatingPanes[index].minimized = false
        }
        var reorderedFloatingPane = false
        if let tab = selectedTab,
           let index = tab.floatingPanes.firstIndex(where: { $0.paneID == id }),
           index != tab.floatingPanes.index(before: tab.floatingPanes.endIndex) {
            let pane = tab.floatingPanes.remove(at: index)
            tab.floatingPanes.append(pane)
            reorderedFloatingPane = true
        }
        // Avoid an unnecessary published mutation for an already-active pane,
        // but never treat active model state as proof of AppKit keyboard
        // ownership. A minimize, Space switch, overlay, or durable-view
        // reparent can leave the model active while the terminal is no longer
        // first responder.
        if activePaneID != id || reorderedFloatingPane {
            activePaneID = id
            persistWorkspace()
        }
        guard let pane = panes[id] else { return }
        if pane.contentKind == .editor { startEditorRuntime(pane) }
        // An explicit click must repair eligibility even if this pane was
        // already selected, and claim a mounted view before the next key.
        updateTerminalFocusOwnership()
        if !networkVisible && !paneLinkSelection.active { pane.focus() }
        Task { @MainActor [weak self, weak pane] in
            await Task.yield()
            guard let self, let pane,
                  !self.networkVisible,
                  !self.paneLinkSelection.active,
                  self.activePaneID == id,
                  self.panes[id] === pane else { return }
            pane.focus()
        }
    }

    /// The Previous/Next pane menu commands: always user-initiated.
    func selectAdjacentPane(offset: Int) {
        guard let tab = selectedTab else { return }
        let ids = tab.allPaneIDs
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(of: activePaneID ?? ids[0]) ?? 0
        activePaneID = ids[(current + offset + ids.count) % ids.count]
        recordPaneVisit(activePaneID!)
        panes[activePaneID!]?.focus()
        persistWorkspace()
    }

    func selectTab(offset: Int) {
        guard let workspaceID = selectedWorkspaceID,
              let next = WorkspaceNavigationState.adjacentTab(current: selectedTabID,
                ordered: railTabs(inWorkspace: workspaceID).map(\.id), offset: offset) else { return }
        selectTab(next, origin: .user)
    }

    private func recordPaneVisit(_ id: UUID, now: Date = Date()) {
        guard panes[id] != nil else { return }
        paneVisits.record(id, at: now)
        persistWorkspace()
    }

    var navigationSessionIDs: [UUID] {
        var seen: Set<UUID> = []
        return tabs.map(\.sessionID).filter { seen.insert($0).inserted }
    }

    func navigationSessionName(_ id: UUID) -> String {
        let pane = tabs.first(where: { $0.sessionID == id })?.allPaneIDs.first.flatMap { panes[$0] }
        let host = pane?.profile.kind == .ssh ? (pane?.profile.host ?? "Remote") : "This Mac"
        return sessionDisplayName(id, fallback: host)
    }

    /// `.user` for a sidebar click or key command: the pane shown is a Go to pane visit.
    func selectSession(_ id: UUID, origin: PaneSelectionOrigin = .programmatic) {
        let candidates = orderedTabs(in: id).map(\.id)
        guard let tabID = navigationState.preferredTab(in: id, available: candidates) else { return }
        selectTab(tabID, origin: origin)
    }

    func selectSession(offset: Int) {
        guard let next = WorkspaceNavigationState.adjacentTab(current: selectedTab?.sessionID,
            ordered: navigationSessionIDs, offset: offset) else { return }
        selectSession(next, origin: .user)
    }

    func toggleNavigationGroup(_ group: WorkspaceNavigationState.Group, id: UUID) {
        navigationState = WorkspaceNavigationState.updating { $0.toggle(group, id: id) }
    }

    /// Collapse or expand every session and tab in the sidebar.
    func setAllNavigationGroups(expanded: Bool) {
        let pairs = tabs.map { (id: $0.id, sessionID: $0.sessionID) }
        navigationState = WorkspaceNavigationState.updating { $0.setAllExpanded(tabs: pairs, expanded: expanded) }
    }

    func setNavigationSortMode(_ mode: WorkspaceNavigationState.SortMode) {
        navigationState = WorkspaceNavigationState.updating { $0.sortMode = mode }
    }

    func setNavigatorSortMode(_ mode: WorkspaceNavigationState.NavigatorSort) {
        navigationState = WorkspaceNavigationState.updating { $0.navigatorSortMode = mode }
    }

    /// Focuses the navigator, inbox, banners and Dock badge on these
    /// workspaces; none ends focus. A shown workspace outside the set gives
    /// way to the first one in it.
    func setFocusedWorkspaces(_ ids: [UUID]) {
        var kept: [UUID] = []
        for id in ids where ownership.workspace(id) != nil && !kept.contains(id) { kept.append(id) }
        focusedWorkspaces = kept
        // Focus changes what the inbox lists; a held inbox follows it.
        if inboxHold != nil, let source = inboxHoldSource { holdAttentionInbox(true, inbox: source) }
        if let first = kept.first, !(selectedWorkspaceID.map(kept.contains) ?? false) { selectWorkspace(first) }
        RelayAttentionNotifier.shared.focusChanged()
    }

    /// Removes a pane's inbox row: reads its alerts and, while it waits,
    /// hides it until a new wait starts.
    func dismissAttention(_ paneID: UUID, inbox: AgentIntelligenceStore = .shared) {
        inbox.markPaneRead(paneID)
        if let pane = panes[paneID], pane.phase == .needsInput, let wait = pane.waitIdentity { dismissedAttention[paneID] = wait }
        else if let pane = panes[paneID], let status = Self.failedExitStatus(pane) { dismissedAttention[paneID] = Self.exitIdentity(status) }
        inboxHold?.removeAll { $0.paneID == paneID }
    }

    /// Freezes the inbox rows as shown now, or releases them.
    func holdAttentionInbox(_ hold: Bool, inbox: AgentIntelligenceStore = .shared) {
        inboxHold = hold ? attentionInbox(inbox: inbox) : nil
        inboxHoldSource = hold ? inbox : nil
    }

    func setAttentionInboxCollapsed(_ collapsed: Bool) {
        navigationState = WorkspaceNavigationState.updating { $0.isAttentionInboxCollapsed = collapsed }
    }

    func updateSplitRatio(_ splitID: UUID, ratio: Double, persist: Bool) {
        guard let tab = selectedTab else { return }
        tab.splitRatios[splitID] = min(max(ratio, 0.12), 0.88)
        if persist { persistWorkspace() }
    }

    func balanceActiveTabPanes() {
        selectedTab?.balanceSplits()
        persistWorkspace()
    }

    /// The save quit and window close run first: true only when the
    /// workspace is safely committed (or preserved) now.
    func saveForClose() -> Bool {
        persistWorkspaceNow()
        return workspaceSaveCanClose
    }

    func confirmEditorClose() -> Bool {
        guard saveForClose() else {
            let alert = NSAlert()
            alert.messageText = "Workspace changes are not safely saved"
            alert.informativeText = workspacePersistenceIssue ?? "Keep this window open until saving can complete."
            alert.addButton(withTitle: "Keep Window Open")
            alert.runModal()
            return false
        }
        for pane in panes.values where pane.contentKind == .editor {
            if !pane.editorRuntime.confirmDiscardChanges() { return false }
        }
        return true
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        paneLinkJanitorTask?.cancel()
        paneLinkJanitorTask = nil
        assistantStorage?.cancel()
        haikuAssistantStorage?.cancel()
        presentationFocusTask?.cancel()
        presentationFocusTask = nil
        persistenceTask?.cancel()
        persistenceTask = nil
        supervisorTask?.cancel()
        supervisorTask = nil
        supervisorAdvisoryTask?.cancel()
        supervisorAdvisoryTask = nil
        supervisorAdvisoryRequestKey = nil
        persistWorkspaceNow()
        panes.values.forEach { $0.stopRuntime() }
    }

    @discardableResult
    private func restoreWorkspace() -> Bool {
        let snapshot: WorkspaceSnapshot
        do {
            guard let saved = try sharedWorkspaceStore.restore(legacy:
                RelayStateProfile.defaults.data(forKey: workspaceKey)) else { return false }
            snapshot = saved
            workspaceBaseline = saved
            workspacePendingChanges = try sharedWorkspaceStore.pendingCount()
            guard !saved.tabs.isEmpty else { return false }
        } catch {
            workspacePersistenceIssue = "Saved workspace could not be read safely. Existing sessions have been left intact."
            workspaceSaveCanClose = false
            return false
        }

        for savedPane in snapshot.panes {
            let pane = PaneModel(
                id: savedPane.id,
                profile: savedPane.profile,
                contentKind: savedPane.contentKind ?? .terminal,
                requiresExistingWorker: (savedPane.contentKind ?? .terminal) == .terminal,
                remoteParentSessionID: savedPane.remoteParentSessionID,
                editorRequest: savedPane.editorRequest,
                customName: savedPane.customName,
                directory: savedPane.directory
            )
            savedPane.restoreBirthHierarchy(on: pane)
            storePane(pane)
        }
        let restoredTabs = snapshot.tabs.compactMap { saved -> TabModel? in
            let floatingPanes = saved.floatingPanes ?? []
            let allPaneIDs = saved.layout.paneIDs + floatingPanes.map(\.paneID)
            guard allPaneIDs.allSatisfy({ panes[$0] != nil }) else { return nil }
            let tab = TabModel(
                id: saved.id,
                sessionID: saved.sessionID ?? saved.id,
                name: saved.name,
                firstPane: saved.layout.paneIDs[0],
                floatingPanes: floatingPanes
            )
            tab.restoreLayout(legacy: saved.layout, visible: saved.visibleLayout, stacks: saved.stacks)
            tab.splitRatios = saved.splitRatios ?? [:]
            restoreRLayout(saved, in: tab)
            if tab.splitRatios.isEmpty { tab.balanceSplits() }
            return tab
        }
        guard !restoredTabs.isEmpty else {
            panes.removeAll()
            activityIndex.removeAll()
            return false
        }
        tabs = restoredTabs
        restoreRPresentationOwnership(snapshot.rPresentations ?? [])
        sidebarVisible = snapshot.sidebarVisible ?? false
        paneVisits = PaneVisitHistory(snapshot.paneVisits ?? [])
        let savedPanes = Dictionary(uniqueKeysWithValues: snapshot.panes.map { ($0.id, $0) })
        for tab in restoredTabs {
            for paneID in tab.allPaneIDs {
                if let pane = panes[paneID] {
                    savedPanes[paneID]?.restoreBirthHierarchy(on: pane, fallbackWorkspaceSessionID: tab.sessionID, fallbackTabID: tab.id)
                }
            }
        }
        sessionNames = snapshot.sessionNames ?? [:]
        restoreOwnership()
        let savedSelection = restoredTabs.contains(where: { $0.id == snapshot.selectedTabID })
            ? snapshot.selectedTabID : restoredTabs[0].id
        // A saved empty workspace is restored first and stays shown, with no
        // actionable selection; otherwise the saved selected tab is shown.
        // Only a snapshot saved with no selection had the empty view showing.
        if snapshot.selectedTabID == nil, let saved = navigationState.visibleWorkspace,
           ownership.workspace(saved) != nil, tabs(inWorkspace: saved).isEmpty {
            visibleWorkspaceID = saved
            rememberedTabID = savedSelection
        } else {
            selectedTabID = savedSelection
        }
        let validPaneIDs = Set(restoredTabs.flatMap(\.allPaneIDs))
        activePaneID = selectedTabID == nil ? nil : snapshot.activePaneID.flatMap { validPaneIDs.contains($0) ? $0 : nil }
            ?? restoredTabs.first(where: { $0.id == selectedTabID })?.layout.paneIDs.first
        restoreOrganization()
        return true
    }

    func restoreRPresentationOwnership(_ saved: [RWorkspacePresentation]) {
        savedRPresentations = saved.filter { item in
            guard tabs.contains(where: { $0.id == item.tabID }),
                  let console = panes[item.consoleID], console.contentKind == .terminal,
                  let editor = panes[item.editorID], editor.contentKind == .editor,
                  editor.remoteParentSessionID.flatMap(UUID.init(uuidString:)) == item.consoleID else { return false }
            floatingRPrimaryEditors[item.consoleID] = item.editorID
            if !tabs.contains(where: { $0.allPaneIDs.contains(item.editorID) }) { floatingRPaneTabs[item.editorID] = item.tabID }
            for extra in item.extras {
                if let id = extra.paneID, panes[id] != nil, !tabs.contains(where: { $0.allPaneIDs.contains(id) }) {
                    floatingRPaneTabs[id] = item.tabID
                }
            }
            return true
        }
    }

    func persistWorkspace() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.persistenceTask = nil
            self.persistWorkspaceNow()
        }
    }

    /// Restore presentation only. Never attach a saved R identity or execute setup.
    func restoreRLayout(_ saved: TabSnapshot, in tab: TabModel) {
        tab.executionContext = saved.executionContext
        guard let id = saved.rLayoutEditorID, tab.allPaneIDs.contains(id),
              let editor = panes[id], editor.contentKind == .editor,
              let parent = editor.remoteParentSessionID.flatMap(UUID.init(uuidString:)),
              tab.layout.paneIDs.contains(parent), let console = panes[parent],
              console.contentKind == .terminal,
              console.profile.connectionKey == editor.profile.connectionKey else { return }
        tab.rLayoutEditorID = id
        editor.editorRuntime.externalRResults = true
        editor.editorRuntime.showsRResults = saved.rResultsVisible ?? true
        // The saved layout also owns its visible results surface. Restoring
        // flags alone leaves chrome hidden after a native restart.
        if editor.editorRuntime.showsRResults {
            tab.chrome.reveal(.rWorkspace, initial: WorkspaceContextAnchor(
                paneID: parent, profile: console.profile, directory: console.directory))
        } else if tab.chrome.destination == .rWorkspace {
            tab.chrome.hide()
        }
    }

    func storePane(_ pane: PaneModel) {
        panes[pane.id] = pane
        if monitorsStoredPanes { pane.startAgentMonitoring(monitor: agentMonitorService) }
        RelaySurfacePublication.shared.restore(pane)
        if pane.contentKind == .editor {
            pane.editorRuntime.canAutomaticallyConnectR = { [weak self, weak pane] in
                guard let self, let pane,
                      let parent = pane.remoteParentSessionID.flatMap(UUID.init(uuidString:)),
                      let console = self.panes[parent],
                      console.profile.connectionKey == pane.profile.connectionKey,
                      console.connectionState == .connected,
                      self.selectedTabOwnsRPane(pane.id),
                      self.selectedTabOwnsRPane(parent) else { return false }
                return RWorkspaceIdlePrompt.accepts(console.runtime.sidePanelViewportText())
            }
            pane.editorRuntime.prepareRSetup = { [weak self, weak pane] in
                guard let self, let pane,
                      let parent = pane.remoteParentSessionID.flatMap(UUID.init(uuidString:)),
                      let console = self.panes[parent], console.contentKind == .terminal,
                      console.profile.connectionKey == pane.profile.connectionKey,
                      console.connectionState == .connected,
                      self.selectedTabOwnsRPane(pane.id),
                      self.selectedTabOwnsRPane(parent) else {
                    throw PluginError.invalid("The linked R console is unavailable")
                }
                guard RWorkspaceIdlePrompt.accepts(console.runtime.sidePanelViewportText()) else {
                    throw PluginError.invalid("Start radian in the linked console and wait for an empty r$> prompt before connecting R")
                }
                let revision = console.agentInputRevision
                return { [weak self, weak pane, weak console] code in
                    guard let self, let pane, let console,
                          self.panes[parent] === console, self.panes[pane.id] === pane,
                          console.agentInputRevision == revision, console.connectionState == .connected,
                          self.selectedTabOwnsRPane(pane.id),
                          self.selectedTabOwnsRPane(parent) else {
                        throw PluginError.invalid("Console changed during R setup; retry from the idle R prompt")
                    }
                    guard RWorkspaceIdlePrompt.accepts(console.runtime.sidePanelViewportText()) else {
                        throw PluginError.invalid("The linked console is no longer at an empty radian prompt; R setup was not sent")
                    }
                    guard console.runtime.sendSidePanelPrompt(code) else { throw PluginError.invalid("R console could not accept setup") }
                }
            }
            pane.editorRuntime.requestRunCode = { [weak self, weak pane] code in
                guard let self, let pane,
                      let parent = pane.remoteParentSessionID.flatMap(UUID.init(uuidString:)),
                      let console = self.panes[parent], console.contentKind == .terminal,
                      console.profile.connectionKey == pane.profile.connectionKey,
                      self.selectedTabOwnsRPane(pane.id),
                      self.selectedTabOwnsRPane(parent) else {
                    throw PluginError.invalid("The editor's original console is unavailable in this tab")
                }
                let proposal = AgentInputProposal(instance: self.editorInputRequests.instance, requestID: UUID(), text: code)
                _ = try self.editorInputRequests.propose(proposal, pane: console) { [weak self, weak pane, weak console] in
                    guard let self, let pane, let console else { return false }
                    return self.panes[parent] === console && self.panes[pane.id] === pane
                        && self.selectedTabOwnsRPane(pane.id)
                        && self.selectedTabOwnsRPane(parent)
                }
            }
            pane.editorRuntime.requestInterruptR = { [weak self, weak pane] in
                guard let self, let pane, let parent = pane.remoteParentSessionID.flatMap(UUID.init(uuidString:)),
                      let console = self.panes[parent], self.selectedTabOwnsRPane(parent) else { return false }
                _ = RAutomationController.shared.pause(parent)
                return console.runtime.sendSupervisorInterrupt()
            }
            pane.editorRuntime.requestUserRCode = { [weak self, weak pane] code in
                guard let self, let pane,
                      let parent = pane.remoteParentSessionID.flatMap(UUID.init(uuidString:)),
                      let session = pane.editorRuntime.rSession?.session_id,
                      self.selectedTabOwnsRPane(parent) else {
                    throw PluginError.invalid("The linked R console is unavailable")
                }
                let id = UUID()
                Task { @MainActor [weak self, weak pane] in
                    guard let self, let pane else { return }
                    do {
                        _ = try await RAutomationController.shared.execute(paneID: parent,
                            expected: session, id: id, code: code, workspace: self, direct: true,
                            source: RExecutionSource(kind: pane.editorRuntime.isDirty ? "unsaved_editor" : "editor",
                                path: pane.editorRuntime.currentPath, codeSHA256: RExecutionSource.digest(code)), human: true)
                    } catch { pane.editorRuntime.noteRExecutionError(error) }
                }
            }
        }
        pane.runtime.onPaneSelection = { [weak self, weak pane] origin in
            guard let self, let pane, self.panes[pane.id] === pane else { return }
            self.updateTerminalFocusOwnership()
            if self.paneLinkSelection.active { self.paneLinkSelection.toggle(pane.id) }
            else { self.selectPane(pane.id, origin: origin) }
        }
        pane.runtime.setKeyboardFocusEligible(pane.id == activePaneID && !paneLinkSelection.active && !networkVisible && !isQuickNavigatePresented && !isFleetBoardPresented)
        activityIndex.observe(pane)
        // Restore stores each saved pane here, so restored editors start too.
        if pane.contentKind == .editor { startEditorRuntime(pane) }
    }

    /// Only the model-selected terminal may run delayed AppKit focus recovery.
    /// Durable terminal views remain mounted while panes are split, floated,
    /// zoomed, and restored. Without explicit ownership, an older pane's
    /// bounded recovery task can steal first responder after the user clicks a
    /// different pane, making typing and Command-C/V appear intermittently
    /// broken in Codex and Claude.
    func updateTerminalFocusOwnership() {
        for (id, pane) in panes {
            pane.runtime.setKeyboardFocusEligible(id == activePaneID && !paneLinkSelection.active && !networkVisible && !isQuickNavigatePresented && !isFleetBoardPresented)
        }
        if paneLinkSelection.active { NSApp?.keyWindow?.makeFirstResponder(nil) }
    }

    private func restoreOrganization() {
        do {
            if let saved = try sharedWorkspaceStore.restoreOrganization() {
                organization.load(saved)
                organizationBaseline = saved
            } else {
                // First run with groups: one session group per existing
                // session, in navigator order. Written with the next save.
                organization.load(WorkspaceOrganizationController.migrated(
                    sessionIDs: navigationSessionIDs, name: navigationSessionName))
            }
        } catch {
            workspacePersistenceIssue = "Workspace groups could not be read safely. Tabs are shown by session."
        }
    }

    /// Takes the organization a migration step committed, as the baseline
    /// too, so the next save does not merge stale placements back.
    private func adoptOrganization(_ saved: WorkspaceOrganizationSnapshot) {
        organization.load(saved)
        organizationBaseline = saved
    }

    private func persistOrganization() {
        let local = organization.snapshot
        guard local != organizationBaseline,
              organizationBaseline != nil || local != .empty else { return }
        do {
            let merged = try sharedWorkspaceStore.commitOrganization(local, baseline: organizationBaseline)
            if merged != local { organization.load(merged) }
            organizationBaseline = merged
        } catch RelaySharedWorkspaceError.busy {
            if !didShutdown { persistWorkspace() }
        } catch RelaySharedWorkspaceError.conflictingEdit {
            // Another instance changed the same group or view: keep theirs.
            if let current = try? sharedWorkspaceStore.restoreOrganization() {
                organization.load(current)
                organizationBaseline = current
            }
            workspacePersistenceIssue = "Another Relay instance changed the same workspace group. Its version was kept."
        } catch {
            workspacePersistenceIssue = "Workspace groups could not be saved safely. Tabs and panes are unaffected."
        }
    }

    // MARK: Stacks and moves. These rearrange existing pane IDs only: they
    // never stop, restart, retarget, reconnect or rebind a pane, and never
    // reassign its remote birth hierarchy.

    private func tab(showing paneID: UUID) -> TabModel? { tabs.first { $0.layout.paneIDs.contains(paneID) } }

    private func tab(holding paneID: UUID) -> TabModel? { tabs.first { $0.allPaneIDs.contains(paneID) } }

    /// R consoles, their editors and panels move only as a bound set.
    private func isRPresentationBound(_ paneID: UUID) -> Bool {
        if floatingRPaneTabs[paneID] != nil || floatingRPrimaryEditors[paneID] != nil
            || floatingRPrimaryEditors.values.contains(paneID) { return true }
        if savedRPresentations.contains(where: { $0.paneIDs.contains(paneID) }) { return true }
        for tab in tabs {
            guard let editorID = tab.rLayoutEditorID else { continue }
            if editorID == paneID { return true }
            if panes[editorID]?.remoteParentSessionID.flatMap(UUID.init(uuidString:)) == paneID { return true }
        }
        return false
    }

    private func finishLayoutChange(in changed: [TabModel], active paneID: UUID, select tab: TabModel) {
        for item in changed {
            item.reconcileStacks()
            item.reconcileSplitRatios()
        }
        if let zoomedPaneID, !(tab.layout.paneIDs.contains(zoomedPaneID)) { self.zoomedPaneID = nil }
        if selectedTabID != tab.id { selectedTabID = tab.id }
        activePaneID = paneID
        persistWorkspace()
        panes[paneID]?.focus()
    }

    /// Gives an existing pane its own presentation tab. A single-pane tab is
    /// reused. Provider, process, host and remote birth IDs are left intact.
    @discardableResult
    func movePaneToNewTab(_ paneID: UUID, inWorkspace workspaceID: UUID? = nil) throws -> UUID {
        guard let pane = panes[paneID], let source = tab(holding: paneID) else {
            throw WorkspaceLayoutError.unknownPane
        }
        if let workspaceID, ownership.workspace(workspaceID) == nil { throw WorkspaceOwnershipError.unknownWorkspace }
        let owner = workspaceID ?? ownership.owner(of: source.id)
        if source.allPaneIDs.count == 1 {
            if let workspaceID { try moveTab(source.id, toWorkspace: workspaceID) }
            return source.id
        }
        if isRPresentationBound(paneID) { throw WorkspaceLayoutError.rPresentationBound }
        if source.floatingPanes.contains(where: { $0.paneID == paneID }) {
            source.floatingPanes.removeAll { $0.paneID == paneID }
        } else {
            guard source.detachTiledPane(paneID) else { throw WorkspaceLayoutError.unknownPane }
        }
        // The legacy session stays birth-derived for the compatibility
        // projection; ownership comes only from the requested destination.
        let birthSessionID = pane.remoteWorkspaceSessionID.flatMap(UUID.init(uuidString:)) ?? source.sessionID
        let destination = TabModel(sessionID: birthSessionID,
            name: pane.customName ?? source.name, firstPane: paneID)
        let insertion = tabs.firstIndex(where: { $0 === source }).map { $0 + 1 } ?? tabs.count
        tabs.insert(destination, at: insertion)
        if let owner { try? moveTab(destination.id, toWorkspace: owner) }
        finishLayoutChange(in: [source, destination], active: paneID, select: destination)
        return destination.id
    }

    // MARK: Workspace ownership. These edit records only: no pane is
    // constructed, stopped, restarted, recovered or attached, and no birth
    // identity (host, parent worker, provider session, incarnation) changes.

    private var tabReferences: [WorkspaceTabReference] {
        tabs.map { WorkspaceTabReference(id: $0.id, sessionID: $0.sessionID, title: $0.name,
                                         sessionName: navigationSessionName($0.sessionID), paneIDs: $0.allPaneIDs) }
    }

    /// A new tab goes to the scope its request was admitted with. Only a
    /// human UI action may use the visible workspace; any other tab without
    /// an admission joins its legacy session's workspace or the Inbox.
    private func reconcileOwnership() {
        guard ownershipReady else { return }
        var next = ownershipBaseline == nil && ownership.owners.isEmpty ? .bootstrap(tabs: tabReferences) : ownership
        let admittedTo: UUID? = switch tabAdmission {
        case .human: selectedWorkspaceID
        case .workspace(let id): id
        case .inbox: WorkspaceOwnershipSnapshot.inboxID
        case nil: nil
        }
        next.reconcile(tabs: tabReferences, admittedTo: admittedTo)
        if next != ownership { ownership = next }
    }

    /// Runs `body` with the scope new tabs are filed under. An outer scope
    /// (captured when an agent request was admitted) wins over inner defaults.
    func withTabAdmission<T>(_ admission: WorkspaceTabAdmission, _ body: () throws -> T) rethrows -> T {
        let previous = tabAdmission
        tabAdmission = previous ?? admission
        defer { tabAdmission = previous }
        return try body()
    }

    func tabAdmission(for origin: WorkspaceTabOrigin) -> WorkspaceTabAdmission {
        switch origin {
        case .human: .human
        case .agent(let sourcePane): tabAdmission(forSourcePane: sourcePane)
        }
    }

    /// The scope of a request from `paneID`, to capture at admission: the
    /// workspace owning that pane's tab, else the Inbox.
    func tabAdmission(forSourcePane paneID: UUID?) -> WorkspaceTabAdmission {
        paneID.flatMap { tabID(containingPane: $0) }.flatMap { ownership.owner(of: $0) }.map { .workspace($0) } ?? .inbox
    }

    private func restoreOwnership() {
        do {
            if let saved = try sharedWorkspaceStore.restoreOwnership() {
                ownershipReady = true
                adoptOwnership(saved)
                return
            }
        } catch {
            ownershipWritable = false
            workspacePersistenceIssue = "Workspace ownership could not be read safely. It was left unchanged."
        }
        ownershipReady = true
        ownership = .bootstrap(tabs: tabReferences)
    }

    /// Keeps other renderers' owners out of this renderer's baseline, so a
    /// later save never deletes records for tabs it does not show.
    private func adoptOwnership(_ loaded: WorkspaceOwnershipSnapshot) {
        let live = Set(tabs.map(\.id))
        var mine = loaded
        mine.owners.removeAll { !live.contains($0.id) }
        ownershipBaseline = mine
        mine.reconcile(tabs: tabReferences)
        if mine != ownership { ownership = mine }
    }

    func workspaceID(forTab tabID: UUID) -> UUID? { ownership.owner(of: tabID) }

    func tabs(inWorkspace workspaceID: UUID) -> [TabModel] {
        ownership.tabIDs(in: workspaceID).compactMap { id in tabs.first { $0.id == id } }
    }

    @discardableResult
    func createWorkspace(named name: String) -> UUID {
        let id = ownership.createWorkspace(name: name)
        persistWorkspace()
        return id
    }

    // MARK: Workspace navigator. Records only: hiding, renaming or reordering
    // a workspace never closes a tab or stops, restarts or attaches a pane.

    /// The workspace the window shows: its own persisted state, so it can be
    /// empty and never follows a tab rehomed elsewhere. Selecting a tab shows
    /// that tab's workspace.
    var selectedWorkspaceID: UUID? {
        if let visibleWorkspaceID, ownership.workspace(visibleWorkspaceID) != nil { return visibleWorkspaceID }
        return selectedTabID.flatMap { ownership.owner(of: $0) }
    }

    /// The selected tab when it belongs to the shown workspace; nil means the
    /// shown workspace is empty (or its tabs all moved away).
    var visibleTab: TabModel? {
        guard let tab = selectedTab, ownership.owner(of: tab.id) == selectedWorkspaceID else { return nil }
        return tab
    }

    private func showWorkspace(_ id: UUID) {
        guard navigationEffectsSuspended == 0, visibleWorkspaceID != id else { return }
        visibleWorkspaceID = id
        navigationState = WorkspaceNavigationState.updating { $0.visibleWorkspace = id }
    }

    /// After a rehome, the shown workspace stays put: select one of its
    /// remaining tabs, or leave it showing as empty. Never shows a hidden
    /// destination.
    private func keepVisibleWorkspace(_ visible: UUID?) {
        guard let visible, ownership.workspace(visible) != nil else { return }
        showWorkspace(visible)
        guard let selectedTabID, ownership.owner(of: selectedTabID) != visible else { return }
        if let next = navigationState.preferredTab(in: visible, available: railTabs(inWorkspace: visible).map(\.id)) {
            selectTab(next)
        } else {
            clearSelectionForEmptyWorkspace()
        }
    }

    /// Whether Relay is the frontmost app. Tests replace it.
    var relayIsFrontmost: () -> Bool = { NSApp?.isActive ?? false }

    /// A pane the user now sees, however it came to the front (click, tab,
    /// keyboard, reveal, an agent's selection), has its alerts read. Nothing
    /// is seen while Relay is in the background; returning to Relay reads the
    /// front pane then (`RelayAttentionNotifier`). A temporary selection is
    /// never shown, so it reads nothing. While a pane is revealed, only that
    /// pane is shown: the switch to its tab passes through the tab's
    /// remembered pane first.
    private func paneShown(_ id: UUID?) {
        guard navigationEffectsSuspended == 0, let id, relayIsFrontmost(),
              revealingPaneID.map({ $0 == id }) ?? true else { return }
        AgentIntelligenceStore.shared.markPaneRead(id)
    }

    /// Runs `body`, which may select tabs and panes temporarily (the R
    /// tool-window restore), with navigation effects suspended: nothing is
    /// remembered or written to the shared navigation preferences, and the
    /// shown workspace and empty view stay as they are. Afterwards only the
    /// in-memory selection, pane and zoom are put back, still suspended, and
    /// only if they changed. Synchronous, so never held across an await;
    /// `defer` unwinds it on a throw or an early return.
    func withoutNavigationEffects<T>(_ body: () throws -> T) rethrows -> T {
        let tab = selectedTabID, pane = activePaneID, zoom = zoomedPaneID
        navigationEffectsSuspended += 1
        defer {
            if selectedTabID != tab { selectedTabID = tab }
            if activePaneID != pane { activePaneID = pane }
            if zoomedPaneID != zoom { zoomedPaneID = zoom }
            navigationEffectsSuspended -= 1
        }
        return try body()
    }

    /// An empty workspace has no actionable selection: every command that
    /// targets the active tab or pane finds none and does nothing, so nothing
    /// out of view can be closed, split or sent to.
    private func clearSelectionForEmptyWorkspace() {
        if let selectedTabID { rememberedTabID = selectedTabID }
        selectedTabID = nil
        activePaneID = nil
        zoomedPaneID = nil
        persistWorkspace()
    }

    /// Pinned tabs first, as arranged, then the workspace's own order; in
    /// attention order only the unpinned part is sorted as `attentionOrdered` does.
    func railTabs(inWorkspace workspaceID: UUID, sort: WorkspaceNavigationState.NavigatorSort = .manual,
                  inbox: AgentIntelligenceStore = .shared, navigation: WorkspaceNavigationState? = nil) -> [TabModel] {
        let navigation = navigation ?? navigationState
        let ordered = tabs(inWorkspace: workspaceID)
        func arrange(_ part: [TabModel]) -> [TabModel] {
            guard sort == .attention else { return part }
            return heldOrder(attentionOrdered(part, panes: { self.paneIDs(inTab: $0.id) }, lastUse: { navigation.lastUse(.tab, id: $0.id) }, inbox: inbox))
        }
        return ordered.filter { pinnedTabIDs.contains($0.id) } + arrange(ordered.filter { !pinnedTabIDs.contains($0.id) })
    }

    /// Shows a workspace, even an empty one, and selects its last tab if any.
    /// `.user` for a navigator click, menu command or Go to pane choice: the
    /// pane shown is a Go to pane visit. Hiding or closing passes `.programmatic`.
    func selectWorkspace(_ id: UUID, origin: PaneSelectionOrigin = .programmatic) {
        guard ownership.workspace(id) != nil else { return }
        showWorkspace(id)
        guard let tabID = navigationState.preferredTab(in: id, available: railTabs(inWorkspace: id).map(\.id)) else {
            clearSelectionForEmptyWorkspace()
            return
        }
        selectTab(tabID, origin: origin)
    }

    /// Cycles the workspaces that are not hidden, in navigator order; while
    /// focusing, only the focused ones.
    func selectWorkspace(offset: Int) {
        let focused = focusedWorkspaceIDs()
        let ordered = ownership.orderedWorkspaces
            .filter { $0.hidden != true && (focused.isEmpty || focused.contains($0.id)) }.map(\.id)
        guard let next = WorkspaceNavigationState.adjacentTab(current: selectedWorkspaceID, ordered: ordered, offset: offset) else { return }
        selectWorkspace(next, origin: .user)
    }

    private func editWorkspace(_ id: UUID, _ change: (inout WorkspaceRecord) -> Void) {
        guard let index = ownership.workspaces.firstIndex(where: { $0.id == id }) else { return }
        var next = ownership
        change(&next.workspaces[index])
        guard next != ownership else { return }
        ownership = next
        persistWorkspace()
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editWorkspace(id) { $0.name = String(trimmed.prefix(120)) }
    }

    func setWorkspaceFavourite(_ id: UUID, _ favourite: Bool) { editWorkspace(id) { $0.favourite = favourite } }

    /// Hiding is not closing: tabs, panes, drafts and runtimes stay as they are.
    func setWorkspaceHidden(_ id: UUID, _ hidden: Bool) { editWorkspace(id) { $0.hidden = hidden ? true : nil } }

    func canMoveWorkspace(_ id: UUID, before target: UUID?) -> WorkspaceMoveRefusal? {
        guard let record = ownership.workspace(id), target.map({ ownership.workspace($0) != nil }) ?? true else { return .unknownWorkspace }
        return record.isInbox || id == target ? .samePlace : nil
    }

    /// Reorders the navigator; the Inbox keeps its place.
    func moveWorkspace(_ id: UUID, before target: UUID?) throws {
        if let refusal = canMoveWorkspace(id, before: target) { throw refusal }
        var ordered = ownership.orderedWorkspaces.filter { !$0.isInbox && $0.id != id }.map(\.id)
        ordered.insert(id, at: target.flatMap { ordered.firstIndex(of: $0) } ?? ordered.count)
        var next = ownership
        for (order, workspaceID) in ordered.enumerated() {
            if let index = next.workspaces.firstIndex(where: { $0.id == workspaceID }) { next.workspaces[index].order = Double(order) }
        }
        guard next != ownership else { return }
        ownership = next
        persistWorkspace()
    }

    /// Hover validation for dropping a tab on a workspace; nil means allowed.
    func canMoveTab(_ tabID: UUID, toWorkspace workspaceID: UUID) -> WorkspaceMoveRefusal? {
        guard tabs.contains(where: { $0.id == tabID }), ownership.owner(of: tabID) != nil else { return .unknownTab }
        return ownership.workspace(workspaceID) == nil ? .unknownWorkspace : nil
    }

    /// Atomic: validated first, then one ownership assignment. Panes, layout,
    /// selection and runtimes are untouched.
    func moveTab(_ tabID: UUID, toWorkspace workspaceID: UUID, at index: Int? = nil) throws {
        if let refusal = canMoveTab(tabID, toWorkspace: workspaceID) { throw refusal }
        var next = ownership
        try next.moveTab(tabID, to: workspaceID, at: index)
        guard next != ownership else { return }
        let visible = selectedWorkspaceID
        ownership = next
        keepVisibleWorkspace(visible)
        persistWorkspace()
    }

    /// Hover validation for dropping a pane; nil means `movePane(_:to:)` will succeed.
    func canMovePane(_ paneID: UUID, to destination: WorkspacePaneDestination) -> WorkspaceMoveRefusal? {
        guard panes[paneID] != nil, let source = tab(holding: paneID) else { return .unknownPane }
        if source.floatingPanes.contains(where: { $0.paneID == paneID }) { return .floatingPane }
        if isRPresentationBound(paneID) { return .rPresentationBound }
        switch destination {
        case .split(let tabID, let beside, _):
            guard let target = tabs.first(where: { $0.id == tabID }) else { return .unknownTab }
            if let beside, beside == paneID || !target.layout.paneIDs.contains(beside) { return .unknownTarget }
            if source === target { return beside == nil ? .samePlace : nil }
            return source.allPaneIDs.count == 1 ? .lastPaneInTab : nil
        case .newTab(let workspaceID, _):
            return ownership.workspace(workspaceID) == nil ? .unknownWorkspace : nil
        }
    }

    /// The one pane move for drag and drop, agents and migration: the same
    /// PaneModel and runtime are re-homed as a split leaf in any tab of any
    /// workspace, or as a new tab. Legacy sessions may differ; birth identity
    /// (host, parent worker, provider session, incarnation) never changes.
    /// Without `reveal` nothing is selected or focused, so a hidden
    /// destination is never mounted, attached or resized. Returns the tab.
    @discardableResult
    func movePane(_ paneID: UUID, to destination: WorkspacePaneDestination, reveal: Bool = false) throws -> UUID {
        if let refusal = canMovePane(paneID, to: destination) { throw refusal }
        guard let pane = panes[paneID], let source = tab(holding: paneID) else { throw WorkspaceMoveRefusal.unknownPane }
        let target: TabModel
        switch destination {
        case .split(let tabID, let beside, let placement):
            guard let destinationTab = tabs.first(where: { $0.id == tabID }) else { throw WorkspaceMoveRefusal.unknownTab }
            target = destinationTab
            let anchor = beside ?? target.layout.paneIDs.last!
            guard source.detachTiledPane(paneID), target.layout.paneIDs.contains(anchor) else { throw WorkspaceMoveRefusal.unknownTarget }
            let effective = placement == .center ? .trailing : placement
            target.layout = target.layout.splitting(anchor, axis: effective == .top || effective == .bottom ? .vertical : .horizontal,
                                                    with: paneID, newPaneFirst: effective == .leading || effective == .top)
        case .newTab(let workspaceID, let index):
            if source.allPaneIDs.count == 1 {
                try moveTab(source.id, toWorkspace: workspaceID, at: index)
                target = source
            } else {
                guard source.detachTiledPane(paneID) else { throw WorkspaceMoveRefusal.unknownPane }
                target = TabModel(sessionID: pane.remoteWorkspaceSessionID.flatMap(UUID.init(uuidString:)) ?? source.sessionID,
                                  name: pane.customName ?? source.name, firstPane: paneID)
                tabs.insert(target, at: tabs.firstIndex(where: { $0 === source }).map { $0 + 1 } ?? tabs.count)
                var next = ownership
                try next.moveTab(target.id, to: workspaceID, at: index)
                ownership = next
            }
        }
        if reveal {
            finishLayoutChange(in: source === target ? [target] : [source, target], active: paneID, select: target)
            return target.id
        }
        for item in source === target ? [target] : [source, target] {
            item.reconcileStacks()
            item.reconcileSplitRatios()
        }
        if zoomedPaneID == paneID, selectedTabID != target.id { zoomedPaneID = nil }
        if activePaneID == paneID, selectedTabID != target.id { activePaneID = selectedTab?.layout.paneIDs.first }
        persistWorkspace()
        return target.id
    }

    /// Previews a reviewed plan file (overrides, pane moves, empty groups)
    /// in-app. Nothing is applied here.
    @discardableResult
    func previewWorkspaceMigration(plan data: Data, name: String? = nil) throws -> WorkspaceMigrationPreview {
        let (preview, plan) = try planPreview(data)
        migrationPreview = preview
        migrationPlan = (plan, name, false, WorkspaceMigrationPlan.digest(data))
        return preview
    }

    private func planPreview(_ data: Data) throws -> (WorkspaceMigrationPreview, WorkspaceMigrationPlan) {
        let parsed = try WorkspaceMigrationPlan.parse(data)
        let plan = try JSONDecoder().decode(WorkspaceMigrationPlan.self, from: data)
        return (try previewWorkspaceMigration(overrides: parsed.overrides, paneMoves: parsed.paneMoves,
                                              keepEmptyGroups: parsed.keepEmptyGroups, scope: parsed.scope), plan)
    }

    /// An agent's plan: validated as the sheet would, kept in the inbox and
    /// loaded as the preview for the user to review. It never applies or
    /// undoes; a different open preview is replaced only on request.
    @discardableResult
    func stageWorkspaceMigrationPlan(_ data: Data, name: String?, replace: Bool,
                                     inbox: WorkspaceMigrationPlanInbox = .shared) throws -> (url: URL, preview: WorkspaceMigrationPreview) {
        guard data.count <= WorkspaceMigrationPlanInbox.maximumBytes else { throw WorkspaceMigrationPlanInboxError.tooLarge }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw WorkspaceMigrationPlanInboxError.notAnObject }
        let plan = try JSONDecoder().decode(WorkspaceMigrationPlan.self, from: data)
        if migrationPreview != nil, migrationPlan?.plan != plan, !replace { throw WorkspaceMigrationPlanInboxError.previewOpen }
        let (preview, _) = try planPreview(data)
        let url = try inbox.store(data, name: name)
        migrationPreview = preview
        migrationPlan = (plan, url.lastPathComponent, true, WorkspaceMigrationPlan.digest(data))
        sidebarVisible = true
        isMigrationPresented = true
        return (url, preview)
    }

    func presentWorkspaceMigration() {
        sidebarVisible = true
        isMigrationPresented = true
    }

    func dismissMigrationPreview() {
        migrationPreview = nil
        migrationPlan = nil
    }

    /// Writes pending changes, then previews what is saved, so the preview's
    /// checksums are the ones a later apply re-checks under the lock.
    func previewWorkspaceMigration(overrides: [UUID: String] = [:], paneMoves: [UUID: UUID] = [:],
                                   keepEmptyGroups: Bool = true, scope: WorkspaceMigrationScope? = nil) throws -> WorkspaceMigrationPreview {
        flushWorkspace()
        return try sharedWorkspaceStore.previewWorkspaceMigration(overrides: overrides, paneMoves: paneMoves,
                                                                  keepEmptyGroups: keepEmptyGroups, scope: scope)
    }

    /// One transaction: the approved pane moves run here first, in memory,
    /// as hidden reparents; then the store, under one lock, re-checks the
    /// preview and writes ownership (moves `pending`), the moved layouts and
    /// ownership (moves `done`). If the store refuses, the moves are undone
    /// in memory, so nothing is half-applied.
    func applyWorkspaceMigration(_ preview: WorkspaceMigrationPreview, caller: String? = nil) throws {
        for move in preview.paneMoves {
            guard tab(holding: move.paneID)?.id == move.fromTabID else { throw WorkspaceMoveRefusal.unknownPane }
            if let refusal = canMovePane(move.paneID, to: .split(tabID: move.toTabID, beside: nil, placement: .trailing)) { throw refusal }
        }
        flushWorkspace()
        let baseline = workspaceBaseline
        var performed: [WorkspaceMigrationPaneMove] = [], submitted: WorkspaceSnapshot?
        do {
            for move in preview.paneMoves {
                guard let source = tabs.first(where: { $0.id == move.fromTabID }) else { throw WorkspaceMoveRefusal.unknownTab }
                let layout = source.layout, ratios = source.splitRatios, stacked = !source.stacks.isEmpty
                try movePane(move.paneID, to: .split(tabID: move.toTabID, beside: nil, placement: .trailing))
                var done = move
                if !stacked {
                    done.sourceLayout = layout
                    done.sourceRatios = ratios.map { WorkspaceSplitRatio(id: $0.key, ratio: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
                    done.movedSourceLayout = source.layout
                }
                performed.append(done)
            }
            let local = currentWorkspaceSnapshot()
            submitted = local
            let result = try sharedWorkspaceStore.applyWorkspaceMigration(preview, paneMoves: performed,
                workspace: performed.isEmpty ? nil : local, baseline: baseline, caller: caller)
            if result.workspace != nil { workspaceBaseline = local }
            adoptOwnership(result.ownership)
            adoptOrganization(result.organization)
        } catch {
            settleMigration(preview.id, moves: performed, applying: true, submitted: submitted)
            throw error
        }
        if migrationPreview?.id == preview.id { dismissMigrationPreview() }
        flushWorkspace()
    }

    /// Moves panes back first, in memory (exactly, while their source tab is
    /// otherwise unchanged), then one locked store transaction marks them
    /// `reverting`, writes the layouts and reverses the ownership edits. A
    /// pane moved again since the migration stays where it is.
    func undoWorkspaceMigration(_ id: UUID, caller: String? = nil) throws {
        guard let record = ownership.migrations.first(where: { $0.id == id }) else { throw WorkspaceOwnershipError.unknownMigration }
        guard record.undoneAt == nil else { throw WorkspaceOwnershipError.alreadyUndone }
        flushWorkspace()
        let baseline = workspaceBaseline
        var returned: [WorkspaceMigrationPaneMove] = [], submitted: WorkspaceSnapshot?
        do {
            for move in record.paneMoves.reversed() where move.state == .done {
                if try returnPane(move) { returned.append(move) }
            }
            let local = currentWorkspaceSnapshot()
            submitted = local
            let result = try sharedWorkspaceStore.undoWorkspaceMigration(id, workspace: local, baseline: baseline, caller: caller)
            workspaceBaseline = local
            adoptOwnership(result.ownership)
            adoptOrganization(result.organization)
        } catch {
            settleMigration(id, moves: returned, applying: false, submitted: submitted)
            throw error
        }
        flushWorkspace()
    }

    /// After a failed migration step, makes this renderer match exactly what
    /// the store committed, without replaying any move: every tab a move
    /// touched takes its saved layout (pane order, split tree, ratios,
    /// stacks and floats), keeping the same pane objects, and the saved
    /// ownership is adopted when the migration record was committed. If the
    /// saved state cannot be read or would drop a pane, saves are held until
    /// Relay restarts.
    private func settleMigration(_ id: UUID, moves: [WorkspaceMigrationPaneMove], applying: Bool, submitted: WorkspaceSnapshot?) {
        defer {
            persistenceTask?.cancel()
            persistenceTask = nil
        }
        // The sidebar takes the saved placements: both layers or neither.
        if let saved = try? sharedWorkspaceStore.restoreOrganization() { adoptOrganization(saved) }
        func hold(_ reason: String) {
            migrationUnsettled = true
            workspaceSaveCanClose = false
            workspacePersistenceIssue = reason + " Changes are held until Relay restarts."
        }
        let saved: WorkspaceOwnershipSnapshot?, disk: WorkspaceSnapshot
        do {
            saved = try sharedWorkspaceStore.restoreOwnership()
            guard let read = try sharedWorkspaceStore.restore(legacy: nil) else { throw RelaySharedWorkspaceError.unavailable }
            disk = read
        } catch {
            hold("A workspace migration step failed and the saved workspace could not be read back.")
            return
        }
        let affected = Set(moves.flatMap { [$0.fromTabID, $0.toTabID] })
        let savedTabs = disk.tabs.filter { affected.contains($0.id) }
        let liveTabs = tabs.filter { affected.contains($0.id) }
        let savedPanes = savedTabs.flatMap { $0.layout.paneIDs + ($0.floatingPanes ?? []).map(\.paneID) }
        guard savedTabs.count == liveTabs.count, Set(savedPanes) == Set(liveTabs.flatMap(\.allPaneIDs)),
              savedPanes.count == Set(savedPanes).count else {
            hold("A workspace migration step failed and the saved layout no longer matches this window.")
            return
        }
        for saved in savedTabs {
            guard let tab = liveTabs.first(where: { $0.id == saved.id }) else { continue }
            tab.floatingPanes = saved.floatingPanes ?? []
            tab.restoreLayout(legacy: saved.layout, visible: saved.visibleLayout, stacks: saved.stacks)
            tab.splitRatios = saved.splitRatios ?? [:]
            tab.reconcileSplitRatios()
        }
        if let zoomedPaneID, selectedTab?.layout.paneIDs.contains(zoomedPaneID) != true { self.zoomedPaneID = nil }
        if let activePaneID, selectedTab?.allPaneIDs.contains(activePaneID) != true { self.activePaneID = selectedTab?.layout.paneIDs.first }
        // The layouts landed only if the store wrote this renderer's submission.
        if let submitted, savedTabs.allSatisfy({ saved in submitted.tabs.first { $0.id == saved.id }?.layout == saved.layout }) {
            workspaceBaseline = submitted
        }
        guard let saved, saved.migrations.contains(where: { $0.id == id }) else { return }
        adoptOwnership(saved)
        workspacePersistenceIssue = "A workspace migration step failed after part of it was saved. This window now matches the saved workspace."
    }

    /// Returns a migrated pane to its source tab, restoring that tab's exact
    /// layout while it is otherwise unchanged. False if it no longer applies.
    private func returnPane(_ move: WorkspaceMigrationPaneMove) throws -> Bool {
        guard let source = tabs.first(where: { $0.id == move.fromTabID }), tab(holding: move.paneID)?.id == move.toTabID,
              canMovePane(move.paneID, to: .split(tabID: move.fromTabID, beside: nil, placement: .trailing)) == nil else { return false }
        let exact = move.movedSourceLayout != nil && source.layout == move.movedSourceLayout && source.stacks.isEmpty
        try movePane(move.paneID, to: .split(tabID: move.fromTabID, beside: nil, placement: .trailing))
        if exact, let layout = move.sourceLayout, Set(layout.paneIDs) == Set(source.layout.paneIDs) {
            source.layout = layout
            source.splitRatios = Dictionary(uniqueKeysWithValues: (move.sourceRatios ?? []).map { ($0.id, $0.ratio) })
            source.reconcileSplitRatios()
        }
        return true
    }

    private func flushWorkspace() {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistWorkspaceNow()
    }

    /// Stacks `paneID` onto the slot showing `targetID`; `paneID` becomes the
    /// shown member. The pane may come from the same tab or a same-session tab.
    func stackPane(_ paneID: UUID, onto targetID: UUID) throws {
        guard paneID != targetID else { throw WorkspaceLayoutError.samePane }
        guard panes[paneID] != nil, let source = tab(holding: paneID) else { throw WorkspaceLayoutError.unknownPane }
        guard panes[targetID] != nil, let target = tab(showing: targetID) else { throw WorkspaceLayoutError.unknownPane }
        guard source.sessionID == target.sessionID else { throw WorkspaceLayoutError.differentSession }
        if source.floatingPanes.contains(where: { $0.paneID == paneID })
            || target.floatingPanes.contains(where: { $0.paneID == targetID }) { throw WorkspaceLayoutError.floatingPane }
        if target.stack(containing: targetID)?.members.contains(paneID) == true { throw WorkspaceLayoutError.alreadyStacked }
        if isRPresentationBound(paneID) || isRPresentationBound(targetID) { throw WorkspaceLayoutError.rPresentationBound }
        if source !== target && source.allPaneIDs.count == 1 { throw WorkspaceLayoutError.lastPaneInTab }
        guard source.detachTiledPane(paneID), target.layout.paneIDs.contains(targetID) else { throw WorkspaceLayoutError.unknownPane }
        if let index = target.stacks.firstIndex(where: { $0.members.contains(targetID) }) {
            target.layout = target.layout.swapping(target.stacks[index].selected, paneID)
            target.stacks[index].members.append(paneID)
            target.stacks[index].selected = paneID
        } else {
            target.layout = target.layout.swapping(targetID, paneID)
            target.stacks.append(PaneStack(id: UUID(), members: [targetID, paneID], selected: paneID))
        }
        finishLayoutChange(in: [source, target], active: paneID, select: target)
    }

    /// Puts `paneID` into the stack of the slot showing `targetID` (making
    /// one if needed) as its shown member. Never adds a split leaf.
    private func joinStack(_ paneID: UUID, onto targetID: UUID, in target: TabModel) -> PaneStack {
        if let index = target.stacks.firstIndex(where: { $0.members.contains(targetID) }) {
            target.layout = target.layout.swapping(target.stacks[index].selected, paneID)
            target.stacks[index].members.append(paneID)
            target.stacks[index].selected = paneID
            return target.stacks[index]
        }
        target.layout = target.layout.swapping(targetID, paneID)
        let stack = PaneStack(id: UUID(), members: [targetID, paneID], selected: paneID)
        target.stacks.append(stack)
        return stack
    }

    /// The slot an MCP stack request may target: a tiled, shown, unbound
    /// pane in a tab that is not closing.
    private func stackTarget(_ targetID: UUID) throws -> TabModel {
        guard panes[targetID] != nil, let target = tab(holding: targetID),
              target.layout.paneIDs.contains(targetID) || target.stack(containing: targetID) != nil else {
            throw WorkspaceLayoutError.unknownPane
        }
        if target.floatingPanes.contains(where: { $0.paneID == targetID }) { throw WorkspaceLayoutError.floatingPane }
        if isRPresentationBound(targetID) { throw WorkspaceLayoutError.rPresentationBound }
        guard !tabsAwaitingCloseConfirmation.contains(target.id) else { throw WorkspaceMoveRefusal.tabClosing }
        return target
    }

    /// Stacks an existing pane under `targetID` in the target's PaneStack,
    /// from any tab or legacy session; it never lands as a split. When the
    /// pane was the last one in its tab, that tab is removed without
    /// stopping anything: the same PaneModel and runtime move. Every check
    /// runs before the first change, so a refusal changes nothing.
    @discardableResult
    func stackPaneAnywhere(_ paneID: UUID, onto targetID: UUID) throws -> (stack: PaneStack, tabID: UUID, removedTabID: UUID?) {
        guard paneID != targetID else { throw WorkspaceLayoutError.samePane }
        guard panes[paneID] != nil, let source = tab(holding: paneID) else { throw WorkspaceLayoutError.unknownPane }
        let target = try stackTarget(targetID)
        if source.floatingPanes.contains(where: { $0.paneID == paneID }) { throw WorkspaceLayoutError.floatingPane }
        if target.stack(containing: targetID)?.members.contains(paneID) == true { throw WorkspaceLayoutError.alreadyStacked }
        if isRPresentationBound(paneID) { throw WorkspaceLayoutError.rPresentationBound }
        guard !tabsAwaitingCloseConfirmation.contains(source.id) else { throw WorkspaceMoveRefusal.tabClosing }
        let emptiesSource = source !== target && source.allPaneIDs == [paneID]
        if !emptiesSource {
            guard source.detachTiledPane(paneID),
                  target.layout.paneIDs.contains(targetID) || target.stack(containing: targetID) != nil else {
                throw WorkspaceLayoutError.unknownPane
            }
        }
        let stack = joinStack(paneID, onto: targetID, in: target)
        var removed: UUID?
        if emptiesSource {
            // Remove the emptied tab object only; closeTab would stop the runtime.
            removed = source.id
            tabs.removeAll { $0 === source }
            organization.pruneClosedTabs()
            if pinnedTabIDs.remove(source.id) != nil { WorkspacePinStore.save(pinnedTabIDs, kind: .tab) }
        }
        finishLayoutChange(in: emptiesSource || source === target ? [target] : [source, target], active: paneID, select: target)
        return (stack, target.id, removed)
    }

    /// Opens a new terminal pane directly as a member of the stack showing
    /// `targetID`, on `profile` (This Mac or an exact SSH host). Like a new
    /// tab, a Relay SSH pane on the target's host is born under the target.
    @discardableResult
    func newStackedPane(onto targetID: UUID, profile: ConnectionProfile) throws -> (paneID: UUID, stack: PaneStack, tabID: UUID) {
        let target = try stackTarget(targetID)
        guard let anchor = panes[targetID] else { throw WorkspaceLayoutError.unknownPane }
        let parentSessionID = profile.kind == .ssh && profile.backend == .relay &&
            anchor.profile.kind == .ssh && anchor.profile.connectionKey == profile.connectionKey
            ? (anchor.contentKind == .terminal ? anchor.id.uuidString.lowercased() : anchor.remoteParentSessionID)
            : nil
        let pane = PaneModel(profile: profile, remoteParentSessionID: parentSessionID, startDirectory: nil)
        pane.assignRemoteHierarchy(workspaceSessionID: target.sessionID, tabID: target.id)
        storePane(pane)
        let stack = joinStack(pane.id, onto: targetID, in: target)
        if profile.kind == .ssh { profileStore.markUsed(profile) }
        finishLayoutChange(in: [target], active: pane.id, select: target)
        return (pane.id, stack, target.id)
    }

    /// Shows a stack member in its stack's slot. No-op for unstacked panes.
    func selectStackMember(_ paneID: UUID) {
        guard let tab = tabs.first(where: { $0.stack(containing: paneID) != nil }),
              let index = tab.stacks.firstIndex(where: { $0.members.contains(paneID) }) else { return }
        let previous = tab.stacks[index].selected
        guard previous != paneID else { return }
        tab.layout = tab.layout.swapping(previous, paneID)
        tab.stacks[index].selected = paneID
        if zoomedPaneID == previous { zoomedPaneID = paneID }
        if selectedTabID == tab.id, activePaneID == previous || activePaneID == nil { activePaneID = paneID }
        persistWorkspace()
    }

    func selectAdjacentStackMember(offset: Int) {
        guard let active = activePaneID, let stack = selectedTab?.stack(containing: active),
              let current = stack.members.firstIndex(of: stack.selected) else { return }
        let next = stack.members[((current + offset) % stack.members.count + stack.members.count) % stack.members.count]
        selectStackMember(next)
        selectPane(next, origin: .user)
    }

    /// Takes a pane out of its stack and tiles it beside the stack's slot.
    func unstackPane(_ paneID: UUID, placement: PaneDropPlacement = .trailing) throws {
        guard let tab = tabs.first(where: { $0.stack(containing: paneID) != nil }) else { throw WorkspaceLayoutError.notStacked }
        let members = tab.stack(containing: paneID)!.members
        guard tab.detachTiledPane(paneID),
              let anchor = members.first(where: { $0 != paneID && tab.layout.paneIDs.contains($0) }) else {
            throw WorkspaceLayoutError.notStacked
        }
        let effective = placement == .center ? .trailing : placement
        tab.layout = tab.layout.splitting(anchor, axis: effective == .top || effective == .bottom ? .vertical : .horizontal,
                                          with: paneID, newPaneFirst: effective == .leading || effective == .top)
        finishLayoutChange(in: [tab], active: paneID, select: tab)
    }

    func moveStackMember(_ paneID: UUID, toIndex index: Int) {
        guard let tab = tabs.first(where: { $0.stack(containing: paneID) != nil }),
              let position = tab.stacks.firstIndex(where: { $0.members.contains(paneID) }) else { return }
        var members = tab.stacks[position].members.filter { $0 != paneID }
        members.insert(paneID, at: max(0, min(index, members.count)))
        guard members != tab.stacks[position].members else { return }
        tab.stacks[position].members = members
        persistWorkspace()
    }

    /// Moves a pane to another tab of the same session, tiled beside
    /// `targetID` (or the tab's last pane). Its remote birth hierarchy is kept.
    func movePane(_ paneID: UUID, toTab tabID: UUID, beside targetID: UUID?, placement: PaneDropPlacement) throws {
        guard panes[paneID] != nil, let source = tab(holding: paneID) else { throw WorkspaceLayoutError.unknownPane }
        guard let target = tabs.first(where: { $0.id == tabID }) else { throw WorkspaceLayoutError.unknownTab }
        guard source !== target else {
            guard let targetID else { return }
            movePane(paneID, to: targetID, placement: placement)
            return
        }
        guard source.sessionID == target.sessionID else { throw WorkspaceLayoutError.differentSession }
        if source.floatingPanes.contains(where: { $0.paneID == paneID }) { throw WorkspaceLayoutError.floatingPane }
        if isRPresentationBound(paneID) { throw WorkspaceLayoutError.rPresentationBound }
        if source.allPaneIDs.count == 1 { throw WorkspaceLayoutError.lastPaneInTab }
        let anchor = targetID ?? target.layout.paneIDs.last!
        guard target.layout.paneIDs.contains(anchor) else { throw WorkspaceLayoutError.unknownPane }
        guard source.detachTiledPane(paneID) else { throw WorkspaceLayoutError.unknownPane }
        let effective = placement == .center ? .trailing : placement
        target.layout = target.layout.splitting(anchor, axis: effective == .top || effective == .bottom ? .vertical : .horizontal,
                                                with: paneID, newPaneFirst: effective == .leading || effective == .top)
        finishLayoutChange(in: [source, target], active: paneID, select: target)
    }

    private func tabSnapshot(_ tab: TabModel) -> TabSnapshot {
        tab.reconcileStacks()
        var snapshot = TabSnapshot(
            id: tab.id,
            sessionID: tab.sessionID,
            name: tab.name,
            layout: tab.legacyLayoutProjection,
            floatingPanes: tab.floatingPanes,
            splitRatios: tab.splitRatios,
            executionContext: tab.executionContext,
            rLayoutEditorID: tab.rLayoutEditorID,
            rResultsVisible: tab.rLayoutEditorID.flatMap { panes[$0]?.editorRuntime.showsRResults }
        )
        if !tab.stacks.isEmpty {
            snapshot.visibleLayout = tab.layout
            snapshot.stacks = tab.stacks
        }
        return snapshot
    }

    private func currentWorkspaceSnapshot() -> WorkspaceSnapshot {
        let rPresentations = captureRPresentations?() ?? savedRPresentations
        let usedPaneIDs = Set(tabs.flatMap(\.allPaneIDs) + rPresentations.flatMap(\.paneIDs))
        return WorkspaceSnapshot(
            tabs: tabs.map(tabSnapshot),
            panes: usedPaneIDs.compactMap { id in
                panes[id].map { PaneSnapshot(pane: $0) }
            },
            sessionNames: sessionNames,
            selectedTabID: selectedTabID,
            activePaneID: activePaneID,
            rPresentations: rPresentations,
            sidebarVisible: savedSidebarVisible,
            paneVisits: paneVisits.visits.filter { usedPaneIDs.contains($0.paneID) }
        )
    }

    /// Pane IDs this profile still holds anywhere: this window's panes and
    /// layouts plus every instance's committed shared snapshot. Nil, so the
    /// janitor does nothing, whenever that cannot be stated authoritatively:
    /// before ownership/restore settles, after a persistence issue, in safe
    /// mode, during a migration, or while any instance has pending changes.
    /// Offline, reconnecting and lazy panes are still workspace panes.
    struct PaneLinkJanitorEvidence {
        /// Panes held anywhere: this window plus every instance's commit.
        let known: Set<UUID>
        /// Panes with a closed-pane archive: positive evidence of closure.
        let closed: Set<UUID>
    }

    /// Runs `body` inside the shared-workspace fence (see
    /// `RelaySharedWorkspaceStore.withCommittedWorkspace`), so no instance can
    /// commit, preserve pending changes or restore while it decides and
    /// retires. Returns nil without running `body` when the workspace cannot
    /// be stated authoritatively, or when another instance holds the lock.
    func withPaneLinkJanitorFence<T>(_ body: (PaneLinkJanitorEvidence) throws -> T) -> T? {
        guard ownershipReady, workspacePersistenceIssue == nil, !migrationUnsettled,
              !RelayLaunchMode.isSafeMode else { return nil }
        return try? sharedWorkspaceStore.withCommittedWorkspace { committed, pending -> T? in
            guard pending == 0, let committed else { return nil }
            let known = Set(panes.keys).union(tabs.flatMap(\.allPaneIDs)).union(committed.panes.map(\.id))
            // The profile-shared archive is written before a close is
            // committed and removed before a reopen is.
            let closed = Set(recoveryStore.loadClosedPanes().map(\.pane.id))
            return try body(PaneLinkJanitorEvidence(known: known, closed: closed))
        } ?? nil
    }

    var paneLinkJanitorKnownPaneIDs: Set<UUID>? { withPaneLinkJanitorFence { $0.known } }

    /// Automatic janitor: once shortly after launch, then every 30 minutes.
    /// The same idempotent sweep also runs at link admission and after a
    /// save in which panes left the workspace.
    private func startPaneLinkJanitor() {
        paneLinkJanitorTask?.cancel()
        paneLinkJanitorTask = Task { @MainActor [weak self] in
            var delay: Duration = .seconds(10)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.paneLinkJanitor?.retireObsoleteLinks(workspace: self, reason: "periodic")
                delay = .seconds(1800)
            }
        }
    }

    /// Lifecycle trigger. Runs after the shared commit, so a closed or deleted
    /// pane is already gone from the authoritative snapshot.
    private func sweepPaneLinksIfPanesLeft(_ merged: WorkspaceSnapshot) {
        let current = Set(merged.panes.map(\.id))
        defer { paneLinkJanitorSavedPaneIDs = current }
        guard !paneLinkJanitorSavedPaneIDs.isEmpty, !paneLinkJanitorSavedPaneIDs.isSubset(of: current) else { return }
        paneLinkJanitor?.retireObsoleteLinks(workspace: self, reason: "pane_removed")
    }

    private func persistWorkspaceNow() {
        guard !migrationUnsettled else {
            workspaceSaveCanClose = false
            return
        }
        let snapshot = currentWorkspaceSnapshot()
        let usedPaneIDs = Set(tabs.flatMap(\.allPaneIDs) + (snapshot.rPresentations ?? []).flatMap(\.paneIDs))
        reportSilentPaneRemovals(placed: usedPaneIDs)
        paneVisits.prune(keeping: usedPaneIDs)
        let livePins = pinnedPaneIDs.intersection(usedPaneIDs)
        if livePins != pinnedPaneIDs {
            pinnedPaneIDs = livePins
            WorkspacePinStore.save(livePins, kind: .pane)
        }
        do {
            let submittedOwnership = ownershipReady && ownershipWritable ? ownership : nil
            let result = try sharedWorkspaceStore.commit(snapshot, baseline: workspaceBaseline,
                ownership: submittedOwnership, ownershipBaseline: ownershipBaseline)
            let merged = result.workspace
            workspaceSaveCount += 1
            // Another writer's placements reach this renderer on every save,
            // not only on a conflict, so captured admissions are never stale.
            if let owned = result.ownership { adoptOwnership(owned) }
            recoveryStore.observeWorkspace(snapshot)
            // Baseline is what this renderer last submitted, not the union.
            // Otherwise an unchanged renderer could delete another's additions.
            workspaceBaseline = snapshot
            workspacePersistenceIssue = result.ownershipConflict
                ? "Another Relay instance moved the same tab at the same time. The newest placement was kept." : nil
            workspaceSaveCanClose = true
            workspacePendingChanges = (try? sharedWorkspaceStore.pendingCount()) ?? workspacePendingChanges
            sweepPaneLinksIfPanesLeft(merged)
            let data = try JSONEncoder().encode(merged)
            RelayStateProfile.defaults.set(data, forKey: workspaceKey)
            persistRemoteWorkspaceStates(merged)
            persistOrganization()
        } catch RelaySharedWorkspaceError.busy {
            workspaceSaveCanClose = false
            workspacePersistenceIssue = "Another Relay instance is saving this workspace. Changes are waiting to be saved."
            if !didShutdown { persistWorkspace() }
        } catch RelaySharedWorkspaceError.conflictingEdit {
            do {
                try sharedWorkspaceStore.preservePending(snapshot)
                workspacePendingChanges = try sharedWorkspaceStore.pendingCount()
                workspacePersistenceIssue = "Another Relay instance changed the same workspace item. Your changes were saved separately for recovery."
                workspaceSaveCanClose = true
            } catch {
                workspaceSaveCanClose = false
                workspacePersistenceIssue = "Conflicting workspace changes could not be saved. Keep this window open to preserve your changes."
            }
        } catch {
            workspaceSaveCanClose = false
            workspacePersistenceIssue = "Workspace changes could not be saved safely. Existing sessions have been left intact."
        }
    }

    struct PaneDeparture: Equatable {
        let tabID: UUID
        let tabSessionID: UUID
        let via: String
        let removedBy: String
    }

    private func observeDepartures(_ tab: TabModel) {
        tab.onPanesLeft = { [weak self, weak tab] paneIDs, via in
            guard let self, let tab else { return }
            self.noteDeparture(paneIDs, from: tab, via: via)
        }
    }

    private func noteDeparture(_ paneIDs: [UUID], from tab: TabModel, via: String) {
        guard !paneIDs.isEmpty else { return }
        let departure = PaneDeparture(tabID: tab.id, tabSessionID: tab.sessionID, via: via,
            removedBy: Self.removalPath(Thread.callStackSymbols,
                                        imageOffsets: Self.imageOffsets(Thread.callStackReturnAddresses)))
        for paneID in paneIDs { paneDepartures[paneID] = departure }
    }

    /// The Relay frames that caused a departure, innermost first, without
    /// the observer's own frames. Each frame carries its offset in the binary
    /// (`@0x…`), so a release build whose names do not resolve at runtime
    /// can still be decoded: `atos -o Relay -l 0x100000000 <0x100000000 + offset>`.
    nonisolated static func removalPath(_ symbols: [String], imageOffsets: [UInt] = []) -> String {
        let frames = symbols.enumerated().compactMap { index, line -> String? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 3, fields[1].hasPrefix("Relay") else { return nil }
            let frame = fields[3...].joined(separator: " ")
            if ["removalPath", "notePanesLeft", "noteDeparture", "observeDepartures", "onPanesLeft"]
                .contains(where: frame.contains) { return nil }
            guard index < imageOffsets.count else { return frame }
            return "\(frame) @0x\(String(imageOffsets[index], radix: 16))"
        }
        // Unnamed observer frames cannot be dropped, so keep enough to reach the caller.
        return frames.prefix(16).joined(separator: " < ")
    }

    /// Each return address as an offset from its image's Mach-O header; 0 when unknown.
    nonisolated static func imageOffsets(_ addresses: [NSNumber]) -> [UInt] {
        addresses.map { number in
            var info = Dl_info()
            guard let address = UnsafeRawPointer(bitPattern: number.uintValue),
                  dladdr(address, &info) != 0, let base = info.dli_fbase else { return 0 }
            return UInt(bitPattern: UnsafeRawPointer(base).distance(to: address))
        }
    }

    /// Logs every pane that left a tab, is now in no tab or R workspace and
    /// was not closed: its tab, sessions and the code path that removed it.
    private func reportSilentPaneRemovals(placed: Set<UUID>) {
        defer { paneDepartures.removeAll(); closedSinceSave.removeAll() }
        for (paneID, departure) in paneDepartures where !placed.contains(paneID) && !closedSinceSave.contains(paneID) {
            let pane = panes[paneID]
            RelayDiagnostics.shared.record(category: "pane", name: "pane-removed-silently", details: [
                "pane_id": paneID.uuidString.lowercased(),
                "tab_id": departure.tabID.uuidString.lowercased(),
                "tab_session": departure.tabSessionID.uuidString.lowercased(),
                "birth_session": pane?.remoteWorkspaceSessionID ?? "",
                "birth_tab": pane?.remoteTabID ?? "",
                "left_via": departure.via,
                "pane_loaded": pane == nil ? "false" : "true",
                "tab_open": tabs.contains { $0.id == departure.tabID } ? "true" : "false",
                "removed_by": departure.removedBy,
            ])
        }
    }

    private func persistRemoteWorkspaceStates(_ snapshot: WorkspaceSnapshot) {
        for sessionID in Set(snapshot.tabs.map { $0.sessionID ?? $0.id }) {
            let sessionTabs = snapshot.tabs.filter { ($0.sessionID ?? $0.id) == sessionID }
            let sessionTabIDs = Set(sessionTabs.map(\.id))
            let presentations = (snapshot.rPresentations ?? []).filter { sessionTabIDs.contains($0.tabID) }
            let paneIDs = Set(sessionTabs.flatMap { $0.layout.paneIDs + ($0.floatingPanes ?? []).map(\.paneID) } + presentations.flatMap(\.paneIDs))
            guard let remotePane = snapshot.panes.first(where: {
                paneIDs.contains($0.id) &&
                $0.profile.kind == .ssh && $0.profile.backend == .relay
            }) else { continue }
            RecoveryWindowRegistry.shared.record(sessionID: sessionID)
            let remoteSnapshot = WorkspaceSnapshot(
                tabs: snapshot.tabs.filter { ($0.sessionID ?? $0.id) == sessionID },
                panes: snapshot.panes.filter { paneIDs.contains($0.id) },
                sessionNames: snapshot.sessionNames?[sessionID].map { [sessionID: $0] },
                selectedTabID: sessionTabs.contains(where: { $0.id == selectedTabID }) ? selectedTabID : sessionTabs.first?.id,
                activePaneID: activePaneID.flatMap { paneIDs.contains($0) ? $0 : nil },
                recoveryWindow: RecoveryWindowRegistry.shared.origin(for: sessionID),
                rPresentations: presentations,
                sidebarVisible: snapshot.sidebarVisible
            )
            guard let state = try? JSONEncoder().encode(remoteSnapshot) else { continue }
            RelayRemoteWorkspaceSync.shared.put(profile: remotePane.profile, workspaceID: sessionID, state: state)
        }
    }
}

enum WorkspacePinStore {
    enum Kind: String { case session, tab, pane }

    static func load(_ kind: Kind, defaults: UserDefaults = .standard) -> Set<UUID> {
        Set((defaults.stringArray(forKey: key(kind)) ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func save(_ ids: Set<UUID>, kind: Kind, defaults: UserDefaults = .standard) {
        defaults.set(ids.map { $0.uuidString.lowercased() }.sorted(), forKey: key(kind))
    }

    private static func key(_ kind: Kind) -> String { "relay.workspace.pinned-\(kind.rawValue)s" }
}

struct WorkspaceSnapshot: Codable, Sendable {
    let tabs: [TabSnapshot]
    let panes: [PaneSnapshot]
    let sessionNames: [UUID: String]?
    let selectedTabID: UUID?
    let activePaneID: UUID?
    var recoveryWindow: RecoveryWindowOrigin? = nil
    var rPresentations: [RWorkspacePresentation]? = nil
    var sidebarVisible: Bool? = nil
    /// Go to pane's user-visit history; local to this Mac, never sent to hosts.
    var paneVisits: [PaneVisit]? = nil
}

struct TabSnapshot: Codable, Sendable {
    let id: UUID
    let sessionID: UUID?
    let name: String
    let layout: PaneLayout
    let floatingPanes: [FloatingPanePlacement]?
    let splitRatios: [UUID: Double]?
    var executionContext: RelayExecutionContext? = nil
    var rLayoutEditorID: UUID? = nil
    var rResultsVisible: Bool? = nil
    /// Present only when the tab has stacks. `layout` is then the legacy
    /// projection with every stacked pane tiled, for older readers.
    var visibleLayout: PaneLayout? = nil
    var stacks: [PaneStack]? = nil
}

struct PaneSnapshot: Codable, Sendable {
    let id: UUID
    let profile: ConnectionProfile
    let contentKind: PaneContentKind?
    let remoteParentSessionID: String?
    let editorRequest: EditorOpenRequest?
    let customName: String?
    let directory: String?
    let remoteWorkspaceSessionID: String?
    let remoteTabID: String?

    init(
        id: UUID,
        profile: ConnectionProfile,
        contentKind: PaneContentKind?,
        remoteParentSessionID: String?,
        editorRequest: EditorOpenRequest?,
        customName: String?,
        directory: String? = nil,
        remoteWorkspaceSessionID: String? = nil,
        remoteTabID: String? = nil
    ) {
        self.id = id
        self.profile = profile
        self.contentKind = contentKind
        self.remoteParentSessionID = remoteParentSessionID
        self.editorRequest = editorRequest
        self.customName = customName
        self.directory = directory
        self.remoteWorkspaceSessionID = remoteWorkspaceSessionID
        self.remoteTabID = remoteTabID
    }

    @MainActor init(pane: PaneModel) {
        self.init(id: pane.id, profile: pane.profile, contentKind: pane.contentKind,
            remoteParentSessionID: pane.remoteParentSessionID, editorRequest: pane.editorRequest,
            customName: pane.customName, directory: pane.directory,
            remoteWorkspaceSessionID: pane.remoteWorkspaceSessionID, remoteTabID: pane.remoteTabID)
    }

    var hasValidBirthHierarchy: Bool {
        if remoteWorkspaceSessionID == nil && remoteTabID == nil { return true }
        guard let workspace = remoteWorkspaceSessionID, let tab = remoteTabID,
              let workspaceID = UUID(uuidString: workspace), let tabID = UUID(uuidString: tab) else { return false }
        return workspaceID.uuidString.lowercased() == workspace && tabID.uuidString.lowercased() == tab
    }

    /// Host catalog birth takes priority; a legacy snapshot falls back to its
    /// presentation tab. Once assigned, a pane's birth is never reassigned here.
    @MainActor func restoreBirthHierarchy(on pane: PaneModel,
        fallbackWorkspaceSessionID: UUID? = nil, fallbackTabID: UUID? = nil,
        hostWorkspaceSessionID: String? = nil, hostTabID: String? = nil) {
        guard hasValidBirthHierarchy, pane.remoteWorkspaceSessionID == nil, pane.remoteTabID == nil else { return }
        if let workspaceID = hostWorkspaceSessionID.flatMap(UUID.init(uuidString:)),
           let tabID = hostTabID.flatMap(UUID.init(uuidString:)) {
            if let saved = remoteWorkspaceSessionID, saved != workspaceID.uuidString.lowercased()
                || remoteTabID != tabID.uuidString.lowercased() {
                RelayDiagnostics.shared.record(category: "workspace", name: "restore-birth-from-host")
            }
            pane.assignRemoteHierarchy(workspaceSessionID: workspaceID, tabID: tabID)
        } else if let workspaceID = remoteWorkspaceSessionID.flatMap(UUID.init(uuidString:)),
                  let tabID = remoteTabID.flatMap(UUID.init(uuidString:)) {
            pane.assignRemoteHierarchy(workspaceSessionID: workspaceID, tabID: tabID)
        } else if let workspaceID = fallbackWorkspaceSessionID, let tabID = fallbackTabID {
            pane.assignRemoteHierarchy(workspaceSessionID: workspaceID, tabID: tabID)
        }
    }
}
