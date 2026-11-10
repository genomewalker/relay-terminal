import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor private func copyWorkspaceID(_ id: UUID) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(id.uuidString.lowercased(), forType: .string)
}

private extension UTType {
    static let relayWorkspaceTab = WorkspaceDragPayload.tab
}

private struct NetworkCoverKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var networkCoverActive: Bool {
        get { self[NetworkCoverKey.self] }
        set { self[NetworkCoverKey.self] = newValue }
    }
}

extension Notification.Name {
    static let relayShowHPC = Notification.Name("relay.showHPC")
    static let relayShowPlugin = Notification.Name("relay.showPlugin")
    static let relayConnectPaneSessions = Notification.Name("relay.connect-pane-sessions")
    /// Opens the agent inspector on a pane's main agent; the object is the pane id.
    static let relayInspectPaneAgent = Notification.Name("relay.inspect-pane-agent")
}

private struct PaneConnectionRequest: Identifiable {
    let id: UUID
}

struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var preferences = RelayPreferences.shared
    @State private var showingQuitConfirmation = false
    @State private var mikoPanelOffset: CGSize = .zero
    @State private var hpcPaneID: UUID?
    @State private var pluginPaneID: UUID?
    @State private var pluginToolID = ""
    @State private var paneConnectionRequest: PaneConnectionRequest?
    @State private var showingRelaydOnboarding = false
    @State private var showingRelaydManager = false
    @State private var preferredRelaydProfile: ConnectionProfile?
    @State private var showingPaneCloseNotice = false
    @State private var paneCloseNoticeTask: Task<Void, Never>?
    @AppStorage("relay.relayd-onboarding-seen.v1") private var relaydOnboardingSeen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
        HStack(spacing: RelayTheme.spacing(0)) {
            WorkspaceToolRail(workspace: workspace)
                if workspace.sidebarVisible {
                    WorkspaceSidebar(workspace: workspace) {
                        SessionManager(workspace: workspace)
                    }
                        .frame(width: preferences.compactInterface ? 244 : 260)
                    Rectangle().fill(RelayTheme.line.opacity(0.38)).frame(width: 1)
            }
            VStack(spacing: RelayTheme.spacing(0)) {
                WorkspaceNavigationHeader(workspace: workspace) {
                    WorkspaceTabRail(workspace: workspace)
                }
                    if let issue = workspace.workspacePersistenceIssue {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, RelayTheme.spacing(12))
                            .padding(.vertical, RelayTheme.spacing(7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RelayTheme.surface)
                    } else if workspace.workspacePendingChanges > 0 {
                        Label("\(workspace.workspacePendingChanges) saved workspace change drafts await recovery", systemImage: "tray.full")
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .padding(.horizontal, RelayTheme.spacing(12))
                            .padding(.vertical, RelayTheme.spacing(7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RelayTheme.surface)
                    }
                    if RelayLaunchMode.isSafeMode {
                        HStack(spacing: RelayTheme.spacing(7)) {
                            Image(systemName: "shield")
                            Text("Safe mode · workspace restore and artifact previews are disabled")
                            Spacer()
                        }
                        .font(RelayTheme.font(size: 10.5, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                        .padding(.horizontal, RelayTheme.spacing(12))
                        .frame(height: 30)
                        .background(RelayTheme.surface)
                        .accessibilityLabel("Relay is running in safe mode")
                    }
                    PaneLinkSelectionBar(workspace: workspace, selection: workspace.paneLinkSelection)
                    Rectangle().fill(RelayTheme.line.opacity(0.45)).frame(height: 1)
                    ZStack {
                    WorkspaceNavigationContent(workspace: workspace) {
                        if let tab = workspace.visibleTab {
                            WorkspaceDockLayout(tab: tab, workspace: workspace)
                                .environment(\.networkCoverActive, workspace.networkVisible)
                                .background(RelayTheme.terminalCanvas)
                        } else if workspace.selectedWorkspaceID != nil {
                            EmptyWorkspaceView(workspace: workspace)
                        }
                    }
                    .opacity(workspace.networkVisible ? 0.42 : 1)
                    .allowsHitTesting(!workspace.networkVisible)
                    .accessibilityHidden(workspace.networkVisible)
                    if workspace.networkVisible {
                        PeerNetworkView(workspace: workspace)
                    }
                    }
                }
            }
            if !workspace.networkVisible {
                RBoundedWorkspaceHost(workspace: workspace)
                    .padding(.trailing, RelayTheme.spacing(220))
                    .zIndex(100)
            }
            if !workspace.networkVisible, let selection = workspace.agentInspector,
               let pane = workspace.panes[selection.paneID] {
                AgentInspectorPanel(
                    pane: pane,
                    subagentID: selection.subagentID,
                    showTerminal: { workspace.revealPane(selection.paneID, origin: .user) },
                    inspect: { workspace.inspectAgent(paneID: selection.paneID, subagentID: $0) },
                    openConversation: { focus in
                        workspace.revealPane(selection.paneID, origin: .user)
                        AgentInspectorPanel.openConversation(pane: pane, focus: focus)
                    },
                    close: workspace.closeAgentInspector
                )
                // Recreate the panel when the inspected agent changes: its
                // snapshot lives in @State, so without a new identity the
                // previous agent's content lingers until the pane publishes.
                .id(selection)
                .padding(.top, workspace.isFullScreen ? 50 : 58)
                .padding(.trailing, RelayTheme.spacing(228))
                .zIndex(500)
            }
            if !workspace.networkVisible && workspace.intelligencePanelVisible {
                AgentIntelligencePanel(
                    workspace: workspace,
                    close: workspace.closeIntelligencePanel
                )
                .padding(.top, workspace.isFullScreen ? 50 : 58)
                .padding(.trailing, RelayTheme.spacing(228))
                .zIndex(650)
            }
            if !workspace.networkVisible && workspace.assistantVisible {
                RelayAssistantPanel(workspace: workspace, controller: workspace.assistantController)
                    .padding(.top, workspace.isFullScreen ? 50 : 58)
                    .padding(.trailing, RelayTheme.spacing(50))
                    .zIndex(700)
            }
            if !workspace.networkVisible && workspace.haikuAssistantVisible {
                GeometryReader { geometry in
                    let size = RelayMikoPanelPlacement.panelSize(in: geometry.size)
                    SmoothFloatingPanelDrag(
                        settledOffset: Binding(
                            get: { RelayMikoPanelPlacement.clampedOffset(mikoPanelOffset, in: geometry.size) },
                            set: { mikoPanelOffset = RelayMikoPanelPlacement.clampedOffset($0, in: geometry.size) }
                        ), headerHeight: 44
                    ) {
                        RelayAssistantHaikuPanel(workspace: workspace, harness: workspace.haikuAssistant, panelSize: size)
                    }
                    .padding(.top, 58).padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .zIndex(710)
            }
            if let id = pluginPaneID, let pane = workspace.panes[id] {
                PluginWorkspaceOverlay(workspace: workspace, pane: pane, toolID: pluginToolID,
                                       close: { pluginPaneID = nil })
                    .id(id.uuidString + pluginToolID)
                    .frame(maxWidth: 1120, maxHeight: 650)
                    .padding(.horizontal, RelayTheme.spacing(32))
                    .padding(.top, RelayTheme.spacing(68))
                    .padding(.bottom, RelayTheme.spacing(28))
                    .padding(.trailing, RelayTheme.spacing(220))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(RelayTheme.canvas.opacity(0.58))
                    .zIndex(680)
            }
            if let id = hpcPaneID, let pane = workspace.panes[id] {
                HPCDiscoveryWorkspace(workspace: workspace, preferredPaneID: pane.id, close: { hpcPaneID = nil })
                    .id(id)
                    .frame(maxWidth: 1120, maxHeight: 650)
                    .padding(.horizontal, RelayTheme.spacing(32))
                    .padding(.top, RelayTheme.spacing(68))
                    .padding(.bottom, RelayTheme.spacing(28))
                    .padding(.trailing, RelayTheme.spacing(220))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(RelayTheme.canvas.opacity(0.58))
                    .zIndex(680)
            }
            if workspace.performancePanelVisible {
                RelayPerformancePanel(
                    workspace: workspace,
                    close: workspace.closePerformancePanel
                )
                .padding(.top, workspace.isFullScreen ? 50 : 58)
                .padding(.trailing, RelayTheme.spacing(228))
                .zIndex(700)
            }

        }
        .background(RelayTheme.canvas)
        .environmentObject(workspace.paneLinkSelection)
        .task { workspace.refreshPaneLinkMemberships() }
        .onReceive(NotificationCenter.default.publisher(for: .relayShowHPC)) { _ in
            guard let pane = workspace.activePane else { return }
            workspace.selectedTab?.chrome.hide()
            pluginPaneID = nil
            hpcPaneID = nil
            RelayToolWindowCoordinator.shared.showHPC(workspace: workspace, pane: pane)
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayShowPlugin)) { notification in
            guard let pane = workspace.activePane else { return }
            workspace.selectedTab?.chrome.hide()
            hpcPaneID = nil
            pluginPaneID = nil
            RelayToolWindowCoordinator.shared.show(workspace: workspace, pane: pane,
                                                   toolID: notification.object as? String ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayNodeReady)) { notification in
            guard let key = notification.object as? String else { return }
            workspace.restartDisconnectedEditors(connectionKey: key)
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayConnectPaneSessions)) { notification in
            guard let id = notification.object as? UUID, workspace.panes[id] != nil else { return }
            paneConnectionRequest = PaneConnectionRequest(id: id)
        }
        .modifier(RInspectPaneAgentRequests(workspace: workspace))
        .sheet(item: $paneConnectionRequest) { request in
            PeerNetworkTopologyView(workspace: workspace, connectionOnly: true, startingPaneID: request.id, manage: {})
        }
        .tint(RelayTheme.accent)
        .modifier(RPresentationPersistence(workspace: workspace))
        .modifier(RelayStartAgentRequestHandler(workspace: workspace))
        .overlay(alignment: .bottom) {
            if showingQuitConfirmation {
                HStack(spacing: RelayTheme.spacing(10)) {
                    Image(systemName: "power")
                        .font(RelayTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(RelayTheme.coral)
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(1)) {
                        Text("Press ⌘Q again to quit")
                            .font(RelayTheme.font(size: 11.5, weight: .medium))
                        Text("Remote sessions keep running")
                            .font(RelayTheme.font(size: 11))
                            .foregroundStyle(RelayTheme.textMuted)
                    }
                }
                .foregroundStyle(RelayTheme.text)
                .padding(.horizontal, RelayTheme.spacing(14))
                .frame(height: 48)
                .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous)
                        .stroke(RelayTheme.line.opacity(0.9))
                }
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                .padding(.bottom, RelayTheme.spacing(20))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Press Command Q again to quit. Remote sessions keep running.")
                .allowsHitTesting(false)
            } else if showingPaneCloseNotice && workspace.canReopenClosedPane {
                HStack(spacing: RelayTheme.spacing(11)) {
                    Image(systemName: workspace.lastClosedPaneWasRemote ? "rectangle.badge.minus" : "xmark.square")
                        .font(RelayTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(1)) {
                        Text(workspace.lastClosedPaneWasRemote ? "Pane detached" : "Pane closed")
                            .font(RelayTheme.font(size: 11.5, weight: .medium))
                        Text(workspace.lastClosedPaneWasRemote ? "Its remote process is still running" : "You can reopen it now")
                            .font(RelayTheme.font(size: 11))
                            .foregroundStyle(RelayTheme.textMuted)
                    }
                    Button("Undo") {
                        paneCloseNoticeTask?.cancel()
                        showingPaneCloseNotice = false
                        workspace.reopenLastClosedPane()
                    }
                    .buttonStyle(.plain)
                    .font(RelayTheme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.accent)
                    .padding(.leading, RelayTheme.spacing(5))
                    .accessibilityHint("Reopens the most recently closed pane")
                }
                .foregroundStyle(RelayTheme.text)
                .padding(.horizontal, RelayTheme.spacing(14))
                .frame(height: 48)
                .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous)
                        .stroke(RelayTheme.line.opacity(0.9))
                }
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                .padding(.bottom, RelayTheme.spacing(20))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
            }
        }
        .sheet(isPresented: $workspace.isQuickNavigatePresented, onDismiss: {
            workspace.quickNavigateDidDismiss()
        }) {
            RelayQuickNavigate(workspace: workspace)
        }
        .sheet(isPresented: $workspace.isFleetBoardPresented, onDismiss: {
            workspace.fleetBoardDidDismiss()
        }) {
            RelayFleetBoard(workspace: workspace)
        }
        .sheet(isPresented: $workspace.isHostLauncherPresented) {
            HostLauncher(workspace: workspace)
        }
        .sheet(isPresented: $workspace.isRecoveryPresented) {
            RelayRecoveryView(workspace: workspace)
        }
        .sheet(isPresented: $workspace.isMigrationPresented) {
            WorkspaceMigrationSheet(workspace: workspace)
        }
        .sheet(isPresented: $workspace.isPaneLinkPresented, onDismiss: {
            workspace.updateTerminalFocusOwnership()
            if let id = workspace.activePaneID { workspace.panes[id]?.runtime.focus() }
        }) {
            PaneMessagingLinkView(workspace: workspace)
        }
        .sheet(isPresented: $workspace.isConnectionSheetPresented) {
            ConnectionSheet(workspace: workspace)
        }
        .sheet(isPresented: $showingRelaydOnboarding) {
            RelaydFirstRunView(
                reviewHosts: {
                    relaydOnboardingSeen = true
                    showingRelaydOnboarding = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        preferredRelaydProfile = workspace.activePane?.profile.kind == .ssh
                            ? workspace.activePane?.profile : nil
                        showingRelaydManager = true
                    }
                },
                continueWithoutReview: {
                    relaydOnboardingSeen = true
                    showingRelaydOnboarding = false
                }
            )
        }
        .sheet(isPresented: $showingRelaydManager) {
            RelaydManagerView(
                profileStore: workspace.profileStore,
                preferredProfile: preferredRelaydProfile
            )
        }
        .alert(
            workspace.renameTarget?.title ?? "Rename",
            isPresented: Binding(
                get: { workspace.renameTarget != nil },
                set: { if !$0 { workspace.cancelRename() } }
            )
        ) {
            TextField("Name", text: $workspace.renameDraft)
            Button("Cancel", role: .cancel) { workspace.cancelRename() }
            Button("Rename") { workspace.commitRename() }
                .disabled(workspace.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "Terminate remote pane?",
            isPresented: Binding(
                get: { workspace.terminationTargetID != nil },
                set: { if !$0 { workspace.cancelTermination() } }
            )
        ) {
            Button("Cancel", role: .cancel) { workspace.cancelTermination() }
            Button("Terminate", role: .destructive) { workspace.confirmTermination() }
        } message: {
            Text("This ends the remote shell and its child processes, then removes the pane from the remote catalog. Detach keeps them running.")
        }
        .alert(
            "Remote operation failed",
            isPresented: Binding(
                get: { workspace.operationError != nil },
                set: { if !$0 { workspace.operationError = nil } }
            )
        ) {
            Button("OK") { workspace.operationError = nil }
        } message: {
            Text(workspace.operationError ?? "Unknown error")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            workspace.setFullScreen(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            workspace.setFullScreen(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayApplicationActivityChanged)) { notification in
            workspace.applicationPresentationChanged(visible: notification.object as? Bool ?? false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayQuitConfirmation)) { notification in
            let update = {
                showingQuitConfirmation = notification.object as? Bool ?? false
            }
            if reduceMotion { update() } else { withAnimation(.easeOut(duration: 0.16), update) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayManageRelayd)) { notification in
            preferredRelaydProfile = (notification.object as? ConnectionProfile)
                ?? workspace.activePane?.profile
            showingRelaydManager = true
        }
        .onChange(of: workspace.recentlyClosedPaneCount) { _, count in
            // Only dismissal lives here; showing is driven by paneCloseEvent
            // so that Undo (count decreasing) never re-shows the notice and
            // the 21st close (count saturated at 20) still shows it.
            guard count == 0 else { return }
            paneCloseNoticeTask?.cancel()
            showingPaneCloseNotice = false
        }
        .onChange(of: workspace.paneCloseEvent) { _, _ in
            paneCloseNoticeTask?.cancel()
            let show = { showingPaneCloseNotice = true }
            if reduceMotion { show() } else { withAnimation(.easeOut(duration: 0.16), show) }
            paneCloseNoticeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                if reduceMotion {
                    showingPaneCloseNotice = false
                } else {
                    withAnimation(.easeOut(duration: 0.16)) { showingPaneCloseNotice = false }
                }
            }
        }
        .onAppear {
            if !relaydOnboardingSeen { showingRelaydOnboarding = true }
            workspace.applicationPresentationChanged(
                visible: RelayApplicationActivityState.allowsContinuousUpdates
            )
        }
    }
}

private struct AgentIntelligencePanel: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var store = AgentIntelligenceStore.shared
    @StateObject private var search = AgentInboxSearchController()
    let close: () -> Void
    @State private var query = ""
    @State private var scope: AgentInboxScope = .all
    @State private var settledOffset: CGSize = .zero
    @State private var isDragging = false

    private var visibleItems: [AgentInboxItem] {
        let byID = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return search.visibleIDs.compactMap { byID[$0] }
    }

    var body: some View {
        SmoothFloatingPanelDrag(
            settledOffset: $settledOffset,
            headerHeight: 54,
            onDragActivityChanged: { isDragging = $0 }
        ) {
            VStack(spacing: RelayTheme.spacing(0)) {
                panelHeader
                Divider().overlay(RelayTheme.line.opacity(0.5))
                searchBar
                scopePicker
                Divider().overlay(RelayTheme.line.opacity(0.35))
                inbox
                Divider().overlay(RelayTheme.line.opacity(0.35))
                statusBar
            }
            .frame(width: 570, height: 620)
            .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous)
                    .stroke(RelayTheme.line.opacity(0.9))
            }
            .shadow(color: .black.opacity(isDragging ? 0.18 : 0.42), radius: isDragging ? 5 : 26, y: isDragging ? 2 : 14)
        }
        .onAppear { refreshSearch() }
        .onChange(of: store.items) { _, _ in refreshSearch() }
        .onChange(of: query) { _, _ in refreshSearch() }
        .onChange(of: scope) { _, _ in refreshSearch() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent activity inbox")
    }

    private var panelHeader: some View {
        HStack(spacing: RelayTheme.spacing(10)) {
            ZStack {
                RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7), style: .continuous)
                    .fill(RelayTheme.blue.opacity(0.14))
                Image(systemName: "sparkles")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.blue)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: RelayTheme.spacing(1)) {
                Text("Agent activity")
                    .font(RelayTheme.font(size: 13, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                Text(store.unreadCount == 0 ? "You're caught up" : "\(store.unreadCount) since you last checked")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(store.attentionCount > 0 ? RelayTheme.coral : RelayTheme.textFaint)
            }
            Spacer()
            if store.unreadCount > 0 {
                Button("Mark all read") { store.markAllRead() }
                    .buttonStyle(.plain)
                    .font(RelayTheme.font(size: 10, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(RelayTheme.font(size: 10, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(RelayTheme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help("Close agent activity")
            .accessibilityLabel("Close agent activity")
        }
        .padding(.horizontal, RelayTheme.spacing(14))
        .frame(height: 54)
        .contentShape(Rectangle())
    }

    private var searchBar: some View {
        HStack(spacing: RelayTheme.spacing(8)) {
            Image(systemName: "magnifyingglass")
                .font(RelayTheme.font(size: 10, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
            TextField("Search work, failures, files, or peer handoffs", text: $query)
                .textFieldStyle(.plain)
                .font(RelayTheme.font(size: 11.5))
                .foregroundStyle(RelayTheme.text)
            if search.isRefining {
                ProgressView().controlSize(.mini)
                    .help("Refining search on this Mac")
            } else if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(RelayTheme.font(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textFaint)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, RelayTheme.spacing(10))
        .frame(height: 32)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
        .padding(.horizontal, RelayTheme.spacing(14))
        .padding(.top, RelayTheme.spacing(12))
    }

    private var scopePicker: some View {
        HStack(spacing: RelayTheme.spacing(6)) {
            ForEach(AgentInboxScope.allCases) { value in
                Button {
                    scope = value
                } label: {
                    Text(value.label)
                        .font(RelayTheme.font(size: 11, weight: scope == value ? .semibold : .medium))
                        .foregroundStyle(scope == value ? RelayTheme.text : RelayTheme.textMuted)
                        .padding(.horizontal, RelayTheme.spacing(9))
                        .frame(height: 24)
                        .background(
                            scope == value ? RelayTheme.surface : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if store.attentionCount > 0 {
                Label("\(store.attentionCount) need you", systemImage: "exclamationmark.circle.fill")
                    .font(RelayTheme.font(size: 9, weight: .medium))
                    .foregroundStyle(RelayTheme.coral)
            }
        }
        .padding(.horizontal, RelayTheme.spacing(14))
        .frame(height: 42)
    }

    @ViewBuilder
    private var inbox: some View {
        if visibleItems.isEmpty {
            VStack(spacing: RelayTheme.spacing(9)) {
                Image(systemName: query.isEmpty ? "checkmark.circle" : "magnifyingglass")
                    .font(RelayTheme.font(size: 21, weight: .light))
                    .foregroundStyle(RelayTheme.textFaint)
                Text(query.isEmpty ? "No activity in this view" : "No matching activity")
                    .font(RelayTheme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: RelayTheme.spacing(2)) {
                    ForEach(visibleItems) { item in
                        AgentInboxRow(item: item) {
                            workspace.openInboxItem(item)
                        }
                    }
                }
                .padding(RelayTheme.spacing(8))
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: RelayTheme.spacing(6)) {
            Image(systemName: ProcessInfo.processInfo.isLowPowerModeEnabled ? "leaf.fill" : "cpu")
                .font(RelayTheme.font(size: 9))
            Text(ProcessInfo.processInfo.isLowPowerModeEnabled
                 ? "Model work paused in Low Power Mode"
                 : search.usedSystemIntelligence
                 ? "Search refined on this Mac"
                 : "Structured events · on-device intelligence")
                .font(RelayTheme.font(size: 9.5, weight: .medium))
            Spacer()
            Text("\(store.items.count) events")
                .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(RelayTheme.textFaint)
        .padding(.horizontal, RelayTheme.spacing(14))
        .frame(height: 34)
    }

    private func refreshSearch() {
        search.scheduleSearch(items: store.items, query: query, scope: scope)
    }
}

private struct AgentInboxRow: View {
    let item: AgentInboxItem
    let open: () -> Void
    @State private var hovering = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: RelayTheme.spacing(10)) {
                ZStack {
                    Circle().fill(item.kind.color.opacity(0.13))
                    Image(systemName: item.kind.symbol)
                        .font(RelayTheme.font(size: 10, weight: .medium))
                        .foregroundStyle(item.kind.color)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                    HStack(spacing: RelayTheme.spacing(6)) {
                        Text(item.title)
                            .font(RelayTheme.font(size: 11, weight: item.isRead ? .medium : .semibold))
                            .foregroundStyle(item.isRead ? RelayTheme.textMuted : RelayTheme.text)
                            .lineLimit(1)
                        if !item.isRead {
                            Circle().fill(item.kind.color).frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        Spacer()
                        // Own clock: no longer refreshed as a side effect of workspace publishes.
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(Self.relativeFormatter.localizedString(for: item.occurredAt, relativeTo: context.date))
                                .font(RelayTheme.font(size: 11, weight: .medium))
                                .foregroundStyle(RelayTheme.textFaint)
                        }
                    }
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(RelayTheme.font(size: 11))
                            .foregroundStyle(RelayTheme.textMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: RelayTheme.spacing(5)) {
                        Text(item.host)
                        Text("·")
                        Text(item.provider.label)
                        Text("·")
                        Text(item.kind.label)
                        if item.summarySource == .onDevice {
                            Image(systemName: "sparkles")
                                .help("Summarized on this Mac")
                                .accessibilityLabel("Summarized on this Mac")
                        }
                    }
                    .font(RelayTheme.font(size: 8.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textFaint)
                }
            }
            .padding(.horizontal, RelayTheme.spacing(10))
            .padding(.vertical, RelayTheme.spacing(9))
            .background(hovering ? RelayTheme.surface.opacity(0.72) : Color.clear,
                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(9), style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(item.kind.label), \(item.title), \(item.host), \(item.isRead ? "read" : "unread")")
        .accessibilityHint("Opens the related terminal or agent thread")
    }
}

/// Opens the agent inspector when a pane header asks for its agent's details.
private struct RInspectPaneAgentRequests: ViewModifier {
    let workspace: WorkspaceModel

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .relayInspectPaneAgent)) { notification in
            guard let id = notification.object as? UUID, workspace.panes[id] != nil else { return }
            workspace.inspectAgent(paneID: id)
        }
    }
}

/// Header text that opens something: plain until hovered, then underlined.
struct RelayHeaderLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Label<Content: View>: View {
        let label: Content
        let pressed: Bool
        @State private var hovering = false

        var body: some View {
            label
                .underline(hovering)
                .opacity(pressed ? 0.6 : 1)
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
        }
    }
}

struct AgentInspectorSnapshot: Equatable {
    let kind: AgentKind
    let agent: SubagentActivity?
    let plans: [AgentTaskPlan]
    /// The pane's sub-agents, listed only for the main agent's view.
    var subagents: [SubagentActivity] = []
    /// The main agent's status as the pane header words it.
    var statusText: String? = nil
}

struct AgentInspectorPanel: View {
    let pane: PaneModel
    /// Nil shows the pane's main agent.
    let subagentID: String?
    let showTerminal: () -> Void
    var inspect: (String) -> Void = { _ in }
    /// Opens View CLI conversation, at a step's tool call when one is given.
    var openConversation: (RelayConversationFocus?) -> Void = { _ in }
    let close: () -> Void
    @State private var settledOffset: CGSize = .zero
    @State private var panelSize = CGSize(width: 470, height: 410)
    @GestureState private var resizeOffset: CGSize = .zero
    @State private var collapsed = false
    @State private var isDragging = false
    @State private var refreshPending = false
    @State private var snapshot: AgentInspectorSnapshot
    @FocusState private var titleFocused: Bool

    init(
        pane: PaneModel,
        subagentID: String?,
        showTerminal: @escaping () -> Void,
        inspect: @escaping (String) -> Void = { _ in },
        openConversation: @escaping (RelayConversationFocus?) -> Void = { _ in },
        close: @escaping () -> Void
    ) {
        self.pane = pane
        self.subagentID = subagentID
        self.showTerminal = showTerminal
        self.inspect = inspect
        self.openConversation = openConversation
        self.close = close
        self._snapshot = State(initialValue: Self.capture(pane: pane, subagentID: subagentID))
    }

    var body: some View {
        SmoothFloatingPanelDrag(
            settledOffset: $settledOffset,
            headerHeight: 42,
            onDragActivityChanged: dragActivityChanged
        ) {
            VStack(spacing: RelayTheme.spacing(0)) {
                inspectorTitleBar
                if !collapsed {
                    Rectangle().fill(RelayTheme.line.opacity(0.7)).frame(height: 1)
                    if let agent = snapshot.agent {
                        inspectorContent(agent)
                    } else {
                        VStack(spacing: RelayTheme.spacing(10)) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(RelayTheme.font(size: 24))
                                .foregroundStyle(RelayTheme.textFaint)
                            Text("This agent is no longer available")
                                .font(RelayTheme.font(size: 12, weight: .medium))
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(
                width: collapsed ? 330 : min(max(panelSize.width + resizeOffset.width, 380), 820),
                height: collapsed ? 42 : min(max(panelSize.height + resizeOffset.height, 260), 760)
            )
            .background(RelayTheme.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous)
                    .stroke(RelayTheme.line.opacity(0.85), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isDragging ? 0.16 : 0.34), radius: isDragging ? 5 : 22, y: isDragging ? 2 : 10)
            .overlay(alignment: .bottomTrailing) {
                if !collapsed {
                    Color.clear
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .updating($resizeOffset) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    panelSize.width = min(max(panelSize.width + value.translation.width, 380), 820)
                                    panelSize.height = min(max(panelSize.height + value.translation.height, 260), 760)
                                }
                        )
                        .help("Resize inspector")
                }
            }
        }
        .onReceive(pane.objectWillChange) { _ in
            // ObservableObject publishes before mutation. Read the resulting
            // agent snapshot on the next main-actor turn.
            Task { @MainActor in
                await Task.yield()
                if isDragging {
                    refreshPending = true
                } else {
                    refreshSnapshot()
                }
            }
        }
    }

    private var inspectorTitleBar: some View {
        HStack(spacing: RelayTheme.spacing(9)) {
            Image(systemName: snapshot.kind.symbol)
                .font(RelayTheme.font(size: 11, weight: .medium))
                .foregroundStyle(RelayTheme.textMuted)
            Text(subagentID == nil ? "Agent details" : "Agent thread")
                .font(RelayTheme.font(size: 11.5, weight: .medium))
                .foregroundStyle(RelayTheme.text)
            Text(snapshot.kind.label)
                .font(RelayTheme.font(size: 11, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
            Spacer()
            Button { collapsed.toggle() } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(RelayTheme.font(size: 9, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help(collapsed ? "Expand inspector" : "Collapse inspector")
            .accessibilityLabel(collapsed ? "Expand agent inspector" : "Collapse agent inspector")
            Button { openConversation(nil) } label: {
                Label("Full conversation", systemImage: "text.bubble")
                    .font(RelayTheme.font(size: 10.5, weight: .medium))
                    .padding(.horizontal, RelayTheme.spacing(7))
                    .frame(height: 22)
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(5)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help("Show the full conversation: every tool call with its command and output")
            .accessibilityIdentifier("relay.agent-inspector.full-conversation")
            Button(action: showTerminal) {
                Image(systemName: "terminal")
                    .font(RelayTheme.font(size: 10, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help("Show parent terminal")
            .accessibilityLabel("Show parent terminal")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(RelayTheme.font(size: 9, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .accessibilityLabel("Close agent inspector")
        }
        .padding(.horizontal, RelayTheme.spacing(12))
        .frame(height: 42)
        .background(RelayTheme.surface.opacity(0.7))
        .contentShape(Rectangle())
        .focusable()
        .focused($titleFocused)
        .focusEffectDisabled()
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(titleFocused ? RelayTheme.accent : Color.clear)
                .frame(height: 2)
                .padding(.horizontal, RelayTheme.spacing(14))
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Movable agent inspector")
        .onKeyPress(.leftArrow) { settledOffset.width -= 20; return .handled }
        .onKeyPress(.rightArrow) { settledOffset.width += 20; return .handled }
        .onKeyPress(.upArrow) { settledOffset.height -= 20; return .handled }
        .onKeyPress(.downArrow) { settledOffset.height += 20; return .handled }
    }

    static func capture(pane: PaneModel, subagentID: String?) -> AgentInspectorSnapshot {
        guard let subagentID else { return captureMainAgent(pane: pane) }
        return AgentInspectorSnapshot(
            kind: pane.kind,
            agent: pane.subagents.first { $0.id == subagentID },
            plans: pane.taskPlans.filter { plan in
                let agent = pane.subagents.first { $0.id == subagentID }
                return plan.id == pane.kind.rawValue + ":" + subagentID ||
                    agent?.threadID.map { plan.id == pane.kind.rawValue + ":" + $0 } == true
            }
        )
    }

    /// The pane's own agent as one thread: its recent steps, newest first,
    /// every task plan in the pane, and its sub-agents to open from here.
    static func captureMainAgent(pane: PaneModel) -> AgentInspectorSnapshot {
        let steps = pane.agentActivities
        let ended = pane.phase == .exited || pane.phase == .quiet
        return AgentInspectorSnapshot(
            kind: pane.kind,
            agent: SubagentActivity(
                id: "",
                label: pane.customName ?? pane.harnessLabel,
                startedAt: steps.first?.occurredAt ?? pane.lastActivity,
                provider: pane.kind,
                phase: pane.phase,
                completedAt: ended ? steps.last?.occurredAt : nil,
                // Newest first: the step the header shows heads the list.
                updates: steps.reversed().map { SubagentUpdate(id: $0.id, message: $0.label, occurredAt: $0.occurredAt) }
            ),
            plans: pane.taskPlans,
            subagents: pane.subagents,
            statusText: pane.headerStatus?.text
        )
    }

    /// Shows the pane's conversation in place of its terminal, scrolled to
    /// `focus` when given.
    static func openConversation(pane: PaneModel, focus: RelayConversationFocus?) {
        pane.conversationFocus = focus
        RelayToolWindowCoordinator.shared.showAgent(pane: pane)
    }

    /// The conversation focus for the step at `index` of the main agent's
    /// newest-first steps: the same tool's newer steps above it count back.
    static func focus(forStepAt index: Int, in updates: [SubagentUpdate]) -> RelayConversationFocus? {
        guard updates.indices.contains(index),
              let name = RelayConversationFocus.toolName(of: updates[index].message) else { return nil }
        let newer = updates[..<index].filter { RelayConversationFocus.toolName(of: $0.message) == name }.count
        return RelayConversationFocus.step(updates[index].message, newerSameTool: newer)
    }

    private func refreshSnapshot() {
        snapshot = Self.capture(pane: pane, subagentID: subagentID)
        refreshPending = false
    }

    private func dragActivityChanged(_ active: Bool) {
        isDragging = active
        if !active, refreshPending {
            refreshSnapshot()
        }
    }

    /// The main agent's sub-agents, newest first; each opens its own thread.
    private var subagentList: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
            Text("Sub-agents")
                .font(RelayTheme.font(size: 10, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
                .padding(.horizontal, RelayTheme.spacing(16))
            ScrollView {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(0)) {
                    ForEach(snapshot.subagents.reversed()) { subagent in
                        Button { inspect(subagent.id) } label: {
                            HStack(spacing: RelayTheme.spacing(8)) {
                                Circle().fill(subagent.phase.color).frame(width: 6, height: 6)
                                // Saved threads may carry an empty label from older events.
                                Text(subagent.label.isEmpty ? "Sub-agent" : subagent.label)
                                    .font(RelayTheme.font(size: 11.5, weight: .medium))
                                    .foregroundStyle(RelayTheme.text)
                                    .lineLimit(1)
                                Text(subagent.updates.last?.message ?? "")
                                    .font(RelayTheme.font(size: 11))
                                    .foregroundStyle(RelayTheme.textMuted)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(RelayTheme.font(size: 9, weight: .medium))
                                    .foregroundStyle(RelayTheme.textFaint)
                            }
                            .padding(.horizontal, RelayTheme.spacing(16))
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(subagent.label)")
                        .accessibilityLabel("Open sub-agent \(subagent.label)")
                    }
                }
            }
            .frame(maxHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, RelayTheme.spacing(10))
    }

    private func stepCard(_ update: SubagentUpdate, opens: Bool) -> some View {
        HStack(alignment: .center, spacing: RelayTheme.spacing(8)) {
            VStack(alignment: .leading, spacing: RelayTheme.spacing(5)) {
                Text(update.occurredAt.formatted(date: .omitted, time: .shortened))
                    .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(RelayTheme.textFaint)
                if opens {
                    // Selection would take the click that opens the conversation.
                    Text(update.message)
                        .font(RelayTheme.font(size: 11.5))
                        .foregroundStyle(RelayTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(update.message)
                        .font(RelayTheme.font(size: 11.5))
                        .foregroundStyle(RelayTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if opens {
                Image(systemName: "arrow.up.right")
                    .font(RelayTheme.font(size: 9, weight: .medium))
                    .foregroundStyle(RelayTheme.textFaint)
                    .accessibilityHidden(true)
            }
        }
        .padding(RelayTheme.spacing(11))
        .background(RelayTheme.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(9)))
        .contentShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(9)))
    }

    private func inspectorContent(_ agent: SubagentActivity) -> some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(0)) {
            ForEach(snapshot.plans) { plan in
                DisclosureGroup("Task plan · \(plan.completedCount)/\(plan.steps.count) completed") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                                Label(step.text, systemImage: step.status == .completed ? "checkmark.circle" : step.status == .in_progress ? "circle.lefthalf.filled" : "circle")
                                    .textSelection(.enabled)
                            }
                        }
                    }.frame(maxHeight: 180)
                }.padding(RelayTheme.spacing(12))
            }
            VStack(alignment: .leading, spacing: RelayTheme.spacing(9)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(agent.label)
                        .font(RelayTheme.font(size: 16, weight: .medium))
                        .foregroundStyle(RelayTheme.text)
                        .textSelection(.enabled)
                    Spacer()
                    HStack(spacing: RelayTheme.spacing(5)) {
                        Circle().fill(agent.phase.color).frame(width: 6, height: 6)
                        Text(snapshot.statusText ?? (agent.phase == .active ? PaneDisplayState.working.label : "Finished"))
                            .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(agent.phase.color)
                    }
                }
                HStack(spacing: RelayTheme.spacing(14)) {
                    Label(agent.startedAt.formatted(date: .omitted, time: .shortened), systemImage: "play.fill")
                    if let completedAt = agent.completedAt {
                        Label(completedAt.formatted(date: .omitted, time: .shortened), systemImage: "checkmark")
                    }
                    if let threadID = agent.threadID {
                        Text(String(threadID.prefix(12)))
                            .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                            .help(threadID)
                    }
                }
                .font(RelayTheme.font(size: 9.5, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
            }
            .padding(RelayTheme.spacing(16))

            if !snapshot.subagents.isEmpty { subagentList }

            Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(12)) {
                    if agent.updates.isEmpty {
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(7)) {
                            Text(agent.phase == .active ? "Waiting for the first progress update" : "No result text was recorded")
                                .font(RelayTheme.font(size: 12, weight: .medium))
                                .foregroundStyle(RelayTheme.textMuted)
                            Text("Relay captured the lifecycle, but this CLI did not expose a readable progress message for this thread.")
                                .font(RelayTheme.font(size: 11))
                                .foregroundStyle(RelayTheme.textFaint)
                        }
                        .padding(.vertical, RelayTheme.spacing(4))
                    } else {
                        ForEach(Array(agent.updates.enumerated()), id: \.element.id) { index, update in
                            if subagentID == nil {
                                // Main agent: a step opens the conversation, at its tool call when it has one.
                                let focus = Self.focus(forStepAt: index, in: agent.updates)
                                Button { openConversation(focus) } label: {
                                    stepCard(update, opens: true)
                                }
                                .buttonStyle(.plain)
                                .help(focus == nil ? "Show the conversation" : "Show this call in the conversation")
                                .accessibilityHint(focus == nil ? "Shows the conversation" : "Shows this call in the conversation")
                            } else {
                                stepCard(update, opens: false)
                            }
                        }
                    }
                }
                .padding(RelayTheme.spacing(14))
            }
        }
    }
}

/// Shown when the visible workspace has no tab: nothing is mounted, and
/// "New tab" files a tab here.
private struct EmptyWorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: RelayTheme.spacing(10)) {
            Image(systemName: "square.stack").font(.system(size: 28)).foregroundStyle(RelayTheme.textFaint)
            Text(workspace.selectedWorkspaceID.flatMap { workspace.ownership.workspace($0)?.name } ?? "Workspace")
                .font(RelayTheme.font(size: 14, weight: .semibold))
            Text("This workspace has no tabs. Drop a tab or pane on it in the sidebar, or start one here.")
                .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
            Text("No tab is selected, so pane and tab commands have nothing to act on.")
                .font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textFaint)
            Button("New tab") { workspace.newTabInActiveSession() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("relay.workspace.empty.new-tab")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RelayTheme.canvas)
    }
}

/// The visible workspace's tabs. Workspaces, not legacy sessions, own tabs;
/// a pane dropped on a tab joins it as a split, from any workspace or host.
struct WorkspaceTabRail: View {
    @ObservedObject var workspace: WorkspaceModel
    // Tab marks follow pane phases, throttled like the fleet board.
    @ObservedObject private var activityIndex: WorkspaceActivityIndex
    @State private var draggedTabID: UUID?
    @State private var dropFailure: String?

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        activityIndex = workspace.activityIndex
    }

    private var workspaceTabs: [TabModel] {
        guard let workspaceID = workspace.selectedWorkspaceID else { return [] }
        return workspace.railTabs(inWorkspace: workspaceID)
    }

    private var workspaceName: String {
        workspace.selectedWorkspaceID.flatMap { workspace.ownership.workspace($0)?.name } ?? "Workspace"
    }

    private func move(_ sourceID: UUID, beside targetID: UUID, placement: TabMovePlacement) {
        guard let workspaceID = workspace.workspaceID(forTab: targetID) else { return }
        let others = workspace.tabs(inWorkspace: workspaceID).map(\.id).filter { $0 != sourceID }
        let index = (others.firstIndex(of: targetID) ?? others.count) + (placement == .after ? 1 : 0)
        do { try workspace.performDrop(.tabOnWorkspace(tabID: sourceID, workspaceID: workspaceID, index: index)) }
        catch { dropFailure = error.localizedDescription }
    }

    var body: some View {
        let _ = activityIndex.revision
        // Same status as the fleet board; one pass over the panes per revision.
        let marks = RelayWorkOverviewIndex.tabStatuses(RelayWorkOverviewIndex.paneFacts(workspace),
                                                       focusedTabID: workspace.selectedTabID)
        HStack(spacing: RelayTheme.spacing(8)) {
            Menu {
                ForEach(workspace.navigatorWorkspaces().shown) { record in
                    Button { workspace.selectWorkspace(record.id, origin: .user) } label: {
                        if record.id == workspace.selectedWorkspaceID {
                            Label(record.name, systemImage: "checkmark")
                        } else { Text(record.name) }
                    }
                }
            } label: {
                // A menu button, not a tab: workspace icon, up-down chevron
                // and a filled control shape instead of the tab underline.
                HStack(spacing: 5) {
                    Image(systemName: "square.stack").font(RelayTheme.font(size: 10)).foregroundStyle(RelayTheme.textMuted)
                    Text(workspaceName).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down").font(RelayTheme.font(size: 8, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                .padding(.horizontal, RelayTheme.Space.sm)
                .frame(height: 24)
                .background(RelayTheme.wash, in: RoundedRectangle(cornerRadius: RelayTheme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: RelayTheme.Radius.control).strokeBorder(RelayTheme.line))
            }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help(dropFailure ?? "Switch workspace")
                .accessibilityLabel("Switch workspace, " + workspaceName)
                .accessibilityIdentifier("relay.navigation.workspace-switcher")
                .font(RelayTheme.font(size: 11.5, weight: .medium))
                .foregroundStyle(RelayTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RelayTheme.spacing(3)) {
                    ForEach(Array(workspaceTabs.enumerated()), id: \.element.id) { index, tab in
                        let fallbackLabel = index == 0 ? "Main" : "Tab \(index + 1)"
                        WorkspaceTab(
                            tab: tab,
                            label: workspace.tabDisplayName(tab, fallback: fallbackLabel),
                            isSelected: tab.id == workspace.selectedTabID,
                            pinned: workspace.isTabPinned(tab.id),
                            status: marks[tab.id],
                            select: { workspace.selectTab(tab.id, origin: .user) },
                            togglePin: { workspace.toggleTabPin(tab.id) },
                            rename: { workspace.beginRenameTab(tab.id) },
                            close: { workspace.closeTab(tab.id) },
                            recover: { workspace.reconnectPanels(in: tab.id) },
                            reopenClosed: { workspace.reopenLastClosedPane(in: tab.id) },
                            toggleAutoLink: { RelayAutoLinker.shared.toggle(.tab(tab.id), workspace: workspace) },
                            recovering: workspace.recoveringTabIDs.contains(tab.id),
                            draggedTabID: $draggedTabID,
                            move: { sourceID, placement in move(sourceID, beside: tab.id, placement: placement) },
                            canDropPane: { workspace.canDrop(.paneOnTab(paneID: $0, tabID: tab.id)) },
                            dropPane: { paneID in
                                do {
                                    try workspace.performDrop(.paneOnTab(paneID: paneID, tabID: tab.id))
                                    dropFailure = nil
                                } catch { dropFailure = error.localizedDescription }
                            }
                        )
                        .frame(width: 158)
                    }
                    ChromeButton(symbol: "plus", help: "New tab in this workspace · ⌘T") {
                        workspace.newTabInActiveSession()
                    }
                    .padding(.leading, RelayTheme.spacing(3))
                }
                .padding(.horizontal, RelayTheme.spacing(4))
            }
            Spacer(minLength: 0)
            if let dropFailure {
                Button { self.dropFailure = nil } label: {
                    Label(dropFailure, systemImage: "exclamationmark.triangle")
                        .font(RelayTheme.font(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityIdentifier("relay.navigation.drop-failure")
            }
        }
        .padding(.horizontal, RelayTheme.spacing(8))
        .frame(height: 36)
        .background(RelayTheme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(RelayTheme.line.opacity(0.45)).frame(height: 1) }
        .relayStatusMarkVisibility()
    }
}

private struct WorkspaceToolRail: View {
    @ObservedObject private var plugins = RelayPluginManager.shared
    @ObservedObject var workspace: WorkspaceModel

    private struct RailTool: Identifiable {
        let id: String
        let title: String
        let symbol: String
    }

    private var railTools: [RailTool] {
        plugins.installations.keys.sorted().flatMap { id -> [RailTool] in
            guard plugins.installations[id]?.enabled == true,
                  let package = plugins.reviewedInstallations[id]?.package else { return [] }
            return package.contributions.compactMap { entry in
                guard entry.kind == .tool, let operation = entry.operation else { return nil }
                let toolID = id + ":" + entry.id
                // The plots button already opens this exact contribution.
                guard toolID != "relay.radian:results", operation != .agentActivity, !operation.isHPC else { return nil }
                return RailTool(id: toolID, title: entry.title, symbol: symbol(for: operation))
            }
        }
    }

    private func symbol(for operation: RelayPluginOperation) -> String {
        switch operation {
        case .agentActivity: return "sparkles"
        case .artifacts: return "shippingbox"
        case .gitReview: return "point.3.connected.trianglepath.dotted"
        case .transfers: return "arrow.left.arrow.right"
        case .projectActions: return "hammer"
        case .projectRun: return "play.rectangle"
        case .hpcJobs: return "server.rack"
        case .hpcAccounting: return "chart.bar"
        case .hpcDetails: return "list.bullet.rectangle"
        case .hpcLogs: return "text.alignleft"
        case .hpcSubmit: return "paperplane"
        case .hpcCancel: return "stop.circle"
        case .vpn: return "lock.shield"
        case .rWorkspace: return "r.square"
        }
    }

    private func revealPlugin(_ id: String) {
        NotificationCenter.default.post(name: .relayShowPlugin, object: id)
    }

    private var railButtons: some View {
        VStack(spacing: RelayTheme.spacing(5)) {
            ChromeButton(symbol: "network", help: workspace.networkVisible ? "Back to workspace" : "Network") {
                if workspace.networkVisible { workspace.hideNetwork() } else { workspace.showNetwork() }
            }.accessibilityIdentifier("relay.navigation.network")
            RelaySubscriptionQuotaButton(workspace: workspace)
            ChromeButton(symbol: "sparkles", help: "Relay assistant") { workspace.toggleHaikuAssistant() }
                .accessibilityIdentifier("relay.assistant.toggle")
            ChromeButton(symbol: "server.rack", help: "Connect to a host · ⌘K") { workspace.presentHostLauncher() }
                .accessibilityIdentifier("relay.tools.connect")
            ChromeButton(symbol: "terminal", help: "New local session") { workspace.newTab(profile: .local) }
                .accessibilityIdentifier("relay.tools.local-session")
            ChromeButton(symbol: "rectangle.split.2x1", help: "Split pane right · ⌘D") { workspace.splitActive(axis: .horizontal) }
            ChromeButton(symbol: "rectangle.split.1x2", help: "Split pane down · ⇧⌘D") { workspace.splitActive(axis: .vertical) }
            ChromeButton(symbol: "arrow.clockwise", help: "Reconnect panels in this tab") {
                if let tabID = workspace.selectedTabID { workspace.reconnectPanels(in: tabID) }
            }
            .disabled(workspace.selectedTabID.map { workspace.recoveringTabIDs.contains($0) } ?? true)
            .accessibilityIdentifier("relay.workspace.recover-panels")
            Divider().frame(width: 22)
            WorkspaceBrowserLauncher(workspace: workspace)
            WorkspaceFileNavigationButton(workspace: workspace)
            RelayExecutionContextButton(workspace: workspace)
            RelayHostRotationButton(workspace: workspace)
            ChromeButton(symbol: "waveform.path.ecg.rectangle", help: "Monitoring · performance, energy, processes and agents") {
                workspace.togglePerformancePanel()
            }.accessibilityIdentifier("relay.tools.monitoring")
            Menu {
                Button("Open remote editor") { workspace.openEditorForActive() }
                    .disabled(workspace.activePane?.profile.kind != .ssh || workspace.activePane?.profile.backend != .relay)
                Button("R workspace") { RelayToolWindowCoordinator.shared.showR(workspace: workspace) }
                Button("R plots and tables") { revealPlugin("relay.radian:results") }
                Button("HPC") { NotificationCenter.default.post(name: .relayShowHPC, object: nil) }
                Divider()
                ForEach(railTools) { tool in
                    Button(tool.title) { revealPlugin(tool.id) }
                        .accessibilityIdentifier("relay.tools." + tool.id)
                }
                Divider()
                Button("Restore closed panes…") { workspace.isRecoveryPresented = true }
                Button("New floating pane") { workspace.newFloatingPane() }
            } label: {
                RelayToolbarMenuIcon(symbol: "wrench.and.screwdriver", title: "Tools")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .foregroundStyle(RelayTheme.textMuted).help("Tools: editor, R, HPC, files and transfers")
            .accessibilityLabel("Tools")
            .accessibilityIdentifier("relay.tools.menu")
            Divider().frame(width: 22)
            Menu {
                Button("Balance pane layout") { workspace.balanceActiveTabPanes() }
                Button("Zoom active pane") { workspace.toggleActivePaneZoom() }
                Button("Float or dock active pane") { workspace.toggleActivePaneFloating() }
                Button("Tile floating panes") { workspace.arrangeFloatingPanes(cascade: false) }
                Button("Cascade floating panes") { workspace.arrangeFloatingPanes(cascade: true) }
                Button("Restore previous layout") { workspace.restorePaneArrangement() }
                Divider()
                Button("New local session") { workspace.newTab(profile: .local) }
            } label: {
                RelayToolbarMenuIcon(symbol: "ellipsis", title: "Layout actions")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .foregroundStyle(RelayTheme.textMuted).help("Pane layout actions")
            .accessibilityLabel("Layout actions")
        }
    }

    var body: some View {
        VStack(spacing: RelayTheme.spacing(6)) {
            ChromeButton(symbol: workspace.sidebarVisible ? "sidebar.left" : "sidebar.right",
                         help: workspace.sidebarVisible ? "Hide navigator" : "Show navigator") {
                workspace.sidebarVisible.toggle()
            }
            .accessibilityLabel(workspace.sidebarVisible ? "Hide navigator" : "Show navigator")
            .accessibilityIdentifier("relay.sessions.toggle-sidebar")
            Divider().frame(width: 22)
            ScrollView(.vertical, showsIndicators: true) {
                railButtons.padding(.vertical, RelayTheme.spacing(4))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, RelayTheme.spacing(7))
        .padding(.bottom, RelayTheme.spacing(7))
        .frame(width: 46)
        .frame(maxHeight: .infinity)
        .background(RelayTheme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(RelayTheme.line.opacity(0.45)).frame(width: 1) }
        .onAppear { plugins.refresh() }
    }
}

private struct WorkspaceTab: View {
    @ObservedObject var tab: TabModel
    let label: String
    let isSelected: Bool
    let pinned: Bool
    let status: RelayWorkOverviewIndex.PaneStatus?
    let select: () -> Void
    let togglePin: () -> Void
    let rename: () -> Void
    let close: () -> Void
    let recover: () -> Void
    let reopenClosed: () -> Void
    let toggleAutoLink: () -> Void
    @ObservedObject private var autoLink = RelayAutoLinker.shared
    let recovering: Bool
    @Binding var draggedTabID: UUID?
    let move: (UUID, TabMovePlacement) -> Void
    let canDropPane: (UUID) -> WorkspaceMoveRefusal?
    let dropPane: (UUID) -> Void
    @State private var hovering = false
    @State private var paneRefusal: String?
    @State private var dropPlacement: TabMovePlacement?
    @State private var tabWidth: CGFloat = 1

    var body: some View {
        HStack(spacing: RelayTheme.spacing(1)) {
            Button(action: select) {
                HStack(spacing: RelayTheme.spacing(4)) {
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(RelayTheme.font(size: 7.5, weight: .medium))
                            .foregroundStyle(RelayTheme.textFaint)
                    }
                    RelayStatusMark(status: status)
                    Text(label)
                        .font(RelayTheme.font(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    RelayFinishedDot(paneIDs: tab.allPaneIDs)
                }
                .padding(.leading, RelayTheme.spacing(10))
                .padding(.trailing, RelayTheme.spacing(6))
                .frame(maxWidth: .infinity, minHeight: 33, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { rename() }
            )
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(RelayTheme.font(size: 7.5, weight: .medium))
                    .frame(width: 22, height: 33)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .opacity(isSelected || hovering ? 1 : 0)
            .allowsHitTesting(isSelected || hovering)
            .accessibilityHidden(!isSelected && !hovering)
            .accessibilityLabel("Close \(label) tab")
        }
        .foregroundStyle(isSelected ? RelayTheme.text : RelayTheme.textMuted)
        .background(isSelected ? RelayTheme.surface : hovering ? RelayTheme.hover.opacity(0.45) : Color.clear,
                    in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6), style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6), style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(RelayTheme.accent)
                    .frame(width: 2, height: 19)
                    .padding(.leading, RelayTheme.spacing(1))
                }
        }
        .overlay {
            HStack(spacing: RelayTheme.spacing(0)) {
                if dropPlacement == .before {
                    Capsule().fill(RelayTheme.accent).frame(width: 2, height: 21)
                }
                Spacer(minLength: 0)
                if dropPlacement == .after {
                    Capsule().fill(RelayTheme.accent).frame(width: 2, height: 21)
                }
            }
            .padding(.horizontal, -2)
            .allowsHitTesting(false)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: WorkspaceTabWidthPreferenceKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(WorkspaceTabWidthPreferenceKey.self) { tabWidth = max($0, 1) }
        .onDrag {
            draggedTabID = tab.id
            WorkspaceNavigatorDragState.shared.item = .tab(tab.id)
            return WorkspaceDragPayload.provider(tab.id, type: .relayWorkspaceTab)
        }
        .onDrop(
            of: [UTType.relayWorkspaceTab.identifier, WorkspaceDragPayload.pane.identifier],
            delegate: WorkspaceTabDropDelegate(
                targetID: tab.id,
                targetWidth: tabWidth,
                draggedTabID: $draggedTabID,
                placement: $dropPlacement,
                paneRefusal: $paneRefusal,
                move: move,
                canDropPane: canDropPane,
                dropPane: dropPane
            )
        )
        .help(paneRefusal ?? "Drop a pane here to add it to this tab")
        .onHover { hovering = $0 }
        .contextMenu {
            Button(pinned ? "Unpin tab" : "Pin tab", action: togglePin)
            Button("Rename tab…", action: rename)
            Button("Copy Tab ID") { copyWorkspaceID(tab.id) }
            Button(recovering ? "Reconnecting panels…" : "Reconnect panels", action: recover)
                .disabled(recovering)
            Button("Reopen last closed pane", action: reopenClosed)
            Toggle("Auto-link agent panes in this tab", isOn: Binding(get: { autoLink.isEnabled(.tab(tab.id)) }, set: { _ in toggleAutoLink() }))
            Toggle("Allow agents to broadcast in this tab", isOn: Binding(get: { autoLink.allowsBroadcast(.tab(tab.id)) },
                                                                          set: { _ in autoLink.toggleBroadcast(.tab(tab.id)) }))
            Divider()
            Button("Close tab", action: close)
        }
    }
}

private struct WorkspaceTabWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WorkspaceTabDropDelegate: DropDelegate {
    let targetID: UUID
    let targetWidth: CGFloat
    @Binding var draggedTabID: UUID?
    @Binding var placement: TabMovePlacement?
    @Binding var paneRefusal: String?
    let move: (UUID, TabMovePlacement) -> Void
    let canDropPane: (UUID) -> WorkspaceMoveRefusal?
    let dropPane: (UUID) -> Void

    /// A pane dragged from a header or the navigator, onto this tab.
    private func draggedPane(_ info: DropInfo) -> UUID? {
        guard info.hasItemsConforming(to: [WorkspaceDragPayload.pane]) else { return nil }
        return PaneDragCoordinator.shared.paneID
    }

    /// A tab from this rail or the workspace navigator. Every tab drag
    /// records itself when it starts, so a cancelled drag is never reused.
    private func draggedTab(_ info: DropInfo) -> UUID? {
        guard info.hasItemsConforming(to: [WorkspaceDragPayload.tab]) else { return nil }
        if case let .tab(id)? = WorkspaceNavigatorDragState.shared.item { return id }
        return draggedTabID
    }

    func validateDrop(info: DropInfo) -> Bool {
        if draggedPane(info) != nil { return true }
        guard let draggedTabID = draggedTab(info) else { return false }
        return draggedTabID != targetID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let paneID = draggedPane(info) {
            let refusal = canDropPane(paneID)
            paneRefusal = refusal?.localizedDescription
            placement = refusal == nil ? .after : nil
            return DropProposal(operation: refusal == nil ? .move : .forbidden)
        }
        let draggedTabID = draggedTab(info)
        guard draggedTabID != nil, draggedTabID != targetID else {
            placement = nil
            return DropProposal(operation: .forbidden)
        }
        placement = info.location.x < targetWidth / 2 ? .before : .after
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        placement = nil
        paneRefusal = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        if let paneID = draggedPane(info) {
            placement = nil
            paneRefusal = nil
            PaneDragCoordinator.shared.paneID = nil
            dropPane(paneID)
            return true
        }
        defer { WorkspaceNavigatorDragState.shared.item = nil }
        guard let draggedTabID = draggedTab(info), draggedTabID != targetID else {
            placement = nil
            return false
        }
        let resolvedPlacement = placement ?? (info.location.x < targetWidth / 2 ? .before : .after)
        move(draggedTabID, resolvedPlacement)
        self.draggedTabID = nil
        placement = nil
        return true
    }
}

private struct ChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        RelayIconAction(help, symbol: symbol, action: action)
        .accessibilityLabel(Text(help.split(separator: "·").first.map(String.init) ?? help))
    }
}

private struct SessionNodeGroup: Identifiable {
    let id: String
    let name: String
    let remote: Bool
    var sessions: [SessionTabGroup]
}

private struct SessionTabGroup: Identifiable {
    let id: UUID
    var tabs: [TabModel]
}

struct SessionManager: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var activityIndex: WorkspaceActivityIndex
    @ObservedObject private var intelligence = AgentIntelligenceStore.shared
    @State private var tabSearchQuery = ""
    @State private var tabSearchHits: [WorkspaceSidebarSearchHit] = []
    @State private var tabSearchTask: Task<Void, Never>?

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        self.activityIndex = workspace.activityIndex
    }

    private var activityBadgeCount: Int {
        intelligence.attentionCount > 0 ? intelligence.attentionCount : intelligence.unreadCount
    }

    private var activityBadgeLabel: String {
        intelligence.attentionCount > 0
            ? "\(intelligence.attentionCount) need attention"
            : "\(intelligence.unreadCount) unread"
    }

    private var nodeGroups: [SessionNodeGroup] {
        _ = activityIndex.revision
        var groups: [SessionNodeGroup] = []
        for tab in workspace.tabs {
            guard let paneID = tab.allPaneIDs.first, let pane = workspace.panes[paneID] else { continue }
            let remote = pane.profile.kind == .ssh
            let key = remote ? "ssh:\(pane.profile.host)" : "local"
            let name = remote ? pane.profile.host : "This Mac"
            if let nodeIndex = groups.firstIndex(where: { $0.id == key }) {
                if let sessionIndex = groups[nodeIndex].sessions.firstIndex(where: { $0.id == tab.sessionID }) {
                    groups[nodeIndex].sessions[sessionIndex].tabs.append(tab)
                } else {
                    groups[nodeIndex].sessions.append(SessionTabGroup(id: tab.sessionID, tabs: [tab]))
                }
            } else {
                groups.append(SessionNodeGroup(
                    id: key,
                    name: name,
                    remote: remote,
                    sessions: [SessionTabGroup(id: tab.sessionID, tabs: [tab])]
                ))
            }
        }
        let navigation = workspace.navigationState
        let now = Date()
        for index in groups.indices {
            for sessionIndex in groups[index].sessions.indices {
                let tabs = groups[index].sessions[sessionIndex].tabs
                let order = navigation.ordered(.tab, ids: tabs.map(\.id), pinned: workspace.isTabPinned, now: now)
                groups[index].sessions[sessionIndex].tabs = order.compactMap { id in tabs.first { $0.id == id } }
            }
            let sessions = groups[index].sessions
            let order = navigation.ordered(.session, ids: sessions.map(\.id), pinned: workspace.isSessionPinned, now: now)
            groups[index].sessions = order.compactMap { id in sessions.first { $0.id == id } }
        }
        return groups
    }

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            Color.clear.frame(height: workspace.isFullScreen ? 38 : 42)
            HStack(spacing: RelayTheme.spacing(8)) {
                Text("Sessions")
                    .font(RelayTheme.font(size: 13, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                Spacer()
                Button {
                    workspace.toggleIntelligencePanel()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: workspace.intelligencePanelVisible ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .frame(width: 26, height: 26)
                        if activityBadgeCount > 0 {
                            Text(activityBadgeCount > 99 ? "99+" : "\(activityBadgeCount)")
                                .font(RelayTheme.font(size: 11, weight: .medium))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, RelayTheme.spacing(3))
                                .frame(minWidth: 17, minHeight: 17)
                                .background(intelligence.attentionCount > 0 ? RelayTheme.coral : RelayTheme.blue, in: Capsule())
                                .offset(x: 3, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(workspace.intelligencePanelVisible ? RelayTheme.blue : RelayTheme.textMuted)
                .help(activityBadgeCount > 0
                      ? "Agent activity · \(activityBadgeLabel)"
                      : "Agent activity")
                .accessibilityLabel("Agent activity, \(activityBadgeLabel)")
                Menu {
                    Button("Expand all") { workspace.setAllNavigationGroups(expanded: true) }
                    Button("Collapse all") { workspace.setAllNavigationGroups(expanded: false) }
                    Divider()
                    Picker("Sort", selection: Binding(
                        get: { workspace.navigationState.sortMode },
                        set: { workspace.setNavigationSortMode($0) }
                    )) {
                        Text("As arranged").tag(WorkspaceNavigationState.SortMode.manual)
                        Text("Most used").tag(WorkspaceNavigationState.SortMode.mostUsed)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(RelayTheme.font(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(RelayTheme.textMuted)
                .help("Expand, collapse or sort sessions")
                .accessibilityIdentifier("relay.navigation.options")
                Button {
                    workspace.presentHostLauncher()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(RelayTheme.font(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help("Connect to a host")
            }
            .padding(.leading, RelayTheme.spacing(14))
            .padding(.trailing, RelayTheme.spacing(10))
            .frame(height: 44)

            HStack(spacing: RelayTheme.spacing(7)) {
                Image(systemName: "magnifyingglass")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.textFaint)
                TextField("Search tabs, text, paths, IDs…", text: $tabSearchQuery)
                    .textFieldStyle(.plain)
                    .font(RelayTheme.font(size: 11.5))
                    .accessibilityIdentifier("relay.tabs.search")
                    .onChange(of: tabSearchQuery) { _, value in
                        tabSearchTask?.cancel()
                        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            tabSearchHits = []
                        } else {
                            tabSearchTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                guard !Task.isCancelled else { return }
                                tabSearchHits = workspace.sidebarSearch(value)
                            }
                        }
                    }
                if !tabSearchQuery.isEmpty {
                    Button {
                        tabSearchQuery = ""
                        tabSearchHits = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(RelayTheme.font(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.textFaint)
                    .accessibilityLabel("Clear tab search")
                }
            }
            .padding(.horizontal, RelayTheme.spacing(9))
            .frame(height: 32)
            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
            .padding(.horizontal, RelayTheme.spacing(10))
            .padding(.bottom, RelayTheme.spacing(6))

            ScrollView {
                if tabSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                        AttentionInboxSection(workspace: workspace)
                        // Same status as the fleet board; one pass over the panes per revision.
                        let marks = RelayWorkOverviewIndex.tabStatuses(RelayWorkOverviewIndex.paneFacts(workspace),
                                                                       focusedTabID: workspace.selectedTabID)
                        ForEach(nodeGroups) { group in
                            SessionNodeSection(group: group, workspace: workspace, marks: marks)
                        }
                    }
                    .padding(.horizontal, RelayTheme.spacing(8))
                    .padding(.vertical, RelayTheme.spacing(6))
                    .relayStatusMarkVisibility()
                } else if tabSearchHits.isEmpty {
                    Text("No matching tabs")
                        .font(RelayTheme.font(size: 11.5))
                        .foregroundStyle(RelayTheme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(RelayTheme.spacing(16))
                } else {
                    LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                        ForEach(tabSearchHits) { hit in
                            Button {
                                if let pane = hit.pane { workspace.revealPane(pane.id, origin: .user) }
                                else if let paneID = hit.tab.allPaneIDs.first { workspace.revealPane(paneID, origin: .user) }
                                else { workspace.selectTab(hit.tab.id, origin: .user) }
                            } label: {
                                VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
                                    Text(hit.tab.name.isEmpty ? "Untitled tab" : hit.tab.name)
                                        .font(RelayTheme.font(size: 11.5, weight: .medium))
                                        .foregroundStyle(RelayTheme.text)
                                        .lineLimit(1)
                                    Text(hit.detail)
                                        .font(RelayTheme.font(size: 10.5))
                                        .foregroundStyle(RelayTheme.textMuted)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, RelayTheme.spacing(9))
                                .padding(.vertical, RelayTheme.spacing(7))
                                .background(RelayTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("relay.tabs.search-result.\(hit.tab.id.uuidString.lowercased())")
                        }
                    }
                    .padding(.horizontal, RelayTheme.spacing(8))
                    .padding(.vertical, RelayTheme.spacing(6))
                }
            }

            Spacer(minLength: 0)
            Button {
                workspace.presentHostLauncher()
            } label: {
                HStack(spacing: RelayTheme.spacing(8)) {
                    Image(systemName: "plus")
                        .font(RelayTheme.font(size: 10, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                    Text("New connection")
                        .font(RelayTheme.font(size: 11.5, weight: .medium))
                        .foregroundStyle(RelayTheme.text)
                    Spacer()
                    Text("⌘K")
                        .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.textFaint)
                }
                .padding(.horizontal, RelayTheme.spacing(12))
                .frame(height: 36)
                .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(9), style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(RelayTheme.spacing(8))
        }
        .background(RelayTheme.sidebar)
    }
}

private struct SessionNodeSection: View {
    let group: SessionNodeGroup
    @ObservedObject var workspace: WorkspaceModel
    let marks: [UUID: RelayWorkOverviewIndex.PaneStatus]
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var nodeConnected: Bool {
        group.sessions.flatMap(\.tabs).flatMap(\.allPaneIDs).compactMap { workspace.panes[$0] }.contains { pane in
            if case .connected = pane.connectionState { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
            HStack(spacing: RelayTheme.spacing(7)) {
                Group {
                    if differentiateWithoutColor {
                        Image(systemName: nodeConnected ? "wifi" : "wifi.slash")
                            .font(RelayTheme.font(size: 8, weight: .medium))
                    } else {
                        Circle()
                            .fill(nodeConnected ? RelayTheme.mint : RelayTheme.textFaint)
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityLabel(nodeConnected ? "Connected" : "Disconnected")
                Text(group.name)
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
                    .lineLimit(1)
                Spacer()
                Text("\(group.sessions.count)")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.textFaint)
            }
            .padding(.horizontal, RelayTheme.spacing(8))
            .frame(height: 30)

            ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                let fallback = group.sessions.count == 1 ? "Session" : "Session \(index + 1)"
                AttachedSessionRow(
                    session: session,
                    label: workspace.sessionDisplayName(session.id, fallback: fallback),
                    workspace: workspace,
                    marks: marks
                )
            }
        }
        .padding(.bottom, RelayTheme.spacing(7))
    }
}

private struct AttachedSessionRow: View {
    let session: SessionTabGroup
    let label: String
    @ObservedObject var workspace: WorkspaceModel
    let marks: [UUID: RelayWorkOverviewIndex.PaneStatus]

    private var selected: Bool { session.tabs.contains { $0.id == workspace.selectedTabID } }
    private var expanded: Bool { workspace.navigationState.isExpanded(.session, id: session.id) }
    private var panes: [PaneModel] {
        session.tabs.flatMap(\.allPaneIDs).compactMap { workspace.panes[$0] }
    }
    var body: some View {
        VStack(spacing: RelayTheme.spacing(1)) {
            HStack(spacing: RelayTheme.spacing(3)) {
                Button { workspace.toggleNavigationGroup(.session, id: session.id) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(RelayTheme.font(size: 8.5, weight: .medium))
                        .frame(width: 24, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textFaint)
                .help(expanded ? "Collapse session" : "Expand session")
                .accessibilityIdentifier("relay.navigation.session-disclosure." + session.id.uuidString.lowercased())
                Button {
                    workspace.selectSession(session.id, origin: .user)
                } label: {
                HStack(spacing: RelayTheme.spacing(7)) {
                    Capsule()
                        .fill(selected ? RelayTheme.accent : Color.clear)
                        .frame(width: 2, height: 16)
                    Image(systemName: "rectangle.stack")
                        .font(RelayTheme.font(size: 9, weight: .medium))
                        .foregroundStyle(selected ? RelayTheme.textMuted : RelayTheme.textFaint)
                    if workspace.isSessionPinned(session.id) {
                        Image(systemName: "pin.fill")
                            .font(RelayTheme.font(size: 7.5, weight: .medium))
                            .foregroundStyle(RelayTheme.textFaint)
                    }
                    Text(label)
                        .font(RelayTheme.font(size: 11.5, weight: .medium))
                        .foregroundStyle(selected ? RelayTheme.text : RelayTheme.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    RelayAttentionSummary(paneIDs: panes.map(\.id),
                                          status: RelayWorkOverviewIndex.mostUrgent(session.tabs.map(\.id), in: marks))
                    Text("\(session.tabs.count) tab\(session.tabs.count == 1 ? "" : "s")")
                        .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.textFaint)
                }
                .padding(.horizontal, RelayTheme.spacing(6))
                .frame(height: 34)
                .background(Color.clear)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(workspace.isSessionPinned(session.id) ? "Unpin session" : "Pin session") {
                        workspace.toggleSessionPin(session.id)
                    }
                    Button("New tab") { workspace.newTab(inSession: session.id) }
                    Button("Rename session…") { workspace.beginRenameSession(session.id, fallback: label) }
                    Button("Copy Session ID") { copyWorkspaceID(session.id) }
                    Divider()
                    Button("Detach session") { workspace.closeSession(session.id) }
                }
                Button { workspace.newTab(inSession: session.id) } label: {
                    Image(systemName: "plus")
                        .font(RelayTheme.font(size: 9, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help("New tab in session")
            }

            if expanded {
                ForEach(session.tabs) { tab in
                    let tabIndex = session.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
                    SessionTabSection(
                        tab: tab,
                        fallbackLabel: tabIndex == 0 ? "Main" : "Tab \(tabIndex + 1)",
                        workspace: workspace,
                        status: marks[tab.id]
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label), \(session.tabs.count) tabs, \(panes.count) panes")
    }
}

private struct SessionTabSection: View {
    @ObservedObject var tab: TabModel
    let fallbackLabel: String
    @ObservedObject var workspace: WorkspaceModel
    let status: RelayWorkOverviewIndex.PaneStatus?
    private var expanded: Bool { workspace.navigationState.isExpanded(.tab, id: tab.id) }

    init(tab: TabModel, fallbackLabel: String, workspace: WorkspaceModel, status: RelayWorkOverviewIndex.PaneStatus?) {
        self.tab = tab
        self.fallbackLabel = fallbackLabel
        self.workspace = workspace
        self.status = status
    }

    private var panes: [PaneModel] { tab.allPaneIDs.compactMap { workspace.panes[$0] } }
    private var displayName: String { workspace.tabDisplayName(tab, fallback: fallbackLabel) }

    var body: some View {
        VStack(spacing: RelayTheme.spacing(1)) {
            HStack(spacing: RelayTheme.spacing(4)) {
                Button {
                    workspace.toggleNavigationGroup(.tab, id: tab.id)
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(RelayTheme.font(size: 8, weight: .medium))
                        .frame(width: 16, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textFaint)
                .accessibilityLabel(expanded ? "Collapse tab" : "Expand tab")

                Button {
                    workspace.selectTab(tab.id, origin: .user)
                } label: {
                    HStack(spacing: RelayTheme.spacing(6)) {
                        Image(systemName: "rectangle")
                            .font(RelayTheme.font(size: 8.5, weight: .medium))
                        if workspace.isTabPinned(tab.id) {
                            Image(systemName: "pin.fill")
                                .font(RelayTheme.font(size: 7, weight: .medium))
                        }
                        Text(displayName)
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        RelayAttentionSummary(paneIDs: panes.map(\.id), status: status)
                        Text("\(panes.count)")
                            .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(tab.id == workspace.selectedTabID ? RelayTheme.text : RelayTheme.textMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(workspace.isTabPinned(tab.id) ? "Unpin tab" : "Pin tab") {
                        workspace.toggleTabPin(tab.id)
                    }
                    Button("Rename tab…") { workspace.beginRenameTab(tab.id) }
                    Button("Copy Tab ID") { copyWorkspaceID(tab.id) }
                    Toggle("Auto-link agent panes in this tab", isOn: Binding(
                        get: { RelayAutoLinker.shared.isEnabled(.tab(tab.id)) },
                        set: { _ in RelayAutoLinker.shared.toggle(.tab(tab.id), workspace: workspace) }))
                    Toggle("Allow agents to broadcast in this tab", isOn: Binding(
                        get: { RelayAutoLinker.shared.allowsBroadcast(.tab(tab.id)) },
                        set: { _ in RelayAutoLinker.shared.toggleBroadcast(.tab(tab.id)) }))
                    Button("Close tab") { workspace.closeTab(tab.id) }
                }
            }
            .padding(.leading, RelayTheme.spacing(21))
            .padding(.trailing, RelayTheme.spacing(9))
            .frame(height: 30)
            .background(
                Color.clear,
                in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6), style: .continuous)
            )

            if expanded {
                ForEach(panes) { pane in
                    SessionPaneRow(
                        pane: pane,
                        tabID: tab.id,
                        workspace: workspace,
                        active: pane.id == workspace.activePaneID && tab.id == workspace.selectedTabID
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab \(displayName), \(panes.count) panes")
    }
}

private struct PanePresence: View {
    @ObservedObject var pane: PaneModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Group {
            if differentiateWithoutColor {
                Image(systemName: pane.phase == .needsInput ? "exclamationmark" : pane.kind == .shell ? "terminal" : "bolt.fill")
                    .font(RelayTheme.font(size: 7, weight: .medium))
            } else {
                Circle()
                    .fill(pane.phase == .needsInput ? RelayTheme.coral : pane.kind == .shell ? RelayTheme.textFaint : RelayTheme.mint)
                    .frame(width: 5, height: 5)
            }
        }
            .help("\(pane.harnessLabel): \(pane.phase.label)")
            .accessibilityLabel("\(pane.harnessLabel): \(pane.phase.label)")
    }
}

/// Panes needing attention, above the session tree and the workspaces:
/// waiting on the user first. Opening a row shows its pane, which reads its
/// alerts; a pane still waiting keeps its row until it goes on or is
/// dismissed. The first rows show; the rest behind "Show more".
struct AttentionInboxSection: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var inbox: AgentIntelligenceStore = .shared
    var identifier = "relay.sidebar.attention-inbox"

    var body: some View {
        // Waiting is a pane phase; the activity index redraws on it.
        AttentionInboxRows(workspace: workspace, activityIndex: workspace.activityIndex, inbox: inbox,
                           hold: workspace.navigatorHoldState, identifier: identifier)
    }
}

private struct AttentionInboxRows: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var activityIndex: WorkspaceActivityIndex
    @ObservedObject var inbox: AgentIntelligenceStore
    @ObservedObject var hold: WorkspaceNavigatorHold
    let identifier: String
    @State private var showingAll = false

    var body: some View {
        let _ = activityIndex.revision
        let entries = workspace.shownAttentionInbox(inbox: inbox)
        if !entries.isEmpty {
            let collapsed = workspace.navigationState.isAttentionInboxCollapsed
            let page = AttentionInboxPage.visible(entries, showingAll: showingAll)
            VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                // Only this click collapses or expands; new rows never do.
                Button { workspace.setAttentionInboxCollapsed(!collapsed) } label: {
                    HStack(spacing: RelayTheme.spacing(7)) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(RelayTheme.font(size: 8, weight: .semibold))
                            .frame(width: 10)
                        Text("Needs attention")
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text("\(entries.count)")
                            .font(RelayTheme.font(size: 10, weight: .semibold))
                            .foregroundStyle(RelayTheme.text)
                            .padding(.horizontal, RelayTheme.spacing(6))
                            .frame(minWidth: 18, minHeight: 16)
                            .background(RelayTheme.accent.opacity(0.28), in: Capsule())
                        // Held under the pointer, new rows wait for release;
                        // their count shows here, in the header's own line.
                        let arrived = workspace.attentionArrivedWhileHeld(inbox: inbox)
                        if arrived > 0 {
                            Text("+\(arrived) new")
                                .font(RelayTheme.font(size: 10, weight: .semibold))
                                .foregroundStyle(RelayTheme.coral)
                                .lineLimit(1)
                                .accessibilityIdentifier("\(identifier).arrived")
                        }
                        Spacer()
                    }
                    .foregroundStyle(RelayTheme.textMuted)
                    .padding(.horizontal, RelayTheme.spacing(6))
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show panes needing attention" : "Hide panes needing attention")
                .accessibilityIdentifier("\(identifier).toggle")
                if !collapsed {
                    ForEach(page.rows) { entry in
                        AttentionInboxRow(entry: entry, workspace: workspace,
                                          identifier: identifier.replacingOccurrences(of: "attention-inbox", with: "attention"))
                    }
                    if page.hiddenCount > 0 || showingAll && entries.count > AttentionInboxPage.limit {
                        Button(page.hiddenCount > 0 ? "Show \(page.hiddenCount) more" : "Show fewer") { showingAll.toggle() }
                            .buttonStyle(RelayQuietButtonStyle())
                            .accessibilityIdentifier("\(identifier).more")
                    }
                }
            }
            .padding(.bottom, RelayTheme.spacing(6))
            .accessibilityIdentifier(identifier)
        }
    }
}

/// An inbox row's two lines: the tab (or, without one, the pane) once, then
/// the status and its workspace once, so neither line repeats the other. The
/// pane is named before the status only when its tab has several panes.
struct AttentionInboxRowText: Equatable {
    let title: String
    let subtitle: String

    init(pane: String?, tab: String?, workspace: String?, status: String, closed: Bool, multiPane: Bool = false) {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let tab = clean(tab)
        title = tab ?? clean(pane) ?? "Pane"
        let status = closed ? "Closed" : status
        var parts: [String] = []
        if multiPane, tab != nil, let pane = clean(pane), pane != title { parts.append(pane) }
        parts.append(status)
        if let workspace = clean(workspace), workspace != title, !status.contains(workspace) {
            parts.append(workspace)
        }
        subtitle = parts.joined(separator: " · ")
    }
}

private struct AttentionInboxRow: View {
    let entry: AttentionInboxEntry
    @ObservedObject var workspace: WorkspaceModel
    let identifier: String

    private var text: AttentionInboxRowText {
        let tabID = workspace.tabID(containingPane: entry.paneID)
        let tab = tabID.flatMap { id in workspace.tabs.first { $0.id == id } }
        return AttentionInboxRowText(pane: workspace.panes[entry.paneID]?.displayName,
                                     tab: tab.map { workspace.tabDisplayName($0, fallback: "") },
                                     workspace: tabID.flatMap(workspace.workspaceID(forTab:))
                                        .flatMap { workspace.ownership.workspace($0)?.name },
                                     status: entry.title.isEmpty ? entry.alert.label : entry.title,
                                     closed: workspace.panes[entry.paneID] == nil,
                                     multiPane: (tab?.allPaneIDs.count ?? 0) > 1)
    }

    var body: some View {
        let alert = entry.alert
        // A pane closed while the inbox is held keeps its row until release.
        let closed = workspace.panes[entry.paneID] == nil
        Button {
            // Selecting the pane reads its alerts, also when it is already
            // in front; a pane that cannot be shown keeps its row.
            workspace.revealPane(entry.paneID, origin: .user)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: RelayTheme.spacing(7)) {
                Image(systemName: alert.symbol)
                    .font(RelayTheme.font(size: 9.5, weight: .semibold))
                    .foregroundStyle(alert.color)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                    Text(text.title)
                        .font(RelayTheme.font(size: 11.5, weight: .medium))
                        .foregroundStyle(RelayTheme.text)
                        .lineLimit(1)
                    Text(text.subtitle)
                        .font(RelayTheme.font(size: 10.5))
                        .foregroundStyle(RelayTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RelayTheme.spacing(8))
            .padding(.vertical, RelayTheme.spacing(5))
            .background(RelayTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
            .opacity(closed ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(closed)
        .help("\(alert.label) · \(text.title) · \(text.subtitle)")
        .accessibilityLabel("\(alert.label), \(text.title), \(text.subtitle)")
        .accessibilityIdentifier("\(identifier).\(entry.paneID.uuidString.lowercased())")
        .contextMenu { Button("Dismiss") { workspace.dismissAttention(entry.paneID) } }
    }
}

/// The most urgent unread alert among some panes (done, needs input, error),
/// with how many panes have one. Selecting a pane clears its alert.
/// A row's unread alert marker, then its status mark. One icon per meaning:
/// the waiting mark gives way to a "needs you" alert already shown.
private struct RelayAttentionSummary: View {
    let paneIDs: [UUID]
    var status: RelayWorkOverviewIndex.PaneStatus?
    @ObservedObject private var inbox = AgentIntelligenceStore.shared

    var body: some View {
        let alerts = paneIDs.compactMap { inbox.marker(for: $0) }
        let shown = alerts.min(by: { $0.rank < $1.rank })
        alertMarker(alerts, shown)
        RelayStatusMark(status: RelayStatusMark.status(status, besideAlert: shown))
    }

    @ViewBuilder private func alertMarker(_ alerts: [RelayAttentionAlert], _ shown: RelayAttentionAlert?) -> some View {
        if shown == .done {
            // Finished, not yet seen: a calm dot, not the checkmark.
            let count = alerts.filter { $0 == .done }.count
            Circle().fill(RelayTheme.StatusRole.info.color).frame(width: 6, height: 6)
                .help(RelayFinishedDot.label(count))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(RelayFinishedDot.label(count))
        } else if let alert = shown {
            let count = alerts.filter { $0 == alert }.count
            HStack(spacing: RelayTheme.spacing(2)) {
                Image(systemName: alert.symbol)
                    .font(RelayTheme.font(size: 9.5, weight: .semibold))
                if count > 1 {
                    Text("\(count)").font(RelayTheme.font(size: 10, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(alert.color)
            .help(count > 1 ? "\(count) panes: \(alert.label)" : alert.label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(count > 1 ? "\(count) panes: \(alert.label)" : alert.label)
        }
    }
}

private struct SessionPaneRow: View {
    @ObservedObject var pane: PaneModel
    let tabID: UUID
    @ObservedObject var workspace: WorkspaceModel
    let active: Bool
    @StateObject private var attention = AgentAttentionController()
    @State private var hovering = false
    @State private var agentThreadsExpanded = false
    @State private var showingAllAgents = false
    @State private var agentQuery = ""

    private var tab: TabModel? { workspace.tabs.first { $0.id == tabID } }
    private var isFloating: Bool { tab?.floatingPanes.contains(where: { $0.paneID == pane.id }) == true }
    private var focusedAgents: [SubagentActivity] {
        attention.snapshot.visibleIDs.compactMap { id in pane.subagents.first { $0.id == id } }
    }
    private var searchedAgents: [SubagentActivity] {
        let query = agentQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return pane.subagents
            .filter { agent in
                guard !query.isEmpty else { return true }
                return [agent.label, agent.id, agent.provider.label, agent.updates.last?.message ?? ""]
                    .joined(separator: " ").lowercased().contains(query)
            }
            .sorted { agentActivityDate($0) > agentActivityDate($1) }
    }

    private func revealPane(origin: PaneSelectionOrigin = .programmatic) {
        if workspace.networkVisible || workspace.selectedTabID != tabID { workspace.selectTab(tabID) }
        workspace.selectPane(pane.id, origin: origin)
        workspace.networkVisible = false
        pane.focus()
    }

    private func agentActivityDate(_ agent: SubagentActivity) -> Date {
        agent.updates.last?.occurredAt ?? agent.completedAt ?? agent.startedAt
    }

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            Button(action: { revealPane(origin: .user) }) {
                HStack(spacing: RelayTheme.spacing(7)) {
                Capsule()
                    .fill(active ? RelayTheme.accent : Color.clear)
                    .frame(width: 2, height: 16)
                Image(systemName: pane.contentKind == .editor ? "curlybraces" : pane.kind.symbol)
                    .font(RelayTheme.font(size: 9.5, weight: .medium))
                    .foregroundStyle(pane.contentKind == .editor ? RelayTheme.blue : pane.phaseColor)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(1)) {
                    Text(pane.contentKind == .editor ? pane.displayName : pane.kind == .shell ? pane.displayName : pane.harnessLabel)
                        .font(RelayTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(active ? RelayTheme.text : RelayTheme.textMuted)
                        .lineLimit(1)
                    if pane.contentKind == .terminal && pane.kind != .shell && (active || pane.phase == .needsInput) {
                        Text(AgentLabelFormatter.activity(pane.activitySummary))
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .foregroundStyle(RelayTheme.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if pane.activeSubagents > 0 {
                    Text("\(pane.activeSubagents)")
                        .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.mint)
                }
                if isFloating {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(RelayTheme.font(size: 8.5, weight: .medium))
                        .foregroundStyle(RelayTheme.textFaint)
                        .help("Floating pane")
                }
                RelayAttentionSummary(paneIDs: [pane.id])
                Circle().fill(pane.connectionState.color).frame(width: 5, height: 5)
                }
                .padding(.leading, RelayTheme.spacing(22))
                .padding(.trailing, pane.subagents.isEmpty ? 9 : 54)
                .frame(height: pane.contentKind == .terminal && pane.kind != .shell && (active || pane.phase == .needsInput) ? 38 : 30)
                .background(active ? RelayTheme.hover.opacity(0.35) : hovering ? RelayTheme.surface.opacity(0.7) : Color.clear,
                            in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7), style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Rename pane…") { workspace.beginRenamePane(pane.id) }
                Button("Copy Pane ID") { copyWorkspaceID(pane.id) }
                if pane.contentKind == .terminal {
                    Button("Connect with other sessions…") {
                        NotificationCenter.default.post(name: .relayConnectPaneSessions, object: pane.id)
                    }
                    Menu("Agent type") {
                        ForEach(AgentKind.allCases, id: \.self) { kind in
                            Button {
                                pane.setAgentKind(kind)
                            } label: {
                                Label(kind.label, systemImage: pane.kind == kind ? "checkmark" : kind.symbol)
                            }
                        }
                    }
                    RelayAgentAccountMenus(pane: pane)
                }
                Divider()
                Button("Split right") {
                    revealPane()
                    workspace.splitActive(axis: .horizontal)
                }
                Button("Split down") {
                    revealPane()
                    workspace.splitActive(axis: .vertical)
                }
                Button("Show pane") { revealPane(origin: .user) }
                Button("Zoom pane") {
                    revealPane()
                    workspace.togglePaneZoom(pane.id)
                }
                Button(isFloating ? "Dock pane" : "Float pane") {
                    revealPane()
                    workspace.toggleActivePaneFloating()
                }
                Divider()
                Button(pane.profile.kind == .ssh ? "Detach pane" : "Close pane") {
                    revealPane()
                    workspace.closeActivePane()
                }
                if pane.profile.kind == .ssh && pane.profile.backend == .relay {
                    Button("Terminate remote pane…", role: .destructive) {
                        workspace.requestTerminatePane(pane.id)
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if pane.contentKind == .terminal && pane.kind != .shell && !pane.subagents.isEmpty {
                    Button {
                        agentThreadsExpanded.toggle()
                    } label: {
                        HStack(spacing: RelayTheme.spacing(5)) {
                            AgentPulse(phase: pane.phase, activeCount: pane.activeSubagents)
                            Text(pane.activeSubagents > 0 ? "\(pane.activeSubagents)/\(pane.subagents.count)" : "\(pane.subagents.count)")
                                .font(RelayTheme.font(size: 8, weight: .medium, design: .rounded))
                            Image(systemName: agentThreadsExpanded ? "chevron.down" : "chevron.right")
                                .font(RelayTheme.font(size: 8, weight: .medium))
                        }
                        .frame(minWidth: 45, minHeight: 29)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.textFaint)
                    .padding(.trailing, RelayTheme.spacing(3))
                    .help(agentThreadsExpanded ? "Hide agent focus" : "Show agent focus")
                    .accessibilityLabel(agentThreadsExpanded ? "Hide agent focus" : "Show agent focus, \(pane.activeSubagents) active")
                }
            }

            if agentThreadsExpanded && !workspace.networkVisible {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                    HStack(spacing: RelayTheme.spacing(6)) {
                        Text(showingAllAgents ? "Agent threads" : "Recent activity")
                            .font(RelayTheme.font(size: 8, weight: .medium, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(RelayTheme.textFaint)
                        if attention.snapshot.attentionCount > 0 {
                            Text("\(attention.snapshot.attentionCount) need you")
                                .font(RelayTheme.font(size: 8, weight: .medium))
                                .foregroundStyle(RelayTheme.coral)
                        }
                        Spacer()
                        if showingAllAgents {
                            Button("Done") {
                                showingAllAgents = false
                                agentQuery = ""
                            }
                            .buttonStyle(.plain)
                            .font(RelayTheme.font(size: 9, weight: .medium))
                            .foregroundStyle(RelayTheme.textMuted)
                        } else {
                            Button {
                                attention.refine(agents: pane.subagents, paneID: pane.id)
                            } label: {
                                Image(systemName: attention.isRefining
                                      ? "hourglass"
                                      : attention.snapshot.usedSystemIntelligence
                                      ? "wand.and.stars.inverse"
                                      : "wand.and.stars")
                                    .font(RelayTheme.font(size: 8, weight: .medium))
                                    .foregroundStyle(attention.snapshot.usedSystemIntelligence
                                                     ? RelayTheme.mint : RelayTheme.textFaint)
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.plain)
                            .disabled(attention.isRefining)
                            .help(attention.snapshot.usedSystemIntelligence
                                  ? "Focus order refined on this Mac"
                                  : "Refine focus on this Mac")
                            .accessibilityLabel(attention.snapshot.usedSystemIntelligence
                                                ? "Focus order refined on this Mac"
                                                : "Refine focus on this Mac")
                        }
                    }
                    .padding(.leading, RelayTheme.spacing(43))
                    .padding(.trailing, RelayTheme.spacing(9))
                    .padding(.top, RelayTheme.spacing(4))

                    if showingAllAgents {
                        HStack(spacing: RelayTheme.spacing(6)) {
                            Image(systemName: "magnifyingglass")
                                .font(RelayTheme.font(size: 9, weight: .medium))
                                .foregroundStyle(RelayTheme.textFaint)
                            TextField("Find a thread", text: $agentQuery)
                                .textFieldStyle(.plain)
                                .font(RelayTheme.font(size: 10.5))
                                .accessibilityLabel("Find an agent thread")
                        }
                        .padding(.horizontal, RelayTheme.spacing(8))
                        .frame(height: 26)
                        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7), style: .continuous))
                        .padding(.leading, RelayTheme.spacing(35))
                        .padding(.trailing, RelayTheme.spacing(7))
                    }

                    ForEach(showingAllAgents ? searchedAgents : focusedAgents) { subagent in
                        AgentFocusRow(
                            agent: subagent,
                            pinned: attention.isPinned(subagent.id, paneID: pane.id),
                            open: { workspace.inspectAgent(paneID: pane.id, subagentID: subagent.id) },
                            togglePin: { attention.togglePin(agentID: subagent.id, paneID: pane.id, agents: pane.subagents) },
                            hide: { attention.toggleMute(agentID: subagent.id, paneID: pane.id, agents: pane.subagents) }
                        )
                    }

                    if showingAllAgents && searchedAgents.isEmpty {
                        Text("No matching threads")
                            .font(RelayTheme.font(size: 11))
                            .foregroundStyle(RelayTheme.textFaint)
                            .padding(.leading, RelayTheme.spacing(43))
                            .frame(height: 25)
                    } else if !showingAllAgents && attention.snapshot.hiddenCount > 0 {
                        Button {
                            showingAllAgents = true
                        } label: {
                            HStack(spacing: RelayTheme.spacing(6)) {
                                Image(systemName: "magnifyingglass")
                                    .font(RelayTheme.font(size: 8.5, weight: .medium))
                                Text("Search \(attention.snapshot.hiddenCount) more")
                                    .font(RelayTheme.font(size: 11, weight: .medium))
                            }
                            .foregroundStyle(RelayTheme.textFaint)
                            .padding(.leading, RelayTheme.spacing(43))
                            .frame(height: 25)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows searchable agent history")
                    }
                }
                .padding(.bottom, RelayTheme.spacing(4))
            }
        }
        .onAppear {
            attention.scheduleRefresh(agents: pane.subagents, paneID: pane.id)
            agentThreadsExpanded = active && !pane.subagents.isEmpty
        }
        .onChange(of: active) { _, isActive in
            agentThreadsExpanded = isActive && !pane.subagents.isEmpty
            if !isActive {
                showingAllAgents = false
                agentQuery = ""
            }
        }
        .onChange(of: pane.subagents) { _, agents in
            attention.scheduleRefresh(agents: agents, paneID: pane.id)
            // A restored or busy agent can publish several structured events
            // in one display frame. Avoid repeatedly assigning the same view
            // state from onChange, which causes SwiftUI re-entrant frame work.
            if active && !agents.isEmpty && !agentThreadsExpanded {
                agentThreadsExpanded = true
            }
        }
    }
}

private struct AgentPulse: View {
    let phase: AgentPhase
    let activeCount: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: RelayTheme.spacing(1.5)) {
            ForEach([4.0, 7.0, 5.0], id: \.self) { height in
                Capsule()
                    .fill(phase == .needsInput ? RelayTheme.coral : activeCount > 0 ? RelayTheme.mint : RelayTheme.textFaint)
                    .frame(width: 1.5, height: height)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

private struct AgentFocusRow: View {
    let agent: SubagentActivity
    let pinned: Bool
    let open: () -> Void
    let togglePin: () -> Void
    let hide: () -> Void
    @State private var hovering = false

    var body: some View {
        let displayLabel = AgentAttentionPolicy.displayLabel(for: agent)
        Button(action: open) {
            HStack(spacing: RelayTheme.spacing(7)) {
                ZStack {
                    Rectangle()
                        .fill(RelayTheme.line.opacity(0.7))
                        .frame(width: 1, height: 26)
                    Circle()
                        .fill(agent.phase.color)
                        .frame(width: agent.phase == .needsInput ? 7 : 5,
                               height: agent.phase == .needsInput ? 7 : 5)
                }
                .frame(width: 9)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(1)) {
                    HStack(spacing: RelayTheme.spacing(4)) {
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(RelayTheme.font(size: 7))
                                .foregroundStyle(RelayTheme.textFaint)
                        }
                        Text(displayLabel)
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .foregroundStyle(agent.phase == .exited ? RelayTheme.textFaint : RelayTheme.textMuted)
                            .lineLimit(1)
                    }
                    Text(agent.provider.label)
                        .font(RelayTheme.font(size: 11, weight: .regular))
                        .foregroundStyle(RelayTheme.textFaint)
                }
                Spacer(minLength: 2)
                Text(agent.phase.label)
                    .font(RelayTheme.font(size: 11, weight: .regular))
                    .foregroundStyle(agent.phase.color)
                    .lineLimit(1)
            }
            .padding(.leading, RelayTheme.spacing(39))
            .padding(.trailing, RelayTheme.spacing(9))
            .frame(height: 31)
            .background(hovering ? RelayTheme.surface.opacity(0.55) : Color.clear,
                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6), style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(displayLabel) activity")
        .contextMenu {
            Button(pinned ? "Unpin from focus" : "Pin in focus", action: togglePin)
            Button(agent.phase == .needsInput ? "Needs input cannot be hidden" : "Hide from focus", action: hide)
                .disabled(agent.phase == .needsInput)
        }
        .accessibilityLabel("\(displayLabel), \(agent.provider.label), \(agent.phase.label)")
        .accessibilityHint("Opens this agent thread in a floating panel")
    }
}

private struct HostLauncher: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var store: ProfileStore
    @State private var query = ""
    @State private var selectedProfile: ConnectionProfile?
    @State private var remoteCatalog: RemoteCatalogSnapshot?
    @State private var catalogError: String?
    @State private var loadingCatalog = false
    @State private var catalogRetryTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        self.store = workspace.profileStore
    }

    private var filteredHosts: [ConnectionProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.connectableHosts }
        let ranked: [(profile: ConnectionProfile, score: Int, index: Int)] = store.connectableHosts
            .enumerated()
            .compactMap { index, profile in
                let searchable = [profile.name, profile.host, profile.subtitle].joined(separator: " ")
                guard let score = HostSearch.score(query: needle, candidate: searchable) else { return nil }
                return (profile: profile, score: score, index: index)
            }
        return ranked
        .sorted { lhs, rhs in lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score < rhs.score }
        .map(\.profile)
    }

    private var typedHost: ConnectionProfile? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains(where: \Character.isWhitespace),
              filteredHosts.isEmpty,
              !store.connectableHosts.contains(where: { $0.host.caseInsensitiveCompare(value) == .orderedSame })
        else { return nil }
        return .sshConfigHost(value)
    }

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack(spacing: RelayTheme.spacing(12)) {
                Image(systemName: "magnifyingglass")
                    .font(RelayTheme.font(size: 16, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
                TextField(selectedProfile == nil ? "Search hosts or enter an SSH alias…" : "Sessions", text: $query)
                    .textFieldStyle(.plain)
                    .font(RelayTheme.font(size: 16, weight: .regular))
                    .foregroundStyle(RelayTheme.text)
                    .focused($searchFocused)
                    .onSubmit(connectFirstResult)
                    .disabled(selectedProfile != nil)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.textFaint)
                }
                Text("esc")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
                    .padding(.horizontal, RelayTheme.spacing(7))
                    .padding(.vertical, RelayTheme.spacing(4))
                    .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6), style: .continuous))
            }
            .padding(.horizontal, RelayTheme.spacing(14))
            .frame(height: 48)
            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(4), style: .continuous))
            .padding(RelayTheme.spacing(16))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: RelayTheme.spacing(6)) {
                    if let selectedProfile {
                        HStack {
                            Button {
                                self.selectedProfile = nil
                                remoteCatalog = nil
                                catalogError = nil
                                query = ""
                            } label: {
                                Label("Hosts", systemImage: "chevron.left")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(RelayTheme.textMuted)
                            Spacer()
                            Text(selectedProfile.kind == .local ? "This Mac" : selectedProfile.name)
                                .font(RelayTheme.font(size: 11.5, weight: .medium))
                                .foregroundStyle(RelayTheme.text)
                        }
                        .padding(.horizontal, RelayTheme.spacing(8))
                        .padding(.vertical, RelayTheme.spacing(5))

                        if loadingCatalog {
                            HStack(spacing: RelayTheme.spacing(10)) {
                                ProgressView().controlSize(.small)
                                Text("Reading Relay sessions…")
                                    .font(RelayTheme.font(size: 12))
                                    .foregroundStyle(RelayTheme.textMuted)
                            }
                            .padding(RelayTheme.spacing(16))
                        } else {
                            HostResultRow(
                                title: "New session",
                                subtitle: "Start a new durable workspace on \(selectedProfile.name)",
                                symbol: "plus.rectangle.on.rectangle",
                                badge: "New"
                            ) { workspace.newTab(profile: selectedProfile) }

                            if let catalogError {
                                VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                                    Text(catalogError)
                                        .font(RelayTheme.font(size: 11.5))
                                        .foregroundStyle(RelayTheme.coral)
                                        .lineLimit(3)
                                    Button("Retry") { loadCatalog(for: selectedProfile) }
                                        .buttonStyle(.plain)
                                        .font(RelayTheme.font(size: 11.5, weight: .medium))
                                        .foregroundStyle(RelayTheme.blue)
                                }
                                .padding(RelayTheme.spacing(12))
                            } else if let sessions = remoteCatalog?.sessions, !sessions.isEmpty {
                                Text("On this host")
                                    .font(RelayTheme.font(size: 11, weight: .medium))
                                    .foregroundStyle(RelayTheme.textMuted)
                                    .padding(.horizontal, RelayTheme.spacing(8))
                                    .padding(.top, RelayTheme.spacing(8))
                                ForEach(sessions) { session in
                                    RemoteSessionResultRow(
                                        session: session,
                                        attachedPaneIDs: Set(workspace.panes.keys),
                                        recoverInNewWindow: {
                                            workspace.attachRemoteSession(profile: selectedProfile, remote: session, inNewWindow: true)
                                        },
                                        attachSession: {
                                            workspace.attachRemoteSession(profile: selectedProfile, remote: session)
                                        },
                                        recoverPane: { pane in
                                            workspace.attachRemotePane(
                                                profile: selectedProfile,
                                                remotePane: pane,
                                                workspaceID: session.workspaceID,
                                                sessionLabel: session.label
                                            )
                                        }
                                    )
                                }
                            } else {
                                Text("No detached Relay sessions here.")
                                    .font(RelayTheme.font(size: 11.5))
                                    .foregroundStyle(RelayTheme.textMuted)
                                    .padding(RelayTheme.spacing(12))
                            }
                        }
                    } else {
                        Text(query.isEmpty ? "Recent and configured" : "Matches")
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .foregroundStyle(RelayTheme.textMuted)
                            .padding(.horizontal, RelayTheme.spacing(8))
                            .padding(.top, RelayTheme.spacing(5))

                        if query.isEmpty {
                            HostResultRow(
                                title: "This Mac",
                                subtitle: "Open a local login shell",
                                symbol: "laptopcomputer",
                                badge: "Local"
                            ) { workspace.newTab(profile: .local) }
                            HostResultRow(
                                title: "Recover local sessions",
                                subtitle: "Reattach existing terminals on this Mac",
                                symbol: "lifepreserver",
                                badge: "Recover"
                            ) { selectHost(.local) }
                        }

                        ForEach(filteredHosts) { profile in
                            HostResultRow(
                                title: profile.name,
                                subtitle: profile.usesSSHConfig ? "SSH config" : profile.subtitle,
                                symbol: "server.rack",
                                badge: profile.backend == .relay ? "Sessions" : "Direct"
                            ) {
                                if profile.backend == .relay { selectHost(profile) }
                                else { workspace.newTab(profile: profile) }
                            }
                        }

                        if let typedHost {
                            Text("Connect directly")
                                .font(RelayTheme.font(size: 11, weight: .medium))
                                .foregroundStyle(RelayTheme.textMuted)
                                .padding(.horizontal, RelayTheme.spacing(8))
                                .padding(.top, RelayTheme.spacing(8))
                            HostResultRow(
                                title: typedHost.host,
                                subtitle: "Use this SSH hostname or config alias",
                                symbol: "arrow.right.circle.fill",
                                badge: "Inspect"
                            ) { selectHost(typedHost) }
                        }

                        if filteredHosts.isEmpty && typedHost == nil {
                            VStack(spacing: RelayTheme.spacing(8)) {
                                Image(systemName: "network.slash")
                                    .font(RelayTheme.font(size: 24, weight: .medium))
                                    .foregroundStyle(RelayTheme.textFaint)
                                Text("No SSH host matches “\(query)”")
                                    .font(RelayTheme.font(size: 13, weight: .medium))
                                    .foregroundStyle(RelayTheme.text)
                                Text("Try an alias from ~/.ssh/config or enter a hostname.")
                                    .font(RelayTheme.font(size: 11.5))
                                    .foregroundStyle(RelayTheme.textMuted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, RelayTheme.spacing(42))
                        }
                    }
                }
                .padding(RelayTheme.spacing(12))
            }

            HStack {
                Label("SSH config, keys and ProxyJump stay with OpenSSH", systemImage: "key.horizontal")
                    .font(RelayTheme.font(size: 10.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
                Spacer()
                Button("Edit connection…") {
                    workspace.isHostLauncherPresented = false
                    Task { @MainActor in
                        await Task.yield()
                        workspace.presentConnectionSheet()
                    }
                }
                .buttonStyle(.plain)
                .font(RelayTheme.font(size: 11.5, weight: .medium))
                .foregroundStyle(RelayTheme.blue)
            }
            .padding(.horizontal, RelayTheme.spacing(18))
            .frame(height: 48)
            .background(RelayTheme.surface.opacity(0.45))
        }
        .frame(width: 640, height: 520)
        .background(RelayTheme.sidebar)
        .relaySurface()
        .onAppear { searchFocused = true }
        .onDisappear { catalogRetryTask?.cancel() }
        .onExitCommand { workspace.isHostLauncherPresented = false }
    }

    private func connectFirstResult() {
        guard selectedProfile == nil else { return }
        if let first = filteredHosts.first {
            if first.backend == .relay { selectHost(first) }
            else { workspace.newTab(profile: first) }
        } else if let typedHost {
            selectHost(typedHost)
        }
    }

    private func selectHost(_ profile: ConnectionProfile) {
        selectedProfile = profile
        query = ""
        loadCatalog(for: profile)
    }

    private func loadCatalog(for profile: ConnectionProfile) {
        catalogRetryTask?.cancel()
        catalogRetryTask = nil
        loadingCatalog = true
        catalogError = nil
        remoteCatalog = nil
        Task {
            do {
                let result = try await RemoteCatalogService.load(profile: profile)
                guard selectedProfile?.connectionKey == profile.connectionKey else { return }
                remoteCatalog = result
            } catch {
                guard selectedProfile?.connectionKey == profile.connectionKey else { return }
                catalogError = error.localizedDescription
                if let remoteError = error as? RemoteCatalogError,
                   remoteError.shouldRetryAutomatically {
                    catalogRetryTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled,
                              selectedProfile?.connectionKey == profile.connectionKey else { return }
                        loadCatalog(for: profile)
                    }
                }
            }
            loadingCatalog = false
        }
    }
}

private struct RemoteSessionResultRow: View {
    let session: RemoteSessionRecord
    let attachedPaneIDs: Set<UUID>
    let recoverInNewWindow: () -> Void
    let attachSession: () -> Void
    let recoverPane: (RemoteCatalogPane) -> Void
    @State private var hovering = false
    @State private var expanded = false

    private var isAttached: Bool {
        session.panes.contains { pane in
            UUID(uuidString: pane.paneID).map(attachedPaneIDs.contains) == true
        }
    }

    private var ownerWindow: NSWindow? {
        session.workspaceID.flatMap(UUID.init(uuidString:)).flatMap { RecoveryWindowRegistry.shared.liveWindow(for: $0) }
    }

    private var origin: RecoveryWindowOrigin? {
        session.workspaceID.flatMap(UUID.init(uuidString:)).flatMap { RecoveryWindowRegistry.shared.origin(for: $0) }
            ?? session.workspaceSnapshot?.recoveryWindow
    }

    private var detachedPanes: [RemoteCatalogPane] {
        session.panes.filter { pane in
            pane.recoverable
                && UUID(uuidString: pane.paneID).map { !attachedPaneIDs.contains($0) } == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RelayTheme.spacing(3)) {
            Button {
                if isAttached && ownerWindow != nil {
                    attachSession()
                } else {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: RelayTheme.spacing(12)) {
                    ZStack {
                        RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10))
                            .fill(hovering ? RelayTheme.hover : RelayTheme.surface)
                            .frame(width: 42, height: 42)
                        Image(systemName: session.isUnfiled ? "lifepreserver" : "rectangle.stack")
                            .font(RelayTheme.font(size: 15, weight: .medium))
                            .foregroundStyle(session.recoverable ? RelayTheme.mint : RelayTheme.textFaint)
                    }
                    VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                        Text(session.label)
                            .font(RelayTheme.font(size: 13.5, weight: .medium))
                            .foregroundStyle(session.recoverable ? RelayTheme.text : RelayTheme.textMuted)
                        Text("\(session.tabCount) tab\(session.tabCount == 1 ? "" : "s") · \(session.panes.count) pane\(session.panes.count == 1 ? "" : "s")")
                            .font(RelayTheme.font(size: 11))
                            .foregroundStyle(RelayTheme.textMuted)
                        if let origin {
                            Text(origin.name)
                                .font(RelayTheme.font(size: 10))
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                    }
                    Spacer()
                    if isAttached {
                        Text(ownerWindow.map { "Open in \($0.title)" } ?? "Open in this workspace")
                    } else if !detachedPanes.isEmpty {
                        Text("\(detachedPanes.count) detached")
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    } else {
                        Text(session.recoverable ? (session.isUnfiled ? "Recover" : "Attach") : "Unavailable")
                    }
                }
                .font(RelayTheme.font(size: 9.5, weight: .medium))
                .foregroundStyle(session.recoverable ? RelayTheme.mint : RelayTheme.textFaint)
                .padding(.horizontal, RelayTheme.spacing(8))
                .frame(minHeight: 58)
                .background(hovering ? RelayTheme.elevated.opacity(0.6) : Color.clear,
                            in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!session.recoverable)
            .onHover { hovering = $0 }

            Button(expanded ? "Hide tabs and recovery options" : "Show tabs and recovery options") {
                expanded.toggle()
            }
            .buttonStyle(.plain)
            .font(RelayTheme.font(size: 10))
            .foregroundStyle(RelayTheme.blue)
            .padding(.leading, RelayTheme.spacing(62))

            if expanded {
                VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                    if let origin {
                        Text("Original window: \(origin.name) · \(origin.lastActive.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Original window unknown · saved before window tracking")
                    }
                    if let snapshot = session.workspaceSnapshot {
                        ForEach(snapshot.tabs, id: \.id) { tab in
                            HStack {
                                Image(systemName: "rectangle.split.2x1")
                                RecoveryLayoutPreview(layout: tab.layout)
                                    .frame(width: 70, height: 32)
                                Text(tab.name)
                                Spacer()
                                Text("\(session.panes.filter { $0.tabID == tab.id.uuidString.lowercased() || $0.tabID == tab.id.uuidString }.count) panes")
                            }
                        }
                    } else {
                        ForEach(session.panes) { pane in Text(pane.title ?? "Terminal") }
                    }
                    HStack {
                        Button(isAttached ? "Show session" : "Recover into this window", action: attachSession)
                        if !isAttached { Button("Recover into new window", action: recoverInNewWindow) }
                    }
                }
                .font(RelayTheme.font(size: 11))
                .foregroundStyle(RelayTheme.textMuted)
                .padding(.horizontal, RelayTheme.spacing(12))
                .padding(.vertical, RelayTheme.spacing(8))
                ForEach(detachedPanes) { pane in
                    RemotePaneRecoveryRow(pane: pane) { recoverPane(pane) }
                        .padding(.leading, RelayTheme.spacing(30))
                }
            }
        }
    }
}

private struct RecoveryLayoutPreview: View {
    let layout: PaneLayout

    var body: some View {
        switch layout {
        case .pane:
            RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(2))
                .fill(RelayTheme.blue.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(2)).stroke(RelayTheme.blue.opacity(0.6)))
        case .split(_, let axis, let first, let second):
            if axis == .horizontal {
                HStack(spacing: RelayTheme.spacing(2)) {
                    AnyView(RecoveryLayoutPreview(layout: first))
                    AnyView(RecoveryLayoutPreview(layout: second))
                }
            } else {
                VStack(spacing: RelayTheme.spacing(2)) {
                    AnyView(RecoveryLayoutPreview(layout: first))
                    AnyView(RecoveryLayoutPreview(layout: second))
                }
            }
        }
    }
}

private struct RemotePaneRecoveryRow: View {
    let pane: RemoteCatalogPane
    let action: () -> Void
    @State private var hovering = false

    private var location: String {
        guard let directory = pane.directory, !directory.isEmpty else { return "Remote pane" }
        let name = TerminalPathSyntax.lastComponent(directory)
        return name.isEmpty ? directory : name
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: RelayTheme.spacing(10)) {
                Image(systemName: "terminal")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                    Text(pane.title ?? "Recovered pane")
                        .font(RelayTheme.font(size: 11.5, weight: .medium))
                        .foregroundStyle(RelayTheme.text)
                    Text("\(location) · \(pane.paneID.prefix(8))")
                        .font(RelayTheme.font(size: 11, design: .monospaced))
                        .foregroundStyle(RelayTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text("Recover")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.mint)
            }
            .padding(.horizontal, RelayTheme.spacing(10))
            .frame(height: 46)
            .background(hovering ? RelayTheme.elevated.opacity(0.7) : RelayTheme.surface.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(9), style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Recover \(pane.title ?? "remote pane") in \(location), pane \(pane.paneID.prefix(8))")
    }
}

private struct HostResultRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let badge: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: RelayTheme.spacing(12)) {
                ZStack {
                    RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10))
                        .fill(hovering ? RelayTheme.hover : RelayTheme.surface)
                        .frame(width: 42, height: 42)
                    Image(systemName: symbol)
                        .font(RelayTheme.font(size: 15, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                VStack(alignment: .leading, spacing: RelayTheme.spacing(4)) {
                    Text(title)
                        .font(RelayTheme.font(size: 13.5, weight: .medium))
                        .foregroundStyle(RelayTheme.text)
                    Text(subtitle)
                        .font(RelayTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text(badge)
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? RelayTheme.textMuted : RelayTheme.textFaint)
                Image(systemName: "arrow.turn.down.left")
                    .font(RelayTheme.font(size: 10, weight: .medium))
                    .foregroundStyle(hovering ? RelayTheme.textMuted : RelayTheme.textFaint)
            }
            .padding(.horizontal, RelayTheme.spacing(10))
            .frame(height: 58)
            .background(hovering ? RelayTheme.elevated : Color.clear, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Adds contextual tools beside the terminal canvas without replacing or
/// reparenting the canvas itself. Ghostty surfaces therefore keep their native
/// attachment leases while this sibling appears and disappears.
private struct WorkspaceDockLayout: View {
    @ObservedObject var tab: TabModel
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var chrome: WorkspaceChrome

    init(tab: TabModel, workspace: WorkspaceModel) {
        self.tab = tab
        self.workspace = workspace
        _chrome = ObservedObject(wrappedValue: tab.chrome)
    }

    var body: some View {
        let rightSurface = chrome.rightSurface(rLayoutEditorID: tab.rLayoutEditorID)
        Group {
            if let pane = workspace.activePane,
               pane.profile.kind == .ssh,
               pane.contentKind == .terminal,
               case .contextDock = rightSurface,
               chrome.destination != .rWorkspace {
                // Claude's SSH question renderer keeps a narrow frame after a
                // side panel closes, even when the PTY has the correct size.
                // Float contextual tools over remote terminals so opening the
                // dock never changes their PTY grid in the first place.
                ZStack(alignment: .trailing) {
                    WorkspaceCanvas(tab: tab, workspace: workspace)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: RelayTheme.spacing(0)) {
                        WorkspaceDockDivider(chrome: chrome)
                        WorkspaceContextDock(tab: tab, workspace: workspace, chrome: chrome)
                            .frame(width: chrome.width)
                    }
                    .frame(maxHeight: .infinity)
                    .background(RelayTheme.surface)
                    .shadow(color: .black.opacity(0.25), radius: 12, x: -5)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            } else {
                HStack(spacing: RelayTheme.spacing(0)) {
                    WorkspaceCanvas(tab: tab, workspace: workspace)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if case .contextDock = rightSurface {
                        WorkspaceDockDivider(chrome: chrome)
                        WorkspaceContextDock(tab: tab, workspace: workspace, chrome: chrome)
                            .frame(width: chrome.width)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: chrome.visible)
    }
}

private struct WorkspaceDockDivider: View {
    @ObservedObject var chrome: WorkspaceChrome
    @State private var initialWidth: Double?

    var body: some View {
        Rectangle()
            .fill(RelayTheme.line.opacity(0.7))
            .frame(width: 6)
            .overlay { Rectangle().fill(RelayTheme.line).frame(width: 1) }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if initialWidth == nil { initialWidth = chrome.width }
                    chrome.setWidth((initialWidth ?? chrome.width) - value.translation.width)
                }
                .onEnded { _ in initialWidth = nil })
            .accessibilityLabel("Resize context panel")
    }
}

private struct WorkspaceContextDock: View {
    @ObservedObject var tab: TabModel
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var chrome: WorkspaceChrome

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            if let anchor = chrome.anchor {
                HStack(spacing: RelayTheme.spacing(8)) {
                    Text(chrome.unresolved ? "Pane unavailable" : "Pane: \(anchor.profile.kind == .ssh ? anchor.profile.host : "This Mac")")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let pane = workspace.activePane, pane.id != anchor.paneID {
                        Button("Use active pane") {
                            let next = WorkspaceContextAnchor(paneID: pane.id, profile: pane.profile,
                                                              directory: pane.directory)
                            _ = chrome.useContext(next)
                        }
                        .disabled(chrome.hasDraft)
                    }
                    Toggle("Follow active pane", isOn: Binding(
                        get: { chrome.followsActivePane },
                        set: { enabled in
                            chrome.setFollowing(enabled)
                            if enabled, let pane = workspace.activePane {
                                chrome.activeContextChanged(WorkspaceContextAnchor(
                                    paneID: pane.id, profile: pane.profile, directory: pane.directory))
                            }
                        }))
                        .toggleStyle(.checkbox)
                        .disabled(chrome.hasDraft || chrome.unresolved)
                }
                .padding(.horizontal, RelayTheme.spacing(12))
                .padding(.vertical, RelayTheme.spacing(6))
                Divider()
            }
            Group {
            if chrome.destination == .rWorkspace,
               let id = tab.rLayoutEditorID,
               let editor = workspace.panes[id] {
                RLayoutResultsDock(runtime: editor.editorRuntime)
            } else if let anchor = chrome.anchor {
                RelayPluginToolsView(
                    workspace: workspace,
                    presentation: workspace.pluginPresentation(
                        paneID: anchor.paneID, profile: anchor.profile, directory: anchor.directory),
                    chrome: chrome,
                    presentationStyle: .dock
                )
                // The presenter claim lives in view-local @State, while each
                // pane owns a distinct retained presentation. Recreate the
                // view when Follow Active Pane changes its anchor so the old
                // claim is released and the new pane receives its own lease.
                .id(anchor.paneID)
            } else {
                ContentUnavailableView(
                    "No pane selected",
                    systemImage: "rectangle.dashed",
                    description: Text("Select a terminal pane and reopen contextual tools.")
                )
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RelayTheme.surface)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { workspace.dockWillTakeFocus() })
    }
}

private struct WorkspaceCanvas: View {
    @ObservedObject private var toolWindows = RelayToolWindowCoordinator.shared
    @ObservedObject var tab: TabModel
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        canvas.frame(minWidth: 380)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            if let zoomedID = workspace.zoomedPaneID,
               tab.allPaneIDs.contains(zoomedID),
               let pane = workspace.panes[zoomedID] {
                PaneView(
                    pane: pane,
                    isActive: true,
                    compactChrome: true,
                    select: { workspace.selectPane(zoomedID, origin: .user) },
                    toggleZoom: { workspace.togglePaneZoom(zoomedID) },
                    toggleFloating: { workspace.toggleActivePaneFloating() },
                    rename: { workspace.beginRenamePane(zoomedID) },
                    terminate: { workspace.requestTerminatePane(zoomedID) },
                    close: {
                        workspace.selectPane(zoomedID, origin: .programmatic)
                        workspace.closeActivePane()
                    },
                    isFloating: tab.floatingPanes.contains(where: { $0.paneID == zoomedID }),
                    isZoomed: true
                )
            } else {
                SplitPaneTree(node: tab.layout, tab: tab, workspace: workspace)
            }

            if workspace.zoomedPaneID == nil {
                GeometryReader { proxy in
                    ForEach(tab.floatingPanes.filter { !$0.isMinimized }) { placement in
                    if let pane = workspace.panes[placement.paneID] {
                        FloatingPaneWindow(
                            pane: pane,
                            placement: placement,
                            bounds: proxy.size,
                            isActive: workspace.activePaneID == pane.id,
                            select: {
                                workspace.selectPane(pane.id, origin: .user)
                                pane.focus()
                            },
                            move: { x, y in
                                workspace.updateFloatingPane(pane.id, originX: x, originY: y)
                            },
                            resize: { width, height in
                                workspace.updateFloatingPane(pane.id, width: width, height: height)
                            },
                            zoom: { workspace.togglePaneZoom(pane.id) },
                            dock: { workspace.dockFloatingPane(pane.id) },
                            minimize: { workspace.minimizeFloatingPane(pane.id) },
                            rename: { workspace.beginRenamePane(pane.id) },
                            terminate: { workspace.requestTerminatePane(pane.id) },
                            close: {
                                workspace.selectPane(pane.id, origin: .programmatic)
                                workspace.closeActivePane()
                            }
                        )
                        .zIndex(Double(tab.floatingPanes.firstIndex(where: { $0.paneID == pane.id }) ?? 0) + 10)
                    }
                }
                .onAppear { tab.canvasSize = proxy.size }
                .onChange(of: proxy.size) { _, size in tab.canvasSize = size }
                }
            }
        }
        .overlay {
            if let id = toolWindows.embeddedAgentPaneID, tab.allPaneIDs.contains(id),
               let pane = workspace.panes[id] {
                GeometryReader { geometry in
                    FloatingAgentConversation(pane: pane, bounds: geometry.size,
                        terminal: { workspace.selectPane(id, origin: .user); pane.focus() },
                        close: { toolWindows.embeddedAgentPaneID = nil })
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if tab.floatingPanes.contains(where: \.isMinimized) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RelayTheme.spacing(6)) {
                        ForEach(tab.floatingPanes.filter(\.isMinimized)) { placement in
                            if let pane = workspace.panes[placement.paneID] {
                                Button { workspace.selectPane(pane.id, origin: .user) } label: {
                                    Label(pane.customName ?? (pane.kind == .shell ? pane.displayName : pane.harnessLabel), systemImage: "arrow.up.forward.square")
                                        .font(RelayTheme.font(size: 11, weight: .medium))
                                        .lineLimit(1)
                                        .padding(.horizontal, RelayTheme.spacing(10)).padding(.vertical, RelayTheme.spacing(6))
                                        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
                                }
                                .buttonStyle(.plain)
                                .help("Restore \(pane.displayName) — session is still running")
                                .accessibilityLabel("Restore minimized pane \(pane.kind == .shell ? pane.displayName : pane.harnessLabel)")
                            }
                        }
                    }.padding(RelayTheme.spacing(6))
                }.background(RelayTheme.canvas)
            }
        }
        .clipped()
    }
}

private struct FloatingAgentConversation: View {
    @ObservedObject var pane: PaneModel
    let bounds: CGSize
    let terminal: () -> Void
    let close: () -> Void
    @State private var origin = CGPoint(x: 24, y: 24)
    @State private var size = CGSize(width: 740, height: 620)
    @GestureState private var movement: CGSize = .zero
    @GestureState private var resizing: CGSize = .zero
    private var width: CGFloat { min(max(360, size.width + resizing.width), max(1, bounds.width - 16)) }
    private var height: CGFloat { min(max(320, size.height + resizing.height), max(1, bounds.height - 16)) }
    private var x: CGFloat { min(max(8, origin.x + movement.width), max(8, bounds.width - width - 8)) }
    private var y: CGFloat { min(max(8, origin.y + movement.height), max(8, bounds.height - height - 8)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Conversation · " + pane.displayName, systemImage: "text.bubble")
                    .font(RelayTheme.font(size: 12, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("relay.agent.embedded." + pane.id.uuidString)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().updating($movement) { value, offset, _ in offset = value.translation }
                        .onEnded { value in
                            origin = CGPoint(x: min(max(8, origin.x + value.translation.width), max(8, bounds.width - width - 8)),
                                             y: min(max(8, origin.y + value.translation.height), max(8, bounds.height - height - 8)))
                        })
                Button(action: terminal) { Image(systemName: "terminal") }.help("Return to the original terminal")
                    .accessibilityIdentifier("relay.agent.embedded.terminal")
                Button(action: close) { Image(systemName: "xmark") }.help("Close conversation; keep the agent running")
                    .accessibilityIdentifier("relay.agent.embedded.close")
            }
            .buttonStyle(.plain).padding(10).background(RelayTheme.elevated)
            RelayAgentConversationHostView(pane: pane).id(pane.id)
        }
        .frame(width: width, height: height)
        .background(RelayTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10)))
        .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10)).stroke(RelayTheme.line))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(RelayTheme.font(size: 11)).padding(8).contentShape(Rectangle())
                .gesture(DragGesture().updating($resizing) { value, offset, _ in offset = value.translation }
                    .onEnded { value in
                        size = CGSize(width: min(max(360, size.width + value.translation.width), max(1, bounds.width - 16)),
                                      height: min(max(320, size.height + value.translation.height), max(1, bounds.height - 16)))
                    })
                .accessibilityLabel("Resize agent conversation")
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .offset(x: x, y: y)
    }
}

private struct RLayoutResultsDock: View {
    @ObservedObject var runtime: RemoteEditorRuntime
    var body: some View {
        if runtime.showsRResults, let scope = runtime.rResultsScope {
            RWorkspaceResults(scope: scope, runtime: runtime)
                .id(scope.paneID.uuidString + ":" + scope.root)
        } else {
            Button("Show results") { runtime.showsRResults = true }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FloatingPaneWindow: View {
    @ObservedObject var pane: PaneModel
    let placement: FloatingPanePlacement
    let bounds: CGSize
    let isActive: Bool
    let select: () -> Void
    let move: (Double, Double) -> Void
    let resize: (Double, Double) -> Void
    let zoom: () -> Void
    let dock: () -> Void
    let minimize: () -> Void
    let rename: () -> Void
    let terminate: () -> Void
    let close: () -> Void

    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var resizeOffset: CGSize = .zero
    @FocusState private var titleFocused: Bool
    @FocusState private var resizeFocused: Bool

    private let minimumWidth: CGFloat = 380
    private let minimumHeight: CGFloat = 260
    private let edgeInset: CGFloat = 12
    private let snapDistance: CGFloat = 18

    private var baseWidth: CGFloat {
        min(max(CGFloat(placement.width), minimumWidth), max(minimumWidth, bounds.width - edgeInset * 2))
    }

    private var baseHeight: CGFloat {
        min(max(CGFloat(placement.height), minimumHeight), max(minimumHeight, bounds.height - edgeInset * 2))
    }

    private var width: CGFloat {
        min(max(baseWidth + resizeOffset.width, minimumWidth), max(minimumWidth, bounds.width - originX - edgeInset))
    }

    private var height: CGFloat {
        min(max(baseHeight + resizeOffset.height, minimumHeight), max(minimumHeight, bounds.height - originY - edgeInset))
    }

    private var baseOriginX: CGFloat {
        min(max(CGFloat(placement.originX), edgeInset), max(edgeInset, bounds.width - baseWidth - edgeInset))
    }

    private var baseOriginY: CGFloat {
        min(max(CGFloat(placement.originY), edgeInset), max(edgeInset, bounds.height - baseHeight - edgeInset))
    }

    private var originX: CGFloat {
        min(max(baseOriginX + dragOffset.width, edgeInset), max(edgeInset, bounds.width - baseWidth - edgeInset))
    }

    private var originY: CGFloat {
        min(max(baseOriginY + dragOffset.height, edgeInset), max(edgeInset, bounds.height - baseHeight - edgeInset))
    }

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            floatingTitleBar
            Rectangle().fill(RelayTheme.line.opacity(0.85)).frame(height: 1)
            PaneView(
                pane: pane,
                isActive: isActive,
                compactChrome: true,
                select: select,
                toggleZoom: zoom,
                toggleFloating: dock,
                rename: rename,
                terminate: terminate,
                isFloating: true
            )
        }
        .frame(width: width, height: height)
        .background(RelayTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(13), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(13), style: .continuous)
                .stroke(isActive ? RelayTheme.accent.opacity(0.45) : RelayTheme.line.opacity(0.75), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
        }
        .shadow(
            color: .black.opacity(dragOffset == .zero && resizeOffset == .zero ? 0.28 : 0.14),
            radius: dragOffset == .zero && resizeOffset == .zero ? 14 : 4,
            y: dragOffset == .zero && resizeOffset == .zero ? 6 : 2
        )
        .offset(x: originX, y: originY)
        .transaction { $0.animation = nil }
    }

    private var floatingTitleBar: some View {
        HStack(spacing: RelayTheme.spacing(9)) {
            HStack(spacing: RelayTheme.spacing(9)) {
                Capsule()
                    .fill(isActive ? RelayTheme.accent : RelayTheme.textFaint)
                    .frame(width: 16, height: 3)
                Text(pane.displayName)
                    .font(RelayTheme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { rename() }
                Text(pane.profile.kind == .ssh ? pane.profile.host : "This Mac")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
                    .padding(.horizontal, RelayTheme.spacing(7))
                    .padding(.vertical, RelayTheme.spacing(3))
                    .background(RelayTheme.surface, in: Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($dragOffset) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        let x = min(
                            max(baseOriginX + value.translation.width, edgeInset),
                            max(edgeInset, bounds.width - baseWidth - edgeInset)
                        )
                        let y = min(
                            max(baseOriginY + value.translation.height, edgeInset),
                            max(edgeInset, bounds.height - baseHeight - edgeInset)
                        )
                        let centeredX = (bounds.width - baseWidth) / 2
                        let centeredY = (bounds.height - baseHeight) / 2
                        let snappedX = abs(x - centeredX) < snapDistance ? centeredX
                            : abs(x - edgeInset) < snapDistance ? edgeInset
                            : abs(x - (bounds.width - baseWidth - edgeInset)) < snapDistance
                                ? bounds.width - baseWidth - edgeInset : x
                        let snappedY = abs(y - centeredY) < snapDistance ? centeredY
                            : abs(y - edgeInset) < snapDistance ? edgeInset
                            : abs(y - (bounds.height - baseHeight - edgeInset)) < snapDistance
                                ? bounds.height - baseHeight - edgeInset : y
                        select()
                        move(Double(snappedX), Double(snappedY))
                    }
            )
            .simultaneousGesture(TapGesture().onEnded(select))
            .focusable()
            .focused($titleFocused)
            .focusEffectDisabled()
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(titleFocused ? RelayTheme.textMuted.opacity(0.7) : Color.clear)
                    .frame(height: 1)
                    .padding(.horizontal, RelayTheme.spacing(8))
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Move floating pane \(pane.displayName)")
            .onKeyPress(.leftArrow) {
                move(Double(max(edgeInset, baseOriginX - 20)), Double(baseOriginY)); return .handled
            }
            .onKeyPress(.rightArrow) {
                move(Double(min(bounds.width - baseWidth - edgeInset, baseOriginX + 20)), Double(baseOriginY)); return .handled
            }
            .onKeyPress(.upArrow) {
                move(Double(baseOriginX), Double(max(edgeInset, baseOriginY - 20))); return .handled
            }
            .onKeyPress(.downArrow) {
                move(Double(baseOriginX), Double(min(bounds.height - baseHeight - edgeInset, baseOriginY + 20))); return .handled
            }

            HStack(spacing: RelayTheme.spacing(0)) {
                Button(action: minimize) {
                    Image(systemName: "minus")
                        .font(RelayTheme.font(size: 9, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .focusEffectDisabled()
                .help("Minimize pane — keep session running")
                .accessibilityLabel("Minimize floating pane")
                Button(action: dock) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(RelayTheme.font(size: 9, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .focusEffectDisabled()
                .help("Dock pane")
                .accessibilityLabel("Dock floating pane")

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(RelayTheme.font(size: 9, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .focusEffectDisabled()
                .help(pane.profile.kind == .ssh ? "Detach floating pane" : "Close floating pane")
                .accessibilityLabel(pane.profile.kind == .ssh ? "Detach floating pane" : "Close floating pane")
            }
            .frame(height: 24)
        }
        .padding(.horizontal, RelayTheme.spacing(10))
        .frame(height: 36)
        .background(RelayTheme.elevated)
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($resizeOffset) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        let maximumWidth = max(minimumWidth, bounds.width - baseOriginX - edgeInset)
                        let maximumHeight = max(minimumHeight, bounds.height - baseOriginY - edgeInset)
                        let newWidth = min(max(baseWidth + value.translation.width, minimumWidth), maximumWidth)
                        let newHeight = min(max(baseHeight + value.translation.height, minimumHeight), maximumHeight)
                        select()
                        resize(Double(newWidth), Double(newHeight))
                    }
            )
            .help("Drag to resize floating pane")
            .focusable()
            .focused($resizeFocused)
            .focusEffectDisabled()
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(resizeFocused ? RelayTheme.textMuted.opacity(0.8) : Color.clear)
                    .frame(width: 4, height: 4)
                    .padding(RelayTheme.spacing(3))
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Resize floating pane")
            .accessibilityValue("\(Int(baseWidth)) by \(Int(baseHeight))")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 24 : -24
                let maximumWidth = max(minimumWidth, bounds.width - baseOriginX - edgeInset)
                let maximumHeight = max(minimumHeight, bounds.height - baseOriginY - edgeInset)
                resize(
                    Double(min(max(baseWidth + delta, minimumWidth), maximumWidth)),
                    Double(min(max(baseHeight + delta, minimumHeight), maximumHeight))
                )
            }
    }
}

private struct SplitPaneTree: View {
    let node: PaneLayout
    @ObservedObject var tab: TabModel
    @ObservedObject var workspace: WorkspaceModel
    @State private var layoutFailure: String?

    var body: some View {
        Group {
        switch node {
        case .pane(let id):
            if let pane = workspace.panes[id] {
                WorkspacePaneStackChrome(tab: tab, workspace: workspace, paneID: id) {
                PaneView(
                    pane: pane,
                    isActive: workspace.activePaneID == id,
                    compactChrome: workspace.isFullScreen,
                    select: { workspace.selectPane(id, origin: .user) },
                    rearrange: { draggedID, placement in
                        do {
                            try workspace.applyWorkspacePaneDrop(draggedID, toTab: tab.id, onto: id, placement: placement)
                        } catch { layoutFailure = error.localizedDescription }
                    },
                    toggleZoom: { workspace.togglePaneZoom(id) },
                    toggleFloating: { workspace.floatTiledPane(id) },
                    rename: { workspace.beginRenamePane(id) },
                    terminate: { workspace.requestTerminatePane(id) },
                    close: {
                        workspace.selectPane(id, origin: .programmatic)
                        workspace.closeActivePane()
                    },
                    isFloating: false
                )
                }
            }
        case .split(_, let axis, let first, let second):
            if case .split(let splitID, _, _, _) = node {
                RelaySplitContainer(
                    axis: axis,
                    ratio: tab.splitRatios[splitID] ?? 0.5,
                    update: { ratio, persist in
                        workspace.updateSplitRatio(splitID, ratio: ratio, persist: persist)
                    }
                ) {
                    SplitPaneTree(node: first, tab: tab, workspace: workspace)
                } second: {
                    SplitPaneTree(node: second, tab: tab, workspace: workspace)
                }
            }
        }
        }
        .alert("Could not change pane layout", isPresented: Binding(get: { layoutFailure != nil }, set: { if !$0 { layoutFailure = nil } })) {
            Button("OK") { layoutFailure = nil }
        } message: { Text(layoutFailure ?? "") }
    }
}

private struct PaneLinkSelectionBar: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var selection: PaneLinkSelection
    var body: some View {
        Group {
            if selection.active || selection.resultMessage != nil {
                HStack {
                    if selection.pairMode || selection.resultMessage != nil {
                        PaneLinkPairControls(workspace: workspace, selection: selection)
                    } else {
                        Label("Select panes to link", systemImage: "link")
                        Text("\(selection.paneIDs.count) selected · up to 8").foregroundStyle(.secondary)
                        Toggle("Across app", isOn: Binding(
                            get: { selection.acrossApp },
                            set: { selection.setAcrossApp($0) }
                        ))
                        .toggleStyle(.checkbox)
                        .help("By default, panes in this tab and window are available. Turn this on to include panes anywhere in Relay.")
                    }
                    Spacer()
                    Button { selection.cancel() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).help("Cancel linking · Escape").accessibilityLabel("Cancel linking")
                        .keyboardShortcut(.cancelAction)
                    if selection.active && !selection.pairMode {
                    Button { selection.reviewing = true } label: {
                        Image(systemName: "link.badge.plus")
                            .frame(width: 28)
                            .font(RelayTheme.font(size: 11, weight: .medium))
                            .padding(.horizontal, RelayTheme.spacing(10))
                            .frame(height: 28)
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .help("Link selected panes")
                    .accessibilityLabel("Link selected panes")
                        .disabled(selection.paneIDs.count < 2)
                    }
                }.font(RelayTheme.font(size: 11.5)).padding(.horizontal, RelayTheme.spacing(12)).padding(.vertical, RelayTheme.spacing(4)).background(RelayTheme.surface)
            }
        }
        .sheet(isPresented: $selection.reviewing, onDismiss: { selection.cancel() }) {
            PeerNetworkTopologyView(workspace: workspace, connectionOnly: true,
                startingTabID: selection.startingTabID,
                initiallyAcrossApp: selection.acrossApp,
                requestedPaneIDs: selection.paneIDs, manage: {})
        }
        .onChange(of: selection.active) { _, active in
            workspace.updateTerminalFocusOwnership()
            if !active, let id = workspace.activePaneID { workspace.panes[id]?.runtime.focus() }
        }
    }
}

private struct PaneView: View {
    @ObservedObject private var toolWindows = RelayToolWindowCoordinator.shared
    @EnvironmentObject private var linkSelection: PaneLinkSelection
    @Environment(\.networkCoverActive) private var networkCoverActive
    @ObservedObject var pane: PaneModel
    @ObservedObject private var preferences = RelayPreferences.shared
    let isActive: Bool
    let compactChrome: Bool
    let select: () -> Void
    var rearrange: (@MainActor @Sendable (UUID, PaneDropPlacement) -> Void)? = nil
    var toggleZoom: (() -> Void)? = nil
    var toggleFloating: (() -> Void)? = nil
    var rename: (() -> Void)? = nil
    var terminate: (() -> Void)? = nil
    var close: (() -> Void)? = nil
    var isFloating = false
    var isZoomed = false
    var inToolWindow = false
    @State private var paneSize: CGSize = .zero
    @State private var linkHovered = false
    @State private var richContentPresented = false
    @State private var sessionEndedNoticeDismissed = false
    @StateObject private var dropPreview = PaneDropPreviewModel()

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            paneHeader
            ZStack {
                if toolWindows.rPaneIDs.contains(pane.id) && !inToolWindow {
                    VStack(spacing: RelayTheme.spacing(10)) {
                        Image(systemName: "macwindow")
                        Text("Open in RStudio workspace")
                        Button("Show window") { toolWindows.focusR(paneID: pane.id) }
                        Button("Return to tab") { toolWindows.returnRPaneToTab(paneID: pane.id) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(RelayTheme.textMuted)
                } else if pane.contentKind == .editor {
                    QuickEditorPane(pane: pane)
                        .id(pane.id)
                } else {
                    TerminalSurface(pane: pane, covered: networkCoverActive || pane.nativeConversationVisible)
                        .equatable()
                        // A terminal backend is immutable after its NSView is created.
                        // Key the representable by the remote session so switching tabs
                        // cannot reuse a local-shell surface for an SSH pane.
                        .id(pane.id)
                        .overlay {
                            if pane.nativeConversationVisible {
                                RelayAgentConversationHostView(pane: pane)
                                    .background(RelayTheme.canvas)
                                    .accessibilityIdentifier("relay.agent.native-pane")
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if let progress = pane.uploadProgress {
                                RelayTransferProgressView(progress: progress,
                                    dismiss: [.complete, .failed].contains(progress.phase) ? { pane.uploadProgress = nil } : nil)
                                    .frame(maxWidth: 360).padding(12)
                            }
                        }
                }
                if pane.connectionState == .connecting && !pane.hasTerminalSnapshot {
                    ConnectingOverlay(host: pane.profile.host, contentKind: pane.contentKind)
                        .allowsHitTesting(false)
                } else if let message = pane.connectionState.recoveryMessage {
                    ConnectionRecoveryBanner(
                        host: pane.profile.host,
                        message: message,
                        waitingForNetwork: pane.connectionState.isWaitingForNetwork
                    )
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(RelayTheme.spacing(12))
                } else if pane.isRestoringTerminal && !pane.hasTerminalSnapshot {
                    RestoringTerminalOverlay(host: pane.profile.host)
                } else if pane.remoteExitCode != nil, pane.exitNotice != nil {
                    // Explained by the banner row below the terminal, which
                    // never covers the output.
                    EmptyView()
                } else if let exitCode = pane.remoteExitCode, !sessionEndedNoticeDismissed {
                    SessionEndedOverlay(
                        exitCode: exitCode,
                        restart: {
                            NotificationCenter.default.post(name: .relayRestartExitedPane, object: pane.id)
                        },
                        dismiss: { sessionEndedNoticeDismissed = true },
                        close: {
                            select()
                            if let close { close() }
                            else { NotificationCenter.default.post(name: .relayClosePane, object: pane.id) }
                        }
                    )
                } else if let message = pane.connectionState.errorMessage {
                    ConnectionErrorBanner(
                        message: message,
                        retry: pane.contentKind == .editor ? { pane.restartRuntime() } : nil,
                        manageRelayd: message.localizedCaseInsensitiveContains("relayd") ||
                            message.localizedCaseInsensitiveContains("remote Relay installation")
                            ? {
                                NotificationCenter.default.post(
                                    name: .relayManageRelayd, object: pane.profile
                                )
                            } : nil
                    )
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(RelayTheme.spacing(12))
                }
                if let artifact = pane.artifacts.last,
                   preferences.artifactPresentation == .preview || artifact.userRequested {
                    GeometryReader { proxy in
                        let inset = RelayTheme.spacing(12)
                        ArtifactPreview(artifact: artifact, bounds: CGSize(
                            width: proxy.size.width - inset * 2, height: proxy.size.height - inset * 2)) {
                            pane.dismissArtifact(artifact.id)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(inset)
                    }
                    .zIndex(100)
                }
            }
            if pane.contentKind == .terminal, pane.remoteExitCode != nil, let notice = pane.exitNotice,
               !sessionEndedNoticeDismissed {
                // A row, not an overlay: the terminal gives up the banner's
                // height, so its last output lines stay visible and scrollable.
                FailedPaneExitBanner(
                    notice: notice,
                    runAgain: {
                        NotificationCenter.default.post(name: .relayRestartExitedPane, object: pane.id)
                    },
                    close: {
                        select()
                        if let close { close() }
                        else { NotificationCenter.default.post(name: .relayClosePane, object: pane.id) }
                    },
                    dismiss: { sessionEndedNoticeDismissed = true }
                )
            } else if pane.contentKind == .terminal, let held = pane.heldExitNotice, !sessionEndedNoticeDismissed {
                // Reconnect/replay of an exited pane: keep the row's height so
                // the terminal does not grow and shrink again.
                FailedPaneExitBanner(notice: held, runAgain: {}, close: {}, dismiss: {})
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if preferences.artifactPresentation == .inline,
               let artifact = pane.artifacts.last, !artifact.userRequested {
                InlineArtifactView(artifact: artifact) {
                    pane.dismissArtifact(artifact.id)
                }
                .frame(height: min(300, max(120, paneSize.height * 0.4)))
            }
        }
        .onChange(of: pane.richContentRequested) { _, requested in
            if requested { richContentPresented = true; pane.richContentRequested = false }
        }
        .onChange(of: richContentPresented) { _, presented in
            if presented { RelayRichContentWindow.shared.show(pane: pane); richContentPresented = false }
        }
        .background(RelayTheme.canvas)
        .overlay {
            RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(2), style: .continuous)
                .stroke(RelayTheme.line.opacity(0.55), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            if isActive && !linkSelection.active {
                Capsule()
                    .fill(RelayTheme.accent)
                    .frame(width: 2, height: 28)
                    .padding(.leading, RelayTheme.spacing(1))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let placement = dropPreview.placement {
                PaneDropPreview(placement: placement)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if linkSelection.active && !linkSelection.pairMode && linkSelection.canSelect(pane.id) {
                Button {
                    if pane.contentKind == .terminal { linkSelection.toggle(pane.id) }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(2), style: .continuous)
                            .fill(Color.accentColor.opacity(linkSelection.paneIDs.contains(pane.id) ? 0.035 : 0))
                        RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(2), style: .continuous)
                            .strokeBorder(linkSelection.paneIDs.contains(pane.id) ? Color.accentColor : Color.secondary.opacity(linkHovered ? 0.5 : 0),
                                          lineWidth: linkSelection.paneIDs.contains(pane.id) ? 1.5 : 1)
                        if linkSelection.paneIDs.contains(pane.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(RelayTheme.font(size: 13, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(RelayTheme.spacing(3)).background(RelayTheme.canvas, in: Circle())
                                .padding(.top, RelayTheme.spacing(5)).padding(.trailing, RelayTheme.spacing(8))
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .onHover { linkHovered = $0 && pane.contentKind == .terminal && linkSelection.canSelect(pane.id) }
                    .help(pane.contentKind == .terminal ? "Click to select or deselect this session" : "Only terminal panes can be linked")
                    .accessibilityLabel("\(linkSelection.paneIDs.contains(pane.id) ? "Deselect" : "Select") session in \(pane.displayName)")
                    .accessibilityValue(pane.contentKind != .terminal ? "Unavailable" : (linkSelection.paneIDs.contains(pane.id) ? "Selected" : "Not selected"))
            }
        }
        .onChange(of: linkSelection.active) { _, _ in linkHovered = false }
        .onChange(of: pane.nativeConversationVisible) { _, visible in
            if !visible {
                pane.runtime.conversationComposerOwnsFocus = false
                Task { @MainActor in
                    await Task.yield()
                    if !pane.nativeConversationVisible { pane.focus() }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { paneSize = $0 }
        .onDrop(
            of: [UTType.utf8PlainText],
            delegate: PaneRearrangementDropDelegate(
                paneSize: paneSize,
                preview: dropPreview,
                rearrange: rearrange
            )
        )
    }

    @ViewBuilder
    private var paneHeader: some View {
        if rearrange != nil {
            ConnectionPath(
                pane: pane,
                active: isActive,
                compact: compactChrome,
                zoomed: isZoomed,
                isFloating: isFloating,
                select: select,
                toggleZoom: toggleZoom,
                toggleFloating: toggleFloating,
                rename: rename,
                terminate: terminate,
                close: close
            )
                .onDrag {
                    WorkspaceDragPayload.paneProvider(pane.id, floating: isFloating)
                }
        } else {
            ConnectionPath(
                pane: pane,
                active: isActive,
                compact: compactChrome,
                zoomed: isZoomed,
                isFloating: isFloating,
                select: select,
                toggleZoom: toggleZoom,
                toggleFloating: toggleFloating,
                rename: rename,
                terminate: terminate,
                close: close
            )
        }
    }
}

@MainActor
final class PaneDragCoordinator {
    static let shared = PaneDragCoordinator()
    var paneID: UUID?
    var isFloating = false
}

@MainActor
private final class PaneDropPreviewModel: ObservableObject {
    @Published private(set) var placement: PaneDropPlacement?
    private var expiryTask: Task<Void, Never>?

    deinit { expiryTask?.cancel() }

    func update(_ placement: PaneDropPlacement) {
        if self.placement != placement {
            self.placement = placement
        }
        expiryTask?.cancel()
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.placement = nil
            self?.expiryTask = nil
        }
    }

    func clear() {
        expiryTask?.cancel()
        expiryTask = nil
        placement = nil
    }
}

enum PaneDropGeometry {
    static func placement(at location: CGPoint, in size: CGSize) -> PaneDropPlacement {
        guard size.width > 0, size.height > 0 else { return .center }
        let horizontal = location.x / size.width
        let vertical = location.y / size.height
        if vertical < 0.28 { return .top }
        if vertical > 0.72 { return .bottom }
        if horizontal < 0.28 { return .leading }
        if horizontal > 0.72 { return .trailing }
        return .center
    }
}

private struct PaneRearrangementDropDelegate: DropDelegate {
    let paneSize: CGSize
    let preview: PaneDropPreviewModel
    let rearrange: (@MainActor @Sendable (UUID, PaneDropPlacement) -> Void)?

    func validateDrop(info: DropInfo) -> Bool {
        rearrange != nil &&
            PaneDragCoordinator.shared.paneID != nil &&
            info.hasItemsConforming(to: [UTType.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        updatePreview(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePreview(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        preview.clear()
    }

    func performDrop(info: DropInfo) -> Bool {
        let placement = PaneDropGeometry.placement(at: info.location, in: paneSize)
        preview.clear()
        guard let rearrange, let draggedID = PaneDragCoordinator.shared.paneID else {
            return false
        }
        // A cancelled pane drag leaves a stale paneID behind (onDrag has no
        // cancellation callback), so an unrelated plain-text drag would
        // otherwise rearrange the layout. Only rearrange when the dropped
        // payload is the UUID token the pane-header drag provided.
        guard let provider = info.itemProviders(for: [UTType.utf8PlainText]).first else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let string = (object as? NSString).map(String.init)
            Task { @MainActor in
                PaneDragCoordinator.shared.paneID = nil
                PaneDragCoordinator.shared.isFloating = false
                guard let string, UUID(uuidString: string) == draggedID else { return }
                rearrange(draggedID, placement)
            }
        }
        return true
    }

    private func updatePreview(info: DropInfo) {
        preview.update(PaneDropGeometry.placement(at: info.location, in: paneSize))
    }
}

private struct PaneDropPreview: View {
    let placement: PaneDropPlacement

    var body: some View {
        GeometryReader { proxy in
            let rect = previewRect(in: proxy.size)
            ZStack(alignment: .topLeading) {
                RelayTheme.canvas.opacity(0.18)
                RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(5), style: .continuous)
                    .fill(RelayTheme.blue.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(5), style: .continuous)
                            .stroke(RelayTheme.blue.opacity(0.9), lineWidth: 2)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)

                Text(label)
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .tracking(0.7)
                    .foregroundStyle(RelayTheme.text)
                    .padding(.horizontal, RelayTheme.spacing(8))
                    .frame(height: 22)
                    .background(RelayTheme.elevated.opacity(0.92), in: Capsule())
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .accessibilityHidden(true)
    }

    private var label: String {
        switch placement {
        case .leading: "LEFT"
        case .trailing: "RIGHT"
        case .top: "ABOVE"
        case .bottom: "BELOW"
        case .center: PaneDragCoordinator.shared.isFloating ? "DOCK" : "STACK"
        }
    }

    private func previewRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = 5
        let width = max(1, size.width - inset * 2)
        let height = max(1, size.height - inset * 2)
        switch placement {
        case .leading:
            return CGRect(x: inset, y: inset, width: width * 0.5, height: height)
        case .trailing:
            return CGRect(x: inset + width * 0.5, y: inset, width: width * 0.5, height: height)
        case .top:
            return CGRect(x: inset, y: inset, width: width, height: height * 0.5)
        case .bottom:
            return CGRect(x: inset, y: inset + height * 0.5, width: width, height: height * 0.5)
        case .center:
            return CGRect(x: inset + width * 0.16, y: inset + height * 0.16, width: width * 0.68, height: height * 0.68)
        }
    }
}

private struct QuickEditorPane: View {
    @ObservedObject var pane: PaneModel

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceFileOriginBar(pane: pane, runtime: pane.editorRuntime)
            QuickEditorContent(runtime: pane.editorRuntime)
        }
    }
}

private struct QuickEditorContent: View {
    @ObservedObject var runtime: RemoteEditorRuntime
    @ObservedObject private var preferences = RelayPreferences.shared

    var body: some View {
        HStack(spacing: RelayTheme.spacing(0)) {
            if runtime.navigatorVisible {
                EditorNavigator(runtime: runtime)
                    .frame(width: 210)
                Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(width: 1)
            }
            HSplitView {
              VStack(spacing: RelayTheme.spacing(0)) {
                editorToolbar
                Rectangle().fill(RelayTheme.line.opacity(0.45)).frame(height: 1)
                MonacoEditorSurface(
                    runtime: runtime,
                    typography: EditorTypography(
                        fontFamily: preferences.resolvedFontFamily,
                        fontSize: preferences.fontSize
                    )
                )
                .overlay {
                    if runtime.currentPath == nil {
                        ZStack {
                            RelayTheme.canvas
                            Text("Choose a file to edit or review")
                                .font(RelayTheme.font(size: 12))
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        .allowsHitTesting(false)
                    }
                }
                editorStatus
              }.frame(minWidth: 220)
              if runtime.showsRResults, !runtime.externalRResults, let scope = runtime.rResultsScope {
                  RWorkspaceResults(scope: scope, runtime: runtime)
                      .id(scope.paneID.uuidString + ":" + scope.root)
                      .frame(minWidth: 320, idealWidth: 380)
              }
            }
        }
        .background(RelayTheme.canvas)
    }

    private var editorToolbar: some View {
        HStack(spacing: RelayTheme.spacing(8)) {
            Menu {
                if runtime.recentDocuments.isEmpty { Text("No recent documents") }
                ForEach(runtime.recentDocuments, id: \.id) { document in
                    Button(document.path + (document.dirty ? " — recovered draft" : "")) {
                        runtime.reopenRecovered(document)
                    }
                }
            } label: { Image(systemName: "clock.arrow.circlepath") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Reopen a recent document or recovered draft")
            .accessibilityLabel("Recent documents")
            .onAppear { runtime.refreshRecentDocuments() }
            Button {
                runtime.navigatorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(RelayTheme.font(size: 10.5, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .help(runtime.navigatorVisible ? "Hide files" : "Show files")

            if let path = runtime.currentPath {
                Text(TerminalPathSyntax.lastComponent(path))
                    .font(RelayTheme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                    .lineLimit(1)
                if runtime.isDirty {
                    Circle().fill(RelayTheme.textMuted).frame(width: 5, height: 5)
                }
            } else {
                Text("Choose a file")
                    .font(RelayTheme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            Spacer(minLength: 8)
            if runtime.isBusy { ProgressView().controlSize(.mini).tint(RelayTheme.accent) }
            if runtime.canRunR {
                RelayIconAction(runtime.showsRResults ? "Hide results" : "Show results", symbol: "sidebar.right") {
                    runtime.showsRResults.toggle()
                    if runtime.showsRResults { runtime.navigatorVisible = false }
                }
                    .buttonStyle(.plain)
                RelayIconAction("Run R selection or current line · ⌘Enter", symbol: "play.fill") { runtime.requestRunSelection() }
                    .buttonStyle(.plain)
                    .help("Run selection or current line in the linked R console · ⌘Enter")
                    .accessibilityLabel("Run R selection or current line")
                RelayIconAction("Run full R file · ⇧⌘Enter", symbol: "play.rectangle") { runtime.requestRunFile() }
                    .buttonStyle(.plain)
                    .help("Run the complete editor file, including unsaved edits, in the linked R console · ⇧⌘Enter")
                    .accessibilityLabel("Run full R file")
                RelayIconAction("Format R document", symbol: "text.alignleft") { runtime.requestEditorAction("format") }
                    .disabled(runtime.rEditorToolBusy || runtime.rSession == nil)
                RelayIconAction("Check R code", symbol: "checkmark.circle") { runtime.requestEditorAction("lint") }
                    .disabled(runtime.rEditorToolBusy || runtime.rSession == nil)
                RelayIconAction("Open R help for selection or word", symbol: "questionmark.circle") { runtime.requestEditorAction("help") }
                    .disabled(runtime.rEditorToolBusy || runtime.rSession == nil)
            }
            RelayIconAction("Undo · ⌘Z", symbol: "arrow.uturn.backward") { runtime.undo(redo: false) }
                .disabled(runtime.currentPath == nil)
            RelayIconAction("Redo · ⇧⌘Z", symbol: "arrow.uturn.forward") { runtime.undo(redo: true) }
                .disabled(runtime.currentPath == nil)
            RelayIconAction(runtime.isDiff ? "Return to editor" : "Show changes", symbol: runtime.isDiff ? "pencil" : "rectangle.split.2x1") { runtime.toggleDiff() }
                .buttonStyle(.plain)
                .font(RelayTheme.font(size: 10.5, weight: .medium))
                .foregroundStyle(runtime.currentPath == nil ? RelayTheme.textFaint : RelayTheme.textMuted)
                .disabled(runtime.currentPath == nil)
            RelayIconAction("Save · ⌘S", symbol: "square.and.arrow.down") { runtime.requestSave() }
                .buttonStyle(.plain)
                .font(RelayTheme.font(size: 10.5, weight: .medium))
                .foregroundStyle(runtime.isDirty ? RelayTheme.text : RelayTheme.textMuted)
                .disabled(runtime.currentPath == nil || !runtime.isDirty || runtime.isBusy)
        }
        .padding(.horizontal, RelayTheme.spacing(8))
        .frame(height: 32)
        .background(RelayTheme.canvas)
    }

    private var editorStatus: some View {
        HStack(spacing: RelayTheme.spacing(8)) {
            if let error = runtime.operationError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(RelayTheme.coral)
                Text(error).foregroundStyle(RelayTheme.coral)
            } else {
                Text(runtime.rLastRequest == nil ? runtime.status : runtime.rSessionStatus)
                    .foregroundStyle(RelayTheme.textFaint)
            }
            Spacer()
            if runtime.isDiff { Text("Diff") }
            Text("UTF-8")
        }
        .font(RelayTheme.font(size: 9.5, weight: .medium))
        .foregroundStyle(RelayTheme.textFaint)
        .lineLimit(1)
        .padding(.horizontal, RelayTheme.spacing(9))
        .frame(height: 23)
        .background(RelayTheme.surface.opacity(0.7))
    }
}

private struct EditorNavigator: View {
    @ObservedObject var runtime: RemoteEditorRuntime

    private var query: String { runtime.searchQuery }
    private var includeUntracked: Bool { runtime.includeUntrackedFiles }

    private var visibleEntries: [RemoteFileEntry] {
        guard !query.isEmpty else { return runtime.entries }
        return runtime.searchResults
    }

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack(spacing: RelayTheme.spacing(7)) {
                Button { runtime.goUp() } label: {
                    Image(systemName: "chevron.left")
                        .font(RelayTheme.font(size: 9, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(runtime.directoryPath == runtime.workspacePath ? RelayTheme.textFaint : RelayTheme.textMuted)
                .disabled(runtime.directoryPath == runtime.workspacePath)
                Text(runtime.directoryPath.isEmpty ? "Files" : TerminalPathSyntax.lastComponent(runtime.directoryPath))
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, RelayTheme.spacing(7))
            .frame(height: 31)

            HStack(spacing: RelayTheme.spacing(6)) {
                Image(systemName: "magnifyingglass")
                    .font(RelayTheme.font(size: 9.5))
                    .foregroundStyle(RelayTheme.textFaint)
                TextField("Search repository files", text: $runtime.searchQuery)
                    .textFieldStyle(.plain)
                    .font(RelayTheme.font(size: 10.5))
                    .foregroundStyle(RelayTheme.text)
            }
            .padding(.horizontal, RelayTheme.spacing(8))
            .frame(height: 27)
            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
            .padding(.horizontal, RelayTheme.spacing(7))
            .padding(.bottom, RelayTheme.spacing(6))

            Rectangle().fill(RelayTheme.line.opacity(0.4)).frame(height: 1)
            if !query.isEmpty {
                Toggle("Include untracked files", isOn: $runtime.includeUntrackedFiles)
                    .toggleStyle(.checkbox)
                    .font(RelayTheme.font(size: 10.5))
                    .padding(.horizontal, RelayTheme.spacing(7))
                    .help("Also search files not tracked by Git; discovery may be slower on shared storage.")
                Text(runtime.searchStatus)
                    .font(RelayTheme.font(size: 11))
                    .foregroundStyle(RelayTheme.textMuted)
                    .padding(RelayTheme.spacing(7))
            }
            ScrollView {
                LazyVStack(spacing: RelayTheme.spacing(1)) {
                    ForEach(visibleEntries) { entry in
                        Button { runtime.openEntry(entry) } label: {
                            HStack(spacing: RelayTheme.spacing(7)) {
                                Image(systemName: entry.directory ? "folder" : fileSymbol(entry.name))
                                    .font(RelayTheme.font(size: 10, weight: .medium))
                                    .foregroundStyle(entry.directory ? RelayTheme.blue : RelayTheme.textMuted)
                                    .frame(width: 13)
                                Text(entry.name)
                                    .font(RelayTheme.font(size: 11, weight: .medium))
                                    .foregroundStyle(RelayTheme.textMuted)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, RelayTheme.spacing(8))
                            .frame(height: 25)
                            .background(runtime.currentPath == entry.path ? RelayTheme.surface : Color.clear,
                                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(RelayTheme.spacing(5))
            }
        }
        .background(RelayTheme.canvas)
        .task(id: runtime.workspacePath + "\u{0}" + query + "\u{0}" + String(includeUntracked)) {
            await runtime.searchFiles(query, includeUntracked: includeUntracked)
        }
    }

    private func fileSymbol(_ name: String) -> String {
        let suffix = TerminalPathSyntax.pathExtension(name)
        return ["swift", "go", "rs", "py", "r", "js", "ts", "c", "cpp"].contains(suffix)
            ? "chevron.left.forwardslash.chevron.right" : "doc"
    }
}

enum FloatingArtifactChromeMetrics {
    static let titleBarHeight: CGFloat = 52
    static let controlLength: CGFloat = 24
    static let resizeHandleLength: CGFloat = 28
    // Keep toolbar controls out from under the invisible corner resize targets.
    static let titleBarEdgeInset: CGFloat = resizeHandleLength + 2
}

private struct ArtifactPreview: View {
    private enum ResizeCorner: CaseIterable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight

        var xDirection: CGFloat {
            switch self {
            case .topLeft, .bottomLeft: -1
            case .topRight, .bottomRight: 1
            }
        }

        var yDirection: CGFloat {
            switch self {
            case .topLeft, .topRight: -1
            case .bottomLeft, .bottomRight: 1
            }
        }

        var alignment: Alignment {
            switch self {
            case .topLeft: .topLeading
            case .topRight: .topTrailing
            case .bottomLeft: .bottomLeading
            case .bottomRight: .bottomTrailing
            }
        }

        var accessibilityName: String {
            switch self {
            case .topLeft: "top-left"
            case .topRight: "top-right"
            case .bottomLeft: "bottom-left"
            case .bottomRight: "bottom-right"
            }
        }
    }

    private struct ResizeGestureState {
        let corner: ResizeCorner
        let translation: CGSize
    }

    private struct ResizeMetrics {
        let size: CGSize
        let centerShift: CGSize
    }

    let artifact: PaneArtifact
    var bounds: CGSize = .zero
    let dismiss: () -> Void
    @State private var offset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var panelSize = CGSize(width: 560, height: 440)
    @GestureState private var resizeGesture: ResizeGestureState?
    @State private var imageZoom: CGFloat = 1
    @GestureState private var pinchZoom: CGFloat = 1
    @State private var imagePan: CGSize = .zero
    @GestureState private var imagePanTranslation: CGSize = .zero
    @State private var imagePixels: CGSize?
    @State private var imageViewport: CGSize = .zero
    @State private var maximized = false
    @StateObject private var pdf = RelayPDFController()
    @FocusState private var focusedResizeCorner: ResizeCorner?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    private static let axID = "relay.file-preview"

    private var displayedSize: CGSize {
        maximized ? CGSize(width: max(260, bounds.width), height: max(180, bounds.height)) : resizeMetrics(for: resizeGesture).size
    }

    private var displayedCenterShift: CGSize {
        maximized ? .zero : resizeMetrics(for: resizeGesture).centerShift
    }

    /// Zoom is relative to the fitted image. Actual size (1 image pixel per backing pixel)
    /// can fall below 1 (small image upscaled to fit) or above 6, so the range widens to
    /// include it; it is capped at 32x.
    private var actualSizeZoom: CGFloat {
        guard let imagePixels else { return 1 }
        return min(32, PaneArtifact.actualSizeZoom(pixelSize: imagePixels, viewport: imageViewport, displayScale: displayScale))
    }
    private var zoomRange: ClosedRange<CGFloat> { min(1, actualSizeZoom)...max(6, actualSizeZoom) }
    private var displayedZoom: CGFloat { min(zoomRange.upperBound, max(zoomRange.lowerBound, imageZoom * pinchZoom)) }

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack(spacing: RelayTheme.spacing(8)) {
                HStack(spacing: RelayTheme.spacing(7)) {
                    Image(systemName: artifact.kind.symbol)
                        .font(RelayTheme.font(size: 10, weight: .medium))
                        .foregroundStyle(RelayTheme.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(artifact.filename)
                            .font(RelayTheme.font(size: 12, weight: .semibold))
                            .foregroundStyle(RelayTheme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(artifact.remotePath)
                            .font(RelayTheme.font(size: 10))
                            .foregroundStyle(RelayTheme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($dragTranslation) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            guard !maximized else { return }
                            offset.width += value.translation.width
                            offset.height += value.translation.height
                        }
                )
                .onTapGesture(count: 2) {
                    if reduceMotion {
                        offset = .zero
                    } else {
                        withAnimation(.easeOut(duration: 0.16)) { offset = .zero }
                    }
                }
                .help(artifact.remotePath + "\nDrag to move · double-click to reset")

                HStack(spacing: RelayTheme.spacing(0)) {
                    control(maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            maximized ? "Restore preview size" : "Maximize preview", "maximize") { toggleMaximized() }
                    control("xmark", "Close preview", "close", action: dismiss)
                }
                .frame(height: FloatingArtifactChromeMetrics.controlLength)
            }
            .padding(.leading, FloatingArtifactChromeMetrics.titleBarEdgeInset)
            .padding(.trailing, FloatingArtifactChromeMetrics.titleBarEdgeInset)
            .frame(height: FloatingArtifactChromeMetrics.titleBarHeight)
            .background(RelayTheme.elevated)

            Divider().overlay(RelayTheme.line)
            if artifact.failure == nil, artifact.kind != .log {
                HStack(spacing: 6) {
                    Text(artifact.kind == .pdf ? "PDF" : artifact.kind == .image ? "Image" : "Text")
                        .font(RelayTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                    Spacer(minLength: 8)
                    kindControls
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RelayTheme.surface)
                Divider().overlay(RelayTheme.line)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: displayedSize.width, height: displayedSize.height)
        .background(RelayTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).stroke(RelayTheme.line.opacity(0.55)) }
        .shadow(color: .black.opacity(0.3), radius: 16, y: 7)
        .overlay {
            if !maximized {
                ZStack {
                    ForEach(ResizeCorner.allCases, id: \.self) { corner in
                        resizeHandle(corner)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                    }
                }
            }
        }
        .offset(
            x: maximized ? 0 : offset.width + dragTranslation.width + displayedCenterShift.width,
            y: maximized ? 0 : offset.height + dragTranslation.height + displayedCenterShift.height
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of \(artifact.filename)")
        .accessibilityIdentifier(Self.axID)
        .onAppear {
            imagePixels = artifact.imagePixelSize
            if bounds.width > 0, bounds.height > 0 {
                panelSize = CGSize(width: min(560, max(260, bounds.width - 24)),
                                   height: min(440, max(180, bounds.height - 24)))
            }
        }
        .onChange(of: artifact.id) {
            imageZoom = 1; imagePan = .zero; imagePixels = artifact.imagePixelSize
        }
    }

    @ViewBuilder private var kindControls: some View {
        switch artifact.kind {
        case .image:
            control("minus", "Zoom out", "zoom-out", disabled: imageZoom <= zoomRange.lowerBound + 0.001) { setZoom(imageZoom / 1.25) }
            textControl("Fit", "Fit image to preview", "fit", help: "Fit · \(Int((imageZoom * 100).rounded()))% of fit") { resetImageView() }
            textControl("1:1", "Actual size", "actual-size", help: "Actual size · one image pixel per display pixel") { showActualSize() }
            control("plus", "Zoom in", "zoom-in", disabled: imageZoom >= zoomRange.upperBound - 0.001) { setZoom(imageZoom * 1.25) }
        case .pdf:
            control("chevron.left", "Previous page", "pdf-previous", disabled: !pdf.canGoBack) { pdf.previous() }
            Text(pdf.pageCount > 0 ? "\(pdf.pageIndex + 1)/\(pdf.pageCount)" : "–")
                .font(RelayTheme.font(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(RelayTheme.textMuted)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("Page \(pdf.pageIndex + 1) of \(pdf.pageCount)")
                .accessibilityIdentifier(Self.axID + ".pdf-page")
            control("chevron.right", "Next page", "pdf-next", disabled: !pdf.canGoForward) { pdf.next() }
            control("minus", "Zoom out", "zoom-out") { pdf.zoomOut() }
            textControl("Fit", "Fit page to preview", "fit") { pdf.fit() }
            control("plus", "Zoom in", "zoom-in") { pdf.zoomIn() }
        case .log:
            EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        if let failure = artifact.failure {
            VStack(spacing: RelayTheme.spacing(8)) {
                Image(systemName: "exclamationmark.triangle")
                    .font(RelayTheme.font(size: 16, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
                Text(failure)
                    .font(RelayTheme.font(size: 11))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .padding(RelayTheme.spacing(12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Could not preview \(artifact.filename): \(failure)")
            .accessibilityIdentifier(Self.axID + ".error")
        } else {
            switch artifact.kind {
            case .pdf:
                RelayPDFPreview(data: artifact.data, controller: pdf)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("PDF document: \(artifact.filename)")
                    .accessibilityIdentifier(Self.axID + ".pdf")
            case .log:
                VStack(spacing: RelayTheme.spacing(0)) {
                    if let label = artifact.log?.label {
                        Text(label)
                            .font(RelayTheme.font(size: 10, weight: .medium))
                            .foregroundStyle(RelayTheme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, RelayTheme.spacing(10))
                            .padding(.vertical, RelayTheme.spacing(4))
                            .background(RelayTheme.canvas.opacity(0.6))
                            .accessibilityIdentifier(Self.axID + ".partial")
                    }
                    RelayLogTextView(text: artifact.text ?? "")
                        .accessibilityLabel("Log text: \(artifact.filename)")
                        .accessibilityIdentifier(Self.axID + ".log")
                }
            case .image:
                if let image = artifact.image {
                    imageContent(image)
                } else {
                    Text("This image cannot be previewed.")
                        .font(RelayTheme.font(size: 11))
                        .foregroundStyle(RelayTheme.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func imageContent(_ image: NSImage) -> some View {
        GeometryReader { proxy in
            Image(nsImage: image)
                .resizable()
                .interpolation(displayedZoom > 1.01 ? .none : .high)
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(displayedZoom)
                .offset(clampedImagePan(in: proxy.size))
                .accessibilityLabel("Generated image: \(artifact.filename)")
        }
        .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { imageViewport = $0 }
        .background(Color.black.opacity(0.24))
        .contentShape(Rectangle())
        .clipped()
        .gesture(
            MagnificationGesture()
                .updating($pinchZoom) { value, state, _ in state = value }
                .onEnded { value in setZoom(imageZoom * value) }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .updating($imagePanTranslation) { value, state, _ in
                    guard displayedZoom > 1 else { return }
                    state = value.translation
                }
                .onEnded { value in
                    guard imageZoom > 1 else { return }
                    imagePan.width += value.translation.width
                    imagePan.height += value.translation.height
                }
        )
        .onTapGesture(count: 2) { resetImageView() }
        .help("Pinch to zoom · drag to pan · double-click to fit")
    }

    private func control(_ symbol: String, _ label: String, _ id: String, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(RelayTheme.font(size: 11, weight: .medium))
                .frame(width: FloatingArtifactChromeMetrics.controlLength, height: FloatingArtifactChromeMetrics.controlLength)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(RelayTheme.textMuted)
        .focusEffectDisabled()
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(Self.axID + "." + id)
    }

    private func textControl(_ title: String, _ label: String, _ id: String, help: String? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(RelayTheme.font(size: 10.5, weight: .medium))
                .padding(.horizontal, RelayTheme.spacing(7))
                .frame(height: FloatingArtifactChromeMetrics.controlLength)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(RelayTheme.textMuted)
        .focusEffectDisabled()
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(Self.axID + "." + id)
    }

    private func toggleMaximized() {
        if reduceMotion { maximized.toggle() } else { withAnimation(.easeOut(duration: 0.16)) { maximized.toggle() } }
    }

    private func resizeMetrics(for gesture: ResizeGestureState?) -> ResizeMetrics {
        guard let gesture else { return ResizeMetrics(size: panelSize, centerShift: .zero) }
        return resizeMetrics(corner: gesture.corner, translation: gesture.translation)
    }

    private func resizeMetrics(corner: ResizeCorner, translation: CGSize) -> ResizeMetrics {
        let width = min(760, max(260, panelSize.width + translation.width * corner.xDirection))
        let height = min(680, max(180, panelSize.height + translation.height * corner.yDirection))
        let widthChange = width - panelSize.width
        let heightChange = height - panelSize.height
        return ResizeMetrics(
            size: CGSize(width: width, height: height),
            centerShift: CGSize(
                width: widthChange * corner.xDirection / 2,
                height: heightChange * corner.yDirection / 2
            )
        )
    }

    private func resizeHandle(_ corner: ResizeCorner) -> some View {
        Color.clear
            .frame(
                width: FloatingArtifactChromeMetrics.resizeHandleLength,
                height: FloatingArtifactChromeMetrics.resizeHandleLength
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($resizeGesture) { value, state, _ in
                        state = ResizeGestureState(corner: corner, translation: value.translation)
                    }
                    .onEnded { value in
                        let metrics = resizeMetrics(corner: corner, translation: value.translation)
                        panelSize = metrics.size
                        offset.width += metrics.centerShift.width
                        offset.height += metrics.centerShift.height
                    }
            )
            .accessibilityLabel("Resize image pane from \(corner.accessibilityName) corner")
            .accessibilityHint("Drag to resize")
            .focusable()
            .focused($focusedResizeCorner, equals: corner)
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(5), style: .continuous)
                    .stroke(
                        focusedResizeCorner == corner ? RelayTheme.textMuted.opacity(0.65) : Color.clear,
                        lineWidth: 1
                    )
                    .padding(RelayTheme.spacing(6))
                    .accessibilityHidden(true)
            }
            .accessibilityAdjustableAction { direction in
                let amount: CGFloat = direction == .increment ? 24 : -24
                let translation = CGSize(
                    width: amount * corner.xDirection,
                    height: amount * corner.yDirection
                )
                let metrics = resizeMetrics(corner: corner, translation: translation)
                panelSize = metrics.size
                offset.width += metrics.centerShift.width
                offset.height += metrics.centerShift.height
            }
    }

    private func setZoom(_ proposedZoom: CGFloat) {
        imageZoom = min(zoomRange.upperBound, max(zoomRange.lowerBound, proposedZoom))
        if imageZoom <= 1 { imagePan = .zero }
    }

    private func showActualSize() {
        let apply = { imageZoom = actualSizeZoom; imagePan = .zero }
        if reduceMotion { apply() } else { withAnimation(.easeOut(duration: 0.14), apply) }
    }

    private func resetImageView() {
        let reset = {
            imageZoom = 1
            imagePan = .zero
        }
        if reduceMotion { reset() } else { withAnimation(.easeOut(duration: 0.14), reset) }
    }

    private func clampedImagePan(in viewport: CGSize) -> CGSize {
        guard displayedZoom > 1 else { return .zero }
        let proposed = CGSize(
            width: imagePan.width + imagePanTranslation.width,
            height: imagePan.height + imagePanTranslation.height
        )
        let maximumX = viewport.width * (displayedZoom - 1) / 2
        let maximumY = viewport.height * (displayedZoom - 1) / 2
        return CGSize(
            width: min(maximumX, max(-maximumX, proposed.width)),
            height: min(maximumY, max(-maximumY, proposed.height))
        )
    }
}

/// Read-only, selectable, monospaced log text. AppKit keeps a 1 MiB tail responsive.
private struct RelayLogTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = RelayPalette.canvas
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = RelayPalette.canvas
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        Task { @MainActor [weak textView] in textView?.scrollToEndOfDocument(nil) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}

private struct InlineArtifactView: View {
    let artifact: PaneArtifact
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack(spacing: RelayTheme.spacing(7)) {
                Image(systemName: artifact.kind.symbol)
                    .foregroundStyle(RelayTheme.blue)
                Text(artifact.filename)
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(RelayTheme.font(size: 9, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .focusEffectDisabled()
                .accessibilityLabel(artifact.kind == .log ? "Close inline text" : "Close inline image")
            }
            .padding(.horizontal, RelayTheme.spacing(10))
            .frame(height: 32)

            if artifact.kind == .log {
                VStack(spacing: 0) {
                    if let label = artifact.log?.label {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    RelayLogTextView(text: artifact.text ?? "")
                        .accessibilityLabel("Log text: \(artifact.filename)")
                }
            } else if artifact.isPDF {
                RelayPDFPreview(data: artifact.data).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image = artifact.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.2))
                    .accessibilityLabel("Generated image: \(artifact.filename)")
            }
        }
        .background(RelayTheme.canvas)
        .overlay(alignment: .top) {
            Rectangle().fill(RelayTheme.line.opacity(0.7)).frame(height: 1)
        }
    }
}

private struct SessionEndedOverlay: View {
    let exitCode: Int
    let restart: () -> Void
    let dismiss: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: RelayTheme.spacing(12)) {
            Image(systemName: "checkmark.circle")
                .font(RelayTheme.font(size: 18, weight: .medium))
                .foregroundStyle(RelayTheme.textMuted)
            Text("Remote process ended")
                .font(RelayTheme.font(size: 12.5, weight: .medium))
                .foregroundStyle(RelayTheme.text)
            Text(exitCode == -1 ? "Process terminated" : "Exit code \(exitCode)")
                .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(RelayTheme.textMuted)
            HStack(spacing: RelayTheme.spacing(8)) {
                Button("Close pane", action: close)
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.textMuted)
                    .padding(.horizontal, RelayTheme.spacing(11))
                    .frame(height: 28)
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
                Button("Restart", action: restart)
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.canvas)
                    .padding(.horizontal, RelayTheme.spacing(12))
                    .frame(height: 28)
                    .background(RelayTheme.blue, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
            }
            Button("Dismiss", action: dismiss)
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .foregroundStyle(RelayTheme.textMuted)
            Text("Restart opens a new shell. Saved provider sessions remain available to resume.")
                .font(RelayTheme.font(size: 10))
                .foregroundStyle(RelayTheme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
        }
        .padding(RelayTheme.spacing(20))
        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).stroke(RelayTheme.line.opacity(0.55)) }
    }
}

struct ConnectionPath: View {
    @EnvironmentObject private var linkSelection: PaneLinkSelection
    @ObservedObject private var agentPicker = RelayAgentPickerPresenter.shared
    @ObservedObject var pane: PaneModel
    let active: Bool
    let compact: Bool
    let zoomed: Bool
    let isFloating: Bool
    let select: () -> Void
    let toggleZoom: (() -> Void)?
    let toggleFloating: (() -> Void)?
    let rename: (() -> Void)?
    let terminate: (() -> Void)?
    let close: (() -> Void)?
    @ObservedObject private var preferences = RelayPreferences.shared

    var body: some View {
        HStack(spacing: RelayTheme.spacing(8)) {
            Circle()
                .fill(pane.connectionState.color)
                .frame(width: 6, height: 6)
            if let inputMessage = pane.terminalInputMessage {
                Label("Typing paused", systemImage: "keyboard")
                    .font(RelayTheme.font(size: 10, weight: .medium))
                    .foregroundStyle(.orange).lineLimit(1)
                    .help(inputMessage).accessibilityLabel("Typing paused. " + inputMessage)
            }
            let nameParts = PaneHeaderName.parts(pane.displayName)
            HStack(spacing: RelayTheme.spacing(5)) {
                Text(nameParts.name)
                    .font(RelayTheme.font(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let id = nameParts.id {
                    Text(id)
                        .font(RelayTheme.font(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.textFaint)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(2)
                }
            }
            .layoutPriority(3)
            .help(pane.displayName + " · " + pane.id.uuidString.lowercased())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pane " + pane.displayName)
            .onTapGesture(count: 2) { rename?() }
            if pane.profile.kind == .ssh, pane.displayName != pane.profile.host {
                droppable {
                    Text(pane.profile.host)
                        .font(RelayTheme.font(size: 11, weight: .medium))
                        .foregroundStyle(RelayTheme.textFaint)
                        .lineLimit(1)
                        .help(pane.profile.host)
                }
                .layoutPriority(-2)
            }
            if pane.profile.kind == .ssh {
                Text(pane.profile.backend == .relay ? "" : "SSH")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            if let directory = pane.directory, !directory.isEmpty {
                let component = TerminalPathSyntax.lastComponent(directory)
                droppable {
                    Text(component.isEmpty ? "/" : component)
                        .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.textFaint)
                        .lineLimit(1)
                        .help(directory)
                        .accessibilityLabel("Working directory \(directory)")
                }
                .layoutPriority(-1)
            }
            if pane.contentKind == .editor {
                Label("Editor", systemImage: "curlybraces")
                    .font(RelayTheme.font(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayTheme.blue)
                    .lineLimit(1)
            } else if pane.kind != .shell {
                Label(pane.activeSubagents > 0 ? String(pane.activeSubagents) + " agents" : pane.harnessLabel,
                      systemImage: pane.kind.symbol)
                    .font(RelayTheme.font(size: 9.5, weight: .medium))
                    .foregroundStyle(pane.phaseColor)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(2)
                RelayAgentAccountBadge(pane: pane)
                    .layoutPriority(2)
                if pane.pendingAgentApprovals > 0 {
                    Image(systemName: "hand.raised.fill")
                        .font(RelayTheme.font(size: 9, weight: .medium))
                        .foregroundStyle(RelayTheme.coral)
                        .accessibilityLabel("\(pane.pendingAgentApprovals) pending agent approvals")
                }
                if let usage = pane.agentResourceUsage {
                    Text("\(usage.inputTokens + usage.outputTokens) tok")
                        .font(RelayTheme.font(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.textFaint)
                        .help("Input \(usage.inputTokens), cached \(usage.cachedInputTokens), output \(usage.outputTokens)")
                }
            }
            Spacer(minLength: 8)
            if let detail = pane.headerActivityDetail {
                droppable {
                    Button(action: inspectAgent) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(RelayTheme.textMuted)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RelayHeaderLinkStyle())
                    .help(detail + " · Show agent details")
                    .accessibilityLabel(detail)
                    .accessibilityHint("Shows agent details")
                }
                .layoutPriority(-1)
            }
            if let status = headerStatus {
                RelayBadge(status.text, role: status.role)
                    .fixedSize()
                    .layoutPriority(2)
                    .help(status.text + (pane.lastCommandExitCode.map { $0 == 0 ? "" : " · last command exited with status \($0)" } ?? ""))
            }
            if connectionNormal { RelayProgramStatusBadge(pane: pane).layoutPriority(2) }
            if let progress = pane.terminalProgressPercent {
                ProgressView(value: Double(progress), total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 42)
                    .help("Command progress \(progress) percent")
                    .accessibilityLabel("Command progress")
                    .accessibilityValue("\(progress) percent")
            } else if pane.terminalProgressState == "indeterminate" {
                Image(systemName: "ellipsis")
                    .font(RelayTheme.font(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayTheme.accent)
                    .help("Command in progress")
                    .accessibilityLabel("Command in progress")
            }
            // An exited or disconnected pane already shows that as its status.
            if connectionNormal, let exitCode = pane.lastCommandExitCode {
                Image(systemName: exitCode == 0 ? "checkmark.circle" : "xmark.circle")
                    .font(RelayTheme.font(size: 9.5, weight: .medium))
                    .foregroundStyle(exitCode == 0 ? RelayTheme.textFaint : RelayTheme.coral)
                    .help(commandStatusHelp(exitCode: exitCode, durationNanos: pane.lastCommandDurationNanos))
                    .accessibilityLabel(exitCode == 0 ? "Last command succeeded" : "Last command exited with status \(exitCode)")
            }
            if pane.contentKind == .terminal || toggleFloating != nil || toggleZoom != nil || close != nil {
                HStack(spacing: RelayTheme.spacing(0)) {
                    if pane.contentKind == .terminal {
                        // A pane with saved or pending links keeps its link control,
                        // which carries that state and the saved-links popover.
                        if linkControlVisible {
                            PaneHeaderLinkButton(paneID: pane.id)
                        }
                        overflowMenu
                    }
                    if let toggleZoom {
                        Button(action: toggleZoom) {
                            Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(RelayTheme.font(size: 9.5, weight: .medium))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(RelayTheme.textMuted)
                        .focusEffectDisabled()
                        .help(zoomed ? "Restore pane layout" : "Zoom pane")
                        .accessibilityLabel(zoomed ? "Restore pane layout" : "Zoom pane")
                    }
                    if let close {
                        Button(action: close) {
                            Image(systemName: "xmark")
                                .font(RelayTheme.font(size: 9, weight: .medium))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(RelayTheme.textMuted)
                        .focusEffectDisabled()
                        .help(pane.profile.kind == .ssh ? "Detach pane · ⌘W" : "Close pane · ⌘W")
                        .accessibilityLabel(pane.profile.kind == .ssh ? "Detach pane" : "Close pane")
                    }
                }
                .frame(height: 24)
                .fixedSize()
                .layoutPriority(4)
            }
        }
        .padding(.horizontal, compact ? 9 : 12)
        .frame(height: compact || preferences.compactInterface ? 28 : 34)
        .foregroundStyle(active ? RelayTheme.text : RelayTheme.textMuted)
        .background(active ? RelayTheme.surface : RelayTheme.canvas)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            if let rename { Button("Rename pane…", action: rename) }
            Button("Copy Pane ID") { copyWorkspaceID(pane.id) }
            if pane.contentKind == .terminal {
                Button("Reconnect pane") {
                    NotificationCenter.default.post(name: .relayReconnectPane, object: pane.id)
                }
                if pane.remoteExitCode != nil || pane.phase == .exited {
                    Button("Resume saved conversation") {
                        NotificationCenter.default.post(name: .relayResumeSavedConversation, object: pane.id)
                    }
                    Button("Open new shell") {
                        NotificationCenter.default.post(name: .relayRestartExitedPane, object: pane.id)
                    }
                }
                Button(pane.nativeConversationVisible ? "Return to terminal" : "View CLI conversation", action: toggleConversation)
                if pane.kind != .shell { Button("Agent details…", action: inspectAgent) }
                Button("Connect with other sessions…") {
                    NotificationCenter.default.post(name: .relayConnectPaneSessions, object: pane.id)
                }
                Menu("Agent type") {
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        Button {
                            pane.setAgentKind(kind)
                        } label: {
                            Label(kind.label, systemImage: pane.kind == kind ? "checkmark" : kind.symbol)
                        }
                    }
                }
                RelayAgentAccountMenus(pane: pane)
            }
            if rename != nil || pane.contentKind == .terminal { Divider() }
            if let toggleZoom { Button(zoomed ? "Restore pane layout" : "Zoom pane", action: toggleZoom) }
            if let toggleFloating { Button(isFloating ? "Dock pane" : "Float pane", action: toggleFloating) }
            if let close { Button(pane.profile.kind == .ssh ? "Detach pane" : "Close pane", action: close) }
            if pane.profile.kind == .ssh, pane.profile.backend == .relay, let terminate {
                Button("Terminate remote pane…", role: .destructive, action: terminate)
            }
        }
    }

    /// A secondary field that cannot show a readable stub is hidden, not shown as one letter.
    private func droppable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shown = content()
        return ViewThatFits(in: .horizontal) {
            shown.frame(minWidth: 56, alignment: .leading)
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private var linkControlVisible: Bool {
        linkSelection.paneIDs.contains(pane.id) || !linkSelection.memberships(for: pane.id).isEmpty
    }

    private var connectionNormal: Bool { pane.connectionIsNormal }

    private var headerStatus: (text: String, role: RelayTheme.StatusRole)? { pane.headerStatus }

    /// Secondary pane actions in one keyboard-reachable menu so the name keeps its width.
    private var overflowMenu: some View {
        Menu {
            Button("Start agent…") { agentPicker.paneID = pane.id }
            if !linkControlVisible {
                Button("Link with another pane") { linkSelection.selectPairPane(pane.id) }
                    .disabled(linkSelection.connecting)
            }
            Button(pane.nativeConversationVisible ? "Return to terminal" : "View CLI conversation", action: toggleConversation)
            if pane.kind != .shell { Button("Agent details…", action: inspectAgent) }
            if let toggleFloating {
                Button(isFloating ? "Dock pane" : "Float pane", action: toggleFloating)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(RelayTheme.font(size: 9.5, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(RelayTheme.textMuted)
        .help("More pane actions")
        .accessibilityLabel("More pane actions")
        .accessibilityIdentifier("relay.pane.more-actions." + pane.id.uuidString.lowercased())
        .popover(isPresented: Binding(get: { agentPicker.paneID == pane.id },
                                      set: { if !$0, agentPicker.paneID == pane.id { agentPicker.paneID = nil } }),
                 arrowEdge: .bottom) {
            RelayAgentPicker(pane: pane) { agentPicker.paneID = nil }
        }
    }

    /// Opens the floating inspector on this pane's agent: its steps, plans and sub-agents.
    private func inspectAgent() {
        select()
        NotificationCenter.default.post(name: .relayInspectPaneAgent, object: pane.id)
    }

    private func toggleConversation() {
        select()
        if pane.nativeConversationVisible {
            pane.nativeConversationVisible = false
        } else {
            RelayToolWindowCoordinator.shared.showAgent(pane: pane)
        }
    }

    private func commandStatusHelp(exitCode: Int, durationNanos: UInt64?) -> String {
        guard let durationNanos else { return "Last command exited with status \(exitCode)" }
        let seconds = Double(durationNanos) / 1_000_000_000
        return String(format: "Last command exited with status %d in %.2f s", exitCode, seconds)
    }
}

private struct ConnectingOverlay: View {
    let host: String
    let contentKind: PaneContentKind

    var body: some View {
        VStack(spacing: RelayTheme.spacing(13)) {
            ProgressView()
                .controlSize(.small)
                .tint(RelayTheme.accent)
            Text(contentKind == .editor ? "Opening remote workspace" : "Opening remote session")
                .font(RelayTheme.font(size: 13, weight: .medium))
                .foregroundStyle(RelayTheme.text)
            Text(contentKind == .editor ? "\(host)  →  code editor" : "\(host)  →  native terminal")
                .font(RelayTheme.font(size: 11, weight: .medium))
                .foregroundStyle(RelayTheme.textMuted)
        }
        .padding(RelayTheme.spacing(22))
        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).stroke(RelayTheme.line.opacity(0.5)) }
    }
}

private struct RestoringTerminalOverlay: View {
    let host: String

    var body: some View {
        ZStack {
            RelayTheme.canvas
            VStack(spacing: RelayTheme.spacing(13)) {
                ProgressView()
                    .controlSize(.small)
                    .tint(RelayTheme.accent)
                Text("Restoring terminal")
                    .font(RelayTheme.font(size: 13, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                Text("Showing the current screen on \(host)")
                    .font(RelayTheme.font(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            .padding(RelayTheme.spacing(22))
            .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8), style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).stroke(RelayTheme.line.opacity(0.5)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConnectionErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil
    var manageRelayd: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: RelayTheme.spacing(9)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(RelayTheme.coral)
            VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                Text("Could not reach the remote session")
                    .font(RelayTheme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                Text(message)
                    .font(RelayTheme.font(size: 11))
                    .foregroundStyle(RelayTheme.textMuted)
                    .lineLimit(2)
            }
            Spacer()
            if let manageRelayd {
                Button("Install relayd", action: manageRelayd)
                    .buttonStyle(.plain)
                    .font(RelayTheme.font(size: 10.5, weight: .medium))
                    .foregroundStyle(RelayTheme.blue)
                    .padding(.horizontal, RelayTheme.spacing(10))
                    .frame(height: 26)
                    .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
            }
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .font(RelayTheme.font(size: 10.5, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                    .padding(.horizontal, RelayTheme.spacing(10))
                    .frame(height: 26)
                    .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(7)))
            }
        }
        .padding(RelayTheme.spacing(11))
        .background(RelayTheme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10)))
        .overlay { RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10)).stroke(RelayTheme.coral.opacity(0.35)) }
    }
}

private struct ConnectionRecoveryBanner: View {
    let host: String
    let message: String
    let waitingForNetwork: Bool

    var body: some View {
        HStack(spacing: RelayTheme.spacing(10)) {
            Image(systemName: waitingForNetwork ? "network.slash" : "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(waitingForNetwork ? RelayTheme.coral : RelayTheme.blue)
            VStack(alignment: .leading, spacing: RelayTheme.spacing(2)) {
                Text(waitingForNetwork ? "Can't reach \(host)" : "Reconnecting to \(host)")
                    .font(RelayTheme.font(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                Text(message)
                    .font(RelayTheme.font(size: 11))
                    .foregroundStyle(RelayTheme.textMuted)
                    .lineLimit(2)
            }
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(RelayTheme.accent)
        }
        .padding(RelayTheme.spacing(11))
        .background(RelayTheme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10)))
        .overlay {
            RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(10))
                .stroke((waitingForNetwork ? RelayTheme.coral : RelayTheme.blue).opacity(0.32))
        }
    }
}

@MainActor
private final class RelayNativeToolWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
func showOriginalCLIConversation(pane: PaneModel) {
    RelayToolWindowCoordinator.shared.showAgent(pane: pane)
}

@MainActor
final class RelayToolWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = RelayToolWindowCoordinator()
    @Published private(set) var rPaneIDs: Set<UUID> = []
    @Published private(set) var detachedRPanels: Set<String> = []
    @Published var extraRPanels: [String: [RExtraPanel]] = [:]
    @Published var embeddedRWorkspaces: [String: REmbeddedContent] = [:]
    @Published var embeddedRPanels: [String: REmbeddedContent] = [:]
    @Published var minimizedRPanels: Set<String> = []
    @Published var selectedRWorkspace: String?
    @Published var minimizedRWorkspaces: Set<String> = []
    @Published var rPanelPlacements: [String: RPanelPlacement] = [:]
    private var rPrimaryEditors: [String: UUID] = [:]
    var initiallyFloatedRPanelKeys: Set<String> = []
    private var windows: [String: NSWindow] = [:]
    private var rWindows: [String: Set<UUID>] = [:]
    private var rPanelParents: [String: String] = [:]

    private func present<Content: View>(_ key: String, title: String, content: Content) {
        if let window = windows[key] { window.makeKeyAndOrderFront(nil); return }
        let vpnWindow = key.hasSuffix(":relay.vpn:main")
        let size = vpnWindow ? NSSize(width: 560, height: 560) : NSSize(width: 1120, height: 700)
        let window = RelayNativeToolWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        RelayToolSurface.configure(window)
        window.minSize = vpnWindow ? NSSize(width: 480, height: 440) : NSSize(width: 720, height: 460)
        window.level = .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        let hosting = NSHostingView(rootView: content.relaySurface().environment(\.relayNativeToolSurface, true))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(size)
        windows[key] = window
        if let parent = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "dev.relay.terminal.workspace" && $0.isVisible
        }) {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                          y: parent.frame.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    func show(workspace: WorkspaceModel, pane: PaneModel, toolID: String) {
        let key = pane.id.uuidString + ":" + toolID
        let parts = toolID.split(separator: ":", maxSplits: 1).map(String.init)
        let package = parts.first.flatMap { RelayPluginManager.shared.reviewedInstallations[$0]?.package }
        let title = package?.contributions.first(where: { parts.count == 2 && $0.id == parts[1] })?.title ?? "Tool"
        present(key, title: title, content: StandalonePluginWorkspace(workspace: workspace, pane: pane, toolID: toolID))
    }

    @Published var embeddedAgentPaneID: UUID?

    func showAgent(pane: PaneModel) {
        embeddedAgentPaneID = nil
        pane.nativeConversationVisible = true
        windows["Agent:" + pane.id.uuidString]?.close()
    }

    private func showDetachedAgent(pane: PaneModel) {
        let key = "Agent:" + pane.id.uuidString
        present(key, title: "Agent conversation · " + pane.displayName, content: RelayAgentConversationHostView(pane: pane))
        windows[key]?.identifier = NSUserInterfaceItemIdentifier("relay.agent." + pane.id.uuidString)
    }

    func showHPC(workspace: WorkspaceModel, pane: PaneModel) {
        let key = "HPC"
        present(key, title: "HPC", content: HPCDiscoveryWorkspace(
            workspace: workspace, preferredPaneID: pane.id,
            close: { [weak self] in self?.windows[key]?.close() }))
    }

    func showR(workspace: WorkspaceModel, consoleID requestedConsoleID: UUID? = nil, restoring: Bool = false) {
        guard let active = workspace.activePane else { return }
        let consoleID = requestedConsoleID ?? (active.contentKind == .editor
            ? active.remoteParentSessionID.flatMap(UUID.init(uuidString:)) : active.id)
        guard let consoleID, let console = workspace.panes[consoleID] else { return }
        let key = consoleID.uuidString + ":RStudio"
        if embeddedRWorkspaces[key] != nil {
            minimizedRWorkspaces.remove(key)
            selectedRWorkspace = key
            return
        }
        guard console.kind == .shell else {
            workspace.operationError = "Select an R console or a shell before opening the RStudio workspace."
            return
        }
        let editor: PaneModel
        do { editor = try workspace.prepareFloatingRWorkspace(consoleID: consoleID) }
        catch { workspace.operationError = error.localizedDescription; return }
        editor.editorRuntime.showsRResults = true
        editor.editorRuntime.externalRResults = true
        if restoring { editor.editorRuntime.refreshRSession() }
        else { editor.editorRuntime.connectRWorkspaceWhenReady() }
        rPrimaryEditors[key] = editor.id
        let ids = Set([console.id, editor.id] + (extraRPanels[key] ?? []).compactMap { $0.pane?.id })
        rWindows[key] = ids
        rPaneIDs.formUnion(ids)
        embeddedRWorkspaces[key] = REmbeddedContent(
            title: "R workspace · " + console.profile.host,
            owner: ObjectIdentifier(workspace),
            content: AnyView(RStandaloneWorkspace(workspace: workspace, editor: editor, console: console)
                .environmentObject(workspace.paneLinkSelection)))
        selectedRWorkspace = key
    }

    func presentationSnapshot(workspace: WorkspaceModel) -> [RWorkspacePresentation] {
        embeddedRWorkspaces.keys.sorted().compactMap { key in
            guard embeddedRWorkspaces[key]?.owner == ObjectIdentifier(workspace),
                  let consoleID = UUID(uuidString: String(key.split(separator: ":")[0])),
                  let editorID = rPrimaryEditors[key],
                  let tabID = workspace.rPresentationTabID(consoleID: consoleID) else { return nil }
            return RWorkspacePresentation(consoleID: consoleID, editorID: editorID, tabID: tabID,
                selected: selectedRWorkspace == key, minimized: minimizedRWorkspaces.contains(key),
                placement: rPanelPlacements[key], extras: (extraRPanels[key] ?? []).map { panel in
                    let child = panel.id.uuidString
                    return RExtraPresentation(id: panel.id, title: panel.title, paneID: panel.pane?.id,
                        returnsToTab: panel.returnsToTab, floating: detachedRPanels.contains(child),
                        minimized: minimizedRPanels.contains(child), placement: rPanelPlacements[child])
                })
        }
    }

    func restorePresentations(workspace: WorkspaceModel) {
        guard workspace.captureRPresentations == nil else { return }
        let saved = workspace.savedRPresentations
        // Each restore selects its R tab temporarily, without navigation
        // effects: nothing is published and the shown workspace never moves.
        workspace.withoutNavigationEffects {
            for item in saved {
                guard workspace.panes[item.consoleID] != nil else { continue }
                workspace.selectedTabID = item.tabID
                workspace.activePaneID = item.consoleID
                let key = item.consoleID.uuidString + ":RStudio"
                rPanelPlacements[key] = item.placement
                extraRPanels[key] = item.extras.compactMap { extra in
                    if let id = extra.paneID, workspace.panes[id] == nil { return nil }
                    let child = extra.id.uuidString
                    rPanelPlacements[child] = extra.placement
                    if extra.minimized { minimizedRPanels.insert(child) }
                    // A docked panel must not be floated by its initial onAppear.
                    if !extra.floating { initiallyFloatedRPanelKeys.insert(child) }
                    return RExtraPanel(id: extra.id, title: extra.title,
                        pane: extra.paneID.flatMap { workspace.panes[$0] }, returnsToTab: extra.returnsToTab)
                }
                showR(workspace: workspace, consoleID: item.consoleID, restoring: true)
                for extra in extraRPanels[key] ?? [] where item.extras.first(where: { $0.id == extra.id })?.floating == true {
                    guard let editor = workspace.panes[item.editorID] else { continue }
                    initiallyFloatedRPanelKeys.insert(extra.id.uuidString)
                    let restoredContent = AnyView(Group {
                        if let pane = extra.pane {
                            PaneView(pane: pane, isActive: true, compactChrome: true,
                                select: { if pane.contentKind == .terminal { workspace.selectPane(pane.id, origin: .user) } }, inToolWindow: true)
                                .environmentObject(workspace.paneLinkSelection)
                        } else {
                            RLayoutResultsDock(runtime: editor.editorRuntime)
                        }
                    })
                    detachRPanel(key: extra.id.uuidString, parent: key, title: "RStudio · " + extra.title, content: restoredContent)
                }
                if item.minimized { minimizedRWorkspaces.insert(key) }
            }
            if let selected = saved.first(where: \.selected) {
                selectedRWorkspace = selected.consoleID.uuidString + ":RStudio"
            }
        }
        workspace.captureRPresentations = { [weak self, weak workspace] in
            guard let self, let workspace else { return [] }
            return self.presentationSnapshot(workspace: workspace)
        }
        workspace.revealFloatingRPane = { [weak self, weak workspace] paneID in
            guard let self, let workspace else { return }
            self.revealR(paneID: paneID, workspace: workspace)
        }
    }

    /// Brings forward the R workspace holding a pane and the pane's own
    /// panel, presenting an editor that is not drawn yet, so selecting draws
    /// that exact pane.
    func revealR(paneID: UUID, workspace: WorkspaceModel) {
        if let key = rWindows.first(where: { $0.value.contains(paneID) })?.key {
            for panel in extraRPanels[key] ?? [] where panel.pane?.id == paneID {
                minimizedRPanels.remove(panel.id.uuidString)
            }
            return focusR(paneID: paneID)
        }
        guard let pane = workspace.panes[paneID], pane.contentKind == .editor,
              let consoleID = pane.remoteParentSessionID.flatMap(UUID.init(uuidString:)) else { return }
        // The editor becomes the primary of a workspace that has none, or
        // else a panel of the console's workspace beside its primary.
        workspace.adoptFloatingRPrimaryEditor(paneID, consoleID: consoleID)
        let key = consoleID.uuidString + ":RStudio"
        showR(workspace: workspace, consoleID: consoleID, restoring: true)
        guard embeddedRWorkspaces[key] != nil, rWindows[key]?.contains(paneID) != true else { return }
        registerExtraRPanel(RExtraPanel(title: "Editor \((extraRPanels[key] ?? []).count + 2)", pane: pane), parent: key)
    }

    func addExistingRTerminal(_ pane: PaneModel, parent: String) {
        guard !rPaneIDs.contains(pane.id), pane.contentKind == .terminal else { return }
        extraRPanels[parent, default: []].append(RExtraPanel(title: pane.harnessLabel + " · " + pane.displayName, pane: pane, returnsToTab: true))
        rWindows[parent, default: []].insert(pane.id)
        rPaneIDs.insert(pane.id)
    }

    func newRWorkspace(workspace: WorkspaceModel, console: PaneModel) {
        do {
            let newConsole = try workspace.addFloatingRPanel(consoleID: console.id, contentKind: .terminal)
            showR(workspace: workspace, consoleID: newConsole.id)
        } catch { workspace.operationError = error.localizedDescription }
    }

    func returnRPaneToTab(paneID: UUID) {
        guard let key = rWindows.first(where: { $0.value.contains(paneID) })?.key else { return }
        if let panel = extraRPanels[key]?.first(where: { $0.pane?.id == paneID && $0.returnsToTab }) {
            let panelKey = panel.id.uuidString
            dockEmbeddedRPanel(panelKey)
            extraRPanels[key]?.removeAll { $0.id == panel.id }
            initiallyFloatedRPanelKeys.remove(panelKey)
            rWindows[key]?.remove(paneID)
            rPaneIDs.remove(paneID)
            return
        }
        closeEmbeddedRWorkspace(key)
    }

    func focusR(paneID: UUID) {
        if let key = rWindows.first(where: { $0.value.contains(paneID) })?.key {
            minimizedRWorkspaces.remove(key)
            selectedRWorkspace = key
        }
    }

    func detachRPanel<Content: View>(key: String, parent: String, title: String, content: Content) {
        guard let owner = embeddedRWorkspaces[parent]?.owner else { return }
        rPanelParents[key] = parent
        detachedRPanels.insert(key)
        embeddedRPanels[key] = REmbeddedContent(title: title, owner: owner, content: AnyView(content))
    }

    func focusRPanel(_ key: String) {
        if let parent = rPanelParents[key] { selectedRWorkspace = parent }
    }

    func dockEmbeddedRPanel(_ key: String) {
        minimizedRPanels.remove(key)
        embeddedRPanels.removeValue(forKey: key)
        detachedRPanels.remove(key)
        rPanelParents.removeValue(forKey: key)
    }

    func panelsForRWorkspace(_ key: String) -> [String] {
        rPanelParents.filter { $0.value == key }.map(\.key).sorted()
    }

    func closeEmbeddedRWorkspace(_ key: String) {
        minimizedRWorkspaces.remove(key)
        for child in panelsForRWorkspace(key) { dockEmbeddedRPanel(child) }
        embeddedRWorkspaces.removeValue(forKey: key)
        if selectedRWorkspace == key { selectedRWorkspace = nil }
        if let ids = rWindows.removeValue(forKey: key) {
            extraRPanels[key]?.removeAll { $0.returnsToTab }
            rPaneIDs.subtract(ids)
        }
    }

    func registerExtraRPanel(_ panel: RExtraPanel, parent: String) {
        extraRPanels[parent, default: []].append(panel)
        if let pane = panel.pane {
            rWindows[parent, default: []].insert(pane.id)
            rPaneIDs.insert(pane.id)
        }
    }

    func closeExtraRPanel(_ key: String, parent: String, workspace: WorkspaceModel, consoleID: UUID) {
        guard let panel = extraRPanels[parent]?.first(where: { $0.id.uuidString == key }) else { return }
        if let pane = panel.pane, !panel.returnsToTab,
           !workspace.closeFloatingRPanel(pane.id, consoleID: consoleID) { return }
        dockEmbeddedRPanel(key)
        extraRPanels[parent]?.removeAll { $0.id.uuidString == key }
        initiallyFloatedRPanelKeys.remove(key)
        if let pane = panel.pane {
            rWindows[parent]?.remove(pane.id)
            rPaneIDs.remove(pane.id)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value === window })?.key else { return }
        window.contentView = nil
        windows[key] = nil
        if let parent = rPanelParents.removeValue(forKey: key) {
            detachedRPanels.remove(key)
            windows[parent]?.makeKeyAndOrderFront(nil)
        }
        let children = rPanelParents.filter { $0.value == key }.map(\.key)
        for child in children { windows[child]?.close() }
        if let ids = rWindows.removeValue(forKey: key) {
            extraRPanels[key]?.removeAll { $0.returnsToTab }
            rPaneIDs.subtract(ids)
        }
    }
}

private struct StandalonePluginWorkspace: View {
    @ObservedObject var workspace: WorkspaceModel
    let pane: PaneModel
    let toolID: String
    @StateObject private var presentation = PluginToolPresentation()
    @StateObject private var chrome = WorkspaceChrome()
    var body: some View {
        RelayPluginToolsView(workspace: workspace, presentation: presentation,
                             chrome: chrome, presentationStyle: .floating)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RelayTheme.surface)
            .onAppear {
                presentation.captureOnce(id: pane.id,
                profile: workspace.executionContext()?.profile ?? pane.profile,
                directory: workspace.executionContext()?.directory ?? pane.directory)
                presentation.selection = toolID
                chrome.reveal(.files, initial: WorkspaceContextAnchor(paneID: pane.id,
                               profile: pane.profile, directory: pane.directory))
            }
    }
}

struct REmbeddedContent {
    let title: String
    let owner: ObjectIdentifier
    let content: AnyView
}

private struct RPresentationPersistence: ViewModifier {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var windows = RelayToolWindowCoordinator.shared

    func body(content: Content) -> some View {
        content
            .onAppear { windows.restorePresentations(workspace: workspace) }
            .onChange(of: windows.presentationSnapshot(workspace: workspace)) { _, _ in
                workspace.persistRPresentation()
            }
            .onChange(of: workspace.sidebarVisible) { _, _ in workspace.persistRPresentation() }
    }
}

private struct RBoundedWorkspaceHost: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var windows = RelayToolWindowCoordinator.shared

    var body: some View {
        if let key = windows.selectedRWorkspace,
           let item = windows.embeddedRWorkspaces[key],
           let consoleID = UUID(uuidString: String(key.prefix(36))),
           workspace.selectedTab?.allPaneIDs.contains(consoleID) == true,
           item.owner == ObjectIdentifier(workspace) {
            ZStack(alignment: .bottomTrailing) {
            RBoundedPanel(title: item.title, initialSize: CGSize(width: 1120, height: 740),
                          closeLabel: "Close R workspace", close: { windows.closeEmbeddedRWorkspace(key) },
                          minimize: { windows.minimizedRWorkspaces.insert(key) },
                          savedPlacement: windows.rPanelPlacements[key],
                          placementChanged: { windows.rPanelPlacements[key] = $0; workspace.persistRPresentation() }) {
                item.content
            }.id(key)
                .opacity(windows.minimizedRWorkspaces.contains(key) ? 0 : 1)
                .allowsHitTesting(!windows.minimizedRWorkspaces.contains(key))
                .accessibilityHidden(windows.minimizedRWorkspaces.contains(key))
            if windows.minimizedRWorkspaces.contains(key) {
                Button {
                    windows.minimizedRWorkspaces.remove(key)
                } label: { Label(item.title, systemImage: "r.square") }
                    .help("Restore R workspace")
                    .accessibilityLabel("Restore R workspace")
                    .padding(RelayTheme.spacing(12)).background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
                    .padding(RelayTheme.spacing(12))
            }
            }
                .padding(.top, workspace.isFullScreen ? 40 : 46)
                .padding(.leading, workspace.sidebarVisible
                         ? (RelayPreferences.shared.compactInterface ? 245 : 261) : 0)
        }
    }
}

// Both levels live in the parent's view hierarchy; geometry is always clamped
// to that parent, including during drags, resizes and main-window resizing.
private struct RBoundedPanel<Content: View>: View {
    let title: String
    let initialSize: CGSize
    let closeLabel: String
    let close: () -> Void
    var minimize: (() -> Void)? = nil
    var showsClose = true
    var savedPlacement: RPanelPlacement? = nil
    var placementChanged: ((RPanelPlacement) -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var origin = CGPoint(x: 16, y: 16)
    @State private var size: CGSize?
    @State private var maximized = false
    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGSize?
    @State private var coordinateID = UUID()

    var body: some View {
        GeometryReader { geometry in
            let base = size ?? initialSize
            let width = maximized ? geometry.size.width : min(geometry.size.width, max(min(360, geometry.size.width), base.width))
            let height = maximized ? geometry.size.height : min(geometry.size.height, max(min(240, geometry.size.height), base.height))
            let x = maximized ? 0 : min(max(0, origin.x), max(0, geometry.size.width - width))
            let y = maximized ? 0 : min(max(0, origin.y), max(0, geometry.size.height - height))
            VStack(spacing: RelayTheme.spacing(0)) {
                HStack {
                    Text(title).font(RelayTheme.font(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { maximized.toggle() }
                        .gesture(DragGesture(coordinateSpace: .named(coordinateID))
                            .onChanged { value in
                                guard !maximized else { return }
                                if dragStart == nil { dragStart = CGPoint(x: x, y: y) }
                                guard let start = dragStart else { return }
                                origin = CGPoint(
                                    x: min(max(0, start.x + value.translation.width), max(0, geometry.size.width - width)),
                                    y: min(max(0, start.y + value.translation.height), max(0, geometry.size.height - height)))
                            }.onEnded { _ in dragStart = nil })
                    Button { maximized.toggle() } label: {
                        Image(systemName: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(.plain)
                        .help(maximized ? "Restore size" : "Maximise inside Relay")
                        .accessibilityLabel(maximized ? "Restore " + title : "Maximise " + title)
                    if let minimize {
                        Button(action: minimize) { Image(systemName: "minus") }
                            .buttonStyle(.plain).help("Minimise panel")
                            .accessibilityLabel("Minimise " + title)
                    }
                    if showsClose {
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help(closeLabel).accessibilityLabel(closeLabel)
                    }
                }.padding(RelayTheme.spacing(10)).background(RelayTheme.surface)
                Divider()
                content().frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
            .frame(width: width, height: height)
            .background(RelayTheme.canvas)
            .overlay(alignment: .bottomTrailing) {
                if !maximized {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(RelayTheme.font(size: 10)).padding(RelayTheme.spacing(7)).background(RelayTheme.surface)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .named(coordinateID))
                        .onChanged { value in
                            if resizeStart == nil {
                                resizeStart = CGSize(width: width, height: height)
                                origin = CGPoint(x: x, y: y)
                            }
                            guard let start = resizeStart else { return }
                            size = CGSize(width: min(geometry.size.width - origin.x, max(360, start.width + value.translation.width)),
                                          height: min(geometry.size.height - origin.y, max(240, start.height + value.translation.height)))
                        }.onEnded { _ in resizeStart = nil })
                    .accessibilityLabel("Resize " + title)
                }
            }
            .overlay(Rectangle().stroke(RelayTheme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            .offset(x: x, y: y)
        }.coordinateSpace(name: coordinateID).clipped()
        .onAppear {
            if let savedPlacement {
                origin = CGPoint(x: savedPlacement.x, y: savedPlacement.y)
                size = CGSize(width: savedPlacement.width, height: savedPlacement.height)
                maximized = savedPlacement.maximized
            }
        }
        .onChange(of: origin) { _, _ in savePlacement() }
        .onChange(of: size) { _, _ in savePlacement() }
        .onChange(of: maximized) { _, _ in savePlacement() }
    }

    private func savePlacement() {
        let actual = size ?? initialSize
        placementChanged?(RPanelPlacement(x: origin.x, y: origin.y, width: actual.width,
            height: actual.height, maximized: maximized))
    }
}

private struct RStandaloneWorkspace: View {
    @ObservedObject var workspace: WorkspaceModel
    let editor: PaneModel
    let console: PaneModel
    private var parentKey: String { console.id.uuidString + ":RStudio" }
    private var extraPanels: [RExtraPanel] { windows.extraRPanels[parentKey] ?? [] }
    @ObservedObject private var windows = RelayToolWindowCoordinator.shared
    @State private var terminalDropTargeted = false
    @State private var showingTerminalPicker = false
    @State private var selectedTerminalIDs: Set<UUID> = []
    @State private var rLinkNotice: String?
    private func linkTerminal(_ pane: PaneModel) {
        windows.addExistingRTerminal(pane, parent: parentKey)
        guard let session = editor.editorRuntime.rSession else { return }
        Task { @MainActor in
            do {
                _ = try await RAutomationController.shared.authorize(paneID: console.id,
                    expected: session.session_id, id: UUID(), workspace: workspace)
            } catch { rLinkNotice = error.localizedDescription }
        }
    }
    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack {
                Button { addPanel(.terminal) } label: {
                    Image(systemName: "terminal")
                }.buttonStyle(.plain)
                    .frame(width: 30, height: 30)
                    .help("New floating console")
                    .accessibilityLabel("New floating console")
                Button {
                    selectedTerminalIDs.removeAll()
                    showingTerminalPicker = true
                } label: {
                    Label("Add existing terminal", systemImage: "rectangle.stack.badge.plus")
                        .labelStyle(.iconOnly)
                }.buttonStyle(.plain)
                    .font(RelayTheme.font(size: 11))
                    .padding(.horizontal, RelayTheme.spacing(10)).frame(height: 30)
                    .background(terminalDropTargeted ? RelayTheme.accent.opacity(0.2) : RelayTheme.surface,
                                in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
                    .help("Add an existing Claude, Codex or terminal pane")
                    .popover(isPresented: $showingTerminalPicker) {
                        VStack(alignment: .leading, spacing: RelayTheme.spacing(8)) {
                            Text("Add existing terminal").font(.headline)
                            Text("From this R workspace’s original tab")
                                .font(.caption).foregroundStyle(RelayTheme.textMuted)
                            Text("Linked agents can run code in this R session. Use Pause MCP analysis to stop them.")
                                .font(.caption).foregroundStyle(RelayTheme.textMuted)
                            if let rLinkNotice { Text(rLinkNotice).font(.caption) }
                            ForEach(availableTerminals) { pane in
                                Toggle(pane.harnessLabel + " · " + pane.displayName, isOn: Binding(
                                    get: { selectedTerminalIDs.contains(pane.id) },
                                    set: { selected in
                                        if selected { selectedTerminalIDs.insert(pane.id) }
                                        else { selectedTerminalIDs.remove(pane.id) }
                                    }))
                                    .toggleStyle(.checkbox)
                            }
                            if availableTerminals.isEmpty { Text("No other terminals available in the original tab") }
                            HStack {
                                Button("Cancel") { showingTerminalPicker = false }
                                Spacer()
                                Button("Add selected") {
                                    for pane in availableTerminals where selectedTerminalIDs.contains(pane.id) {
                                        linkTerminal(pane)
                                    }
                                    showingTerminalPicker = false
                                    selectedTerminalIDs.removeAll()
                                }.disabled(selectedTerminalIDs.isEmpty)
                            }
                        }.padding(RelayTheme.spacing(14))
                    }
                    .onDrop(of: [UTType.utf8PlainText], isTargeted: $terminalDropTargeted) { providers in
                        if let id = PaneDragCoordinator.shared.paneID,
                           let pane = availableTerminals.first(where: { $0.id == id }) {
                            linkTerminal(pane)
                            PaneDragCoordinator.shared.paneID = nil
                            return true
                        }
                        guard let provider = providers.first else { return false }
                        provider.loadObject(ofClass: NSString.self) { object, _ in
                            guard let text = object as? String, let id = UUID(uuidString: text) else { return }
                            Task { @MainActor in
                                guard let pane = availableTerminals.first(where: { $0.id == id }) else { return }
                                linkTerminal(pane)
                            }
                        }
                        return true
                    }
                Spacer()
            }.padding(RelayTheme.spacing(10))
            Divider()
        GeometryReader { geometry in
        HStack(spacing: RelayTheme.spacing(1)) {
            VStack(spacing: RelayTheme.spacing(1)) {
                RDetachablePanel(title: "Editor", key: parentKey + ":editor", parent: parentKey, allowsFloating: false) {
                PaneView(pane: editor, isActive: true,
                         compactChrome: true, select: {}, inToolWindow: true)
                    .environmentObject(workspace.paneLinkSelection)
                }.frame(height: max(0, geometry.size.height * 0.65 - 1))
                RDetachablePanel(title: "Console", key: parentKey + ":console", parent: parentKey, allowsFloating: false) {
                PaneView(pane: console, isActive: workspace.activePaneID == console.id,
                         compactChrome: true, select: { workspace.selectPane(console.id, origin: .user) }, inToolWindow: true)
                    .environmentObject(workspace.paneLinkSelection)
                }
            }.frame(width: max(0, geometry.size.width * 0.65 - 1))
            RDetachablePanel(title: "Results", key: parentKey + ":results", parent: parentKey, allowsFloating: false) {
            RLayoutResultsDock(runtime: editor.editorRuntime)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(RelayTheme.line)
        }
        .background {
            ForEach(extraPanels.filter { !windows.detachedRPanels.contains($0.id.uuidString) }) { panel in
                RDetachablePanel(title: panel.title, key: panel.id.uuidString, parent: parentKey,
                                 initiallyFloating: true) {
                    if let pane = panel.pane {
                        PaneView(pane: pane, isActive: true, compactChrome: true,
                                 select: { if pane.contentKind == .terminal { workspace.selectPane(pane.id, origin: .user) } },
                                 inToolWindow: true)
                            .environmentObject(workspace.paneLinkSelection)
                    } else {
                        RLayoutResultsDock(runtime: editor.editorRuntime)
                    }
                }.frame(width: 0, height: 0).hidden()
            }
        }
        }.background(RelayTheme.canvas)
        .overlay {
            ForEach(windows.panelsForRWorkspace(parentKey), id: \.self) { key in
                if let panel = windows.embeddedRPanels[key] {
                    RBoundedPanel(title: panel.title, initialSize: CGSize(width: 620, height: 420),
                                  closeLabel: "Close floating console", close: {
                                      windows.closeExtraRPanel(key, parent: parentKey, workspace: workspace, consoleID: console.id)
                                  },
                                  minimize: { windows.minimizedRPanels.insert(key) },
                                  savedPlacement: windows.rPanelPlacements[key],
                                  placementChanged: { windows.rPanelPlacements[key] = $0; workspace.persistRPresentation() }) {
                        panel.content
                    }.id(key)
                        .opacity(windows.minimizedRPanels.contains(key) ? 0 : 1)
                        .allowsHitTesting(!windows.minimizedRPanels.contains(key))
                        .accessibilityHidden(windows.minimizedRPanels.contains(key))
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            let minimized = windows.panelsForRWorkspace(parentKey).filter { windows.minimizedRPanels.contains($0) }
            if !minimized.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(minimized, id: \.self) { key in
                            Button {
                                windows.minimizedRPanels.remove(key)
                            } label: {
                                Label(windows.embeddedRPanels[key]?.title ?? "Panel", systemImage: "macwindow")
                            }.help("Restore minimised panel")
                        }
                    }.padding(RelayTheme.spacing(8))
                }.fixedSize(horizontal: false, vertical: true)
                    .background(RelayTheme.surface)
            }
        }
    }

    private var availableTerminals: [PaneModel] {
        workspace.rWorkspaceTerminalCandidates(consoleID: console.id).filter {
            !windows.rPaneIDs.contains($0.id)
        }
    }

    private func addPanel(_ kind: PaneContentKind?) {
        do {
            let pane = try kind.map { try workspace.addFloatingRPanel(consoleID: console.id, contentKind: $0) }
            let name = kind == .editor ? "Editor" : (kind == .terminal ? "Console" : "Results")
            windows.registerExtraRPanel(RExtraPanel(title: name + " \(extraPanels.count + 2)", pane: pane), parent: parentKey)
        } catch { workspace.operationError = error.localizedDescription }
    }
}

struct RExtraPanel: Identifiable {
    var id = UUID()
    let title: String
    let pane: PaneModel?
    var returnsToTab = false
}

private struct RDetachablePanel<Content: View>: View {
    let title: String
    let key: String
    let parent: String
    var initiallyFloating = false
    var allowsFloating = true
    @State private var presentedInitially = false
    @ViewBuilder let content: () -> Content
    @ObservedObject private var windows = RelayToolWindowCoordinator.shared

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack {
                Text(title).font(RelayTheme.font(size: 11, weight: .medium))
                Spacer()
                if allowsFloating && !windows.detachedRPanels.contains(key) {
                    Button {
                        windows.detachRPanel(key: key, parent: parent, title: "RStudio · " + title,
                                             content: content())
                    } label: {
                        Label("Float \(title.lowercased())", systemImage: "macwindow.on.rectangle")
                    }.labelStyle(.iconOnly).buttonStyle(.plain)
                        .help("Float \(title.lowercased()) inside this R workspace")
                }
            }.padding(RelayTheme.spacing(8))
            Divider()
            if windows.detachedRPanels.contains(key) {
                VStack(spacing: RelayTheme.spacing(10)) {
                    Image(systemName: "macwindow")
                    Text("\(title) is in a floating window")
                    Button("Show \(title.lowercased()) window") { windows.focusRPanel(key) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(RelayTheme.textMuted)
            } else {
                content()
            }
        }.frame(minHeight: 140).background(RelayTheme.canvas)
        .onAppear {
            guard initiallyFloating, !presentedInitially else { return }
            presentedInitially = true
            guard !windows.initiallyFloatedRPanelKeys.contains(key) else { return }
            windows.initiallyFloatedRPanelKeys.insert(key)
            windows.detachRPanel(key: key, parent: parent, title: "RStudio · " + title, content: content())
        }
    }
}

private struct PluginWorkspaceOverlay: View {
    @ObservedObject var workspace: WorkspaceModel
    let pane: PaneModel
    let toolID: String
    let close: () -> Void
    @StateObject private var presentation = PluginToolPresentation()
    @StateObject private var chrome = WorkspaceChrome()

    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            HStack {
                Text("Plugins").font(RelayTheme.font(size: 14, weight: .medium))
                Text(pane.profile.kind == .ssh ? pane.profile.host : "This Mac")
                    .font(RelayTheme.font(size: 11)).foregroundStyle(RelayTheme.textMuted)
                Spacer()
                RelayIconAction("Close plugins", symbol: "xmark", action: close)
            }.padding(RelayTheme.spacing(16))
            Rectangle().fill(RelayTheme.line).frame(height: 1)
            RelayPluginToolsView(workspace: workspace, presentation: presentation,
                                 chrome: chrome, presentationStyle: .floating)
        }
        .background(RelayTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
        .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).stroke(RelayTheme.line).allowsHitTesting(false))
        .onAppear {
            presentation.captureOnce(id: pane.id,
                profile: workspace.executionContext()?.profile ?? pane.profile,
                directory: workspace.executionContext()?.directory ?? pane.directory)
            presentation.selection = toolID
            chrome.reveal(.files, initial: WorkspaceContextAnchor(paneID: pane.id,
                           profile: pane.profile, directory: pane.directory))
        }
    }
}

struct HPCClusterWorkspaceOverlay: View {
    @ObservedObject var workspace: WorkspaceModel
    let pane: PaneModel
    let close: () -> Void
    @ObservedObject var presentation: PluginToolPresentation
    @ObservedObject var chrome: WorkspaceChrome
    var body: some View {
        VStack(spacing: RelayTheme.spacing(0)) {
            RelayPluginToolsView(workspace: workspace, presentation: presentation, chrome: chrome, presentationStyle: .overlay)
        }
        .background(RelayTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)))
        .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(8)).stroke(RelayTheme.line).allowsHitTesting(false))
        .onAppear {
            presentation.captureOnce(id: pane.id,
                profile: workspace.executionContext()?.profile ?? pane.profile,
                directory: workspace.executionContext()?.directory ?? pane.directory)
            presentation.selection = "relay.hpc-jobs:main"
            chrome.reveal(.jobs, initial: WorkspaceContextAnchor(paneID: pane.id, profile: pane.profile, directory: pane.directory))
        }
    }
}

/// The startup R tool-window restore on a fresh coordinator; the window's
/// `onAppear` runs the same method. Used by tests of the shown workspace.
@MainActor func relayRestoreToolWindowPresentations(_ workspace: WorkspaceModel) {
    RelayToolWindowCoordinator().restorePresentations(workspace: workspace)
}
