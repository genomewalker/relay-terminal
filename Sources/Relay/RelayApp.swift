import AppKit
import SwiftUI

@MainActor
enum RelayApplicationActivityState {
    private(set) static var allowsContinuousUpdates = true
    private static var applicationIsActive = true
    private static var userSessionIsActive = true

    static func setApplicationActive(_ active: Bool) {
        applicationIsActive = active
        update()
    }

    static func setUserSessionActive(_ active: Bool) {
        userSessionIsActive = active
        update()
    }

    private static func update() {
        let allowed = applicationIsActive && userSessionIsActive
        guard allowsContinuousUpdates != allowed else { return }
        allowsContinuousUpdates = allowed
        NotificationCenter.default.post(name: .relayApplicationActivityChanged, object: allowed)
    }
}

enum RelayQuitConfirmationPolicy {
    enum Action: Equatable { case arm, quit }

    static let windowNanoseconds: UInt64 = 2_000_000_000

    static func action(armedAt: UInt64?, now: UInt64) -> Action {
        guard let armedAt, now >= armedAt, now - armedAt <= windowNanoseconds else {
            return .arm
        }
        return .quit
    }
}

@MainActor
final class RelayApplicationDelegate: NSObject, NSApplicationDelegate {
    private var keyboardMonitor: Any?
    private var quitArmedAt: UInt64?
    private var quitConfirmationTimer: Timer?
    private var workspaceActivityObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        RelayApplicationActivityState.setApplicationActive(NSApp.isActive)
        RelayCrashRecovery.shared.beginLaunch()
        RelayDiagnostics.shared.record(category: "app", name: "launched", details: [
            "safe_mode": String(RelayLaunchMode.isSafeMode),
        ])
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let binding = RelayKeyBinding(event: event)
            if binding == RelayKeyBinding("q", command: true) {
                // A held key must never count as the second deliberate press.
                guard !event.isARepeat else { return nil }
                self.handleQuitShortcut()
                return nil
            }
            guard NSApp.keyWindow?.identifier == .relayWorkspaceWindow,
                  binding == RelayCommand.closePane.defaultBinding else {
                return event
            }
            let configured = RelayKeyBindingStorage.binding(
                for: .closePane,
                overrides: RelayKeyBindingStorage.load()
            )
            if configured == RelayCommand.closePane.defaultBinding {
                NotificationCenter.default.post(name: .relayClosePane, object: nil)
            }
            // Never let the standard macOS Close Window handler consume ⌘W
            // in the workspace. If the user moved Close Pane elsewhere, ⌘W
            // becomes intentionally unassigned for this window.
            return nil
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceActivityObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in RelayApplicationActivityState.setUserSessionActive(false) }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in RelayApplicationActivityState.setUserSessionActive(true) }
            },
        ]
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        RelayApplicationActivityState.setApplicationActive(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        RelayApplicationActivityState.setApplicationActive(false)
    }

    func applicationDidHide(_ notification: Notification) {
        RelayApplicationActivityState.setApplicationActive(false)
    }

    func applicationDidUnhide(_ notification: Notification) {
        RelayApplicationActivityState.setApplicationActive(NSApp.isActive)
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitConfirmationTimer?.invalidate()
        quitConfirmationTimer = nil
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceActivityObservers.forEach(workspaceCenter.removeObserver)
        workspaceActivityObservers.removeAll()
        RelayDiagnostics.shared.record(category: "app", name: "clean-shutdown")
        RelayCrashRecovery.shared.cleanShutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func handleQuitShortcut() {
        let now = DispatchTime.now().uptimeNanoseconds
        switch RelayQuitConfirmationPolicy.action(armedAt: quitArmedAt, now: now) {
        case .quit:
            quitArmedAt = nil
            quitConfirmationTimer?.invalidate()
            quitConfirmationTimer = nil
            NotificationCenter.default.post(name: .relayQuitConfirmation, object: false)
            NSApp.terminate(nil)
        case .arm:
            quitArmedAt = now
            quitConfirmationTimer?.invalidate()
            NotificationCenter.default.post(name: .relayQuitConfirmation, object: true)
            quitConfirmationTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                Task { @MainActor [weak self] in
                    guard let self, self.quitArmedAt == now else { return }
                    self.quitArmedAt = nil
                    self.quitConfirmationTimer = nil
                    NotificationCenter.default.post(name: .relayQuitConfirmation, object: false)
                }
            }
        }
    }
}

extension Notification.Name {
    static let relayQuitConfirmation = Notification.Name("relay.quit-confirmation")
    static let relayApplicationActivityChanged = Notification.Name("relay.application-activity-changed")
}

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(RelayApplicationDelegate.self) private var applicationDelegate
    @StateObject private var workspace = WorkspaceModel()
    @StateObject private var preferences = RelayPreferences.shared

    private func shortcut(_ command: RelayCommand) -> RelayKeyBinding {
        preferences.keyBinding(for: command)
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 880, minHeight: 560)
                .background(RelayWorkspaceWindowMarker().frame(width: 0, height: 0))
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
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    workspace.shutdown()
                }
        }
        .defaultSize(width: 1320, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New tab in session") { workspace.newTabInActiveSession() }
                    .keyboardShortcut(shortcut(.newTab).keyEquivalent, modifiers: shortcut(.newTab).eventModifiers)
                Button("New local session") { workspace.newTab(profile: .local) }
                    .keyboardShortcut(shortcut(.newLocalSession).keyEquivalent, modifiers: shortcut(.newLocalSession).eventModifiers)
                Button("Find SSH host…") { workspace.presentHostLauncher() }
                    .keyboardShortcut(shortcut(.findHost).keyEquivalent, modifiers: shortcut(.findHost).eventModifiers)
                Button("Connect to host…") { workspace.presentConnectionSheet() }
                    .keyboardShortcut(shortcut(.connectHost).keyEquivalent, modifiers: shortcut(.connectHost).eventModifiers)
            }
            CommandMenu("Pane") {
                Button("Open remote editor") { workspace.openEditorForActive() }
                    .keyboardShortcut(shortcut(.openEditor).keyEquivalent, modifiers: shortcut(.openEditor).eventModifiers)
                    .disabled(workspace.activePane?.profile.kind != .ssh || workspace.activePane?.profile.backend != .relay)
                Divider()
                Button(workspace.zoomedPaneID == workspace.activePaneID ? "Restore pane layout" : "Zoom active pane") {
                    workspace.toggleActivePaneZoom()
                }
                    .keyboardShortcut(shortcut(.zoomPane).keyEquivalent, modifiers: shortcut(.zoomPane).eventModifiers)
                Button("Float or dock active pane") {
                    workspace.toggleActivePaneFloating()
                }
                    .keyboardShortcut(shortcut(.floatPane).keyEquivalent, modifiers: shortcut(.floatPane).eventModifiers)
                Button("Balance pane layout") { workspace.balanceActiveTabPanes() }
                    .keyboardShortcut(shortcut(.balancePanes).keyEquivalent, modifiers: shortcut(.balancePanes).eventModifiers)
                Divider()
                Button("Split right") { workspace.splitActive(axis: .horizontal) }
                    .keyboardShortcut(shortcut(.splitRight).keyEquivalent, modifiers: shortcut(.splitRight).eventModifiers)
                Button("Split down") { workspace.splitActive(axis: .vertical) }
                    .keyboardShortcut(shortcut(.splitDown).keyEquivalent, modifiers: shortcut(.splitDown).eventModifiers)
                Button("New floating pane") { workspace.newFloatingPane() }
                    .keyboardShortcut(shortcut(.newFloatingPane).keyEquivalent, modifiers: shortcut(.newFloatingPane).eventModifiers)
                Divider()
                Button("Previous pane") { workspace.selectAdjacentPane(offset: -1) }
                    .keyboardShortcut(shortcut(.previousPane).keyEquivalent, modifiers: shortcut(.previousPane).eventModifiers)
                Button("Next pane") { workspace.selectAdjacentPane(offset: 1) }
                    .keyboardShortcut(shortcut(.nextPane).keyEquivalent, modifiers: shortcut(.nextPane).eventModifiers)
                Divider()
                Button("Previous prompt") { _ = workspace.activePane?.runtime.jumpToPrompt(by: -1) }
                    .keyboardShortcut(shortcut(.previousPrompt).keyEquivalent, modifiers: shortcut(.previousPrompt).eventModifiers)
                Button("Next prompt") { _ = workspace.activePane?.runtime.jumpToPrompt(by: 1) }
                    .keyboardShortcut(shortcut(.nextPrompt).keyEquivalent, modifiers: shortcut(.nextPrompt).eventModifiers)
                    .disabled(workspace.activePane?.contentKind != .terminal)
                Divider()
                Button(workspace.activePane?.profile.kind == .ssh ? "Detach pane" : "Close pane") {
                    workspace.closeActivePane()
                }
                    .keyboardShortcut(shortcut(.closePane).keyEquivalent, modifiers: shortcut(.closePane).eventModifiers)
            }
            CommandMenu("Tab") {
                Button("Previous tab") { workspace.selectTab(offset: -1) }
                    .keyboardShortcut(shortcut(.previousTab).keyEquivalent, modifiers: shortcut(.previousTab).eventModifiers)
                Button("Next tab") { workspace.selectTab(offset: 1) }
                    .keyboardShortcut(shortcut(.nextTab).keyEquivalent, modifiers: shortcut(.nextTab).eventModifiers)
            }
            CommandGroup(after: .sidebar) {
                Button(workspace.sidebarVisible ? "Hide session rail" : "Show session rail") {
                    workspace.sidebarVisible.toggle()
                }
                .keyboardShortcut(shortcut(.toggleSidebar).keyEquivalent, modifiers: shortcut(.toggleSidebar).eventModifiers)
                Button(workspace.intelligencePanelVisible ? "Hide agent activity" : "Show agent activity") {
                    workspace.toggleIntelligencePanel()
                }
                .keyboardShortcut(shortcut(.agentActivity).keyEquivalent, modifiers: shortcut(.agentActivity).eventModifiers)
            }
            CommandMenu("Remote") {
                Button("Manage relayd…") {
                    NotificationCenter.default.post(
                        name: .relayManageRelayd, object: workspace.activePane?.profile
                    )
                }
                Button("Check relayd on active host") {
                    guard let profile = workspace.activePane?.profile, profile.kind == .ssh else { return }
                    RelaydManager.shared.select(profile)
                    RelaydManager.shared.check(profile)
                    NotificationCenter.default.post(name: .relayManageRelayd, object: profile)
                }
                .disabled(workspace.activePane?.profile.kind != .ssh)
            }
            CommandMenu("Diagnostics") {
                Button("Export diagnostics…") {
                    RelayDiagnostics.shared.presentExportPanel()
                }
                Button("Relaunch in safe mode…") {
                    RelayDiagnostics.shared.record(category: "app", name: "safe-mode-relaunch-requested")
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.arguments = ["--safe-mode"]
                    NSWorkspace.shared.openApplication(
                        at: Bundle.main.bundleURL,
                        configuration: configuration
                    ) { _, error in
                        Task { @MainActor in
                            if let error { NSAlert(error: error).runModal() }
                            else { NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }

        Settings {
            RelaySettingsView()
        }
    }
}
