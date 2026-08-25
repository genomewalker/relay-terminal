import SwiftUI

enum RelayTheme {
    private static var palette: RelayTerminalPalette {
        RelayTerminalPalette(rawValue: UserDefaults.standard.string(forKey: "relay.settings.palette") ?? "") ?? .midnight
    }

    static var canvas: Color { Color(hex: palette == .graphite ? 0x111214 : palette == .oled ? 0x000000 : 0x080C13) }
    static var sidebar: Color { Color(hex: palette == .graphite ? 0x191B1F : palette == .oled ? 0x080808 : 0x0E141E) }
    static var surface: Color { Color(hex: palette == .graphite ? 0x22252A : palette == .oled ? 0x101010 : 0x141C29) }
    static var elevated: Color { Color(hex: palette == .graphite ? 0x2B2F35 : palette == .oled ? 0x181818 : 0x1C2737) }
    static var hover: Color { Color(hex: palette == .graphite ? 0x343941 : palette == .oled ? 0x222222 : 0x243247) }
    static var line: Color { Color(hex: palette == .graphite ? 0x3A3F47 : palette == .oled ? 0x2A2A2A : 0x28364A) }
    static var blue: Color { Color(hex: palette == .graphite ? 0xA8B4C8 : 0x7C9CFF) }
    static var blueDim: Color { Color(hex: palette == .graphite ? 0x303740 : palette == .oled ? 0x16233D : 0x24385F) }
    static let mint = Color(hex: 0x59D6A5)
    static let coral = Color(hex: 0xFF766D)
    static let red = Color(hex: 0xE66767)
    static let text = Color(hex: 0xE8EEF9)
    static let textMuted = Color(hex: 0x8998AE)
    static let textFaint = Color(hex: 0x5E6B7D)
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
