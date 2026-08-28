import AppKit
import Foundation
import GhosttyTerminal

enum RelayTerminalPalette: String, CaseIterable, Identifiable {
    case midnight
    case graphite
    case oled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .midnight: "Midnight"
        case .graphite: "Graphite"
        case .oled: "OLED Black"
        }
    }

    var background: String {
        switch self {
        case .midnight: "0B1018"
        case .graphite: "17191D"
        case .oled: "000000"
        }
    }

    var foreground: String {
        switch self {
        case .midnight: "E8EEF9"
        case .graphite: "E6E6E6"
        case .oled: "F2F2F2"
        }
    }

    var cursor: String {
        switch self {
        case .midnight: "7C9CFF"
        case .graphite: "A8B4C8"
        case .oled: "75A7FF"
        }
    }

    var selectionBackground: String {
        switch self {
        case .midnight: "315A78"
        case .graphite: "4A5A70"
        case .oled: "285B53"
        }
    }

    var selectionForeground: String { "FFFFFF" }
}

enum RelayArtifactPresentation: String, CaseIterable, Identifiable, Sendable {
    case inline
    case preview

    var id: String { rawValue }
    var label: String { self == .inline ? "Inline" : "Floating" }
}

@MainActor
final class RelayPreferences: ObservableObject {
    static let shared = RelayPreferences()

    @Published var fontFamily: String { didSet { saveAndApply() } }
    @Published var fontSize: Double { didSet { saveAndApply() } }
    @Published var terminalPadding: Double { didSet { saveAndApply() } }
    @Published var cursorBlink: Bool { didSet { saveAndApply() } }
    @Published var palette: RelayTerminalPalette { didSet { saveAndApply() } }
    @Published var compactInterface: Bool { didSet { save() } }
    @Published var hideSidebarInFullScreen: Bool { didSet { save() } }
    @Published var showArtifactPreviews: Bool { didSet { save() } }
    @Published var artifactPresentation: RelayArtifactPresentation { didSet { save() } }
    @Published var intelligenceEnabled: Bool { didSet { save() } }
    @Published var predictiveSuggestions: Bool { didSet { save() } }
    @Published var experimentalGenerativeSuggestions: Bool { didSet { save() } }
    @Published var automaticAgentSummaries: Bool { didSet { save() } }
    @Published var semanticAgentSearch: Bool { didSet { save() } }
    @Published var automaticallyUpdateRelayd: Bool { didSet { save() } }
    @Published private(set) var keyBindings: [String: RelayKeyBinding] { didSet { save() } }

    private let defaults = UserDefaults.standard
    private var isLoading = true

    private init() {
        fontFamily = defaults.string(forKey: "relay.settings.font-family") ?? "Menlo"
        let storedSize = defaults.double(forKey: "relay.settings.font-size")
        fontSize = storedSize == 0 ? 13.5 : storedSize
        let storedPadding = defaults.double(forKey: "relay.settings.terminal-padding")
        terminalPadding = storedPadding == 0 ? 9 : storedPadding
        cursorBlink = defaults.object(forKey: "relay.settings.cursor-blink") as? Bool ?? false
        palette = RelayTerminalPalette(rawValue: defaults.string(forKey: "relay.settings.palette") ?? "") ?? .midnight
        compactInterface = defaults.object(forKey: "relay.settings.compact-interface") as? Bool ?? true
        hideSidebarInFullScreen = defaults.object(forKey: "relay.settings.hide-sidebar-fullscreen") as? Bool ?? true
        showArtifactPreviews = defaults.object(forKey: "relay.settings.artifact-previews") as? Bool ?? true
        artifactPresentation = RelayArtifactPresentation(
            rawValue: defaults.string(forKey: "relay.settings.artifact-presentation") ?? ""
        ) ?? .preview
        intelligenceEnabled = defaults.object(forKey: "relay.settings.intelligence-enabled") as? Bool ?? true
        predictiveSuggestions = defaults.object(forKey: "relay.settings.predictive-suggestions") as? Bool ?? true
        experimentalGenerativeSuggestions = defaults.object(
            forKey: "relay.settings.experimental-generative-suggestions"
        ) as? Bool ?? false
        automaticAgentSummaries = defaults.object(forKey: "relay.settings.intelligence-summaries") as? Bool ?? true
        semanticAgentSearch = defaults.object(forKey: "relay.settings.intelligence-search") as? Bool ?? true
        automaticallyUpdateRelayd = defaults.object(forKey: "relay.settings.relayd-auto-update") as? Bool ?? false
        keyBindings = RelayKeyBindingStorage.load(from: defaults)
        isLoading = false
    }

    func keyBinding(for command: RelayCommand) -> RelayKeyBinding {
        RelayKeyBindingStorage.binding(for: command, overrides: keyBindings)
    }

    @discardableResult
    func setKeyBinding(_ binding: RelayKeyBinding, for command: RelayCommand) -> RelayCommand? {
        if let conflict = RelayKeyBindingStorage.conflict(
            for: binding, command: command, overrides: keyBindings
        ) {
            return conflict
        }
        keyBindings[command.rawValue] = binding
        return nil
    }

    func resetKeyBinding(_ command: RelayCommand) {
        keyBindings.removeValue(forKey: command.rawValue)
    }

    func resetAllKeyBindings() {
        keyBindings.removeAll()
    }

    func terminalConfiguration() -> TerminalConfiguration {
        let resolvedFamily = resolvedFontFamily
        return TerminalConfiguration(startingFrom: .default) { builder in
            builder.withFontFamily(resolvedFamily)
            let normalizedFontSize = String(
                format: "%.1f",
                locale: Locale(identifier: "en_US_POSIX"),
                min(max(fontSize, 9), 32)
            )
            // Ghostty's typed numeric builder currently honors the process
            // locale and can emit `13,5` on Danish systems. Its config parser
            // requires a period regardless of locale.
            builder.withCustom("font-size", normalizedFontSize)
            builder.withBackground(palette.background)
            builder.withForeground(palette.foreground)
            // Never inherit an application's reverse-video colors for local
            // selection. Codex and Claude often leave a dark TUI background,
            // which previously produced black-on-dark selected text.
            builder.withSelectionBackground(palette.selectionBackground)
            builder.withSelectionForeground(palette.selectionForeground)
            // Relay reads the local selection to implement prompt editing.
            // Keep it painted after that internal copy; normal typing still
            // clears it through Ghostty's default selection-clear-on-typing.
            builder.withCustom("selection-clear-on-copy", "false")
            builder.withCustom("minimum-contrast", "2.2")
            builder.withBackgroundOpacity(1)
            builder.withCursorColor(palette.cursor)
            builder.withCursorStyle(.bar)
            // A blinking caret wakes every visible terminal even when the
            // session is otherwise completely idle. Keep the low-energy
            // solid caret as the default; users can opt into blinking.
            builder.withCursorStyleBlink(cursorBlink)
            let padding = Int(min(max(terminalPadding.rounded(), 0), 32))
            builder.withWindowPaddingX(padding)
            builder.withWindowPaddingY(padding)
            builder.withCustom("copy-on-select", "clipboard")
            builder.withCustom("mouse-hide-while-typing", "true")
            // Ghostty uses OSC 133 prompt boundaries to translate a click in
            // an editable command line into the application's native cursor
            // movement. relayd emits those boundaries for remote shells.
            builder.withCustom("cursor-click-to-move", "true")
        }
    }

    var resolvedFontFamily: String {
        let requested = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return "Menlo" }
        return NSFontManager.shared.availableFontFamilies.contains {
            $0.caseInsensitiveCompare(requested) == .orderedSame
        } ? requested : "Menlo"
    }

    var isUsingFontFallback: Bool {
        let requested = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        return !requested.isEmpty && requested.caseInsensitiveCompare(resolvedFontFamily) != .orderedSame
    }

    private func saveAndApply() {
        guard !isLoading else { return }
        save()
        TerminalRuntime.applyPreferences(self)
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(fontFamily, forKey: "relay.settings.font-family")
        defaults.set(fontSize, forKey: "relay.settings.font-size")
        defaults.set(terminalPadding, forKey: "relay.settings.terminal-padding")
        defaults.set(cursorBlink, forKey: "relay.settings.cursor-blink")
        defaults.set(palette.rawValue, forKey: "relay.settings.palette")
        defaults.set(compactInterface, forKey: "relay.settings.compact-interface")
        defaults.set(hideSidebarInFullScreen, forKey: "relay.settings.hide-sidebar-fullscreen")
        defaults.set(showArtifactPreviews, forKey: "relay.settings.artifact-previews")
        defaults.set(artifactPresentation.rawValue, forKey: "relay.settings.artifact-presentation")
        defaults.set(intelligenceEnabled, forKey: "relay.settings.intelligence-enabled")
        defaults.set(predictiveSuggestions, forKey: "relay.settings.predictive-suggestions")
        defaults.set(
            experimentalGenerativeSuggestions,
            forKey: "relay.settings.experimental-generative-suggestions"
        )
        defaults.set(automaticAgentSummaries, forKey: "relay.settings.intelligence-summaries")
        defaults.set(semanticAgentSearch, forKey: "relay.settings.intelligence-search")
        defaults.set(automaticallyUpdateRelayd, forKey: "relay.settings.relayd-auto-update")
        RelayKeyBindingStorage.save(keyBindings, to: defaults)
    }
}
