import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var preferences = RelayPreferences.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if workspace.sidebarVisible {
                    SessionManager(workspace: workspace)
                        .frame(width: preferences.compactInterface ? 244 : 260)
                    Rectangle().fill(RelayTheme.line.opacity(0.38)).frame(width: 1)
                }
                VStack(spacing: 0) {
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
        }
        .background(RelayTheme.canvas)
        .sheet(isPresented: $workspace.isHostLauncherPresented) {
            HostLauncher(workspace: workspace)
        }
        .sheet(isPresented: $workspace.isConnectionSheetPresented) {
            ConnectionSheet(workspace: workspace)
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            workspace.setFullScreen(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            workspace.setFullScreen(false)
        }
    }
}

private struct AgentInspectorPanel: View {
    @ObservedObject var pane: PaneModel
    let subagentID: String
    let showTerminal: () -> Void
    let close: () -> Void
    @State private var settledOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    private var agent: SubagentActivity? {
        pane.subagents.first { $0.id == subagentID }
    }

    var body: some View {
        VStack(spacing: 0) {
            inspectorTitleBar
            Rectangle().fill(RelayTheme.line.opacity(0.7)).frame(height: 1)
            if let agent {
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
        .frame(width: 470, height: 410)
        .background(RelayTheme.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(RelayTheme.line.opacity(0.85), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
        .offset(
            x: settledOffset.width + dragOffset.width,
            y: settledOffset.height + dragOffset.height
        )
    }

    private var inspectorTitleBar: some View {
        HStack(spacing: 9) {
            Image(systemName: pane.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RelayTheme.textMuted)
            Text("Agent thread")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(RelayTheme.text)
            Text(pane.kind.label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(RelayTheme.textFaint)
            Spacer()
            Button(action: showTerminal) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .help("Show parent terminal")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RelayTheme.surface.opacity(0.7))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .updating($dragOffset) { value, state, _ in state = value.translation }
                .onEnded { value in
                    settledOffset.width += value.translation.width
                    settledOffset.height += value.translation.height
                }
        )
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
        return workspace.tabs.filter { $0.sessionID == sessionID }
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
                        WorkspaceTab(
                            tab: tab,
                            label: index == 0 ? "Main" : "Tab \(index + 1)",
                            isSelected: tab.id == workspace.selectedTabID,
                            select: { workspace.selectTab(tab.id) },
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
        .padding(.leading, workspace.isFullScreen || workspace.sidebarVisible ? 10 : 76)
        .padding(.trailing, 10)
        .frame(height: workspace.isFullScreen ? 38 : 44)
        .background(RelayTheme.canvas)
    }
}

private struct WorkspaceTab: View {
    @ObservedObject var tab: TabModel
    let label: String
    let isSelected: Bool
    let select: () -> Void
    let rename: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 1) {
            Button(action: select) {
                Text(label)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .padding(.leading, 9)
                    .padding(.trailing, 4)
                    .frame(height: 29)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .frame(width: 18, height: 29)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .opacity(isSelected || hovering ? 1 : 0)
        }
        .foregroundStyle(isSelected ? RelayTheme.text : RelayTheme.textMuted)
        .background(hovering ? RelayTheme.hover.opacity(0.45) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    private var nodeGroups: [SessionNodeGroup] {
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
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.isFullScreen {
                Color.clear.frame(height: 42)
            }
            HStack(spacing: 8) {
                Text("Sessions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RelayTheme.text)
                Spacer()
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

    private var nodeConnected: Bool {
        group.sessions.flatMap(\.tabs).flatMap(\.allPaneIDs).compactMap { workspace.panes[$0] }.contains { pane in
            if case .connected = pane.connectionState { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle()
                    .fill(nodeConnected ? RelayTheme.mint : RelayTheme.textFaint)
                    .frame(width: 6, height: 6)
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
                .background(selected ? RelayTheme.surface.opacity(0.82) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
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
                    let tabPanes = tab.allPaneIDs.compactMap { workspace.panes[$0] }
                    let visiblePanes = selected && tab.id == workspace.selectedTabID
                        ? tabPanes
                        : tabPanes.filter { $0.contentKind == .terminal && $0.kind != .shell }
                    let tabIndex = session.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
                    ForEach(visiblePanes) { pane in
                        SessionPaneRow(
                            pane: pane,
                            tabID: tab.id,
                            tabLabel: tabIndex == 0 ? "Main" : "Tab \(tabIndex + 1)",
                            workspace: workspace,
                            active: pane.id == workspace.activePaneID && tab.id == workspace.selectedTabID
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label), \(session.tabs.count) tabs, \(panes.count) panes, \(agentThreads) agent threads")
    }
}

private struct PanePresence: View {
    @ObservedObject var pane: PaneModel

    var body: some View {
        Circle()
            .fill(pane.phase == .needsInput ? RelayTheme.coral : pane.kind == .shell ? RelayTheme.textFaint : RelayTheme.mint)
            .frame(width: 5, height: 5)
            .help("\(pane.kind.label): \(pane.phase.label)")
    }
}

private struct SessionPaneRow: View {
    @ObservedObject var pane: PaneModel
    let tabID: UUID
    let tabLabel: String
    @ObservedObject var workspace: WorkspaceModel
    let active: Bool
    @State private var hovering = false
    @State private var agentThreadsExpanded = false

    private var tab: TabModel? { workspace.tabs.first { $0.id == tabID } }
    private var isFloating: Bool { tab?.floatingPanes.contains(where: { $0.paneID == pane.id }) == true }

    private func revealPane() {
        if workspace.selectedTabID != tabID { workspace.selectTab(tabID) }
        workspace.selectPane(pane.id)
        pane.focus()
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
                        Text(pane.activitySummary)
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
                } else if workspace.selectedTabID != tabID {
                    Text(tabLabel)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(RelayTheme.textFaint)
                }
                Circle().fill(pane.connectionState.color).frame(width: 5, height: 5)
                }
                .padding(.leading, 22)
                .padding(.trailing, pane.subagents.isEmpty ? 9 : 54)
                .frame(height: pane.contentKind == .terminal && pane.kind != .shell ? 38 : 29)
                .background(active ? RelayTheme.elevated : hovering ? RelayTheme.surface.opacity(0.7) : Color.clear,
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
            }
            .overlay(alignment: .trailing) {
                if pane.contentKind == .terminal && pane.kind != .shell && !pane.subagents.isEmpty {
                    Button {
                        agentThreadsExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(pane.subagents.count)")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            Image(systemName: agentThreadsExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .frame(width: 45, height: 29)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.textFaint)
                    .padding(.trailing, 3)
                    .help(agentThreadsExpanded ? "Collapse \(pane.subagents.count) agent threads" : "Show \(pane.subagents.count) agent threads")
                }
            }

            if pane.contentKind == .terminal && pane.kind != .shell && agentThreadsExpanded {
                ForEach(Array(pane.agentActivities.suffix(4))) { activity in
                    AgentActivityTreeRow(activity: activity, action: revealPane)
                }
                if pane.agentActivities.isEmpty {
                    AgentActivityTreeRow(activity: AgentActivityItem(
                        id: pane.id,
                        label: pane.activitySummary,
                        phase: pane.phase,
                        occurredAt: pane.lastActivity
                    ), action: revealPane)
                }
            }

            if agentThreadsExpanded {
                ForEach(pane.subagents) { subagent in
                    Button {
                        workspace.inspectAgent(paneID: pane.id, subagentID: subagent.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(RelayTheme.textFaint)
                            Circle().fill(subagent.phase.color).frame(width: 5, height: 5)
                            Text(subagent.label)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(RelayTheme.textMuted)
                                .lineLimit(1)
                            Spacer()
                            Text(subagent.phase == .active ? "working" : "finished")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(subagent.phase.color)
                        }
                        .padding(.leading, 43)
                        .padding(.trailing, 9)
                        .frame(height: 23)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(subagent.label) activity")
                }
            }
        }
    }
}

private struct AgentActivityTreeRow: View {
    let activity: AgentActivityItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(RelayTheme.textFaint)
                Circle()
                    .fill(activity.phase.color)
                    .frame(width: 5, height: 5)
                Text(activity.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(activity.phase == .quiet ? RelayTheme.textFaint : RelayTheme.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(activity.phase.label)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(activity.phase.color)
            }
            .padding(.leading, 43)
            .padding(.trailing, 9)
            .frame(height: 23)
            .background(hovering ? RelayTheme.surface.opacity(0.55) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct HostLauncher: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var store: ProfileStore
    @State private var query = ""
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
                TextField("Search hosts or enter an SSH alias…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(RelayTheme.text)
                    .focused($searchFocused)
                    .onSubmit(connectFirstResult)
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
                            subtitle: profile.usesSSHConfig
                                ? "SSH config · Opens as a native Relay terminal"
                                : profile.subtitle,
                            symbol: "server.rack",
                            badge: profile.backend == .relay ? "Persistent" : "Direct"
                        ) { workspace.newTab(profile: profile) }
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
                            badge: "New"
                        ) { workspace.newTab(profile: typedHost) }
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
        .onExitCommand { workspace.isHostLauncherPresented = false }
    }

    private func connectFirstResult() {
        if let first = filteredHosts.first {
            workspace.newTab(profile: first)
        } else if let typedHost {
            workspace.newTab(profile: typedHost)
        }
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
        .shadow(color: .black.opacity(0.32), radius: dragOffset == .zero ? 16 : 7, y: dragOffset == .zero ? 8 : 3)
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
                DragGesture(minimumDistance: 2)
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
            .draggable(pane.id.uuidString)

            Button(action: dock) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .help("Dock pane")

            Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .help(pane.profile.kind == .ssh ? "Detach floating pane" : "Close floating pane")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RelayTheme.elevated)
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(isActive ? RelayTheme.blue : RelayTheme.textFaint)
            .frame(width: 28, height: 28)
            .background(
                LinearGradient(
                    colors: [RelayTheme.elevated.opacity(0), RelayTheme.elevated],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
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
            .help("Resize floating pane")
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

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let divider: CGFloat = 6
            let available = max(1, total - divider)
            let firstLength = available * ratio
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
        }
    }

    private func splitDivider(total: CGFloat) -> some View {
        Rectangle()
            .fill(RelayTheme.canvas)
            .overlay {
                Capsule()
                    .fill(RelayTheme.line.opacity(0.8))
                    .frame(width: axis == .horizontal ? 1 : 24, height: axis == .horizontal ? 24 : 1)
            }
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                if axis == .horizontal {
                    (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                } else {
                    (hovering ? NSCursor.resizeUpDown : NSCursor.arrow).set()
                }
            }
            .highPriorityGesture(TapGesture(count: 2).onEnded { update(0.5, true) })
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        let start = dragStartRatio ?? ratio
                        if dragStartRatio == nil { dragStartRatio = ratio }
                        update(start + delta / total, false)
                    }
                    .onEnded { value in
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        update((dragStartRatio ?? ratio) + delta / total, true)
                        dragStartRatio = nil
                    }
            )
            .help("Drag to resize · double-click to center")
    }
}

private struct PaneView: View {
    @ObservedObject var pane: PaneModel
    let isActive: Bool
    let compactChrome: Bool
    let select: () -> Void
    var rearrange: ((UUID, PaneDropPlacement) -> Void)? = nil
    var toggleZoom: (() -> Void)? = nil
    var toggleFloating: (() -> Void)? = nil
    var rename: (() -> Void)? = nil
    var close: (() -> Void)? = nil
    var isFloating = false
    var isZoomed = false
    @State private var paneSize: CGSize = .zero
    @State private var isDropTarget = false

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
                if pane.connectionState == .connecting {
                    ConnectingOverlay(host: pane.profile.host, contentKind: pane.contentKind)
                        .allowsHitTesting(false)
                } else if pane.isRestoringTerminal {
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
                        retry: pane.contentKind == .editor ? { pane.restartRuntime() } : nil
                    )
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(12)
                }
                if let artifact = pane.artifacts.last {
                    ArtifactPreview(artifact: artifact) {
                        pane.dismissArtifact(artifact.id)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
                    .zIndex(100)
                }
            }
        }
        .background(RelayTheme.canvas)
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(RelayTheme.line.opacity(0.55), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if isActive {
                Capsule()
                    .fill(RelayTheme.accent)
                    .frame(width: 34, height: 2)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(RelayTheme.blue.opacity(0.8), lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { paneSize = $0 }
        .dropDestination(for: String.self) { items, location in
            guard let rawID = items.first, let draggedID = UUID(uuidString: rawID), let rearrange else {
                return false
            }
            rearrange(draggedID, dropPlacement(at: location))
            return true
        } isTargeted: { isDropTarget = $0 }
    }

    private func dropPlacement(at location: CGPoint) -> PaneDropPlacement {
        guard paneSize.width > 0, paneSize.height > 0 else { return .center }
        let horizontal = location.x / paneSize.width
        let vertical = location.y / paneSize.height
        if vertical < 0.28 { return .top }
        if vertical > 0.72 { return .bottom }
        if horizontal < 0.28 { return .leading }
        if horizontal > 0.72 { return .trailing }
        return .center
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
                .draggable(pane.id.uuidString)
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

private struct QuickEditorPane: View {
    @ObservedObject var pane: PaneModel

    var body: some View {
        QuickEditorContent(runtime: pane.editorRuntime)
    }
}

private struct QuickEditorContent: View {
    @ObservedObject var runtime: RemoteEditorRuntime

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
                MonacoEditorSurface(runtime: runtime)
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
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RelayTheme.elevated)

            if let image = artifact.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 320)
                    .background(Color.black.opacity(0.24))
            }
        }
        .frame(width: 360)
        .background(RelayTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(RelayTheme.line.opacity(0.55)) }
        .shadow(color: .black.opacity(0.3), radius: 16, y: 7)
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
            Text(pane.profile.kind == .ssh ? pane.profile.host : "This Mac")
                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                .lineLimit(1)
            if pane.profile.kind == .ssh {
                Text(pane.profile.backend == .relay ? "Relay" : "SSH")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
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
                Text(pane.activitySummary)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textFaint)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
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
            }
            if let toggleZoom {
                Button(action: toggleZoom) {
                    Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help(zoomed ? "Restore pane layout" : "Zoom pane")
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
            }
        }
        .padding(.horizontal, compact ? 9 : 12)
        .frame(height: compact || preferences.compactInterface ? 28 : 34)
        .foregroundStyle(active ? RelayTheme.text : RelayTheme.textMuted)
        .background(active ? RelayTheme.surface : RelayTheme.canvas)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onTapGesture(count: 2) { toggleZoom?() }
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
