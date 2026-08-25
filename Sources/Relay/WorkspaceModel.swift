import AppKit
import Foundation

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
    @Published private(set) var sessionNames: [UUID: String] = [:]

    let profileStore = ProfileStore()
    private(set) var panes: [UUID: PaneModel] = [:]
    private let workspaceKey = "relay.workspace.v1"
    private var sidebarBeforeFullScreen = true
    private var persistenceTask: Task<Void, Never>?

    init() {
        if !restoreWorkspace() {
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

    func sessionDisplayName(_ sessionID: UUID, fallback: String) -> String {
        sessionNames[sessionID] ?? fallback
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
        panes[pane.id] = pane
        let tab = TabModel(sessionID: UUID(), name: profile.name, firstPane: pane.id)
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
        panes[pane.id] = pane
        let ordinal = sessionTabs.count + 1
        let tab = TabModel(
            sessionID: sessionID,
            name: ordinal == 1 ? sourcePane.profile.name : "\(sourcePane.profile.name) \(ordinal)",
            firstPane: pane.id
        )
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
        panes[pane.id] = pane
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
        panes[pane.id] = pane
        tab.layout = tab.layout.splitting(active.id, axis: .horizontal, with: pane.id)
        tab.balanceSplits()
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
        guard let activePaneID else { return }
        let pane = PaneModel(
            profile: open.profile,
            contentKind: .editor,
            remoteParentSessionID: open.parentSessionID,
            editorRequest: open.request
        )
        panes[pane.id] = pane
        tab.layout = tab.layout.splitting(activePaneID, axis: .horizontal, with: pane.id)
        tab.balanceSplits()
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
        panes[pane.id] = pane
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
        if zoomedPaneID == activePaneID { zoomedPaneID = nil }
        if let floatingIndex = tab.floatingPanes.firstIndex(where: { $0.paneID == activePaneID }) {
            tab.floatingPanes.remove(at: floatingIndex)
            panes[activePaneID]?.stopRuntime()
            panes.removeValue(forKey: activePaneID)
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
        self.activePaneID = tab.layout.paneIDs.first
        persistWorkspace()
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let ids = tabs[index].allPaneIDs
        if let zoomedPaneID, ids.contains(zoomedPaneID) { self.zoomedPaneID = nil }
        for paneID in ids {
            panes[paneID]?.stopRuntime()
            panes.removeValue(forKey: paneID)
        }
        tabs.remove(at: index)
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
            panes[paneID]?.stopRuntime()
            panes.removeValue(forKey: paneID)
        }
        tabs.removeAll { closingTabIDs.contains($0.id) }
        sessionNames.removeValue(forKey: sessionID)
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
        zoomedPaneID = nil
        selectedTabID = id
        activePaneID = tabs.first(where: { $0.id == id })?.layout.paneIDs.first
        persistWorkspace()
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
            panes[savedPane.id] = PaneModel(
                id: savedPane.id,
                profile: savedPane.profile,
                contentKind: savedPane.contentKind ?? .terminal,
                remoteParentSessionID: savedPane.remoteParentSessionID,
                editorRequest: savedPane.editorRequest,
                customName: savedPane.customName
            )
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
            return false
        }
        tabs = restoredTabs
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
                        customName: $0.customName
                    )
                }
            },
            sessionNames: sessionNames,
            selectedTabID: selectedTabID,
            activePaneID: activePaneID
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: workspaceKey)
    }
}

private struct WorkspaceSnapshot: Codable {
    let tabs: [TabSnapshot]
    let panes: [PaneSnapshot]
    let sessionNames: [UUID: String]?
    let selectedTabID: UUID?
    let activePaneID: UUID?
}

private struct TabSnapshot: Codable {
    let id: UUID
    let sessionID: UUID?
    let name: String
    let layout: PaneLayout
    let floatingPanes: [FloatingPanePlacement]?
    let splitRatios: [UUID: Double]?
}

private struct PaneSnapshot: Codable {
    let id: UUID
    let profile: ConnectionProfile
    let contentKind: PaneContentKind?
    let remoteParentSessionID: String?
    let editorRequest: EditorOpenRequest?
    let customName: String?
}
