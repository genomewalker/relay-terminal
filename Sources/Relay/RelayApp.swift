import SwiftUI

@main
struct RelayApp: App {
    @StateObject private var workspace = WorkspaceModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 880, minHeight: 560)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .relaySelectPane)) { note in
                    if let id = note.object as? UUID { workspace.selectPane(id) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .relaySplitRight)) { _ in
                    workspace.splitActive(axis: .horizontal)
                }
                .onReceive(NotificationCenter.default.publisher(for: .relaySplitDown)) { _ in
                    workspace.splitActive(axis: .vertical)
                }
                .onReceive(NotificationCenter.default.publisher(for: .relayClosePane)) { _ in
                    workspace.closeActivePane()
                }
                .onReceive(NotificationCenter.default.publisher(for: .relayOpenRemoteFile)) { note in
                    if let request = note.object as? RemoteFileOpenRequest {
                        workspace.openRemoteFile(request)
                    }
                }
                .onDisappear { workspace.shutdown() }
        }
        .defaultSize(width: 1320, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New tab in session") { workspace.newTabInActiveSession() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New local session") { workspace.newTab(profile: .local) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Find SSH host…") { workspace.presentHostLauncher() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Connect to host…") { workspace.presentConnectionSheet() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Pane") {
                Button("Open remote editor") { workspace.openEditorForActive() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(workspace.activePane?.profile.kind != .ssh || workspace.activePane?.profile.backend != .relay)
                Divider()
                Button(workspace.zoomedPaneID == workspace.activePaneID ? "Restore pane layout" : "Zoom active pane") {
                    workspace.toggleActivePaneZoom()
                }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Float or dock active pane") {
                    workspace.toggleActivePaneFloating()
                }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Balance pane layout") { workspace.balanceActiveTabPanes() }
                    .keyboardShortcut("=", modifiers: [.command, .option])
                Divider()
                Button("Split right") { workspace.splitActive(axis: .horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split down") { workspace.splitActive(axis: .vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("New floating pane") { workspace.newFloatingPane() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                Button("Previous pane") { workspace.selectAdjacentPane(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                Button("Next pane") { workspace.selectAdjacentPane(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Divider()
                Button(workspace.activePane?.profile.kind == .ssh ? "Detach pane" : "Close pane") {
                    workspace.closeActivePane()
                }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Tab") {
                Button("Previous tab") { workspace.selectTab(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next tab") { workspace.selectTab(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button(workspace.sidebarVisible ? "Hide session rail" : "Show session rail") {
                    workspace.sidebarVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }

        Settings {
            RelaySettingsView()
        }
    }
}
