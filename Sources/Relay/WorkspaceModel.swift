import AppKit
import Foundation

struct AgentInspectorSelection: Equatable, Sendable {
    let paneID: UUID
    let subagentID: String
}

private struct ClosedPaneRecovery {
    let pane: PaneSnapshot
    let tab: TabSnapshot
    let tabIndex: Int
    let floatingPlacement: FloatingPanePlacement?
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var tabs: [TabModel] = []
    @Published var selectedTabID: UUID?
    @Published var activePaneID: UUID?
    @Published var isConnectionSheetPresented = false
    @Published var isHostLauncherPresented = false
    @Published var sidebarVisible = true
    @Published var isFullScreen = false
    @Published var zoomedPaneID: UUID?
    @Published var draftProfile = ConnectionProfile()
    @Published var renameTarget: WorkspaceRenameTarget?
    @Published var renameDraft = ""
    @Published var agentInspector: AgentInspectorSelection?
    @Published var intelligencePanelVisible = false
    @Published var terminationTargetID: UUID?
    @Published var operationError: String?
    @Published private(set) var sessionNames: [UUID: String] = [:]
    @Published private(set) var pinnedSessionIDs = WorkspacePinStore.load(.session)
    @Published private(set) var pinnedTabIDs = WorkspacePinStore.load(.tab)
    @Published private(set) var recentlyClosedPaneCount = 0
    @Published private(set) var lastClosedPaneWasRemote = false

    let profileStore = ProfileStore()
    let activityIndex = WorkspaceActivityIndex()
    private(set) var panes: [UUID: PaneModel] = [:]
    private let workspaceKey = "relay.workspace.v1"
    private var sidebarBeforeFullScreen = true
    private var persistenceTask: Task<Void, Never>?
    private var didShutdown = false
    private var recentlyClosedPanes: [ClosedPaneRecovery] = []

    init(restoreSavedWorkspace: Bool = true) {
        let shouldRestore = restoreSavedWorkspace && !RelayLaunchMode.isSafeMode
        if shouldRestore && restoreWorkspace() {
            panes.values.forEach { $0.startAgentMonitoring() }
        } else {
            newTab(profile: .local)
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

    func inspectAgent(paneID: UUID, subagentID: String) {
        intelligencePanelVisible = false
        agentInspector = AgentInspectorSelection(paneID: paneID, subagentID: subagentID)
    }

    func closeAgentInspector() {
        agentInspector = nil
    }

    func toggleIntelligencePanel() {
        if !intelligencePanelVisible { agentInspector = nil }
        intelligencePanelVisible.toggle()
    }

    func closeIntelligencePanel() {
        intelligencePanelVisible = false
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
        guard let pane = panes[paneID], pane.profile.kind == .ssh, pane.profile.backend == .relay else { return }
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
        if selectedTabID != tab.id { selectTab(tab.id) }
        selectPane(paneID)
        panes[paneID]?.focus()
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
            let component = URL(fileURLWithPath: directory).lastPathComponent
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
        Task { @MainActor in
            await Task.yield()
            pane.focus()
        }
    }

    func attachRemoteSession(profile: ConnectionProfile, remote: RemoteSessionRecord) {
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
        profileStore.markUsed(profile)
        isHostLauncherPresented = false
        persistWorkspace()
    }

    /// Recreates one catalogued relay pane that is still alive remotely but no
    /// longer appears in the local layout. It is attached directly; no nested
    /// terminal command is launched and the remote process keeps one PTY writer.
    func attachRemotePane(
        profile: ConnectionProfile,
        remotePane: RemoteCatalogPane,
        workspaceID: String?,
        sessionLabel: String
    ) {
        guard remotePane.recoverable,
              let paneID = UUID(uuidString: remotePane.paneID) else { return }
        if panes[paneID] != nil {
            isHostLauncherPresented = false
            revealPane(paneID)
            return
        }

        let sessionID = workspaceID.flatMap(UUID.init(uuidString:)) ?? UUID()
        let tabID = remotePane.tabID.flatMap(UUID.init(uuidString:)) ?? UUID()
        let pane = PaneModel(
            id: paneID,
            profile: profile,
            contentKind: PaneContentKind(rawValue: remotePane.contentKind) ?? .terminal,
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
        profileStore.markUsed(profile)
        isHostLauncherPresented = false
        persistWorkspace()
        Task { @MainActor in
            await Task.yield()
            pane.focus()
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
            if tab.splitRatios.isEmpty { tab.balanceSplits() }
            for paneID in tab.allPaneIDs {
                panes[paneID]?.assignRemoteHierarchy(workspaceSessionID: sessionID, tabID: tab.id)
            }
            return tab
        }
        guard !restoredTabs.isEmpty else {
            for paneID in requiredIDs {
                panes.removeValue(forKey: paneID)
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
        profileStore.markUsed(profile)
        isHostLauncherPresented = false
        persistWorkspace()
        return true
    }

    func newTabInActiveSession() {
        guard let selectedTab else { return }
        newTab(inSession: selectedTab.sessionID)
    }

    func newTab(inSession sessionID: UUID) {
        let sessionTabs = tabs.filter { $0.sessionID == sessionID }
        guard let sourceTab = sessionTabs.first,
              let sourcePaneID = (selectedTab?.sessionID == sessionID ? activePaneID : sourceTab.allPaneIDs.first),
              let sourcePane = panes[sourcePaneID] else { return }
        let parentSessionID = sourcePane.profile.kind == .ssh && sourcePane.profile.backend == .relay
            ? (sourcePane.contentKind == .terminal ? sourcePane.id.uuidString.lowercased() : sourcePane.remoteParentSessionID)
            : nil
        let pane = PaneModel(profile: sourcePane.profile, remoteParentSessionID: parentSessionID)
        storePane(pane)
        let ordinal = sessionTabs.count + 1
        let tab = TabModel(
            sessionID: sessionID,
            name: ordinal == 1 ? sourcePane.profile.name : "\(sourcePane.profile.name) \(ordinal)",
            firstPane: pane.id
        )
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        tabs.append(tab)
        selectedTabID = tab.id
        activePaneID = pane.id
        persistWorkspace()
        Task { @MainActor in
            await Task.yield()
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
        guard let tab = selectedTab, let active = activePane else { return }
        let splitProfile = profile ?? active.profile
        let parentSessionID = splitProfile.kind == .ssh && splitProfile.backend == .relay
            ? active.id.uuidString.lowercased()
            : nil
        let pane = PaneModel(profile: splitProfile, remoteParentSessionID: parentSessionID)
        pane.assignRemoteHierarchy(workspaceSessionID: tab.sessionID, tabID: tab.id)
        storePane(pane)
        tab.layout = tab.layout.splitting(active.id, axis: axis, with: pane.id)
        tab.balanceSplits()
        activePaneID = pane.id
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
        guard let tab = selectedTab else { return }
        if let existingID = tab.allPaneIDs.first(where: { id in
            guard let pane = panes[id] else { return false }
            return pane.contentKind == .editor && pane.profile.connectionKey == open.profile.connectionKey
        }), let editor = panes[existingID] {
            activePaneID = existingID
            editor.editorRequest = open.request
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
        tab.balanceSplits()
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

    func toggleActivePaneZoom() {
        guard let activePaneID else { return }
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
        tab.balanceSplits()
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
        tab.balanceSplits()
        activePaneID = paneID
        zoomedPaneID = nil
        persistWorkspace()
        panes[paneID]?.focus()
    }

    func closeActivePane() {
        guard let tab = selectedTab, let activePaneID else { return }
        rememberClosedPane(activePaneID, in: tab)
        if agentInspector?.paneID == activePaneID { agentInspector = nil }
        if zoomedPaneID == activePaneID { zoomedPaneID = nil }
        if let floatingIndex = tab.floatingPanes.firstIndex(where: { $0.paneID == activePaneID }) {
            tab.floatingPanes.remove(at: floatingIndex)
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
        tab.balanceSplits()
        panes[activePaneID]?.stopRuntime()
        panes.removeValue(forKey: activePaneID)
        activityIndex.remove(activePaneID)
        self.activePaneID = tab.layout.paneIDs.first
        persistWorkspace()
    }

    var canReopenClosedPane: Bool { recentlyClosedPaneCount > 0 }

    func reopenLastClosedPane() {
        while let recovery = recentlyClosedPanes.popLast() {
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
                    existing.balanceSplits()
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
            splitRatios: tab.splitRatios
        )
        recentlyClosedPanes.append(ClosedPaneRecovery(
            pane: paneSnapshot,
            tab: tabSnapshot,
            tabIndex: tabIndex,
            floatingPlacement: tab.floatingPanes.first(where: { $0.paneID == paneID })
        ))
        if recentlyClosedPanes.count > 20 {
            recentlyClosedPanes.removeFirst(recentlyClosedPanes.count - 20)
        }
        lastClosedPaneWasRemote = pane.profile.kind == .ssh && pane.profile.backend == .relay
        recentlyClosedPaneCount = recentlyClosedPanes.count
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let ids = tabs[index].allPaneIDs
        if let zoomedPaneID, ids.contains(zoomedPaneID) { self.zoomedPaneID = nil }
        for paneID in ids {
            if agentInspector?.paneID == paneID { agentInspector = nil }
            panes[paneID]?.stopRuntime()
            panes.removeValue(forKey: paneID)
            activityIndex.remove(paneID)
        }
        tabs.remove(at: index)
        pinnedTabIDs.remove(id)
        WorkspacePinStore.save(pinnedTabIDs, kind: .tab)
        if tabs.isEmpty {
            newTab(profile: .local)
        } else {
            let nextIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[nextIndex].id
            activePaneID = tabs[nextIndex].layout.paneIDs.first
        }
        persistWorkspace()
    }

    func closeSession(_ sessionID: UUID) {
        let closingTabs = tabs.filter { $0.sessionID == sessionID }
        guard !closingTabs.isEmpty else { return }
        let closingTabIDs = Set(closingTabs.map(\.id))
        let closingPaneIDs = closingTabs.flatMap(\.allPaneIDs)
        for paneID in closingPaneIDs {
            if agentInspector?.paneID == paneID { agentInspector = nil }
            panes[paneID]?.stopRuntime()
            panes.removeValue(forKey: paneID)
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
        let next = tabs[0]
        selectedTabID = next.id
        activePaneID = next.layout.paneIDs.first
        zoomedPaneID = nil
        persistWorkspace()
    }

    func selectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        zoomedPaneID = nil
        selectedTabID = id
        activePaneID = tab.layout.paneIDs.first
        persistWorkspace()
        // The previous tab's Ghostty surface can remain the AppKit first
        // responder briefly after SwiftUI hides it. Wait for the selected
        // surface to mount, then transfer keyboard focus explicitly.
        if let paneID = activePaneID, let pane = panes[paneID] {
            Task { @MainActor in
                await Task.yield()
                guard self.selectedTabID == id, self.activePaneID == paneID else { return }
                pane.focus()
            }
        }
    }

    func selectPane(_ id: UUID) {
        activePaneID = id
        if let tab = selectedTab,
           let index = tab.floatingPanes.firstIndex(where: { $0.paneID == id }),
           index != tab.floatingPanes.index(before: tab.floatingPanes.endIndex) {
            let pane = tab.floatingPanes.remove(at: index)
            tab.floatingPanes.append(pane)
        }
        persistWorkspace()
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
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        selectTab(tabs[(current + offset + tabs.count) % tabs.count].id)
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

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        persistenceTask?.cancel()
        persistenceTask = nil
        persistWorkspaceNow()
        panes.values.forEach { $0.stopRuntime() }
    }

    @discardableResult
    private func restoreWorkspace() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: workspaceKey),
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
              !snapshot.tabs.isEmpty else { return false }

        for savedPane in snapshot.panes {
            let pane = PaneModel(
                id: savedPane.id,
                profile: savedPane.profile,
                contentKind: savedPane.contentKind ?? .terminal,
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
            if tab.splitRatios.isEmpty { tab.balanceSplits() }
            return tab
        }
        guard !restoredTabs.isEmpty else {
            panes.removeAll()
            activityIndex.removeAll()
            return false
        }
        tabs = restoredTabs
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

    private func persistWorkspace() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.persistenceTask = nil
            self.persistWorkspaceNow()
        }
    }

    private func storePane(_ pane: PaneModel) {
        panes[pane.id] = pane
        activityIndex.observe(pane)
    }

    private func persistWorkspaceNow() {
        let usedPaneIDs = Set(tabs.flatMap(\.allPaneIDs))
        let snapshot = WorkspaceSnapshot(
            tabs: tabs.map {
                TabSnapshot(
                    id: $0.id,
                    sessionID: $0.sessionID,
                    name: $0.name,
                    layout: $0.layout,
                    floatingPanes: $0.floatingPanes,
                    splitRatios: $0.splitRatios
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
            activePaneID: activePaneID
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: workspaceKey)
        persistRemoteWorkspaceStates(snapshot)
    }

    private func persistRemoteWorkspaceStates(_ snapshot: WorkspaceSnapshot) {
        for sessionID in Set(tabs.map(\.sessionID)) {
            let sessionTabs = tabs.filter { $0.sessionID == sessionID }
            let paneIDs = Set(sessionTabs.flatMap(\.allPaneIDs))
            guard let remotePane = paneIDs.compactMap({ panes[$0] }).first(where: {
                $0.profile.kind == .ssh && $0.profile.backend == .relay
            }) else { continue }
            let remoteSnapshot = WorkspaceSnapshot(
                tabs: snapshot.tabs.filter { ($0.sessionID ?? $0.id) == sessionID },
                panes: snapshot.panes.filter { paneIDs.contains($0.id) },
                sessionNames: sessionNames[sessionID].map { [sessionID: $0] },
                selectedTabID: sessionTabs.contains(where: { $0.id == selectedTabID }) ? selectedTabID : sessionTabs.first?.id,
                activePaneID: activePaneID.flatMap { paneIDs.contains($0) ? $0 : nil }
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
}

struct TabSnapshot: Codable, Sendable {
    let id: UUID
    let sessionID: UUID?
    let name: String
    let layout: PaneLayout
    let floatingPanes: [FloatingPanePlacement]?
    let splitRatios: [UUID: Double]?
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
