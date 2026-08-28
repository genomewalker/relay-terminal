import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var preferences = RelayPreferences.shared
    @State private var showingQuitConfirmation = false
    @State private var showingRelaydOnboarding = false
    @State private var showingRelaydManager = false
    @State private var preferredRelaydProfile: ConnectionProfile?
    @AppStorage("relay.relayd-onboarding-seen.v1") private var relaydOnboardingSeen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if workspace.sidebarVisible {
                    SessionManager(workspace: workspace)
                        .frame(width: preferences.compactInterface ? 244 : 260)
                    Rectangle().fill(RelayTheme.line.opacity(0.38)).frame(width: 1)
                }
                VStack(spacing: 0) {
                    if RelayLaunchMode.isSafeMode {
                        HStack(spacing: 7) {
                            Image(systemName: "shield")
                            Text("Safe mode · workspace restore and artifact previews are disabled")
                            Spacer()
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(RelayTheme.surface)
                        .accessibilityLabel("Relay is running in safe mode")
                    }
                    WorkspaceBar(workspace: workspace)
                    Rectangle().fill(RelayTheme.line.opacity(0.45)).frame(height: 1)
                    if let tab = workspace.selectedTab {
                        WorkspaceCanvas(tab: tab, workspace: workspace)
                            .background(RelayTheme.canvas)
                    }
                }
            }
            if let selection = workspace.agentInspector,
               let pane = workspace.panes[selection.paneID] {
                AgentInspectorPanel(
                    pane: pane,
                    subagentID: selection.subagentID,
                    showTerminal: { workspace.revealPane(selection.paneID) },
                    close: workspace.closeAgentInspector
                )
                .padding(.top, workspace.isFullScreen ? 50 : 58)
                .padding(.trailing, 18)
                .zIndex(500)
            }
            if workspace.intelligencePanelVisible {
                AgentIntelligencePanel(
                    workspace: workspace,
                    close: workspace.closeIntelligencePanel
                )
                .padding(.top, workspace.isFullScreen ? 50 : 58)
                .padding(.trailing, 18)
                .zIndex(650)
            }

            RelayWindowControls(isFullScreen: workspace.isFullScreen)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 14)
                .padding(.top, workspace.isFullScreen ? 13 : 15)
                .zIndex(1_000)
        }
        .background(RelayTheme.canvas)
        .tint(RelayTheme.accent)
        // The workspace already provides a compact draggable chrome row and
        // its own visible window controls. Do not also reserve AppKit's empty
        // hidden-titlebar safe area above it.
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) {
            if showingQuitConfirmation {
                HStack(spacing: 10) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RelayTheme.coral)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Press ⌘Q again to quit")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("Remote sessions keep running")
                            .font(.system(size: 10.5))
                            .foregroundStyle(RelayTheme.textMuted)
                    }
                }
                .foregroundStyle(RelayTheme.text)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(RelayTheme.line.opacity(0.9))
                }
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Press Command Q again to quit. Remote sessions keep running.")
                .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $workspace.isHostLauncherPresented) {
            HostLauncher(workspace: workspace)
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
        .onAppear {
            if !relaydOnboardingSeen { showingRelaydOnboarding = true }
        }
    }
}

private struct RelayWindowControls: View {
    let isFullScreen: Bool
    @State private var hovered: WindowControlKind?

    var body: some View {
        HStack(spacing: 8) {
            control(.close)
            control(.minimize)
            control(.zoom)
        }
        .accessibilityElement(children: .contain)
    }

    private func control(_ kind: WindowControlKind) -> some View {
        Button {
            guard let window = NSApp.windows.first(where: { $0.identifier == .relayWorkspaceWindow })
                ?? NSApp.keyWindow else { return }
            switch kind {
            case .close: window.performClose(nil)
            case .minimize: window.miniaturize(nil)
            case .zoom: window.toggleFullScreen(nil)
            }
        } label: {
            ZStack {
                Circle().fill(kind.color)
                if hovered != nil {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.58))
                }
            }
            .frame(width: 12, height: 12)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? kind : nil }
        .accessibilityLabel(kind.accessibilityLabel(isFullScreen: isFullScreen))
        .help(kind.accessibilityLabel(isFullScreen: isFullScreen))
    }
}

private enum WindowControlKind: Equatable {
    case close, minimize, zoom

    var color: Color {
        switch self {
        case .close: Color(red: 1, green: 0.37, blue: 0.34)
        case .minimize: Color(red: 1, green: 0.74, blue: 0.18)
        case .zoom: Color(red: 0.16, green: 0.78, blue: 0.27)
        }
    }

    var symbol: String {
        switch self {
        case .close: "xmark"
        case .minimize: "minus"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        }
    }

    func accessibilityLabel(isFullScreen: Bool) -> String {
        switch self {
        case .close: "Close Relay window"
        case .minimize: "Minimize Relay window"
        case .zoom: isFullScreen ? "Exit full screen" : "Enter full screen"
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
        let byID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
        return search.visibleIDs.compactMap { byID[$0] }
    }

    var body: some View {
        SmoothFloatingPanelDrag(
            settledOffset: $settledOffset,
            headerHeight: 54,
            onDragActivityChanged: { isDragging = $0 }
        ) {
            VStack(spacing: 0) {
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
            .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
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
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(RelayTheme.blue.opacity(0.14))
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RelayTheme.blue)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent activity")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RelayTheme.text)
                Text(store.unreadCount == 0 ? "You're caught up" : "\(store.unreadCount) since you last checked")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(store.attentionCount > 0 ? RelayTheme.coral : RelayTheme.textFaint)
            }
            Spacer()
            if store.unreadCount > 0 {
                Button("Mark all read") { store.markAllRead() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(RelayTheme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help("Close agent activity")
            .accessibilityLabel("Close agent activity")
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .contentShape(Rectangle())
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
            TextField("Search work, failures, files, or peer handoffs", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(RelayTheme.text)
            if search.isRefining {
                ProgressView().controlSize(.mini)
                    .help("Refining search on this Mac")
            } else if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textFaint)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private var scopePicker: some View {
        HStack(spacing: 6) {
            ForEach(AgentInboxScope.allCases) { value in
                Button {
                    scope = value
                } label: {
                    Text(value.label)
                        .font(.system(size: 9.5, weight: scope == value ? .semibold : .medium))
                        .foregroundStyle(scope == value ? RelayTheme.text : RelayTheme.textMuted)
                        .padding(.horizontal, 9)
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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RelayTheme.coral)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    @ViewBuilder
    private var inbox: some View {
        if visibleItems.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: query.isEmpty ? "checkmark.circle" : "magnifyingglass")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(RelayTheme.textFaint)
                Text(query.isEmpty ? "No activity in this view" : "No matching activity")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(visibleItems) { item in
                        AgentInboxRow(item: item) {
                            workspace.openInboxItem(item)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Image(systemName: ProcessInfo.processInfo.isLowPowerModeEnabled ? "leaf.fill" : "cpu")
                .font(.system(size: 9))
            Text(ProcessInfo.processInfo.isLowPowerModeEnabled
                 ? "Model work paused in Low Power Mode"
                 : search.usedSystemIntelligence
                 ? "Search refined on this Mac"
                 : "Structured events · on-device intelligence")
                .font(.system(size: 9.5, weight: .medium))
            Spacer()
            Text("\(store.items.count) events")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(RelayTheme.textFaint)
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func refreshSearch() {
        search.search(items: store.items, query: query, scope: scope)
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
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(item.kind.color.opacity(0.13))
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.kind.color)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 11, weight: item.isRead ? .medium : .semibold))
                            .foregroundStyle(item.isRead ? RelayTheme.textMuted : RelayTheme.text)
                            .lineLimit(1)
                        if !item.isRead {
                            Circle().fill(item.kind.color).frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        Spacer()
                        Text(Self.relativeFormatter.localizedString(for: item.occurredAt, relativeTo: Date()))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(RelayTheme.textFaint)
                    }
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(RelayTheme.textMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 5) {
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
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textFaint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(hovering ? RelayTheme.surface.opacity(0.72) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(item.kind.label), \(item.title), \(item.host), \(item.isRead ? "read" : "unread")")
        .accessibilityHint("Opens the related terminal or agent thread")
    }
}

private struct AgentInspectorSnapshot: Equatable {
    let kind: AgentKind
    let agent: SubagentActivity?
}

private struct AgentInspectorPanel: View {
    let pane: PaneModel
    let subagentID: String
    let showTerminal: () -> Void
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
        subagentID: String,
        showTerminal: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.pane = pane
        self.subagentID = subagentID
        self.showTerminal = showTerminal
        self.close = close
        self._snapshot = State(initialValue: Self.capture(pane: pane, subagentID: subagentID))
    }

    var body: some View {
        SmoothFloatingPanelDrag(
            settledOffset: $settledOffset,
            headerHeight: 42,
            onDragActivityChanged: dragActivityChanged
        ) {
            VStack(spacing: 0) {
                inspectorTitleBar
                if !collapsed {
                    Rectangle().fill(RelayTheme.line.opacity(0.7)).frame(height: 1)
                    if let agent = snapshot.agent {
                        inspectorContent(agent)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 24))
                                .foregroundStyle(RelayTheme.textFaint)
                            Text("This agent is no longer available")
                                .font(.system(size: 12, weight: .medium))
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
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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
        HStack(spacing: 9) {
            Image(systemName: snapshot.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RelayTheme.textMuted)
            Text("Agent thread")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(RelayTheme.text)
            Text(snapshot.kind.label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
            Spacer()
            Button { collapsed.toggle() } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help(collapsed ? "Expand inspector" : "Collapse inspector")
            .accessibilityLabel(collapsed ? "Expand agent inspector" : "Collapse agent inspector")
            Button(action: showTerminal) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help("Show parent terminal")
            .accessibilityLabel("Show parent terminal")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .accessibilityLabel("Close agent inspector")
        }
        .padding(.horizontal, 12)
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
                .padding(.horizontal, 14)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Movable agent inspector")
        .onKeyPress(.leftArrow) { settledOffset.width -= 20; return .handled }
        .onKeyPress(.rightArrow) { settledOffset.width += 20; return .handled }
        .onKeyPress(.upArrow) { settledOffset.height -= 20; return .handled }
        .onKeyPress(.downArrow) { settledOffset.height += 20; return .handled }
    }

    private static func capture(pane: PaneModel, subagentID: String) -> AgentInspectorSnapshot {
        AgentInspectorSnapshot(
            kind: pane.kind,
            agent: pane.subagents.first { $0.id == subagentID }
        )
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

    private func inspectorContent(_ agent: SubagentActivity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(agent.label)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RelayTheme.text)
                        .textSelection(.enabled)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(agent.phase.color).frame(width: 6, height: 6)
                        Text(agent.phase == .active ? "Working" : "Finished")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(agent.phase.color)
                    }
                }
                HStack(spacing: 14) {
                    Label(agent.startedAt.formatted(date: .omitted, time: .shortened), systemImage: "play.fill")
                    if let completedAt = agent.completedAt {
                        Label(completedAt.formatted(date: .omitted, time: .shortened), systemImage: "checkmark")
                    }
                    if let threadID = agent.threadID {
                        Text(String(threadID.prefix(12)))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .help(threadID)
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
            }
            .padding(16)

            Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if agent.updates.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(agent.phase == .active ? "Waiting for the first progress update" : "No result text was recorded")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RelayTheme.textMuted)
                            Text("Relay captured the lifecycle, but this CLI did not expose a readable progress message for this thread.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(RelayTheme.textFaint)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(agent.updates) { update in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(update.occurredAt.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(RelayTheme.textFaint)
                                Text(update.message)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(RelayTheme.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(11)
                            .background(RelayTheme.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

private struct WorkspaceBar: View {
    @ObservedObject var workspace: WorkspaceModel

    private var sessionTabs: [TabModel] {
        guard let sessionID = workspace.selectedTab?.sessionID else { return [] }
        return workspace.orderedTabs(in: sessionID)
    }

    private var sessionName: String {
        guard let tab = workspace.selectedTab,
              let paneID = tab.allPaneIDs.first,
              let pane = workspace.panes[paneID] else { return "Session" }
        let fallback = pane.profile.kind == .ssh ? pane.profile.host : "This Mac"
        return workspace.sessionDisplayName(tab.sessionID, fallback: fallback)
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if !workspace.sidebarVisible {
                    ChromeButton(symbol: "sidebar.left", help: "Show navigator") {
                        workspace.sidebarVisible = true
                    }
                }
                if !workspace.isFullScreen {
                    if !workspace.sidebarVisible {
                        Text("Relay")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(RelayTheme.text)
                    }
                }
            }

            Text(sessionName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(RelayTheme.textMuted)
                .lineLimit(1)

            Rectangle()
                .fill(RelayTheme.line.opacity(0.65))
                .frame(width: 1, height: 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(sessionTabs.enumerated()), id: \.element.id) { index, tab in
                        let fallbackLabel = index == 0 ? "Main" : "Tab \(index + 1)"
                        WorkspaceTab(
                            tab: tab,
                            label: workspace.tabDisplayName(tab, fallback: fallbackLabel),
                            isSelected: tab.id == workspace.selectedTabID,
                            pinned: workspace.isTabPinned(tab.id),
                            select: { workspace.selectTab(tab.id) },
                            togglePin: { workspace.toggleTabPin(tab.id) },
                            rename: { workspace.beginRenameTab(tab.id) },
                            close: { workspace.closeTab(tab.id) }
                        )
                    }
                    ChromeButton(symbol: "plus", help: "New tab in this session · ⌘T") {
                        workspace.newTabInActiveSession()
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if workspace.activePane?.profile.kind == .ssh,
                   workspace.activePane?.profile.backend == .relay {
                    ChromeButton(symbol: "curlybraces", help: "Open remote editor · ⇧⌘E") {
                        workspace.openEditorForActive()
                    }
                }
                ChromeButton(symbol: "rectangle.split.2x1", help: "Split remote pane right · ⌘D") {
                    workspace.splitActive(axis: .horizontal)
                }
                ChromeButton(symbol: "rectangle.split.1x2", help: "Split remote pane down · ⇧⌘D") {
                    workspace.splitActive(axis: .vertical)
                }
                ChromeButton(symbol: "rectangle.on.rectangle", help: "New floating remote pane · ⌥⌘F") {
                    workspace.newFloatingPane()
                }
                Menu {
                    Button("Balance pane layout") { workspace.balanceActiveTabPanes() }
                    Button("Zoom active pane") { workspace.toggleActivePaneZoom() }
                    Button("Float or dock active pane") { workspace.toggleActivePaneFloating() }
                    Divider()
                    Button("New local session") { workspace.newTab(profile: .local) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(RelayTheme.textMuted)
                .help("More workspace actions")
                if workspace.isFullScreen {
                    ChromeButton(symbol: "plus", help: "Connect to a host · ⌘K") {
                        workspace.presentHostLauncher()
                    }
                } else {
                    Button {
                        workspace.presentHostLauncher()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Connect")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 29)
                        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.text)
                }
            }
        }
        .padding(.leading, workspace.sidebarVisible ? 10 : 76)
        .padding(.trailing, 10)
        .frame(height: workspace.isFullScreen ? 38 : 44)
        .background(RelayTheme.canvas)
    }
}

private struct WorkspaceTab: View {
    @ObservedObject var tab: TabModel
    let label: String
    let isSelected: Bool
    let pinned: Bool
    let select: () -> Void
    let togglePin: () -> Void
    let rename: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 1) {
            Button(action: select) {
                HStack(spacing: 4) {
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(RelayTheme.textFaint)
                    }
                    Text(label)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                }
                .padding(.leading, 9)
                .padding(.trailing, 4)
                .frame(height: 29)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { rename() }
            )
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .frame(width: 18, height: 29)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .opacity(isSelected || hovering ? 1 : 0)
            .allowsHitTesting(isSelected || hovering)
            .accessibilityHidden(!isSelected && !hovering)
            .accessibilityLabel("Close \(label) tab")
        }
        .foregroundStyle(isSelected ? RelayTheme.text : RelayTheme.textMuted)
        .background(isSelected ? RelayTheme.accentDim.opacity(0.48) : hovering ? RelayTheme.hover.opacity(0.45) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottom) {
            if isSelected {
                Capsule()
                    .fill(RelayTheme.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 7)
                }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(pinned ? "Unpin tab" : "Pin tab", action: togglePin)
            Button("Rename tab…", action: rename)
            Divider()
            Button("Close tab", action: close)
        }
    }
}

private struct ChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(hovering ? RelayTheme.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(RelayTheme.textMuted)
        .onHover { hovering = $0 }
        .help(help)
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

private struct SessionManager: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var activityIndex: WorkspaceActivityIndex
    @ObservedObject private var intelligence = AgentIntelligenceStore.shared

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        self.activityIndex = workspace.activityIndex
    }

    private var activityBadgeCount: Int {
        intelligence.attentionCount > 0 ? intelligence.attentionCount : intelligence.unreadCount
    }

    private var activityBadgeLabel: String {
        intelligence.attentionCount > 0
            ? "\(intelligence.attentionCount) need you"
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
        for index in groups.indices {
            for sessionIndex in groups[index].sessions.indices {
                let tabs = groups[index].sessions[sessionIndex].tabs
                groups[index].sessions[sessionIndex].tabs =
                    tabs.filter { workspace.isTabPinned($0.id) } +
                    tabs.filter { !workspace.isTabPinned($0.id) }
            }
            let sessions = groups[index].sessions
            groups[index].sessions = sessions.filter { workspace.isSessionPinned($0.id) } +
                sessions.filter { !workspace.isSessionPinned($0.id) }
        }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: workspace.isFullScreen ? 38 : 42)
            HStack(spacing: 8) {
                Text("Sessions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RelayTheme.text)
                Spacer()
                Button {
                    workspace.toggleIntelligencePanel()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: workspace.intelligencePanelVisible ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 26)
                        if activityBadgeCount > 0 {
                            Text(activityBadgeCount > 99 ? "99+" : "\(activityBadgeCount)")
                                .font(.system(size: 6.5, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 11, minHeight: 11)
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
                Button {
                    workspace.presentHostLauncher()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help("Connect to a host")
                Button {
                    workspace.sidebarVisible = false
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help("Hide sessions")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 44)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(nodeGroups) { group in
                        SessionNodeSection(group: group, workspace: workspace)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)
            Button {
                workspace.presentHostLauncher()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RelayTheme.textMuted)
                    Text("New connection")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(RelayTheme.text)
                    Spacer()
                    Text("⌘K")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.textFaint)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .background(RelayTheme.sidebar)
    }
}

private struct SessionNodeSection: View {
    let group: SessionNodeGroup
    @ObservedObject var workspace: WorkspaceModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var nodeConnected: Bool {
        group.sessions.flatMap(\.tabs).flatMap(\.allPaneIDs).compactMap { workspace.panes[$0] }.contains { pane in
            if case .connected = pane.connectionState { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Group {
                    if differentiateWithoutColor {
                        Image(systemName: nodeConnected ? "wifi" : "wifi.slash")
                            .font(.system(size: 8, weight: .semibold))
                    } else {
                        Circle()
                            .fill(nodeConnected ? RelayTheme.mint : RelayTheme.textFaint)
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityLabel(nodeConnected ? "Connected" : "Disconnected")
                Text(group.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(RelayTheme.textMuted)
                    .lineLimit(1)
                Spacer()
                Text("\(group.sessions.count)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textFaint)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)

            ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                let fallback = group.sessions.count == 1 ? "Session" : "Session \(index + 1)"
                AttachedSessionRow(
                    session: session,
                    label: workspace.sessionDisplayName(session.id, fallback: fallback),
                    workspace: workspace
                )
            }
        }
        .padding(.bottom, 7)
    }
}

private struct AttachedSessionRow: View {
    let session: SessionTabGroup
    let label: String
    @ObservedObject var workspace: WorkspaceModel

    private var selected: Bool { session.tabs.contains { $0.id == workspace.selectedTabID } }
    private var panes: [PaneModel] {
        session.tabs.flatMap(\.allPaneIDs).compactMap { workspace.panes[$0] }
    }
    private var agentThreads: Int {
        panes.reduce(into: 0) { count, pane in
            guard pane.contentKind == .terminal, pane.kind != .shell else { return }
            count += 1 + pane.subagents.count
        }
    }
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Button {
                    if let tab = session.tabs.first { workspace.selectTab(tab.id) }
                } label: {
                HStack(spacing: 7) {
                    Capsule()
                        .fill(selected ? RelayTheme.accent : Color.clear)
                        .frame(width: 3, height: 18)
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selected ? RelayTheme.textMuted : RelayTheme.textFaint)
                    if workspace.isSessionPinned(session.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(RelayTheme.textFaint)
                    }
                    Text(label)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? RelayTheme.text : RelayTheme.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    Text("\(session.tabs.count) tab\(session.tabs.count == 1 ? "" : "s")")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.textFaint)
                    if agentThreads > 0 {
                        Text("\(agentThreads) thread\(agentThreads == 1 ? "" : "s")")
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RelayTheme.mint)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 34)
                .background(selected ? RelayTheme.accentDim.opacity(0.24) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(workspace.isSessionPinned(session.id) ? "Unpin session" : "Pin session") {
                        workspace.toggleSessionPin(session.id)
                    }
                    Button("New tab") { workspace.newTab(inSession: session.id) }
                    Button("Rename session…") { workspace.beginRenameSession(session.id, fallback: label) }
                    Divider()
                    Button("Detach session") { workspace.closeSession(session.id) }
                }
                Button { workspace.newTab(inSession: session.id) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help("New tab in session")
            }

            if selected || agentThreads > 0 {
                ForEach(session.tabs) { tab in
                    let tabIndex = session.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
                    SessionTabSection(
                        tab: tab,
                        fallbackLabel: tabIndex == 0 ? "Main" : "Tab \(tabIndex + 1)",
                        workspace: workspace
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label), \(session.tabs.count) tabs, \(panes.count) panes, \(agentThreads) agent threads")
    }
}

private struct SessionTabSection: View {
    @ObservedObject var tab: TabModel
    let fallbackLabel: String
    @ObservedObject var workspace: WorkspaceModel
    @State private var expanded: Bool

    init(tab: TabModel, fallbackLabel: String, workspace: WorkspaceModel) {
        self.tab = tab
        self.fallbackLabel = fallbackLabel
        self.workspace = workspace
        let containsActiveAgent = tab.allPaneIDs.compactMap { workspace.panes[$0] }
            .contains { $0.contentKind == .terminal && $0.kind != .shell }
        _expanded = State(initialValue: tab.id == workspace.selectedTabID || containsActiveAgent)
    }

    private var panes: [PaneModel] { tab.allPaneIDs.compactMap { workspace.panes[$0] } }
    private var activeAgents: Int {
        panes.reduce(0) { $0 + ($1.contentKind == .terminal && $1.kind != .shell ? 1 + $1.activeSubagents : 0) }
    }
    private var displayName: String { workspace.tabDisplayName(tab, fallback: fallbackLabel) }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textFaint)
                .accessibilityLabel(expanded ? "Collapse tab" : "Expand tab")

                Button {
                    workspace.selectTab(tab.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle")
                            .font(.system(size: 8.5, weight: .semibold))
                        if workspace.isTabPinned(tab.id) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 7, weight: .semibold))
                        }
                        Text(displayName)
                            .font(.system(size: 10, weight: tab.id == workspace.selectedTabID ? .semibold : .medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(panes.count)")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        if activeAgents > 0 {
                            Circle().fill(RelayTheme.mint).frame(width: 5, height: 5)
                        }
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
                    Button("Close tab") { workspace.closeTab(tab.id) }
                }
            }
            .padding(.leading, 21)
            .padding(.trailing, 9)
            .frame(height: 27)
            .background(
                tab.id == workspace.selectedTabID ? RelayTheme.accentDim.opacity(0.34) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
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
        .onChange(of: workspace.selectedTabID) { _, selectedID in
            if selectedID == tab.id { expanded = true }
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
                    .font(.system(size: 7, weight: .bold))
            } else {
                Circle()
                    .fill(pane.phase == .needsInput ? RelayTheme.coral : pane.kind == .shell ? RelayTheme.textFaint : RelayTheme.mint)
                    .frame(width: 5, height: 5)
            }
        }
            .help("\(pane.kind.label): \(pane.phase.label)")
            .accessibilityLabel("\(pane.kind.label): \(pane.phase.label)")
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

    private func revealPane() {
        if workspace.selectedTabID != tabID { workspace.selectTab(tabID) }
        workspace.selectPane(pane.id)
        pane.focus()
    }

    private func agentActivityDate(_ agent: SubagentActivity) -> Date {
        agent.updates.last?.occurredAt ?? agent.completedAt ?? agent.startedAt
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: revealPane) {
                HStack(spacing: 7) {
                Capsule()
                    .fill(active ? RelayTheme.accent : Color.clear)
                    .frame(width: 2, height: 16)
                Image(systemName: pane.contentKind == .editor ? "curlybraces" : pane.kind.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(pane.contentKind == .editor ? RelayTheme.blue : pane.phase.color)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pane.contentKind == .editor ? pane.displayName : pane.kind == .shell ? pane.displayName : pane.kind.label)
                        .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? RelayTheme.text : RelayTheme.textMuted)
                        .lineLimit(1)
                    if pane.contentKind == .terminal && pane.kind != .shell {
                        Text(AgentLabelFormatter.activity(pane.activitySummary))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(RelayTheme.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if pane.activeSubagents > 0 {
                    Text("\(pane.activeSubagents)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayTheme.mint)
                }
                if isFloating {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(RelayTheme.textFaint)
                        .help("Floating pane")
                }
                Circle().fill(pane.connectionState.color).frame(width: 5, height: 5)
                }
                .padding(.leading, 22)
                .padding(.trailing, pane.subagents.isEmpty ? 9 : 54)
                .frame(height: pane.contentKind == .terminal && pane.kind != .shell ? 38 : 29)
                .background(active ? RelayTheme.accentDim.opacity(0.58) : hovering ? RelayTheme.surface.opacity(0.7) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Rename pane…") { workspace.beginRenamePane(pane.id) }
                if pane.contentKind == .terminal {
                    Menu("Agent type") {
                        ForEach(AgentKind.allCases, id: \.self) { kind in
                            Button {
                                pane.setAgentKind(kind)
                            } label: {
                                Label(kind.label, systemImage: pane.kind == kind ? "checkmark" : kind.symbol)
                            }
                        }
                    }
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
                Button("Show pane") { revealPane() }
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
                        HStack(spacing: 5) {
                            AgentPulse(phase: pane.phase, activeCount: pane.activeSubagents)
                            Text(pane.activeSubagents > 0 ? "\(pane.activeSubagents)/\(pane.subagents.count)" : "\(pane.subagents.count)")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                            Image(systemName: agentThreadsExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .frame(minWidth: 45, minHeight: 29)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.textFaint)
                    .padding(.trailing, 3)
                    .help(agentThreadsExpanded ? "Hide agent focus" : "Show agent focus")
                    .accessibilityLabel(agentThreadsExpanded ? "Hide agent focus" : "Show agent focus, \(pane.activeSubagents) active")
                }
            }

            if agentThreadsExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(showingAllAgents ? "THREADS" : "FOCUS")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(RelayTheme.textFaint)
                        if attention.snapshot.attentionCount > 0 {
                            Text("\(attention.snapshot.attentionCount) need you")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(RelayTheme.coral)
                        }
                        Spacer()
                        if showingAllAgents {
                            Button("Done") {
                                showingAllAgents = false
                                agentQuery = ""
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .semibold))
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
                                    .font(.system(size: 8, weight: .medium))
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
                    .padding(.leading, 43)
                    .padding(.trailing, 9)
                    .padding(.top, 4)

                    if showingAllAgents {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(RelayTheme.textFaint)
                            TextField("Find a thread", text: $agentQuery)
                                .textFieldStyle(.plain)
                                .font(.system(size: 10.5))
                                .accessibilityLabel("Find an agent thread")
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(.leading, 35)
                        .padding(.trailing, 7)
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
                            .font(.system(size: 10))
                            .foregroundStyle(RelayTheme.textFaint)
                            .padding(.leading, 43)
                            .frame(height: 25)
                    } else if !showingAllAgents && attention.snapshot.hiddenCount > 0 {
                        Button {
                            showingAllAgents = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text("Search \(attention.snapshot.hiddenCount) more")
                                    .font(.system(size: 9.5, weight: .medium))
                            }
                            .foregroundStyle(RelayTheme.textFaint)
                            .padding(.leading, 43)
                            .frame(height: 25)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows searchable agent history")
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .onAppear {
            attention.refresh(agents: pane.subagents, paneID: pane.id)
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
            attention.refresh(agents: agents, paneID: pane.id)
            if active && !agents.isEmpty { agentThreadsExpanded = true }
        }
    }
}

private struct AgentPulse: View {
    let phase: AgentPhase
    let activeCount: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
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
            HStack(spacing: 7) {
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
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(RelayTheme.textFaint)
                        }
                        Text(displayLabel)
                            .font(.system(size: 9.75, weight: agent.phase == .needsInput ? .semibold : .medium))
                            .foregroundStyle(agent.phase == .exited ? RelayTheme.textFaint : RelayTheme.textMuted)
                            .lineLimit(1)
                    }
                    Text(agent.provider.label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(RelayTheme.textFaint)
                }
                Spacer(minLength: 2)
                Text(agent.phase.label)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(agent.phase.color)
                    .lineLimit(1)
            }
            .padding(.leading, 39)
            .padding(.trailing, 9)
            .frame(height: 31)
            .background(hovering ? RelayTheme.surface.opacity(0.55) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RelayTheme.textMuted)
                TextField(selectedProfile == nil ? "Search hosts or enter an SSH alias…" : "Remote sessions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
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
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
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
                            Text(selectedProfile.name)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(RelayTheme.text)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)

                        if loadingCatalog {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Reading remote sessions…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(RelayTheme.textMuted)
                            }
                            .padding(16)
                        } else {
                            HostResultRow(
                                title: "New session",
                                subtitle: "Start a new durable workspace on \(selectedProfile.name)",
                                symbol: "plus.rectangle.on.rectangle",
                                badge: "New"
                            ) { workspace.newTab(profile: selectedProfile) }

                            if let catalogError {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(catalogError)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(RelayTheme.coral)
                                        .lineLimit(3)
                                    Button("Retry") { loadCatalog(for: selectedProfile) }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(RelayTheme.blue)
                                }
                                .padding(12)
                            } else if let sessions = remoteCatalog?.sessions, !sessions.isEmpty {
                                Text("On this host")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(RelayTheme.textMuted)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 8)
                                ForEach(sessions) { session in
                                    RemoteSessionResultRow(session: session) {
                                        workspace.attachRemoteSession(profile: selectedProfile, remote: session)
                                    }
                                }
                            } else {
                                Text("No detached Relay sessions on this host.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(RelayTheme.textMuted)
                                    .padding(12)
                            }
                        }
                    } else {
                        Text(query.isEmpty ? "Recent and configured" : "Matches")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(RelayTheme.textMuted)
                            .padding(.horizontal, 8)
                            .padding(.top, 5)

                        if query.isEmpty {
                            HostResultRow(
                                title: "This Mac",
                                subtitle: "Open a local login shell",
                                symbol: "laptopcomputer",
                                badge: "Local"
                            ) { workspace.newTab(profile: .local) }
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
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(RelayTheme.textMuted)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                            HostResultRow(
                                title: typedHost.host,
                                subtitle: "Use this SSH hostname or config alias",
                                symbol: "arrow.right.circle.fill",
                                badge: "Inspect"
                            ) { selectHost(typedHost) }
                        }

                        if filteredHosts.isEmpty && typedHost == nil {
                            VStack(spacing: 8) {
                                Image(systemName: "network.slash")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(RelayTheme.textFaint)
                                Text("No SSH host matches “\(query)”")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(RelayTheme.text)
                                Text("Try an alias from ~/.ssh/config or enter a hostname.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(RelayTheme.textMuted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 42)
                        }
                    }
                }
                .padding(12)
            }

            HStack {
                Label("SSH config, keys and ProxyJump stay with OpenSSH", systemImage: "key.horizontal")
                    .font(.system(size: 10.5, weight: .medium))
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
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(RelayTheme.blue)
            }
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(RelayTheme.surface.opacity(0.45))
        }
        .frame(width: 640, height: 520)
        .background(RelayTheme.sidebar)
        .preferredColorScheme(.dark)
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
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(hovering ? RelayTheme.hover : RelayTheme.surface)
                        .frame(width: 42, height: 42)
                    Image(systemName: session.isUnfiled ? "lifepreserver" : "rectangle.stack")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(session.recoverable ? RelayTheme.mint : RelayTheme.textFaint)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(session.recoverable ? RelayTheme.text : RelayTheme.textMuted)
                    Text("\(session.tabCount) tab\(session.tabCount == 1 ? "" : "s") · \(session.panes.count) pane\(session.panes.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                Spacer()
                Text(session.recoverable ? (session.isUnfiled ? "Recover" : "Attach") : "Unavailable")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(session.recoverable ? RelayTheme.mint : RelayTheme.textFaint)
            }
            .padding(.horizontal, 8)
            .frame(height: 58)
            .background(hovering ? RelayTheme.elevated.opacity(0.6) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.recoverable)
        .onHover { hovering = $0 }
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
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(hovering ? RelayTheme.hover : RelayTheme.surface)
                        .frame(width: 42, height: 42)
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RelayTheme.textMuted)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(RelayTheme.text)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text(badge)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(hovering ? RelayTheme.textMuted : RelayTheme.textFaint)
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? RelayTheme.textMuted : RelayTheme.textFaint)
            }
            .padding(.horizontal, 10)
            .frame(height: 58)
            .background(hovering ? RelayTheme.elevated : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct WorkspaceCanvas: View {
    @ObservedObject var tab: TabModel
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let zoomedID = workspace.zoomedPaneID,
               tab.allPaneIDs.contains(zoomedID),
               let pane = workspace.panes[zoomedID] {
                PaneView(
                    pane: pane,
                    isActive: true,
                    compactChrome: true,
                    select: { workspace.selectPane(zoomedID) },
                    toggleZoom: { workspace.togglePaneZoom(zoomedID) },
                    toggleFloating: { workspace.toggleActivePaneFloating() },
                    rename: { workspace.beginRenamePane(zoomedID) },
                    close: {
                        workspace.selectPane(zoomedID)
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
                    ForEach(tab.floatingPanes) { placement in
                    if let pane = workspace.panes[placement.paneID] {
                        FloatingPaneWindow(
                            pane: pane,
                            placement: placement,
                            bounds: proxy.size,
                            isActive: workspace.activePaneID == pane.id,
                            select: {
                                workspace.selectPane(pane.id)
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
                            rename: { workspace.beginRenamePane(pane.id) },
                            close: {
                                workspace.selectPane(pane.id)
                                workspace.closeActivePane()
                            }
                        )
                        .zIndex(Double(tab.floatingPanes.firstIndex(where: { $0.paneID == pane.id }) ?? 0) + 10)
                    }
                }
                }
            }
        }
        .clipped()
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
    let rename: () -> Void
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
        VStack(spacing: 0) {
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
                isFloating: true
            )
        }
        .frame(width: width, height: height)
        .background(RelayTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
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
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Capsule()
                    .fill(isActive ? RelayTheme.accent : RelayTheme.textFaint)
                    .frame(width: 16, height: 3)
                Text(pane.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { rename() }
                Text(pane.profile.kind == .ssh ? pane.profile.host : "This Mac")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
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
                    .padding(.horizontal, 8)
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

            Button(action: dock) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help("Dock pane")
            .accessibilityLabel("Dock floating pane")

            Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .focusEffectDisabled()
            .help(pane.profile.kind == .ssh ? "Detach floating pane" : "Close floating pane")
            .accessibilityLabel(pane.profile.kind == .ssh ? "Detach floating pane" : "Close floating pane")
        }
        .padding(.horizontal, 10)
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
                    .padding(3)
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

    var body: some View {
        switch node {
        case .pane(let id):
            if let pane = workspace.panes[id] {
                PaneView(
                    pane: pane,
                    isActive: workspace.activePaneID == id,
                    compactChrome: workspace.isFullScreen,
                    select: { workspace.selectPane(id) },
                    rearrange: { draggedID, placement in workspace.movePane(draggedID, to: id, placement: placement) },
                    toggleZoom: { workspace.togglePaneZoom(id) },
                    toggleFloating: { workspace.floatTiledPane(id) },
                    rename: { workspace.beginRenamePane(id) },
                    close: {
                        workspace.selectPane(id)
                        workspace.closeActivePane()
                    },
                    isFloating: false
                )
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
}

private struct RelaySplitContainer<First: View, Second: View>: View {
    let axis: SplitAxis
    let ratio: Double
    let update: (Double, Bool) -> Void
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @State private var dragStartRatio: Double?
    @State private var dragPreviewRatio: Double?
    @FocusState private var dividerFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let divider: CGFloat = 6
            let available = max(1, total - divider)
            let firstLength = available * ratio
            ZStack(alignment: .topLeading) {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        first().frame(width: firstLength, height: proxy.size.height)
                        splitDivider(total: available)
                            .frame(width: divider, height: proxy.size.height)
                        second().frame(width: available - firstLength, height: proxy.size.height)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    VStack(spacing: 0) {
                        first().frame(width: proxy.size.width, height: firstLength)
                        splitDivider(total: available)
                            .frame(width: proxy.size.width, height: divider)
                        second().frame(width: proxy.size.width, height: available - firstLength)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }

                if let preview = dragPreviewRatio {
                    Capsule()
                        .fill(RelayTheme.blue.opacity(0.9))
                        .frame(
                            width: axis == .horizontal ? 2 : proxy.size.width,
                            height: axis == .horizontal ? proxy.size.height : 2
                        )
                        .position(
                            x: axis == .horizontal ? available * preview + divider * 0.5 : proxy.size.width * 0.5,
                            y: axis == .horizontal ? proxy.size.height * 0.5 : available * preview + divider * 0.5
                        )
                        .shadow(color: RelayTheme.blue.opacity(0.35), radius: 4)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func splitDivider(total: CGFloat) -> some View {
        let visual = Rectangle()
            .fill(RelayTheme.canvas)
            .overlay {
                Capsule()
                    .fill(dividerFocused ? RelayTheme.accent.opacity(0.85) : RelayTheme.line.opacity(0.8))
                    .frame(width: axis == .horizontal ? 1 : 24, height: axis == .horizontal ? 24 : 1)
            }
            .contentShape(Rectangle().inset(by: -4))

        let pointer = visual
            .onHover { hovering in
                if axis == .horizontal {
                    (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                } else {
                    (hovering ? NSCursor.resizeUpDown : NSCursor.arrow).set()
                }
            }

        let draggable = pointer
            .highPriorityGesture(TapGesture(count: 2).onEnded { update(0.5, true) })
            .simultaneousGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        let start = dragStartRatio ?? ratio
                        if dragStartRatio == nil { dragStartRatio = ratio }
                        dragPreviewRatio = min(max(start + delta / total, 0.12), 0.88)
                    }
                    .onEnded { value in
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        update((dragStartRatio ?? ratio) + delta / total, true)
                        dragStartRatio = nil
                        dragPreviewRatio = nil
                    }
            )

        let accessible = draggable
            .help("Drag to resize · double-click to center")
            .focusable()
            .focused($dividerFocused)
            // Preserve keyboard and VoiceOver resizing without AppKit's large
            // blue focus rectangle around the otherwise invisible hit target.
            // The center hairline above becomes Relay accent-colored instead.
            .focusEffectDisabled()
            .accessibilityElement()
            .accessibilityLabel(axis == .horizontal ? "Vertical pane divider" : "Horizontal pane divider")
            .accessibilityValue("\(Int(ratio * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: update(min(0.9, ratio + 0.05), true)
                case .decrement: update(max(0.1, ratio - 0.05), true)
                @unknown default: break
                }
            }

        return accessible
            .onMoveCommand { direction in
                switch (axis, direction) {
                case (.horizontal, .left), (.vertical, .up):
                    update(max(0.1, ratio - 0.05), true)
                case (.horizontal, .right), (.vertical, .down):
                    update(min(0.9, ratio + 0.05), true)
                default:
                    break
                }
            }
    }
}

private struct PaneView: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject private var preferences = RelayPreferences.shared
    let isActive: Bool
    let compactChrome: Bool
    let select: () -> Void
    var rearrange: (@MainActor @Sendable (UUID, PaneDropPlacement) -> Void)? = nil
    var toggleZoom: (() -> Void)? = nil
    var toggleFloating: (() -> Void)? = nil
    var rename: (() -> Void)? = nil
    var close: (() -> Void)? = nil
    var isFloating = false
    var isZoomed = false
    @State private var paneSize: CGSize = .zero
    @StateObject private var dropPreview = PaneDropPreviewModel()

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            ZStack {
                if pane.contentKind == .editor {
                    QuickEditorPane(pane: pane)
                        .id(pane.id)
                } else {
                    TerminalSurface(pane: pane)
                        .equatable()
                        // A terminal backend is immutable after its NSView is created.
                        // Key the representable by the remote session so switching tabs
                        // cannot reuse a local-shell surface for an SSH pane.
                        .id(pane.id)
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
                        .padding(12)
                } else if pane.isRestoringTerminal && !pane.hasTerminalSnapshot {
                    RestoringTerminalOverlay(host: pane.profile.host)
                } else if let exitCode = pane.remoteExitCode {
                    SessionEndedOverlay(
                        exitCode: exitCode,
                        restart: { pane.restartRuntime() },
                        detach: {
                            select()
                            NotificationCenter.default.post(name: .relayClosePane, object: pane.id)
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
                        .padding(12)
                }
                if preferences.artifactPresentation == .preview,
                   let artifact = pane.artifacts.last {
                    ArtifactPreview(artifact: artifact) {
                        pane.dismissArtifact(artifact.id)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
                    .zIndex(100)
                }
            }
            if preferences.artifactPresentation == .inline,
               let artifact = pane.artifacts.last {
                InlineArtifactView(artifact: artifact) {
                    pane.dismissArtifact(artifact.id)
                }
                .frame(height: min(300, max(120, paneSize.height * 0.4)))
            }
        }
        .background(RelayTheme.canvas)
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(RelayTheme.line.opacity(0.55), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(RelayTheme.accent)
                    .frame(width: 2, height: 28)
                    .padding(.leading, 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let placement = dropPreview.placement {
                PaneDropPreview(placement: placement)
                    .allowsHitTesting(false)
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
                close: close
            )
                .onDrag {
                    PaneDragCoordinator.shared.paneID = pane.id
                    return NSItemProvider(object: pane.id.uuidString as NSString)
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
                close: close
            )
        }
    }
}

@MainActor
private final class PaneDragCoordinator {
    static let shared = PaneDragCoordinator()
    var paneID: UUID?
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
        PaneDragCoordinator.shared.paneID = nil
        rearrange(draggedID, placement)
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
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(RelayTheme.blue.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(RelayTheme.blue.opacity(0.9), lineWidth: 2)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)

                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(RelayTheme.text)
                    .padding(.horizontal, 8)
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
        case .center: "SWAP"
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
        QuickEditorContent(runtime: pane.editorRuntime)
    }
}

private struct QuickEditorContent: View {
    @ObservedObject var runtime: RemoteEditorRuntime
    @ObservedObject private var preferences = RelayPreferences.shared

    var body: some View {
        HStack(spacing: 0) {
            if runtime.navigatorVisible {
                EditorNavigator(runtime: runtime)
                    .frame(width: 210)
                Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(width: 1)
            }
            VStack(spacing: 0) {
                editorToolbar
                Rectangle().fill(RelayTheme.line.opacity(0.45)).frame(height: 1)
                MonacoEditorSurface(
                    runtime: runtime,
                    typography: EditorTypography(
                        fontFamily: preferences.resolvedFontFamily,
                        fontSize: preferences.fontSize
                    )
                )
                editorStatus
            }
        }
        .background(RelayTheme.canvas)
    }

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            Button {
                runtime.navigatorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 10.5, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .help(runtime.navigatorVisible ? "Hide files" : "Show files")

            if let path = runtime.currentPath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.text)
                    .lineLimit(1)
                if runtime.isDirty {
                    Circle().fill(RelayTheme.textMuted).frame(width: 5, height: 5)
                }
            } else {
                Text("Choose a file")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            Spacer(minLength: 8)
            if runtime.isBusy { ProgressView().controlSize(.mini).tint(RelayTheme.accent) }
            Button(runtime.isDiff ? "Edit" : "Changes") { runtime.toggleDiff() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(runtime.currentPath == nil ? RelayTheme.textFaint : RelayTheme.textMuted)
                .disabled(runtime.currentPath == nil)
            Button("Save") { runtime.requestSave() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(runtime.isDirty ? RelayTheme.text : RelayTheme.textMuted)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                .disabled(runtime.currentPath == nil)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RelayTheme.canvas)
    }

    private var editorStatus: some View {
        HStack(spacing: 8) {
            if let error = runtime.operationError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(RelayTheme.coral)
                Text(error).foregroundStyle(RelayTheme.coral)
            } else {
                Text(runtime.status)
                    .foregroundStyle(RelayTheme.textFaint)
            }
            Spacer()
            if runtime.isDiff { Text("Diff") }
            Text("UTF-8")
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(RelayTheme.textFaint)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: 23)
        .background(RelayTheme.surface.opacity(0.7))
    }
}

private struct EditorNavigator: View {
    @ObservedObject var runtime: RemoteEditorRuntime
    @State private var query = ""

    private var visibleEntries: [RemoteFileEntry] {
        guard !query.isEmpty else { return runtime.entries }
        return runtime.entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button { runtime.goUp() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(runtime.directoryPath == runtime.workspacePath ? RelayTheme.textFaint : RelayTheme.textMuted)
                .disabled(runtime.directoryPath == runtime.workspacePath)
                Text(runtime.directoryPath.isEmpty ? "Files" : URL(fileURLWithPath: runtime.directoryPath).lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RelayTheme.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(height: 31)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9.5))
                    .foregroundStyle(RelayTheme.textFaint)
                TextField("Filter files", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(RelayTheme.text)
            }
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 7)
            .padding(.bottom, 6)

            Rectangle().fill(RelayTheme.line.opacity(0.4)).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(visibleEntries) { entry in
                        Button { runtime.openEntry(entry) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: entry.directory ? "folder" : fileSymbol(entry.name))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(entry.directory ? RelayTheme.blue : RelayTheme.textMuted)
                                    .frame(width: 13)
                                Text(entry.name)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(RelayTheme.textMuted)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 25)
                            .background(runtime.currentPath == entry.path ? RelayTheme.surface : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(5)
            }
        }
        .background(RelayTheme.canvas)
    }

    private func fileSymbol(_ name: String) -> String {
        let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ["swift", "go", "rs", "py", "r", "js", "ts", "c", "cpp"].contains(suffix)
            ? "chevron.left.forwardslash.chevron.right" : "doc"
    }
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
    let dismiss: () -> Void
    @State private var offset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var panelSize = CGSize(width: 360, height: 354)
    @GestureState private var resizeGesture: ResizeGestureState?
    @State private var imageZoom: CGFloat = 1
    @GestureState private var pinchZoom: CGFloat = 1
    @State private var imagePan: CGSize = .zero
    @GestureState private var imagePanTranslation: CGSize = .zero
    @FocusState private var focusedResizeCorner: ResizeCorner?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayedSize: CGSize {
        resizeMetrics(for: resizeGesture).size
    }

    private var displayedCenterShift: CGSize {
        resizeMetrics(for: resizeGesture).centerShift
    }

    private var displayedZoom: CGFloat { min(6, max(1, imageZoom * pinchZoom)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RelayTheme.textFaint)
                Image(systemName: "photo")
                    .foregroundStyle(RelayTheme.blue)
                Text(artifact.filename)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    setZoom(imageZoom - 0.25)
                } label: {
                    Text("−")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .focusEffectDisabled()
                .disabled(imageZoom <= 1)
                .accessibilityLabel("Zoom out")
                Button {
                    resetImageView()
                } label: {
                    Text("\(Int((imageZoom * 100).rounded()))%")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .frame(minWidth: 34, minHeight: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .focusEffectDisabled()
                .accessibilityLabel("Reset image zoom")
                Button {
                    setZoom(imageZoom + 0.25)
                } label: {
                    Text("+")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .focusEffectDisabled()
                .disabled(imageZoom >= 6)
                .accessibilityLabel("Zoom in")
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .focusEffectDisabled()
                .accessibilityLabel("Close image preview")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RelayTheme.elevated)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($dragTranslation) { value, state, _ in state = value.translation }
                    .onEnded { value in
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
            .help("Drag to move · double-click to reset")

            if let image = artifact.image {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(displayedZoom)
                        .offset(clampedImagePan(in: proxy.size))
                        .accessibilityLabel("Generated image: \(artifact.filename)")
                }
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
                .help("Pinch to zoom · drag to pan · double-click to reset")
            }
        }
        .frame(width: displayedSize.width, height: displayedSize.height)
        .background(RelayTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(RelayTheme.line.opacity(0.55)) }
        .shadow(color: .black.opacity(0.3), radius: 16, y: 7)
        .overlay {
            ZStack {
                ForEach(ResizeCorner.allCases, id: \.self) { corner in
                    resizeHandle(corner)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                }
            }
        }
        .offset(
            x: offset.width + dragTranslation.width + displayedCenterShift.width,
            y: offset.height + dragTranslation.height + displayedCenterShift.height
        )
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
            .frame(width: 28, height: 28)
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
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(
                        focusedResizeCorner == corner ? RelayTheme.textMuted.opacity(0.65) : Color.clear,
                        lineWidth: 1
                    )
                    .padding(6)
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
        imageZoom = min(6, max(1, proposedZoom))
        if imageZoom == 1 { imagePan = .zero }
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

private struct InlineArtifactView: View {
    let artifact: PaneArtifact
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "photo")
                    .foregroundStyle(RelayTheme.blue)
                Text(artifact.filename)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .focusEffectDisabled()
                .accessibilityLabel("Close inline image")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)

            if let image = artifact.image {
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
    let detach: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(RelayTheme.textMuted)
            Text("Remote process ended")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(RelayTheme.text)
            Text("Exit code \(exitCode)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(RelayTheme.textMuted)
            HStack(spacing: 8) {
                Button("Detach", action: detach)
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.textMuted)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                Button("Restart", action: restart)
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.canvas)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RelayTheme.blue, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(20)
        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(RelayTheme.line.opacity(0.55)) }
    }
}

private struct ConnectionPath: View {
    @ObservedObject var pane: PaneModel
    let active: Bool
    let compact: Bool
    let zoomed: Bool
    let isFloating: Bool
    let select: () -> Void
    let toggleZoom: (() -> Void)?
    let toggleFloating: (() -> Void)?
    let rename: (() -> Void)?
    let close: (() -> Void)?
    @ObservedObject private var preferences = RelayPreferences.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(pane.connectionState.color)
                .frame(width: 6, height: 6)
            Text(pane.displayName)
                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                .lineLimit(1)
                .onTapGesture(count: 2) { rename?() }
            if pane.profile.kind == .ssh, pane.displayName != pane.profile.host {
                Text(pane.profile.host)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textFaint)
                    .lineLimit(1)
            }
            if pane.profile.kind == .ssh {
                Text(pane.profile.backend == .relay ? "Relay" : "SSH")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            if let directory = pane.directory, !directory.isEmpty {
                Text(URL(fileURLWithPath: directory).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: directory).lastPathComponent)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(RelayTheme.textFaint)
                    .lineLimit(1)
                    .help(directory)
                    .accessibilityLabel("Working directory \(directory)")
            }
            if pane.contentKind == .editor {
                Label("Editor", systemImage: "curlybraces")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(RelayTheme.blue)
            } else if pane.kind != .shell {
                Label(pane.activeSubagents > 0 ? String(pane.activeSubagents) + " agents" : pane.kind.label,
                      systemImage: pane.kind.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(pane.phase.color)
                Text(AgentLabelFormatter.activity(pane.activitySummary))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textFaint)
                    .lineLimit(1)
                    .layoutPriority(-1)
                if pane.pendingAgentApprovals > 0 {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(RelayTheme.coral)
                        .accessibilityLabel("\(pane.pendingAgentApprovals) pending agent approvals")
                }
                if let usage = pane.agentResourceUsage {
                    Text("\(usage.inputTokens + usage.outputTokens) tok")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.textFaint)
                        .help("Input \(usage.inputTokens), cached \(usage.cachedInputTokens), output \(usage.outputTokens)")
                }
            }
            Spacer(minLength: 8)
            if let progress = pane.terminalProgressPercent {
                ProgressView(value: Double(progress), total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 42)
                    .help("Command progress \(progress) percent")
                    .accessibilityLabel("Command progress")
                    .accessibilityValue("\(progress) percent")
            } else if pane.terminalProgressState == "indeterminate" {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(RelayTheme.accent)
                    .help("Command in progress")
                    .accessibilityLabel("Command in progress")
            }
            if let exitCode = pane.lastCommandExitCode {
                Image(systemName: exitCode == 0 ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(exitCode == 0 ? RelayTheme.textFaint : RelayTheme.coral)
                    .help(commandStatusHelp(exitCode: exitCode, durationNanos: pane.lastCommandDurationNanos))
                    .accessibilityLabel(exitCode == 0 ? "Last command succeeded" : "Last command exited with status \(exitCode)")
            }
            if pane.connectionState != .connected {
                Text(pane.connectionState.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(pane.connectionState.color)
            }
            if let toggleFloating {
                Button(action: toggleFloating) {
                    Image(systemName: isFloating ? "rectangle.portrait.and.arrow.right" : "macwindow.on.rectangle")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help(isFloating ? "Dock pane" : "Float pane")
                .accessibilityLabel(isFloating ? "Dock pane" : "Float pane")
            }
            if let toggleZoom {
                Button(action: toggleZoom) {
                    Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help(zoomed ? "Restore pane layout" : "Zoom pane")
                .accessibilityLabel(zoomed ? "Restore pane layout" : "Zoom pane")
            }
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help(pane.profile.kind == .ssh ? "Detach pane · ⌘W" : "Close pane · ⌘W")
                .accessibilityLabel(pane.profile.kind == .ssh ? "Detach pane" : "Close pane")
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
            if pane.contentKind == .terminal {
                Menu("Agent type") {
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        Button {
                            pane.setAgentKind(kind)
                        } label: {
                            Label(kind.label, systemImage: pane.kind == kind ? "checkmark" : kind.symbol)
                        }
                    }
                }
            }
            if rename != nil || pane.contentKind == .terminal { Divider() }
            if let toggleZoom { Button(zoomed ? "Restore pane layout" : "Zoom pane", action: toggleZoom) }
            if let toggleFloating { Button(isFloating ? "Dock pane" : "Float pane", action: toggleFloating) }
            if let close { Button(pane.profile.kind == .ssh ? "Detach pane" : "Close pane", action: close) }
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
        VStack(spacing: 13) {
            ProgressView()
                .controlSize(.small)
                .tint(RelayTheme.accent)
            Text(contentKind == .editor ? "Opening remote workspace" : "Opening remote session")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RelayTheme.text)
            Text(contentKind == .editor ? "\(host)  →  code editor" : "\(host)  →  native terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RelayTheme.textMuted)
        }
        .padding(22)
        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(RelayTheme.line.opacity(0.5)) }
    }
}

private struct RestoringTerminalOverlay: View {
    let host: String

    var body: some View {
        ZStack {
            RelayTheme.canvas
            VStack(spacing: 13) {
                ProgressView()
                    .controlSize(.small)
                    .tint(RelayTheme.accent)
                Text("Restoring terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RelayTheme.text)
                Text("Showing the current screen on \(host)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            }
            .padding(22)
            .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(RelayTheme.line.opacity(0.5)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConnectionErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil
    var manageRelayd: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(RelayTheme.coral)
            VStack(alignment: .leading, spacing: 2) {
                Text("Could not reach the remote session")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(RelayTheme.text)
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(RelayTheme.textMuted)
                    .lineLimit(2)
            }
            Spacer()
            if let manageRelayd {
                Button("Install relayd", action: manageRelayd)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(RelayTheme.blue)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 7))
            }
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(RelayTheme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(11)
        .background(RelayTheme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(RelayTheme.coral.opacity(0.35)) }
    }
}

private struct ConnectionRecoveryBanner: View {
    let host: String
    let message: String
    let waitingForNetwork: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: waitingForNetwork ? "network.slash" : "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(waitingForNetwork ? RelayTheme.coral : RelayTheme.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(waitingForNetwork ? "VPN or network unavailable" : "Reconnecting to \(host)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(RelayTheme.text)
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(RelayTheme.textMuted)
                    .lineLimit(2)
            }
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(RelayTheme.accent)
        }
        .padding(11)
        .background(RelayTheme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke((waitingForNetwork ? RelayTheme.coral : RelayTheme.blue).opacity(0.32))
        }
    }
}
