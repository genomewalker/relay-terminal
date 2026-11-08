import AppKit
import SwiftUI

/// Chrome colours as AppKit colours. Under a dark appearance every colour is
/// Relay's own value; a light appearance uses the matching system colour.
enum RelayPalette {
    static let canvas = dynamic(dark: 0x171717, light: .windowBackgroundColor)
    static let sidebar = dynamic(dark: 0x1B1B1B, light: .underPageBackgroundColor)
    static let surface = dynamic(dark: 0x222222, light: .controlBackgroundColor)
    static let elevated = dynamic(dark: 0x2A2A2A, light: .textBackgroundColor)
    static let text = dynamic(dark: 0xEBEBEB, light: .labelColor)
    static let textMuted = dynamic(dark: 0xAAAAAA, light: .secondaryLabelColor)
    static let textFaint = dynamic(dark: 0x969696, light: .tertiaryLabelColor)
    static let accent = dynamic(dark: 0x8DB7EB, light: .controlAccentColor)
    static let coral = dynamic(dark: 0xDDA398, light: .systemOrange)
    static let red = dynamic(dark: 0xDE827B, light: .systemRed)
    /// Success/connected state; the side panel's Relay green.
    static let success = dynamic(dark: 0x73C7A5, light: .systemGreen)

    static func dynamic(dark: UInt32, light: NSColor) -> NSColor {
        let dark = hex(dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

enum RelayTheme {
    // The application chrome is deliberately independent from the terminal
    // palette. A terminal theme should not recolor navigation and controls.
    // App-wide template. Edit these values to restyle every Relay surface.
    static let colorScheme: ColorScheme = .dark
    static let appearanceName: NSAppearance.Name = .darkAqua
    static let canvas = Color(nsColor: RelayPalette.canvas)
    /// Behind terminals, which keep their dark background in any appearance.
    static let terminalCanvas = Color(hex: 0x171717)
    static let sidebar = Color(nsColor: RelayPalette.sidebar)
    static let surface = Color(nsColor: RelayPalette.surface)
    static let elevated = Color(nsColor: RelayPalette.elevated)
    static let text = Color(nsColor: RelayPalette.text)
    static let textMuted = Color(nsColor: RelayPalette.textMuted)
    static let textFaint = Color(nsColor: RelayPalette.textFaint)
    static let stroke = text.opacity(0.07)
    static let line = stroke
    static let wash = text.opacity(0.08)
    static let bubble = text.opacity(0.10)
    static let hover = text.opacity(0.15)
    static let codeFill = text.opacity(0.05)
    static let composerFill = text.opacity(0.03)
    static let accent = Color(nsColor: RelayPalette.accent)
    static let accentDim = surface
    static let blue = accent
    static let blueDim = accentDim
    static let mint = accent
    static let coral = Color(nsColor: RelayPalette.coral)
    static let red = Color(nsColor: RelayPalette.red)
    static let success = Color(nsColor: RelayPalette.success)

    /// Spacing tokens: the 2/4/6/8/12/16/24 set the app already uses, scaled by `spacingScale`.
    enum Space {
        static let scale: [CGFloat] = [2, 4, 6, 8, 12, 16, 24]
        static var xxs: CGFloat { spacing(2) }
        static var xs: CGFloat { spacing(4) }
        static var sm: CGFloat { spacing(6) }
        static var md: CGFloat { spacing(8) }
        static var lg: CGFloat { spacing(12) }
        static var xl: CGFloat { spacing(16) }
        static var xxl: CGFloat { spacing(24) }
    }

    /// Control geometry: standard controls are 28 pt; compact icon buttons in dense rows are 22 pt.
    enum Control {
        static let height: CGFloat = 28
        static let compactIcon: CGFloat = 22
    }

    /// Smallest text Relay draws; badges and micro labels use exactly this size.
    static let minimumTextSize: CGFloat = 10

    /// Text roles mapped from today's dominant sizes. None is below `minimumTextSize`.
    enum TextRole: CaseIterable {
        case title, heading, body, label, callout, caption, micro, code, codeSmall

        var size: CGFloat {
            switch self {
            case .title: 17
            case .heading: 14
            case .body: 13
            case .label, .code: 12
            case .callout: 11.5
            case .caption, .codeSmall: 11
            case .micro: RelayTheme.minimumTextSize
            }
        }

        var weight: Font.Weight {
            switch self {
            case .title, .heading, .label: .medium
            default: .regular
            }
        }

        var design: Font.Design {
            switch self {
            case .code, .codeSmall: .monospaced
            default: .default
            }
        }

        var font: Font { RelayTheme.font(size: size, weight: weight, design: design) }
    }

    static let typeScale: CGFloat = 1
    static let spacingScale: CGFloat = 1
    static let cornerScale: CGFloat = 1
    static let contentWidth: CGFloat = 760
    static let gutter: CGFloat = 20
    static let controlSize: ControlSize = .small
    static func font(size: CGFloat, weight: Font.Weight = .regular,
                     design: Font.Design = .default) -> Font {
        .system(size: size * typeScale, weight: weight, design: design)
    }
    static func font(_ style: Font.TextStyle, design: Font.Design = .default) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 26
        case .title: size = 22
        case .title2: size = 17
        case .title3: size = 15
        case .caption, .caption2: size = 11
        case .footnote: size = 12
        default: size = 13
        }
        return font(size: size, weight: style == .headline ? .semibold : .regular, design: design)
    }

    @MainActor static func alert() -> NSAlert {
        let alert = NSAlert(); configureAppearance(alert.window); return alert
    }
    @MainActor static func alert(error: Error) -> NSAlert {
        let alert = NSAlert(error: error); configureAppearance(alert.window); return alert
    }
    @MainActor static func openPanel() -> NSOpenPanel {
        let panel = NSOpenPanel(); configureAppearance(panel); return panel
    }
    @MainActor static func savePanel() -> NSSavePanel {
        let panel = NSSavePanel(); configureAppearance(panel); return panel
    }
    static func spacing(_ value: CGFloat) -> CGFloat { value * spacingScale }
    static func cornerRadius(_ value: CGFloat) -> CGFloat { value * cornerScale }
    static let body = font(size: 13)
    static let label = font(size: 12, weight: .medium)
    static let caption = font(size: 11)
    static let code = font(size: 12, design: .monospaced)

    // Visual configuration only. Sheets and panels retain native roles, focus,
    // modal behavior and traffic-light policy.
    @MainActor static func configureAppearance(_ window: NSWindow) {
        let background = RelayPalette.canvas
        if window.backgroundColor != background { window.backgroundColor = background }
        if window.appearance?.name != appearanceName { window.appearance = NSAppearance(named: appearanceName) }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
    }

}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

/// Use on every presentation root; descendants and sheets inherit the template.
struct RelaySurfaceStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(RelayTheme.body)
            .foregroundStyle(RelayTheme.text)
            .tint(RelayTheme.accent)
            .controlSize(RelayTheme.controlSize)
            .preferredColorScheme(RelayTheme.colorScheme)
            .background(RelayTheme.canvas)
            .background(RelaySurfaceAppearanceMarker().frame(width: 0, height: 0))
    }
}

extension View {
    func relaySurface() -> some View { modifier(RelaySurfaceStyle()) }
}

private struct RelaySurfaceAppearanceMarker: NSViewRepresentable {
    final class Marker: NSView {
        private weak var configuredWindow: NSWindow?
        private var scheduled = false
        func schedule() {
            guard window != nil, configuredWindow !== window, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard let window = self.window, self.configuredWindow !== window else { return }
                RelayTheme.configureAppearance(window)
                self.configuredWindow = window
            }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
    }
    func makeNSView(context: Context) -> NSView { Marker(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Marker)?.schedule() }
}

/// Solid primary action, matching the composer submit treatment.
struct RelayPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let ink: Color = scheme == .dark ? .white : .black
        let paper: Color = scheme == .dark ? .black : .white
        configuration.label
            .font(RelayTheme.font(size: 12, weight: .medium))
            .padding(.horizontal, RelayTheme.spacing(10)).frame(height: 26)
            .foregroundStyle(enabled ? paper : paper.opacity(0.6))
            .background(ink.opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.28),
                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet text button used for secondary actions such as Copy or Show more.
struct RelayQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RelayTheme.caption)
            .foregroundStyle(configuration.isPressed ? Color.primary : RelayTheme.textMuted)
            .padding(.horizontal, RelayTheme.spacing(6)).frame(height: 22)
            .background(configuration.isPressed ? RelayTheme.wash : .clear,
                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(5)))
            .contentShape(Rectangle())
    }
}


struct RelaySecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(RelayTheme.label)
            .padding(.horizontal, RelayTheme.spacing(10)).frame(minHeight: 26)
            .foregroundStyle(RelayTheme.text.opacity(enabled ? 1 : 0.45))
            .background(configuration.isPressed ? RelayTheme.wash : RelayTheme.surface,
                        in: RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)))
            .overlay(RoundedRectangle(cornerRadius: RelayTheme.cornerRadius(6)).strokeBorder(RelayTheme.stroke))
    }
}
