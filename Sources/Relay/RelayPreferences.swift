import CoreText
import Foundation
import GhosttyTerminal

enum RelayShellIntegrationPolicy {
    private static let supportedShells: Set<String> = [
        "bash", "elvish", "fish", "nu", "nushell", "zsh",
    ]

    static func configurationValue(shellPath: String?) -> String {
        guard let shellPath else { return "detect" }
        let name = URL(fileURLWithPath: shellPath).lastPathComponent.lowercased()
        guard supportedShells.contains(name) else { return "detect" }
        return name == "nu" ? "nushell" : name
    }
}

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

enum RelayIntelligencePreferencePolicy {
    static let optInRevision = 1

    static func enabled(storedValue: Bool?, storedRevision: Int) -> Bool {
        guard storedRevision >= optInRevision else { return false }
        return storedValue ?? false
    }
}

@MainActor
final class RelayPreferences: ObservableObject {
    static let shared = RelayPreferences()

    private static let availableFontFamilies: Set<String> = {
        let families = CTFontManagerCopyAvailableFontFamilyNames() as NSArray
        return Set(families.compactMap { ($0 as? String)?.lowercased() })
    }()

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
    @Published var decisionModelPath: String { didSet { save() } }
    @Published var decisionModelSHA256: String { didSet { save() } }
    @Published var automaticAgentSummaries: Bool { didSet { save() } }
    @Published var semanticAgentSearch: Bool { didSet { save() } }
    @Published var automaticallyUpdateRelayd: Bool { didSet { save() } }
    @Published private(set) var keyBindings: [String: RelayKeyBinding] { didSet { save() } }

    private let defaults = RelayStateProfile.defaults
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
        let intelligenceRevision = defaults.integer(forKey: "relay.settings.intelligence-opt-in-revision")
        decisionModelPath = defaults.string(forKey: "relay.settings.decision-model-path") ?? ""
        decisionModelSHA256 = defaults.string(forKey: "relay.settings.decision-model-sha256") ?? ""
        intelligenceEnabled = RelayIntelligencePreferencePolicy.enabled(
            storedValue: defaults.object(forKey: "relay.settings.intelligence-enabled") as? Bool,
            storedRevision: intelligenceRevision
        )
        automaticAgentSummaries = RelayIntelligencePreferencePolicy.enabled(
            storedValue: defaults.object(forKey: "relay.settings.intelligence-summaries") as? Bool,
            storedRevision: intelligenceRevision
        )
        semanticAgentSearch = RelayIntelligencePreferencePolicy.enabled(
            storedValue: defaults.object(forKey: "relay.settings.intelligence-search") as? Bool,
            storedRevision: intelligenceRevision
        )
        automaticallyUpdateRelayd = defaults.object(forKey: "relay.settings.relayd-auto-update") as? Bool ?? false
        keyBindings = RelayKeyBindingStorage.load(from: defaults)
        isLoading = false
        // Remove stale completion preferences left by older builds.
        defaults.removeObject(forKey: "relay.settings.predictive-suggestions")
        defaults.removeObject(forKey: "relay.settings.experimental-generative-suggestions")
        if intelligenceRevision < RelayIntelligencePreferencePolicy.optInRevision {
            // Foundation Models work must be a deliberate opt-in. Earlier
            // builds enabled it implicitly, which could create local model
            // sessions while the user was typing in a busy terminal.
            defaults.set(false, forKey: "relay.settings.intelligence-enabled")
            defaults.set(false, forKey: "relay.settings.intelligence-summaries")
            defaults.set(false, forKey: "relay.settings.intelligence-search")
            defaults.set(
                RelayIntelligencePreferencePolicy.optInRevision,
                forKey: "relay.settings.intelligence-opt-in-revision"
            )
        }
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

    /// Called only after the complete map passed RelaySettingsPolicy validation.
    func replaceValidatedKeyBindings(_ bindings: [String: RelayKeyBinding]) {
        keyBindings = bindings
    }

    func resetAllKeyBindings() {
        keyBindings.removeAll()
    }

    func terminalConfiguration() -> TerminalConfiguration {
        let resolvedFamily = resolvedFontFamily
        // Preserve the existing ANSI palette while applying Relay's explicit
        // colors last, without a controller theme overriding them afterward.
        return TerminalConfiguration(startingFrom: TerminalConfiguration(startingFrom: .default) { builder in
            let colors = ["151515", "AC4142", "7E8E50", "E4B567", "6C99BB", "9F4E86", "7DD5CF", "D0D0D0", "505050", "AC4142", "7E8E50", "E4B567", "6C99BB", "9F4E86", "7DD5CF", "F5F5F5"]
            for (index, color) in colors.enumerated() {
                builder.withPalette(index, color: "#" + color)
            }
        }) { builder in
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
            // Keep the highlight after an explicit copy. Relay replays local
            // drags with Shift held so Ghostty selects under TUI mouse
            // reporting, and a retained selection would make that Shift+press
            // extend from the old anchor — so the runtime resets the selection
            // (libghostty resetSelection) right before replaying a new drag.
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
            // Prompt editing converts IME positions back to grid cells using
            // this explicit padding; surplus pixels stay at the trailing edge.
            builder.withCustom("window-padding-balance", "false")
            // Never let pointer gestures write the system clipboard: Ghostty
            // re-copies a retained selection on every left-button release, so
            // a misclassified click clobbered whatever the user was about to
            // paste. Copy is explicit (Cmd+C / Edit menu) in Relay.
            builder.withCustom("copy-on-select", "false")
            builder.withCustom("mouse-hide-while-typing", "true")
            // libghostty's macOS exec backend starts login shells through
            // /usr/bin/login. Auto-detection therefore sees `login` instead of
            // the user's real shell and skips OSC 133 injection. Force the
            // supported shell selected by $SHELL; unknown shells retain
            // Ghostty's normal detection path.
            builder.withCustom(
                "shell-integration",
                RelayShellIntegrationPolicy.configurationValue(
                    shellPath: ProcessInfo.processInfo.environment["SHELL"]
                )
            )
            // Embedded host-managed Ghostty surfaces recognize this option but
            // do not emit the movement sequence. Relay supplies the adapter for
            // semantic shell prompts only; alternate-screen TUIs receive their
            // real mouse events and are never moved with guessed arrow keys.
            builder.withCustom("cursor-click-to-move", "false")
        }
    }

    var resolvedFontFamily: String {
        let requested = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return "Menlo" }
        return Self.availableFontFamilies.contains(requested.lowercased()) ? requested : "Menlo"
    }

    var isUsingFontFallback: Bool {
        let requested = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        return !requested.isEmpty && requested.caseInsensitiveCompare(resolvedFontFamily) != .orderedSame
    }

    private func saveAndApply() {
        guard !isLoading else { return }
        save()
        if !RelayLaunchMode.isRunningTests {
            TerminalRuntime.applyPreferences(self)
        }
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
        defaults.set(decisionModelPath, forKey: "relay.settings.decision-model-path")
        defaults.set(decisionModelSHA256, forKey: "relay.settings.decision-model-sha256")
        defaults.set(automaticAgentSummaries, forKey: "relay.settings.intelligence-summaries")
        defaults.set(semanticAgentSearch, forKey: "relay.settings.intelligence-search")
        defaults.set(automaticallyUpdateRelayd, forKey: "relay.settings.relayd-auto-update")
        RelayKeyBindingStorage.save(keyBindings, to: defaults)
    }
}
