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
    @Published var tabs: [TabModel] = []
    @Published private(set) var navigationState = WorkspaceNavigationState.load()
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
                navigationState = WorkspaceNavigationState.updating { $0.remember(tabID: tab.id, sessionID: tab.sessionID) }
            }
            // Keep a tab's presentation separate from the remote session. A
            // switch must not unzoom it or select its first shell on return.
            let paneIDs = Set(selectedTab?.allPaneIDs ?? [])
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
            updateTerminalFocusOwnership()
            if let pane = activePane {
                selectedTab?.chrome.activeContextChanged(WorkspaceContextAnchor(
                    paneID: pane.id, profile: pane.profile, directory: pane.directory))
            }
        }
    }
    @Published var isConnectionSheetPresented = false
    @Published var isHostLauncherPresented = false
    @Published var isPaneLinkPresented = false
    @Published var sidebarVisible = false
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
    private var assistantStorage: RelayAssistantController?
    var assistantController: RelayAssistantController {
        if let assistantStorage { return assistantStorage }
        let controller = RelayAssistantController(workspace: self)
        assistantStorage = controller
        return controller
    }
    @Published var energyMonitorMode = false
    @Published var performancePanelVisible = false
    @Published var terminationTargetID: UUID?
    @Published var operationError: String?
    @Published private(set) var sessionNames: [UUID: String] = [:]
    @Published private(set) var pinnedSessionIDs = WorkspacePinStore.load(.session)
    @Published private(set) var pinnedTabIDs = WorkspacePinStore.load(.tab)
    @Published private(set) var recentlyClosedPaneCount = 0
    @Published var isRecoveryPresented = false
    @Published private(set) var recoveringTabIDs: Set<UUID> = []
    @Published private(set) var recoveringConversationPaneIDs: Set<UUID> = []
    @Published private(set) var paneCloseEvent = 0
    @Published private(set) var lastClosedPaneWasRemote = false
    @Published private(set) var supervisorRecommendations: [UUID: RelaySupervisorRecommendation] = [:]
    @Published private(set) var supervisorAdvisories: [UUID: RelaySupervisorAdvisory] = [:]
    @Published private(set) var supervisorReceipts: [UUID: RelaySupervisorActionReceipt] = [:]

    let profileStore = ProfileStore()
    let activityIndex = WorkspaceActivityIndex()
    private(set) var panes: [UUID: PaneModel] = [:]
    private var floatingRPaneTabs: [UUID: UUID] = [:]
    private var floatingRPrimaryEditors: [UUID: UUID] = [:]
    var savedRPresentations: [RWorkspacePresentation] = []
    var captureRPresentations: (() -> [RWorkspacePresentation])?

    func persistRPresentation() { persistWorkspace() }

    func rPresentationTabID(consoleID: UUID) -> UUID? {
        tabs.first(where: { $0.allPaneIDs.contains(consoleID) })?.id ?? floatingRPaneTabs[consoleID]
    }
    private let editorInputRequests = AgentInputRequests()
    private let workspaceKey = "relay.workspace.v1"
    private lazy var sharedWorkspaceStore = RelaySharedWorkspaceStore(directory:
        RelayStateProfile.applicationSupportRoot.appendingPathComponent("Relay/Workspace", isDirectory: true))
    private var workspaceBaseline: WorkspaceSnapshot?
    private var workspaceSaveCanClose = true
    @Published private(set) var workspacePersistenceIssue: String?
    @Published private(set) var workspacePendingChanges = 0
    private var sidebarBeforeFullScreen = true
    private var persistenceTask: Task<Void, Never>?
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

    init(restoreSavedWorkspace: Bool = true) {
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
        recentlyClosedPanes = RelayRecoveryStore.shared.loadClosedPanes()
        recentlyClosedPaneCount = recentlyClosedPanes.count
        let shouldRestore = restoreSavedWorkspace && !RelayLaunchMode.isSafeMode
        if shouldRestore && restoreWorkspace() {
            panes.values.forEach { $0.startAgentMonitoring() }
        } else if workspacePersistenceIssue == nil {
            newTab(profile: .local)
        }
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
        startSupervisorMonitoring()
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
        performancePanelVisible.toggle()
    }

    func closePerformancePanel() {
        performancePanelVisible = false
    }

    func openInboxItem(_ item: AgentInboxItem) {
        AgentIntelligenceStore.shared.markRead(item.id)
        guard panes[item.paneID] != nil else { return }
        revealPane(item.paneID)
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
        Task {
            do {
                try await RemotePaneControlService.terminate(profile: pane.profile, paneID: paneID)
                guard panes[paneID] != nil else { return }
                revealPane(paneID)
                closeActivePane()
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    func revealPane(_ paneID: UUID) {
        guard let tab = tabs.first(where: { $0.allPaneIDs.contains(paneID) }) else { return }
        if networkVisible || selectedTabID != tab.id { selectTab(tab.id) }
        selectPane(paneID)
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
                            panes: (tab.allPaneIDs + floatingRPaneTabs.filter {
                                $0.value == tab.id && !tab.allPaneIDs.contains($0.key)
                            }.map(\.key).sorted { $0.uuidString < $1.uuidString }).compactMap { paneID in
                                guard let pane = panes[paneID] else { return nil }
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
                                        (pane.profile.backend == .relay ? "detach_persistent_session" : "stop_nonpersistent_process")
                                )
                            }
                        )
                    }
                )
            }
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
        revealPane(paneID)
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
        if fullScreen && RelayPreferences.shared.hideSidebarInFullScreen {
            sidebarBeforeFullScreen = sidebarVisible
            sidebarVisible = false
        } else if !fullScreen && RelayPreferences.shared.hideSidebarInFullScreen {
            sidebarVisible = sidebarBeforeFullScreen
        }
        isFullScreen = fullScreen
    }

    func newTab(profile: ConnectionProfile) {
        let pane = PaneModel(profile: profile)
        storePane(pane)
        let tab = TabModel(sessionID: UUID(), name: profile.name, firstPane: pane.id)
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        tabs.append(tab)
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
            if let pane = remote.panes.compactMap({ UUID(uuidString: $0.paneID) }).first(where: { panes[$0] != nil }) { revealPane(pane) }
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
            revealPane(existingPane)
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
            revealPane(paneID)
            // Catalog recovery is an explicit viewer reconnect. Renderer
            // status may still say connected after a failed native surface
            // attachment; it must not suppress the requested recovery.
            pane.runtime.reconnectRetainedPane()
            RelayRecoveryStore.shared.record(kind: "viewer_reconnect_requested", paneID: paneID,
                profile: pane.profile, directory: pane.directory)
            return true
        }

        let sessionID = intoSessionID ?? workspaceID.flatMap(UUID.init(uuidString:)) ?? UUID()
        let tabID = remotePane.tabID.flatMap(UUID.init(uuidString:)) ?? UUID()
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
                // Restore editors only when their original console is retained
                // on this host and belongs to this tab.
                guard let parent = saved.remoteParentSessionID.flatMap(UUID.init(uuidString:)),
                      target.allPaneIDs.contains(parent), panes[parent]?.profile.connectionKey == profile.connectionKey else { continue }
                let pane = PaneModel(id: saved.id, profile: profile, contentKind: .editor,
                                     remoteParentSessionID: saved.remoteParentSessionID,
                                     editorRequest: saved.editorRequest, customName: saved.customName, directory: saved.directory)
                pane.assignRemoteHierarchy(workspaceSessionID: sessionID, tabID: tabID)
                storePane(pane)
                target.floatingPanes.append(.initial(paneID: saved.id, index: target.floatingPanes.count))
                added.append(saved.id)
            }
            if Set(desired).count == desired.count,
               Set(target.allPaneIDs) == Set(desired),
               desired.allSatisfy({ panes[$0] != nil }) {
                rememberArrangement(target)
                target.layout = savedTab.layout
                target.floatingPanes = savedTab.floatingPanes ?? []
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
            tab.layout = saved.layout
            tab.splitRatios = saved.splitRatios ?? [:]
            restoreRLayout(saved, in: tab)
            if tab.splitRatios.isEmpty { tab.balanceSplits() }
            for paneID in tab.allPaneIDs {
                panes[paneID]?.assignRemoteHierarchy(workspaceSessionID: sessionID, tabID: tab.id)
            }
            return tab
        }
        guard !restoredTabs.isEmpty else {
            for paneID in requiredIDs {
                panes.removeValue(forKey: paneID)
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

    func newTabInActiveSession(profile: ConnectionProfile? = nil) {
        guard let selectedTab else { return }
        newTab(inSession: selectedTab.sessionID, profile: profile)
    }

    func newTab(inSession sessionID: UUID) {
        let sessionTabs = tabs.filter { $0.sessionID == sessionID }
        guard let sourceTab = sessionTabs.first,
              let sourcePaneID = (selectedTab?.sessionID == sessionID ? activePaneID : sourceTab.allPaneIDs.first),
              let sourcePane = panes[sourcePaneID] else { return }
        newTab(inSession: sessionID, profile: sourcePane.profile)
    }

    func newTab(inSession sessionID: UUID, profile: ConnectionProfile?) {
        let sessionTabs = tabs.filter { $0.sessionID == sessionID }
        guard let sourceTab = sessionTabs.first,
              let sourcePaneID = (selectedTab?.sessionID == sessionID ? activePaneID : sourceTab.allPaneIDs.first),
              let sourcePane = panes[sourcePaneID] else { return }
        let targetProfile = profile ?? sourcePane.profile
        let parentSessionID = targetProfile.kind == .ssh && targetProfile.backend == .relay &&
            sourcePane.profile.kind == .ssh && sourcePane.profile.connectionKey == targetProfile.connectionKey
            ? (sourcePane.contentKind == .terminal ? sourcePane.id.uuidString.lowercased() : sourcePane.remoteParentSessionID)
            : nil
        let pane = PaneModel(profile: targetProfile, remoteParentSessionID: parentSessionID)
        storePane(pane)
        let ordinal = sessionTabs.count + 1
        let tab = TabModel(
            sessionID: sessionID,
            name: ordinal == 1 ? targetProfile.name : "\(targetProfile.name) \(ordinal)",
            firstPane: pane.id
        )
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        tabs.append(tab)
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

    func splitActive(axis: SplitAxis, profile: ConnectionProfile? = nil) {
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
        let pane = PaneModel(profile: splitProfile, remoteParentSessionID: parentSessionID)
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
              active.profile.kind == .ssh,
              active.profile.backend == .relay else { return }
        let parentSessionID = active.contentKind == .terminal
            ? active.id.uuidString.lowercased()
            : active.remoteParentSessionID
        let pane = PaneModel(
            profile: active.profile,
            contentKind: .editor,
            remoteParentSessionID: parentSessionID
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
        let wasTiled = tab.layout.paneIDs.contains(paneID)
        if placement == .center, wasTiled {
            swapTiledPanes(paneID, targetID)
            return
        }
        let baseLayout: PaneLayout
        if wasTiled {
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
        if activePaneID == id, let next = tab.layout.paneIDs.first { selectPane(next) }
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
        selectPane(paneID)
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
              tab.layout.paneIDs.count > 1,
              tab.layout.paneIDs.contains(paneID),
              let remaining = tab.layout.removing(paneID) else { return }
        tab.layout = remaining
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
        RelayRecoveryStore.shared.recordRestore(source: paneID, destination: replacement, plan: plan, profile: profile)
        return replacement
    }

    func reconnectPane(_ paneID: UUID) {
        guard let pane = panes[paneID], pane.contentKind == .terminal else { return }
        selectPane(paneID)
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
            panes[activePaneID]?.stopRuntime()
            panes.removeValue(forKey: activePaneID)
            activityIndex.remove(activePaneID)
            self.activePaneID = tab.allPaneIDs.first
            persistWorkspace()
            return
        }
        if tab.layout.paneIDs.count == 1 {
            closeTab(tab.id)
            return
        }
        tab.layout = tab.layout.removing(activePaneID) ?? tab.layout
        tab.reconcileSplitRatios()
        retirePluginPresentation(for: activePaneID)
        panes[activePaneID]?.stopRuntime()
        panes.removeValue(forKey: activePaneID)
        activityIndex.remove(activePaneID)
        self.activePaneID = tab.layout.paneIDs.first
        persistWorkspace()
    }

    var canReopenClosedPane: Bool { recentlyClosedPaneCount > 0 }

    var recoveryEntries: [ClosedPaneRecovery] {
        RelayRecoveryStore.shared.loadClosedPanes().filter { panes[$0.pane.id] == nil }
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
        RelayRecoveryStore.shared.recordRestore(source: source.id, destination: pane.id, plan: plan, profile: profile)
        persistWorkspace()
    }

    func reopenLastClosedPane(in tabID: UUID? = nil) {
        while let index = recentlyClosedPanes.lastIndex(where: { tabID == nil || $0.tab.id == tabID }) {
            let recovery = recentlyClosedPanes.remove(at: index)
            recentlyClosedPaneCount = recentlyClosedPanes.count
            guard panes[recovery.pane.id] == nil else { continue }

            let saved = recovery.pane
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
            pane.assignRemoteHierarchy(workspaceSessionID: sessionID, tabID: recovery.tab.id)
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
            RelayRecoveryStore.shared.removeClosedPane(recovery.id)
            RelayRecoveryStore.shared.record(kind: "pane_reopened", paneID: saved.id, profile: saved.profile,
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
        let paneSnapshot = PaneSnapshot(
            id: pane.id,
            profile: pane.profile,
            contentKind: pane.contentKind,
            remoteParentSessionID: pane.remoteParentSessionID,
            editorRequest: pane.editorRequest,
            customName: pane.customName,
            directory: pane.directory
        )
        let tabSnapshot = TabSnapshot(
            id: tab.id,
            sessionID: tab.sessionID,
            name: tab.name,
            layout: tab.layout,
            floatingPanes: tab.floatingPanes,
            splitRatios: tab.splitRatios,
            executionContext: tab.executionContext,
            rLayoutEditorID: tab.rLayoutEditorID,
            rResultsVisible: tab.rLayoutEditorID.flatMap { panes[$0]?.editorRuntime.showsRResults }
        )
        let recovery = ClosedPaneRecovery(
            pane: paneSnapshot,
            tab: tabSnapshot,
            tabIndex: tabIndex,
            floatingPlacement: tab.floatingPanes.first(where: { $0.paneID == paneID })
        )
        RelayRecoveryStore.shared.saveClosedPane(recovery)
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
        guard ids.allSatisfy({ id in
            guard let pane = panes[id], pane.contentKind == .editor else { return true }
            return pane.editorRuntime.confirmDiscardChanges()
        }) else { return }
        if let zoomedPaneID, ids.contains(zoomedPaneID) { self.zoomedPaneID = nil }
        for paneID in ids {
            rememberClosedPane(paneID, in: tabs[index])
            if agentInspector?.paneID == paneID { agentInspector = nil }
            retirePluginPresentation(for: paneID)
            panes[paneID]?.stopRuntime()
            panes.removeValue(forKey: paneID)
            floatingRPaneTabs.removeValue(forKey: paneID)
            floatingRPrimaryEditors = floatingRPrimaryEditors.filter { $0.key != paneID && $0.value != paneID }
            activityIndex.remove(paneID)
        }
        tabs.remove(at: index)
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

    func closeSession(_ sessionID: UUID) {
        let closingTabs = tabs.filter { $0.sessionID == sessionID }
        guard !closingTabs.isEmpty else { return }
        let closingTabIDs = Set(closingTabs.map(\.id))
        let closingPaneIDs = closingTabs.flatMap(\.allPaneIDs) + floatingRPaneTabs.filter { closingTabIDs.contains($0.value) }.map(\.key)
        guard closingPaneIDs.allSatisfy({ id in
            guard let pane = panes[id], pane.contentKind == .editor else { return true }
            return pane.editorRuntime.confirmDiscardChanges()
        }) else { return }
        for paneID in closingPaneIDs {
            if let tab = closingTabs.first(where: { $0.allPaneIDs.contains(paneID) }) {
                rememberClosedPane(paneID, in: tab)
            }
            if agentInspector?.paneID == paneID { agentInspector = nil }
            retirePluginPresentation(for: paneID)
            panes[paneID]?.stopRuntime()
            panes.removeValue(forKey: paneID)
            floatingRPaneTabs.removeValue(forKey: paneID)
            floatingRPrimaryEditors = floatingRPrimaryEditors.filter { $0.key != paneID && $0.value != paneID }
            activityIndex.remove(paneID)
        }
        tabs.removeAll { closingTabIDs.contains($0.id) }
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

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
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

    func selectPane(_ id: UUID) {
        // Late callbacks from durable views in another tab must not corrupt
        // selection. Explicit cross-tab navigation reveals its owner first.
        guard panes[id] != nil, let selectedTabID, let tab = selectedTab,
              tab.allPaneIDs.contains(id) || floatingRPaneTabs[id] == selectedTabID else { return }
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

    func selectAdjacentPane(offset: Int) {
        guard let tab = selectedTab else { return }
        let ids = tab.allPaneIDs
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(of: activePaneID ?? ids[0]) ?? 0
        activePaneID = ids[(current + offset + ids.count) % ids.count]
        panes[activePaneID!]?.focus()
        persistWorkspace()
    }

    func selectTab(offset: Int) {
        guard let sessionID = selectedTab?.sessionID,
              let next = WorkspaceNavigationState.adjacentTab(current: selectedTabID,
                ordered: orderedTabs(in: sessionID).map(\.id), offset: offset) else { return }
        selectTab(next)
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

    func selectSession(_ id: UUID) {
        let candidates = orderedTabs(in: id).map(\.id)
        guard let tabID = navigationState.preferredTab(in: id, available: candidates) else { return }
        selectTab(tabID)
    }

    func selectSession(offset: Int) {
        guard let next = WorkspaceNavigationState.adjacentTab(current: selectedTab?.sessionID,
            ordered: navigationSessionIDs, offset: offset) else { return }
        selectSession(next)
    }

    func toggleNavigationGroup(_ group: WorkspaceNavigationState.Group, id: UUID) {
        navigationState = WorkspaceNavigationState.updating { $0.toggle(group, id: id) }
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

    func confirmEditorClose() -> Bool {
        persistWorkspaceNow()
        guard workspaceSaveCanClose else {
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
        assistantStorage?.cancel()
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
            tab.layout = saved.layout
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
        for tab in restoredTabs {
            for paneID in tab.allPaneIDs {
                panes[paneID]?.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
            }
        }
        sessionNames = snapshot.sessionNames ?? [:]
        selectedTabID = restoredTabs.contains(where: { $0.id == snapshot.selectedTabID })
            ? snapshot.selectedTabID : restoredTabs[0].id
        let validPaneIDs = Set(restoredTabs.flatMap(\.allPaneIDs))
        activePaneID = snapshot.activePaneID.flatMap { validPaneIDs.contains($0) ? $0 : nil }
            ?? restoredTabs.first(where: { $0.id == selectedTabID })?.layout.paneIDs.first
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

    private func persistWorkspace() {
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

    private func storePane(_ pane: PaneModel) {
        panes[pane.id] = pane
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
        pane.runtime.onPaneSelection = { [weak self, weak pane] in
            guard let self, let pane, self.panes[pane.id] === pane else { return }
            self.updateTerminalFocusOwnership()
            if self.paneLinkSelection.active { self.paneLinkSelection.toggle(pane.id) }
            else { self.selectPane(pane.id) }
        }
        pane.runtime.setKeyboardFocusEligible(pane.id == activePaneID && !paneLinkSelection.active && !networkVisible)
        activityIndex.observe(pane)
    }

    /// Only the model-selected terminal may run delayed AppKit focus recovery.
    /// Durable terminal views remain mounted while panes are split, floated,
    /// zoomed, and restored. Without explicit ownership, an older pane's
    /// bounded recovery task can steal first responder after the user clicks a
    /// different pane, making typing and Command-C/V appear intermittently
    /// broken in Codex and Claude.
    func updateTerminalFocusOwnership() {
        for (id, pane) in panes {
            pane.runtime.setKeyboardFocusEligible(id == activePaneID && !paneLinkSelection.active && !networkVisible)
        }
        if paneLinkSelection.active { NSApp?.keyWindow?.makeFirstResponder(nil) }
    }

    private func persistWorkspaceNow() {
        let rPresentations = captureRPresentations?() ?? savedRPresentations
        let usedPaneIDs = Set(tabs.flatMap(\.allPaneIDs) + rPresentations.flatMap(\.paneIDs))
        let snapshot = WorkspaceSnapshot(
            tabs: tabs.map {
                TabSnapshot(
                    id: $0.id,
                    sessionID: $0.sessionID,
                    name: $0.name,
                    layout: $0.layout,
                    floatingPanes: $0.floatingPanes,
                    splitRatios: $0.splitRatios,
                    executionContext: $0.executionContext,
                    rLayoutEditorID: $0.rLayoutEditorID,
                    rResultsVisible: $0.rLayoutEditorID.flatMap { panes[$0]?.editorRuntime.showsRResults }
                )
            },
            panes: usedPaneIDs.compactMap { id in
                panes[id].map {
                    PaneSnapshot(
                        id: id,
                        profile: $0.profile,
                        contentKind: $0.contentKind,
                        remoteParentSessionID: $0.remoteParentSessionID,
                        editorRequest: $0.editorRequest,
                        customName: $0.customName,
                        directory: $0.directory
                    )
                }
            },
            sessionNames: sessionNames,
            selectedTabID: selectedTabID,
            activePaneID: activePaneID,
            rPresentations: rPresentations,
            sidebarVisible: sidebarVisible
        )
        do {
            let merged = try sharedWorkspaceStore.commit(snapshot, baseline: workspaceBaseline)
            RelayRecoveryStore.shared.observeWorkspace(snapshot)
            // Baseline is what this renderer last submitted, not the union.
            // Otherwise an unchanged renderer could delete another's additions.
            workspaceBaseline = snapshot
            workspacePersistenceIssue = nil
            workspaceSaveCanClose = true
            workspacePendingChanges = (try? sharedWorkspaceStore.pendingCount()) ?? workspacePendingChanges
            let data = try JSONEncoder().encode(merged)
            RelayStateProfile.defaults.set(data, forKey: workspaceKey)
            persistRemoteWorkspaceStates(merged)
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
    enum Kind: String { case session, tab }

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
}

struct PaneSnapshot: Codable, Sendable {
    let id: UUID
    let profile: ConnectionProfile
    let contentKind: PaneContentKind?
    let remoteParentSessionID: String?
    let editorRequest: EditorOpenRequest?
    let customName: String?
    let directory: String?

    init(
        id: UUID,
        profile: ConnectionProfile,
        contentKind: PaneContentKind?,
        remoteParentSessionID: String?,
        editorRequest: EditorOpenRequest?,
        customName: String?,
        directory: String? = nil
    ) {
        self.id = id
        self.profile = profile
        self.contentKind = contentKind
        self.remoteParentSessionID = remoteParentSessionID
        self.editorRequest = editorRequest
        self.customName = customName
        self.directory = directory
    }
}
