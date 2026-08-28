import AppKit
import Foundation
import SwiftUI

enum RelayCommand: String, CaseIterable, Identifiable, Codable, Sendable {
    case newTab
    case newLocalSession
    case findHost
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
    case previousTab
    case nextTab
    case toggleSidebar
    case agentActivity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newTab: "New tab in session"
        case .newLocalSession: "New local session"
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
        case .previousTab: "Previous tab"
        case .nextTab: "Next tab"
        case .toggleSidebar: "Show or hide navigator"
        case .agentActivity: "Show or hide agent activity"
        }
    }

    var section: String {
        switch self {
        case .newTab, .newLocalSession, .findHost, .connectHost: "Sessions"
        case .previousTab, .nextTab: "Tabs"
        case .openEditor, .zoomPane, .floatPane, .balancePanes, .splitRight,
             .splitDown, .newFloatingPane, .previousPane, .nextPane,
             .previousPrompt, .nextPrompt, .closePane: "Panes"
        case .toggleSidebar, .agentActivity: "Workspace"
        }
    }

    var defaultBinding: RelayKeyBinding {
        switch self {
        case .newTab: .init("t", command: true)
        case .newLocalSession: .init("t", command: true, shift: true)
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
        case .previousTab: .init("[", command: true, shift: true)
        case .nextTab: .init("]", command: true, shift: true)
        case .toggleSidebar: .init("s", command: true, control: true)
        case .agentActivity: .init("i", command: true, option: true)
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
            guard let characters = event.charactersIgnoringModifiers?.lowercased(),
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.identifier = .relayWorkspaceWindow
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            // Relay draws stable, high-contrast controls inside its unified
            // title bar. The native buttons become nearly black under
            // hiddenTitleBar + dark appearance and remain in the hit-testing
            // path even when visually absent, so remove that duplicate set.
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
        }
    }

    func makeNSView(context: Context) -> NSView { MarkerView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MarkerView)?.configureWindow()
    }
}
