import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject private var preferences = RelayPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceBar(workspace: workspace)
            Rectangle().fill(RelayTheme.line.opacity(0.7)).frame(height: 1)
            HStack(spacing: 0) {
                if workspace.sidebarVisible {
                    SessionManager(workspace: workspace)
                        .frame(width: preferences.compactInterface ? 208 : 228)
                    Rectangle().fill(RelayTheme.line.opacity(0.7)).frame(width: 1)
                }

                if let tab = workspace.selectedTab {
                    WorkspaceCanvas(tab: tab, workspace: workspace)
                        .background(RelayTheme.canvas)
                }
            }
        }
        .background(RelayTheme.canvas)
        .sheet(isPresented: $workspace.isHostLauncherPresented) {
            HostLauncher(workspace: workspace)
        }
        .sheet(isPresented: $workspace.isConnectionSheetPresented) {
            ConnectionSheet(workspace: workspace)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            workspace.setFullScreen(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            workspace.setFullScreen(false)
        }
    }
}

private struct WorkspaceBar: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: workspace.isFullScreen ? 6 : 9) {
                if !workspace.sidebarVisible {
                    ChromeButton(symbol: "sidebar.left", help: "Show navigator") {
                        workspace.sidebarVisible = true
                    }
                }
                if !workspace.isFullScreen {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(RelayTheme.blueDim)
                            .frame(width: 30, height: 30)
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(RelayTheme.blue)
                    }
                    Text("Relay")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(RelayTheme.text)
                }
            }
            .frame(width: workspace.sidebarVisible && !workspace.isFullScreen ? 220 : nil, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        WorkspaceTab(
                            tab: tab,
                            isSelected: tab.id == workspace.selectedTabID,
                            select: { workspace.selectTab(tab.id) },
                            close: { workspace.closeTab(tab.id) }
                        )
                    }
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                ChromeButton(symbol: "rectangle.split.2x1", help: "Split remote pane right · ⌘D") {
                    workspace.splitActive(axis: .horizontal)
                }
                ChromeButton(symbol: "rectangle.split.1x2", help: "Split remote pane down · ⇧⌘D") {
                    workspace.splitActive(axis: .vertical)
                }
                ChromeButton(symbol: "rectangle.on.rectangle", help: "New floating remote pane · ⌥⌘F") {
                    workspace.newFloatingPane()
                }
                ChromeButton(symbol: "rectangle.split.3x1", help: "Balance pane layout · ⌥⌘=") {
                    workspace.balanceActiveTabPanes()
                }
                if workspace.isFullScreen {
                    ChromeButton(symbol: "plus", help: "Connect to a host · ⌘K") {
                        workspace.presentHostLauncher()
                    }
                } else {
                    Button {
                        workspace.presentHostLauncher()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("Connect")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("⌘K")
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundStyle(RelayTheme.textMuted)
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).stroke(RelayTheme.line.opacity(0.8))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayTheme.text)
                }
            }
        }
        .padding(.leading, workspace.isFullScreen ? 10 : 76)
        .padding(.trailing, workspace.isFullScreen ? 8 : 12)
        .frame(height: workspace.isFullScreen ? 40 : 54)
        .background(.ultraThinMaterial)
        .background(RelayTheme.sidebar.opacity(0.92))
    }
}

private struct WorkspaceTab: View {
    @ObservedObject var tab: TabModel
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? RelayTheme.blue : RelayTheme.textFaint)
                Text(tab.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .foregroundStyle(isSelected ? RelayTheme.text : RelayTheme.textMuted)
            .background(isSelected ? RelayTheme.elevated : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8).stroke(RelayTheme.line.opacity(0.8))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(RelayTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(RelayTheme.textMuted)
        .help(help)
    }
}

private struct SessionNodeGroup: Identifiable {
    let id: String
    let name: String
    let remote: Bool
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
            if let index = groups.firstIndex(where: { $0.id == key }) {
                groups[index].tabs.append(tab)
            } else {
                groups.append(SessionNodeGroup(id: key, name: name, remote: remote, tabs: [tab]))
            }
        }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("SESSIONS")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(RelayTheme.textMuted)
                Spacer()
                Button {
                    workspace.presentHostLauncher()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help("Connect to a host")
                Button {
                    workspace.sidebarVisible = false
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayTheme.textMuted)
                .help("Hide sessions")
            }
            .padding(.leading, 13)
            .padding(.trailing, 8)
            .frame(height: 40)

            Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(nodeGroups) { group in
                        SessionNodeSection(group: group, workspace: workspace)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)
            Rectangle().fill(RelayTheme.line.opacity(0.55)).frame(height: 1)
            Button {
                workspace.presentHostLauncher()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(RelayTheme.blue)
                    Text("New connection")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(RelayTheme.text)
                    Spacer()
                    Text("⌘K")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.textFaint)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
            }
            .buttonStyle(.plain)
        }
        .background(RelayTheme.sidebar)
    }
}

private struct SessionNodeSection: View {
    let group: SessionNodeGroup
    @ObservedObject var workspace: WorkspaceModel

    private var nodeConnected: Bool {
        group.tabs.flatMap(\.allPaneIDs).compactMap { workspace.panes[$0] }.contains { pane in
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
                Image(systemName: group.remote ? "server.rack" : "laptopcomputer")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RelayTheme.textMuted)
                Text(group.name)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RelayTheme.textMuted)
                    .lineLimit(1)
                Spacer()
                Text("\(group.tabs.count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(RelayTheme.textFaint)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)

            ForEach(group.tabs) { tab in
                AttachedSessionRow(
                    tab: tab,
                    panes: tab.allPaneIDs.compactMap { workspace.panes[$0] },
                    selected: workspace.selectedTabID == tab.id,
                    activePaneID: workspace.activePaneID,
                    selectTab: { workspace.selectTab(tab.id) },
                    selectPane: { pane in
                        workspace.selectPane(pane.id)
                        pane.runtime.focus()
                    },
                    detach: { workspace.closeTab(tab.id) }
                )
            }
        }
        .padding(.bottom, 7)
    }
}

private struct AttachedSessionRow: View {
    @ObservedObject var tab: TabModel
    let panes: [PaneModel]
    let selected: Bool
    let activePaneID: UUID?
    let selectTab: () -> Void
    let selectPane: (PaneModel) -> Void
    let detach: () -> Void

    private var activeAgents: Int { panes.filter { $0.kind != .shell }.count }

    var body: some View {
        VStack(spacing: 1) {
            Button(action: selectTab) {
                HStack(spacing: 7) {
                    Capsule()
                        .fill(selected ? RelayTheme.blue : Color.clear)
                        .frame(width: 2, height: 20)
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(selected ? RelayTheme.blue : RelayTheme.textFaint)
                    Text(tab.name)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? RelayTheme.text : RelayTheme.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    ForEach(Array(panes.prefix(3))) { pane in
                        PanePresence(pane: pane)
                    }
                    Text("\(panes.count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayTheme.textFaint)
                }
                .padding(.horizontal, 6)
                .frame(height: 32)
                .background(selected ? RelayTheme.surface.opacity(0.72) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Detach session", action: detach)
            }

            if selected {
                ForEach(panes) { pane in
                    SessionPaneRow(
                        pane: pane,
                        active: pane.id == activePaneID,
                        select: { selectPane(pane) }
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tab.name), \(panes.count) panes, \(activeAgents) agents")
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
    let active: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 7) {
                Rectangle()
                    .fill(active ? RelayTheme.blue.opacity(0.8) : RelayTheme.line.opacity(0.7))
                    .frame(width: 1, height: 24)
                Image(systemName: pane.kind.symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(pane.phase.color)
                    .frame(width: 14)
                Text(pane.kind == .shell ? pane.title : pane.kind.label)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? RelayTheme.text : RelayTheme.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if pane.activeSubagents > 0 {
                    Text("\(pane.activeSubagents)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayTheme.mint)
                }
                Circle().fill(pane.connectionState.color).frame(width: 5, height: 5)
                }
                .padding(.leading, 25)
                .padding(.trailing, 9)
                .frame(height: 28)
                .background(active ? RelayTheme.elevated.opacity(0.72) : hovering ? RelayTheme.surface.opacity(0.45) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Mark as \(pane.kind == .shell ? "Claude" : pane.kind == .claude ? "Codex" : "shell")") {
                    pane.cycleAgentKind()
                }
            }

            ForEach(pane.subagents.prefix(4)) { subagent in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(RelayTheme.textFaint)
                    Circle().fill(RelayTheme.mint).frame(width: 5, height: 5)
                    Text(subagent.label)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(RelayTheme.textMuted)
                        .lineLimit(1)
                    Spacer()
                    Text("working")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RelayTheme.mint)
                }
                .padding(.leading, 43)
                .padding(.trailing, 9)
                .frame(height: 23)
            }
        }
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
                    .font(.system(size: 18, weight: .medium))
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
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(RelayTheme.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RelayTheme.elevated, in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 20)
            .frame(height: 66)

            Rectangle().fill(RelayTheme.line.opacity(0.75)).frame(height: 1)

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
                            badge: "LOCAL"
                        ) { workspace.newTab(profile: .local) }
                    }

                    ForEach(filteredHosts) { profile in
                        HostResultRow(
                            title: profile.name,
                            subtitle: profile.usesSSHConfig
                                ? "SSH config · Opens as a native Relay terminal"
                                : profile.subtitle,
                            symbol: "server.rack",
                            badge: profile.backend == .relay ? "PERSISTENT" : "DIRECT"
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
                            badge: "NEW"
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

            Rectangle().fill(RelayTheme.line.opacity(0.75)).frame(height: 1)
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
                        .fill(hovering ? RelayTheme.blueDim : RelayTheme.surface)
                        .frame(width: 42, height: 42)
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(hovering ? RelayTheme.blue : RelayTheme.textMuted)
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
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(hovering ? RelayTheme.blue : RelayTheme.textFaint)
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
                                pane.runtime.focus()
                            },
                            move: { x, y in
                                workspace.updateFloatingPane(pane.id, originX: x, originY: y)
                            },
                            resize: { width, height in
                                workspace.updateFloatingPane(pane.id, width: width, height: height)
                            },
                            zoom: { workspace.togglePaneZoom(pane.id) },
                            dock: { workspace.dockFloatingPane(pane.id) },
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
                isFloating: true
            )
        }
        .frame(width: width, height: height)
        .background(RelayTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isActive ? RelayTheme.blue.opacity(0.9) : RelayTheme.line, lineWidth: isActive ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
        }
        .shadow(color: .black.opacity(0.42), radius: dragOffset == .zero ? 18 : 8, y: dragOffset == .zero ? 10 : 3)
        .offset(x: originX, y: originY)
        .transaction { $0.animation = nil }
    }

    private var floatingTitleBar: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Capsule()
                    .fill(isActive ? RelayTheme.blue : RelayTheme.textFaint)
                    .frame(width: 18, height: 4)
                Text(pane.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(RelayTheme.text)
                    .lineLimit(1)
                Text(pane.profile.kind == .ssh ? pane.profile.host.uppercased() : "THIS MAC")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(RelayTheme.blue)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RelayTheme.blueDim.opacity(0.75), in: Capsule())
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

            Button(action: dock) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(RelayTheme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .help("Dock pane")

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(RelayTheme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayTheme.textMuted)
            .help(pane.profile.kind == .ssh ? "Detach floating pane" : "Close floating pane")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(RelayTheme.elevated.opacity(0.92))
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
                    rearrange: { draggedID in workspace.swapTiledPanes(draggedID, id) },
                    toggleZoom: { workspace.togglePaneZoom(id) },
                    toggleFloating: { workspace.floatTiledPane(id) },
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
            let divider: CGFloat = 5
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
            .fill(RelayTheme.line.opacity(0.72))
            .overlay {
                Capsule()
                    .fill(RelayTheme.textFaint.opacity(0.65))
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
    var rearrange: ((UUID) -> Void)? = nil
    var toggleZoom: (() -> Void)? = nil
    var toggleFloating: (() -> Void)? = nil
    var isFloating = false
    var isZoomed = false

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            ZStack {
                TerminalSurface(pane: pane)
                    // A terminal backend is immutable after its NSView is created.
                    // Key the representable by the remote session so switching tabs
                    // cannot reuse a local-shell surface for an SSH pane.
                    .id(pane.id)
                if pane.connectionState == .connecting {
                    ConnectingOverlay(host: pane.profile.host)
                        .allowsHitTesting(false)
                } else if let exitCode = pane.remoteExitCode {
                    SessionEndedOverlay(
                        exitCode: exitCode,
                        restart: { pane.runtime.restart() },
                        detach: {
                            select()
                            NotificationCenter.default.post(name: .relayClosePane, object: pane.id)
                        }
                    )
                } else if let message = pane.connectionState.errorMessage {
                    ConnectionErrorBanner(message: message)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(12)
                        .allowsHitTesting(false)
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
            Rectangle()
                .stroke(isActive ? RelayTheme.blue.opacity(0.75) : RelayTheme.line.opacity(0.5), lineWidth: isActive ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let rawID = items.first, let draggedID = UUID(uuidString: rawID), let rearrange else {
                return false
            }
            rearrange(draggedID)
            return true
        }
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
                toggleFloating: toggleFloating
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
                toggleFloating: toggleFloating
            )
        }
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
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
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
        .background(RelayTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(RelayTheme.line) }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
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
        .background(RelayTheme.sidebar.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(RelayTheme.line) }
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
    @ObservedObject private var preferences = RelayPreferences.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(RelayTheme.textMuted)
            if pane.profile.kind == .ssh {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(RelayTheme.textFaint)
                Text(pane.profile.host)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(RelayTheme.textFaint)
                Text(pane.profile.backend == .relay ? "remote PTY" : "direct SSH")
                    .hidden()
                    .overlay(alignment: .leading) {
                        Text(pane.profile.backend == .relay ? "native terminal" : "direct SSH")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(RelayTheme.textMuted)
            } else {
                Text("This Mac")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            Spacer()
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
            if pane.kind != .shell {
                Label(pane.activeSubagents > 0 ? "\(pane.activeSubagents) agents" : pane.kind.label, systemImage: pane.kind.symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(pane.phase.color)
            }
            HStack(spacing: 5) {
                Image(systemName: pane.connectionState.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(pane.connectionState.label)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(pane.connectionState.color)
        }
        .padding(.horizontal, compact ? 9 : 12)
        .frame(height: compact || preferences.compactInterface ? 26 : 36)
        .foregroundStyle(active ? RelayTheme.text : RelayTheme.textMuted)
        .background(active ? RelayTheme.surface : RelayTheme.sidebar)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onTapGesture(count: 2) { toggleZoom?() }
        .contextMenu {
            if let toggleZoom { Button(zoomed ? "Restore pane layout" : "Zoom pane", action: toggleZoom) }
            if let toggleFloating { Button(isFloating ? "Dock pane" : "Float pane", action: toggleFloating) }
        }
    }
}

private struct ConnectingOverlay: View {
    let host: String

    var body: some View {
        VStack(spacing: 13) {
            ProgressView()
                .controlSize(.small)
                .tint(RelayTheme.blue)
            Text("Opening remote session")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RelayTheme.text)
            Text("\(host)  →  native terminal")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(RelayTheme.textMuted)
        }
        .padding(22)
        .background(RelayTheme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(RelayTheme.line) }
    }
}

private struct ConnectionErrorBanner: View {
    let message: String

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
        }
        .padding(11)
        .background(RelayTheme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(RelayTheme.coral.opacity(0.35)) }
    }
}
