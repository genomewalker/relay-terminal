import AppKit
import SwiftUI
import Testing
@testable import Relay

@MainActor @Suite("Relay theme colours and appearance")
struct RelayThemeTests {
    private func components(_ color: NSColor, in name: NSAppearance.Name) throws -> [CGFloat] {
        var resolved: NSColor?
        let appearance = try #require(NSAppearance(named: name))
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let sRGB = try #require(resolved)
        return [sRGB.redComponent, sRGB.greenComponent, sRGB.blueComponent, sRGB.alphaComponent]
    }

    private func close(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) < 0.004 }
    }

    @Test func relayPaletteMatchesTodaysDarkAndAdaptsToLight() throws {
        let canvasDark = try components(RelayPalette.canvas, in: .darkAqua)
        let today: CGFloat = 0x17 / 255
        #expect(close(canvasDark, [today, today, today, 1]))
        #expect(try !close(canvasDark, components(RelayPalette.canvas, in: .aqua)))
        #expect(try !close(components(RelayPalette.text, in: .darkAqua), components(RelayPalette.text, in: .aqua)))

        // Terminals keep their dark background in either appearance.
        let terminal = NSColor(RelayTheme.terminalCanvas)
        let terminalDark = try components(terminal, in: .darkAqua)
        #expect(close(terminalDark, canvasDark))
        #expect(try close(terminalDark, components(terminal, in: .aqua)))
    }

    @Test(arguments: [
        ("sidebar", RelayPalette.sidebar, 0x1B1B1B as UInt32),
        ("text", RelayPalette.text, 0xEBEBEB),
        ("textMuted", RelayPalette.textMuted, 0xAAAAAA),
        ("textFaint", RelayPalette.textFaint, 0x969696),
        ("accent", RelayPalette.accent, 0x8DB7EB),
    ])
    func darkPaletteKeepsRelaysOwnColours(name: String, color: NSColor, hex: UInt32) throws {
        let channel = { (shift: UInt32) in CGFloat((hex >> shift) & 0xff) / 255 }
        #expect(try close(components(color, in: .darkAqua), [channel(16), channel(8), channel(0), 1]), "\(name)")
    }

    @Test func successIsRelayGreenInDarkAndSystemGreenInLight() throws {
        let dark = try components(RelayPalette.success, in: .darkAqua)
        let green: [CGFloat] = [0x73, 0xC7, 0xA5].map { CGFloat($0) / 255 } + [1]
        #expect(close(dark, green))
        #expect(try close(components(RelayPalette.success, in: .aqua),
                          components(NSColor.systemGreen, in: .aqua)))
        // Success must be distinguishable from the accent it used to share.
        #expect(try !close(dark, components(RelayPalette.accent, in: .darkAqua)))
        #expect(try close(components(NSColor(RelayTheme.success), in: .darkAqua), dark))
    }

    @Test func spacingScaleIsTheCodifiedSet() {
        typealias S = RelayTheme.Space
        let expected: [CGFloat] = [2, 4, 6, 8, 12, 16, 24]
        let named: [CGFloat] = [S.xxs, S.xs, S.sm, S.md, S.lg, S.xl, S.xxl]
        let scaled: [CGFloat] = expected.map { RelayTheme.spacing($0) }
        #expect(S.scale == expected)
        #expect(named == scaled)
    }

    @Test func controlsAre28PointWithCompact22PointIcons() {
        #expect(RelayTheme.Control.height == 28)
        #expect(RelayTheme.Control.compactIcon == 22)
    }

    @Test func noTextRoleIsBelowTheTenPointFloor() {
        #expect(RelayTheme.minimumTextSize == 10)
        #expect(RelayTheme.TextRole.micro.size == RelayTheme.minimumTextSize)
        for role in RelayTheme.TextRole.allCases {
            #expect(role.size >= RelayTheme.minimumTextSize, "\(role)")
            #expect(role.renderedSize >= RelayTheme.minimumTextSize, "\(role)")
        }
        // Roles keep today's dominant sizes so later migrations stay 1:1.
        #expect(RelayTheme.TextRole.body.size == 13)
        #expect(RelayTheme.TextRole.label.size == 12)
        #expect(RelayTheme.TextRole.caption.size == 11)
    }

    /// Relay follows the system appearance: configuring a window keeps its
    /// appearance (previously this forced darkAqua; see RelayLightModeTests).
    @Test func relayWindowsFollowTheSystemAppearance() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        RelayTheme.configureAppearance(window)
        #expect(window.appearance?.name == .aqua)
        window.appearance = nil
        RelayTheme.configureAppearance(window)
        #expect(window.appearance == nil)
    }
}
