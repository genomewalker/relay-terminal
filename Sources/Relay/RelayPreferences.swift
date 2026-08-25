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
}

enum RelayArtifactPresentation: String, CaseIterable, Identifiable {
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

    private let defaults = UserDefaults.standard
    private var isLoading = true

    private init() {
        fontFamily = defaults.string(forKey: "relay.settings.font-family") ?? "Berkeley Mono"
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
        ) ?? .inline
        isLoading = false
    }

    func terminalConfiguration() -> TerminalConfiguration {
        let family = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFamily = family.isEmpty ? "Menlo" : family
        return TerminalConfiguration(startingFrom: .default) { builder in
            builder.withFontFamily(resolvedFamily)
            builder.withFontSize(Float(min(max(fontSize, 9), 32)))
            builder.withBackground(palette.background)
            builder.withForeground(palette.foreground)
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
    }
}
