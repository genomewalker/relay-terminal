import AppKit
import SwiftUI
import Testing
@testable import Relay

@MainActor @Suite("Relay template tokens and shared components")
struct RelayComponentTests {
    private func rgba(_ color: NSColor, in name: NSAppearance.Name) throws -> [CGFloat] {
        var resolved: NSColor?
        try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let c = try #require(resolved)
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    private func same(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) < 0.004 } }

    private func hex(_ value: UInt32) -> [CGFloat] {
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        return [r, g, b, 1]
    }

    @Test func statusRolesUseRelayDarkValuesAndSystemLightFallbacks() throws {
        let cases: [(NSColor, UInt32, NSColor)] = [
            (RelayPalette.warning, 0xDDA398, .systemOrange),
            (RelayPalette.danger, 0xDE827B, .systemRed),
            (RelayPalette.info, 0x8DB7EB, .controlAccentColor),
        ]
        for (color, dark, light) in cases {
            #expect(try same(rgba(color, in: .darkAqua), hex(dark)))
            #expect(try same(rgba(color, in: .aqua), rgba(light, in: .aqua)))
        }
    }

    @Test func everyStatusRoleHasAColourAndASymbol() {
        let symbols = RelayTheme.StatusRole.allCases.map(\.symbol)
        #expect(symbols.allSatisfy { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
        // Colour is never the only signal: each role has its own symbol.
        #expect(Set(symbols).count == symbols.count)
        // Assistive technology hears the role too.
        #expect(RelayTheme.StatusRole.warning.spoken("dandy-07 is reconnecting") == "Warning: dandy-07 is reconnecting")
        #expect(RelayTheme.StatusRole.danger.spoken("Update failed") == "Error: Update failed")
        #expect(RelayTheme.StatusRole.neutral.spoken("Idle") == "Idle")
        for role in RelayTheme.StatusRole.allCases where role != .neutral {
            #expect(role.spokenName != nil, "\(role)")
        }
    }

    @Test func radiiAndMotionTokens() {
        typealias R = RelayTheme.Radius
        let radii: [CGFloat] = [R.pane, R.control, R.card, R.panel]
        #expect(radii == [2, 6, 8, 12].map { RelayTheme.cornerRadius($0) })
        #expect(RelayTheme.Motion.fast.rawValue == 0.12)
        #expect(RelayTheme.Motion.standard.rawValue == 0.16)
        #expect(RelayTheme.animation(.fast, reduceMotion: true) == nil)
        #expect(RelayTheme.animation(.standard, reduceMotion: false) != nil)
    }

    @Test func elevationLiftsPopoversAboveFloatingPanels() {
        let popover = RelayTheme.Elevation.popover
        let floating = RelayTheme.Elevation.floating
        #expect(popover.radius > floating.radius)
        #expect(popover.opacity > floating.opacity)
        #expect(popover.y > 0 && floating.y > 0)
    }

    @Test func eyebrowIsUppercaseTrackedAndAboveTheFloor() {
        let eyebrow = RelayTheme.TextRole.eyebrow
        #expect(eyebrow.size == 11)
        #expect(eyebrow.isUppercase)
        #expect(eyebrow.tracking > 0)
        #expect(RelayTheme.TextRole.body.tracking == 0)
    }

    @Test func iconActionSizes() {
        #expect(RelayIconAction.Size.regular.side == RelayTheme.Control.height)
        #expect(RelayIconAction.Size.compact.side == RelayTheme.Control.compactIcon)
        // Existing buttons keep 30 pt until slice 10 moves them.
        #expect(RelayIconAction.Size.legacy.side == 30)
    }

    @Test(arguments: [NSAppearance.Name.darkAqua, .aqua])
    func componentsRenderInBothAppearances(appearance: NSAppearance.Name) throws {
        let gallery = VStack(alignment: .leading, spacing: RelayTheme.Space.lg) {
            RelaySectionHeader("Hosts")
            HStack(spacing: RelayTheme.Space.sm) {
                ForEach(RelayTheme.StatusRole.allCases, id: \.self) { role in
                    RelayBadge("\(role)".capitalized, role: role)
                }
            }
            RelayBanner(role: .warning, title: "dandy-07 is reconnecting",
                        message: "Panes reconnect automatically.") {
                Button("Retry now") {}.buttonStyle(RelaySecondaryButtonStyle())
            }
            Text("Card").padding(RelayTheme.Space.md).relayCard()
            RelayEmptyState("No hosts yet", symbol: "server.rack", detail: "Add a host to run agents on it.")
        }
        .padding(RelayTheme.Space.xl)
        let shot = try RelaySnapshot.render(gallery, name: "components", width: 520, appearance: appearance)
        #expect(shot.size.height > 200)
    }
}
