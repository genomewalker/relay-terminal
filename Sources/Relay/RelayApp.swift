import AppKit
import Darwin
import GhosttyTerminal
import SwiftUI

enum RelayBundledGhosttyResources {
    static let bundleDirectoryName = "GhosttyKit_GhosttyTerminal.bundle"

    static func directory(in applicationResourcesURL: URL) -> URL {
        applicationResourcesURL
            .appendingPathComponent(bundleDirectoryName, isDirectory: true)
            .appendingPathComponent("Ghostty", isDirectory: true)
    }

    @discardableResult
    static func configure(
        applicationResourcesURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let applicationResourcesURL else { return false }
        let resourceDirectory = directory(in: applicationResourcesURL)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: resourceDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return false
        }
        setenv("GHOSTTY_RESOURCES_DIR", resourceDirectory.path, 1)
        if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(
                "[RelayTerminal] ghostty_resources=\(resourceDirectory.path)\n".utf8
            ))
        }
        return true
    }
}

@MainActor
enum RelayApplicationActivityState {
    private(set) static var allowsContinuousUpdates = true
    private static var applicationIsVisible = true
    private static var userSessionIsActive = true

    static func setApplicationVisible(_ visible: Bool) {
        applicationIsVisible = visible
        update()
    }

    static func setUserSessionActive(_ active: Bool) {
        userSessionIsActive = active
        update()
    }

    private static func update() {
        let allowed = applicationIsVisible && userSessionIsActive
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
    private var windowPresentationObservers: [NSObjectProtocol] = []
    private var presentationSuspensionTask: Task<Void, Never>?
    private let responsivenessMonitor = RelayResponsivenessMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        responsivenessMonitor.start()
        if ProcessInfo.processInfo.environment["RELAY_TERMINAL_DEBUG"] == "1" {
            // Developer-only lifecycle tracing. Deliberately excludes input
            // and output categories so terminal contents and secrets never
            // enter logs.
            TerminalDebugLog.sink = { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            TerminalDebugLog.enable([.lifecycle, .metrics])
        }
        updateApplicationPresentationVisibility()
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
            if let terminal = NSApp.keyWindow?.firstResponder as? RelayGhosttyView,
               terminal.handleApplicationClipboardShortcut(event) {
                return nil
            }
            if NSApp.keyWindow?.identifier == .relayWorkspaceWindow,
               event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
               let key = event.charactersIgnoringModifiers?.lowercased(),
               !(NSApp.keyWindow?.firstResponder is NSTextView) {
                let action: RelayClipboardAction? = switch key {
                case "c": .copy
                case "v": .paste
                case "a": .selectAll
                default: nil
                }
                if let action {
                    // A restored, zoomed, or floating terminal can briefly be
                    // visible while SwiftUI owns first responder. Route the
                    // standard clipboard shortcut to the selected terminal so
                    // that transient reparenting cannot eat Command-C/V.
                    let request = RelayClipboardRequest(action)
                    NotificationCenter.default.post(name: .relayClipboardRequest, object: request)
                    if request.handled { return nil }
                }
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
        let notificationCenter = NotificationCenter.default
        windowPresentationObservers = [
            notificationCenter.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateApplicationPresentationVisibility()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateApplicationPresentationVisibility()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateApplicationPresentationVisibility()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.updateApplicationPresentationVisibility()
                }
            },
        ]
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        presentRecoverableWorkspaceWindowIfNeeded()
        updateApplicationPresentationVisibility()
        // During a Space/full-screen handoff AppKit can deliver activation
        // before the workspace window's visible occlusion bit settles. Check
        // again after that window transition instead of leaving rendering
        // paused until an unrelated resize or tab switch.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.updateApplicationPresentationVisibility()
            try? await Task.sleep(for: .milliseconds(120))
            self?.updateApplicationPresentationVisibility()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        // AppKit can briefly resign Relay during a Space/full-screen handoff.
        // Do not tear down every display link for a transient notification;
        // sustained backgrounding still enters the low-energy state shortly.
        scheduleApplicationPresentationSuspension()
    }

    func applicationDidHide(_ notification: Notification) {
        presentationSuspensionTask?.cancel()
        presentationSuspensionTask = nil
        RelayApplicationActivityState.setApplicationVisible(false)
    }

    func applicationDidUnhide(_ notification: Notification) {
        updateApplicationPresentationVisibility()
    }

    func applicationDidChangeOcclusionState(_ notification: Notification) {
        // Space and full-screen transitions may occlude Relay without hiding
        // it. This gates presentation only; the terminal byte stream remains
        // attached and its in-memory state continues to advance.
        updateApplicationPresentationVisibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        responsivenessMonitor.stop()
        presentationSuspensionTask?.cancel()
        presentationSuspensionTask = nil
        quitConfirmationTimer?.invalidate()
        quitConfirmationTimer = nil
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceActivityObservers.forEach(workspaceCenter.removeObserver)
        workspaceActivityObservers.removeAll()
        let notificationCenter = NotificationCenter.default
        windowPresentationObservers.forEach(notificationCenter.removeObserver)
        windowPresentationObservers.removeAll()
        RelayDiagnostics.shared.record(category: "app", name: "clean-shutdown")
        RelayCrashRecovery.shared.cleanShutdown()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { presentRecoverableWorkspaceWindowIfNeeded() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// SwiftUI can retain a WindowGroup scene across an in-place app update
    /// while AppKit restores that window off-screen or hidden. The process and
    /// remote transports then run with no usable UI. Reopen the existing scene
    /// instead of creating a second workspace/controller and a second remote
    /// writer.
    private func presentRecoverableWorkspaceWindowIfNeeded() {
        guard !NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) else { return }
        let workspaceWindow = NSApp.windows.first(where: {
            $0.identifier == .relayWorkspaceWindow
        }) ?? NSApp.windows.first(where: {
            $0.canBecomeMain && !($0 is NSPanel)
        })
        guard let workspaceWindow else { return }
        if workspaceWindow.isMiniaturized { workspaceWindow.deminiaturize(nil) }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(workspaceWindow.frame) }) {
            workspaceWindow.center()
        }
        workspaceWindow.makeKeyAndOrderFront(nil)
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

    private func updateApplicationPresentationVisibility() {
        let visible = applicationHasPresentableWorkspace
        if visible {
            presentationSuspensionTask?.cancel()
            presentationSuspensionTask = nil
            RelayApplicationActivityState.setApplicationVisible(true)
        } else {
            scheduleApplicationPresentationSuspension()
        }
    }

    private var applicationHasPresentableWorkspace: Bool {
        let workspaceWindows = NSApp.windows.filter { $0.identifier == .relayWorkspaceWindow }
        let hasPresentableWorkspace = workspaceWindows.isEmpty || workspaceWindows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
        return !NSApp.isHidden
            && NSApp.isActive
            && NSApp.occlusionState.contains(.visible)
            && hasPresentableWorkspace
    }

    private func scheduleApplicationPresentationSuspension() {
        guard presentationSuspensionTask == nil else { return }
        presentationSuspensionTask = Task { @MainActor [weak self] in
            // Long enough to absorb AppKit's transient false occlusion state,
            // short enough that a genuinely backgrounded Relay stops GPU work.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.presentationSuspensionTask = nil
            if self.applicationHasPresentableWorkspace {
                RelayApplicationActivityState.setApplicationVisible(true)
            } else {
                RelayApplicationActivityState.setApplicationVisible(false)
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
    @StateObject private var workspace: WorkspaceModel
    @StateObject private var preferences: RelayPreferences
    private let sidePanelServer: RelaySidePanelServer

    init() {
        // Ghostty's SwiftPM resource accessor can fall back to the build-tree
        // path when the executable is launched outside its project directory.
        // Configure the installed bundle explicitly before WorkspaceModel can
        // create a pane and initialize TerminalRuntime's shared controller.
        RelayBundledGhosttyResources.configure()
        // Install Relay's own terminal identity before any local surface is
        // created. The installer is content-addressed and falls back to the
        // system xterm entry when this machine cannot resolve xterm-relay.
        RelayTerminfo.bootstrap()
        let workspace = WorkspaceModel()
        _workspace = StateObject(wrappedValue: workspace)
        _preferences = StateObject(wrappedValue: RelayPreferences.shared)
        sidePanelServer = RelaySidePanelServer(workspace: workspace)
    }

    private func shortcut(_ command: RelayCommand) -> RelayKeyBinding {
        preferences.keyBinding(for: command)
    }

    private func performClipboardCommand(_ action: RelayClipboardAction) {
        let firstResponder = NSApp.keyWindow?.firstResponder
        let isNativeTextEditor = firstResponder is NSTextView
        if let terminal = firstResponder as? RelayGhosttyView,
           terminal.handleApplicationClipboardAction(action) {
            return
        }
        if NSApp.keyWindow?.identifier == .relayWorkspaceWindow,
           !isNativeTextEditor,
           workspace.activePane?.contentKind == .terminal,
           workspace.activePane?.runtime.handleApplicationClipboardAction(action) == true {
            return
        }

        // Keep rename fields, Settings controls, and rcode's editor on the
        // standard responder chain. Terminal panes use the branch above so
        // the Edit menu and its hardware shortcuts cannot fall through to
        // Ghostty's asynchronous clipboard lookup after a focus transition.
        let selectorName = switch action {
        case .copy: "copy:"
        case .paste: "paste:"
        case .selectAll: "selectAll:"
        }
        _ = NSApp.sendAction(NSSelectorFromString(selectorName), to: nil, from: nil)
    }

    private func performUndoCommand(redo: Bool) {
        let firstResponder = NSApp.keyWindow?.firstResponder
        if let terminal = firstResponder as? RelayGhosttyView,
           terminal.performPromptHistoryAction(redo: redo) {
            return
        }
        if NSApp.keyWindow?.identifier == .relayWorkspaceWindow,
           !(firstResponder is NSTextView),
           workspace.activePane?.runtime.handleApplicationUndoAction(redo: redo) == true {
            return
        }
        _ = NSApp.sendAction(
            NSSelectorFromString(redo ? "redo:" : "undo:"),
            to: nil,
            from: nil
        )
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
                .onReceive(NotificationCenter.default.publisher(for: .relayTerminatePane)) { note in
                    if let id = note.object as? UUID { workspace.requestTerminatePane(id) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .relayOpenRemoteFile)) { note in
                    if let request = note.object as? RemoteFileOpenRequest {
                        workspace.openRemoteFile(request)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .relayClipboardRequest)) { note in
                    guard let request = note.object as? RelayClipboardRequest,
                          workspace.activePane?.contentKind == .terminal else { return }
                    request.handled = workspace.activePane?.runtime
                        .handleApplicationClipboardAction(request.action) == true
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
            CommandGroup(replacing: .undoRedo) {
                Button("Undo prompt edit") { performUndoCommand(redo: false) }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo prompt edit") { performUndoCommand(redo: true) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") { performClipboardCommand(.copy) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { performClipboardCommand(.paste) }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Select All") { performClipboardCommand(.selectAll) }
                    .keyboardShortcut("a", modifiers: .command)
            }
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
                Button("Reopen closed pane") { workspace.reopenLastClosedPane() }
                    .keyboardShortcut(shortcut(.reopenClosedPane).keyEquivalent, modifiers: shortcut(.reopenClosedPane).eventModifiers)
                    .disabled(!workspace.canReopenClosedPane)
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
                Divider()
                Button("Copy Codex panel link") {
                    sidePanelServer.copyAccessLink()
                }
            }
            CommandMenu("Diagnostics") {
                Button(workspace.performancePanelVisible ? "Hide performance" : "Show performance") {
                    workspace.togglePerformancePanel()
                }
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
