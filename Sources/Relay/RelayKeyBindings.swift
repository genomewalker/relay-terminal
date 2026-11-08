import AppKit
import Foundation
import SwiftUI

enum RelayCommand: String, CaseIterable, Identifiable, Codable, Sendable {
    case newTab
    case newLocalSession
    case findHost
    case quickNavigate
    case fleetBoard
    case connectHost
    case openEditor
    case zoomPane
    case floatPane
    case balancePanes
    case splitRight
    case splitDown
    case newFloatingPane
    case previousPane
    case nextPane
    case previousPrompt
    case nextPrompt
    case closePane
    case reopenClosedPane
    case previousTab
    case nextTab
    case toggleSidebar
    case agentActivity
    case workspaceOverview
    case workspaceBack
    case workspaceForward
    case workspaceUp
    case stackPane
    case unstackPane
    case previousStackPane
    case nextStackPane
    case saveWorkspaceView
    case openWorkspaceView

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newTab: "New tab in session"
        case .newLocalSession: "New local session"
        case .quickNavigate: "Go to pane"
        case .fleetBoard: "Agent fleet"
        case .findHost: "Find SSH host"
        case .connectHost: "Connect to host"
        case .openEditor: "Open remote editor"
        case .zoomPane: "Zoom or restore pane"
        case .floatPane: "Float or dock pane"
        case .balancePanes: "Balance pane layout"
        case .splitRight: "Split right"
        case .splitDown: "Split down"
        case .newFloatingPane: "New floating pane"
        case .previousPane: "Previous pane"
        case .nextPane: "Next pane"
        case .previousPrompt: "Previous prompt"
        case .nextPrompt: "Next prompt"
        case .closePane: "Close pane"
        case .reopenClosedPane: "Reopen closed pane"
        case .previousTab: "Previous tab"
        case .nextTab: "Next tab"
        case .toggleSidebar: "Show or hide navigator"
        case .agentActivity: "Show or hide agent activity"
        case .workspaceOverview: "All workspaces"
        case .workspaceBack: "Back in workspace"
        case .workspaceForward: "Forward in workspace"
        case .workspaceUp: "Parent workspace"
        case .stackPane: "Stack active pane with…"
        case .unstackPane: "Unstack active pane"
        case .previousStackPane: "Previous pane in stack"
        case .nextStackPane: "Next pane in stack"
        case .saveWorkspaceView: "Save current view"
        case .openWorkspaceView: "Open saved view"
        }
    }

    var section: String {
        switch self {
        case .newTab, .newLocalSession, .findHost, .quickNavigate, .fleetBoard, .connectHost: "Sessions"
        case .previousTab, .nextTab: "Tabs"
        case .openEditor, .zoomPane, .floatPane, .balancePanes, .splitRight,
             .splitDown, .newFloatingPane, .previousPane, .nextPane,
             .previousPrompt, .nextPrompt, .closePane, .reopenClosedPane: "Panes"
        case .toggleSidebar, .agentActivity: "Workspace"
        case .workspaceOverview, .workspaceBack, .workspaceForward, .workspaceUp,
             .saveWorkspaceView, .openWorkspaceView: "Workspace"
        case .stackPane, .unstackPane, .previousStackPane, .nextStackPane: "Panes"
        }
    }

    var defaultBinding: RelayKeyBinding {
        switch self {
        case .newTab: .init("t", command: true)
        case .newLocalSession: .init("n", command: true, option: true)
        case .quickNavigate: .init("p", command: true, shift: true)
        case .fleetBoard: .init("a", command: true, shift: true)
        case .findHost: .init("k", command: true)
        case .connectHost: .init("n", command: true, shift: true)
        case .openEditor: .init("e", command: true, shift: true)
        case .zoomPane: .init("return", command: true, shift: true)
        case .floatPane: .init("p", command: true, option: true)
        case .balancePanes: .init("=", command: true, option: true)
        case .splitRight: .init("d", command: true)
        case .splitDown: .init("d", command: true, shift: true)
        case .newFloatingPane: .init("f", command: true, option: true)
        case .previousPane: .init("[", command: true, option: true)
        case .nextPane: .init("]", command: true, option: true)
        case .previousPrompt: .init("up", command: true, shift: true)
        case .nextPrompt: .init("down", command: true, shift: true)
        case .closePane: .init("w", command: true)
        case .reopenClosedPane: .init("t", command: true, shift: true)
        case .previousTab: .init("[", command: true, shift: true)
        case .nextTab: .init("]", command: true, shift: true)
        case .toggleSidebar: .init("s", command: true, control: true)
        case .agentActivity: .init("i", command: true, option: true)
        case .workspaceOverview: .init("o", command: true, control: true)
        case .workspaceBack: .init("left", command: true, control: true)
        case .workspaceForward: .init("right", command: true, control: true)
        case .workspaceUp: .init("up", command: true, control: true)
        case .stackPane: .init("g", command: true, control: true)
        case .unstackPane: .init("u", command: true, control: true)
        case .previousStackPane: .init("[", command: true, control: true)
        case .nextStackPane: .init("]", command: true, control: true)
        case .saveWorkspaceView: .init("s", command: true, control: true, shift: true)
        case .openWorkspaceView: .init("o", command: true, control: true, shift: true)
        }
    }
}

struct RelayKeyBinding: Codable, Equatable, Hashable, Sendable {
    let key: String
    let command: Bool
    let control: Bool
    let option: Bool
    let shift: Bool

    init(
        _ key: String,
        command: Bool = false,
        control: Bool = false,
        option: Bool = false,
        shift: Bool = false
    ) {
        self.key = key.lowercased()
        self.command = command
        self.control = control
        self.option = option
        self.shift = shift
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        guard command || control || option else { return nil }

        let key: String
        switch event.keyCode {
        case 36, 76: key = "return"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        default:
            // charactersIgnoringModifiers still applies Shift, so recording
            // ⌘⇧] would store "}"+shift while the defaults are written with
            // the unshifted key ("]"+shift) — conflict detection would miss
            // duplicates and the stored shortcut would never match. Resolve
            // the physical key with no modifiers applied instead.
            let base = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
            guard let characters = base?.lowercased(),
                  characters.count == 1,
                  let character = characters.first,
                  !character.isWhitespace else { return nil }
            key = String(character)
        }
        self.init(key, command: command, control: control, option: option, shift: shift)
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "return": .return
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        default: KeyEquivalent(key.first ?? "?")
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if command { result.insert(.command) }
        if control { result.insert(.control) }
        if option { result.insert(.option) }
        if shift { result.insert(.shift) }
        return result
    }

    var displayName: String {
        var result = ""
        if control { result += "⌃" }
        if option { result += "⌥" }
        if shift { result += "⇧" }
        if command { result += "⌘" }
        let keyLabel = switch key {
        case "return": "↩"
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        default: key.uppercased()
        }
        result += keyLabel
        return result
    }
}

enum RelayKeyBindingStorage {
    static let defaultsKey = "relay.settings.key-bindings.v1"

    static func load(from defaults: UserDefaults = .standard) -> [String: RelayKeyBinding] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: RelayKeyBinding].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func save(_ bindings: [String: RelayKeyBinding], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func binding(for command: RelayCommand, overrides: [String: RelayKeyBinding]) -> RelayKeyBinding {
        overrides[command.rawValue] ?? command.defaultBinding
    }

    /// System chords Relay itself intercepts before its remappable commands:
    /// the app-delegate quit monitor and the pasteboard/undo CommandGroups.
    /// Recording one of these silently shadows the user's command, so the
    /// recorder must warn instead of saving a binding that never fires.
    static func reservedConflictName(for candidate: RelayKeyBinding) -> String? {
        let reserved: [(RelayKeyBinding, String)] = [
            (RelayKeyBinding("q", command: true), "Quit Relay"),
            (RelayKeyBinding("c", command: true), "Copy"),
            (RelayKeyBinding("v", command: true), "Paste"),
            (RelayKeyBinding("a", command: true), "Select All"),
            (RelayKeyBinding("z", command: true), "Undo"),
            (RelayKeyBinding("z", command: true, shift: true), "Redo"),
        ]
        return reserved.first { $0.0 == candidate }?.1
    }

    static func conflict(
        for candidate: RelayKeyBinding,
        command: RelayCommand,
        overrides: [String: RelayKeyBinding]
    ) -> RelayCommand? {
        // Command-W is intercepted before AppKit's Close Window command. Keep
        // that system-sensitive chord dedicated to Close Pane even when the
        // user temporarily assigns Close Pane another shortcut.
        if candidate == RelayCommand.closePane.defaultBinding, command != .closePane {
            return .closePane
        }
        return RelayCommand.allCases.first { other in
            other != command && binding(for: other, overrides: overrides) == candidate
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    static let relayWorkspaceWindow = NSUserInterfaceItemIdentifier("dev.relay.terminal.workspace")
}

struct RelayWorkspaceWindowMarker: NSViewRepresentable {
    final class MarkerView: NSView {
        private var configurationScheduled = false
        private weak var configuredWindow: NSWindow?

        func scheduleConfiguration() {
            guard window != nil, configuredWindow !== window, !configurationScheduled else { return }
            configurationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configurationScheduled = false
                guard let window = self.window, self.configuredWindow !== window else { return }
                self.configureWindow()
                self.configuredWindow = window
                NotificationCenter.default.post(name: .relayWorkspaceWindowConfigured, object: window)
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        func configureWindow() {
            guard let window else { return }
            window.identifier = .relayWorkspaceWindow
            RecoveryWindowRegistry.shared.register(window)
            RelayToolSurface.configure(window)
            // Full-size content includes terminals, editors, image previews,
            // floating panes, and resize handles. Treating all of it as window
            // background lets AppKit steal their drags. WorkspaceBar provides
            // the one explicit drag region for moving the macOS window.
            window.isMovableByWindowBackground = false
            // Use AppKit's real traffic lights. A custom SwiftUI control layer
            // across the workspace obscures native accessibility geometry and
            // can receive an activation click intended for terminal input.
            // Keep one control set with native roles, bounds and hit testing.
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = false
            }
        }
    }

    func makeNSView(context: Context) -> NSView { MarkerView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MarkerView)?.scheduleConfiguration()
    }
}

struct RelayWindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
