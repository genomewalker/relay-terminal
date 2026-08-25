import SwiftUI

enum RelayTheme {
    // The application chrome is deliberately independent from the terminal
    // palette. A terminal theme should not recolor navigation and controls.
    static let canvas = Color(hex: 0x212121)
    static let sidebar = Color(hex: 0x171717)
    static let surface = Color(hex: 0x2F2F2F)
    static let elevated = Color(hex: 0x353535)
    static let hover = Color(hex: 0x2A2A2A)
    static let line = Color(hex: 0x3D3D3D)
    static let accent = Color(hex: 0x2FC6A0)
    static let accentDim = Color(hex: 0x173D35)
    // Retain the old names while view code migrates to semantic tokens.
    static let blue = accent
    static let blueDim = accentDim
    static let mint = Color(hex: 0x66CDAA)
    static let coral = Color(hex: 0xE68B82)
    static let red = Color(hex: 0xD86F68)
    static let text = Color(hex: 0xECECEC)
    static let textMuted = Color(hex: 0xB4B4B4)
    // Small metadata text uses this token extensively. #9D9D9D remains above
    // 4.5:1 even on the elevated #353535 surface.
    static let textFaint = Color(hex: 0x9D9D9D)
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
