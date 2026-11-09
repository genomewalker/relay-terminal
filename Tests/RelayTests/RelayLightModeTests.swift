import AppKit
import SwiftUI
import Testing
@testable import Relay

/// Relay follows the macOS appearance: nothing pins dark, and the light
/// palette keeps readable contrast. Renders go to RELAY_SNAPSHOT_DIR when set.
@MainActor @Suite("Light mode follows the system", .serialized)
struct RelayLightModeTests {
    // MARK: Colour helpers

    private static func rgb(_ color: NSColor, in name: NSAppearance.Name) throws -> [CGFloat] {
        var resolved: NSColor?
        try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let c = try #require(resolved)
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    /// `top` composited over the opaque `bottom`.
    private static func over(_ top: [CGFloat], _ bottom: [CGFloat], alpha: CGFloat? = nil) -> [CGFloat] {
        let a = alpha ?? top[3]
        return (0..<3).map { top[$0] * a + bottom[$0] * (1 - a) } + [1]
    }

    private static func luminance(_ c: [CGFloat]) -> CGFloat {
        let lin = c.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    }

    static func contrast(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // MARK: Nothing forces dark

    @Test func windowsKeepTheSystemAppearance() {
        for initial in [nil, NSAppearance(named: .aqua)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = initial
            RelayTheme.configureAppearance(window)
            #expect(window.appearance?.name == initial?.name)
            #expect(window.titlebarAppearsTransparent)
        }
    }

    /// A `.relaySurface()` root in a window under the light appearance draws the
    /// light canvas and leaves the window's appearance alone.
    @Test func relaySurfaceDoesNotPinAColorScheme() throws {
        for (appearance, light) in [(NSAppearance.Name.aqua, true), (.darkAqua, false)] {
            let size = NSSize(width: 40, height: 40)
            let host = NSHostingView(rootView: Color.clear.frame(width: 40, height: 40).relaySurface())
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            // The surface marker configures its window asynchronously; let it run.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let pixel = try #require(rep.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
            let expected = try Self.rgb(RelayPalette.canvas, in: appearance)
            // The cached bitmap is in the display colour space; allow for the conversion.
            #expect(abs(pixel.redComponent - expected[0]) < 0.04, "\(appearance.rawValue) \(pixel.redComponent) vs \(expected[0])")
            #expect((pixel.redComponent > 0.5) == light, "\(appearance.rawValue)")
            #expect(window.appearance?.name == appearance)
            window.contentView = nil
            window.close()
        }
    }

    // MARK: Contrast of the light palette

    @Test func lightTextMeetsContrastOnEverySurface() throws {
        let surfaces: [(String, NSColor)] = [("canvas", RelayPalette.canvas), ("sidebar", RelayPalette.sidebar),
                                             ("surface", RelayPalette.surface), ("elevated", RelayPalette.elevated)]
        let accent = try Self.rgb(RelayPalette.accent, in: .aqua)
        let sidebar = try Self.rgb(RelayPalette.sidebar, in: .aqua)
        // The navigator's selected row: accent at 16% over the sidebar.
        let selection = Self.over(accent, sidebar, alpha: 0.16)
        var backgrounds = try surfaces.map { ($0.0, try Self.rgb($0.1, in: .aqua)) }
        backgrounds.append(("selection", selection))
        for (surfaceName, background) in backgrounds {
            for (name, color, minimum) in [("text", RelayPalette.text, 4.5), ("textMuted", RelayPalette.textMuted, 4.5),
                                           ("textFaint", RelayPalette.textFaint, 3.0)] as [(String, NSColor, CGFloat)] {
                // Composite in case a token is translucent (system label colours are).
                let ratio = Self.contrast(Self.over(try Self.rgb(color, in: .aqua), background), background)
                print("contrast light \(name) on \(surfaceName): \(String(format: "%.2f", ratio))")
                #expect(ratio >= minimum, "\(name) on \(surfaceName): \(ratio)")
            }
        }
        // Links and tinted controls use the accent on light surfaces.
        let canvas = try Self.rgb(RelayPalette.canvas, in: .aqua)
        #expect(Self.contrast(Self.over(accent, canvas), canvas) >= 4.5)
        // The sidebar is visibly distinct from content, and the selection from the sidebar.
        #expect(Self.contrast(canvas, sidebar) >= 1.08)
        #expect(Self.contrast(sidebar, selection) >= 1.15)
        // Content surfaces stay near-white.
        #expect(Self.luminance(canvas) > 0.9)
    }

    // MARK: Renders

    private func shot<V: View>(_ view: V, _ name: String, size: NSSize, background: Color) throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(background))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let dir = ProcessInfo.processInfo.environment["RELAY_SNAPSHOT_DIR"], !dir.isEmpty,
               let png = rep.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
            }
            #expect(rep.pixelsWide >= Int(size.width))
            window.contentView = nil
            window.close()
        }
    }

    @Test func rendersSidebarHeaderBoardAndSettingsInBothAppearances() throws {
        let f = try RelayAttentionClassificationTests.makeFixture()
        defer { f.workspace.shutdown() }
        try shot(WorkspaceNavigator(workspace: f.workspace, inbox: f.store), "light-sidebar-navigator",
                 size: NSSize(width: 260, height: 520), background: RelayTheme.sidebar)

        let profile = ConnectionProfile(name: "dandy-07", kind: .ssh, host: "dandy-07.ux-light.invalid")
        let saved = PersistedAgentPaneState(cursor: 0, kind: .claude, phase: .needsInput, summary: "Waiting for approval",
                                            subagents: [], activities: [], resourceUsage: nil, progressPercent: nil,
                                            pendingApprovals: 0)
        let pane = PaneModel(profile: profile, customName: "Sapropel - annotation jobs - claude 767dc7",
                             directory: "/projects/sapropel", savedAgentState: saved)
        pane.connectionState = .connected
        let header = ConnectionPath(pane: pane, active: true, compact: false, zoomed: false, isFloating: false,
                                    select: {}, toggleZoom: {}, toggleFloating: {}, rename: {}, terminate: nil, close: {})
            .environmentObject(PaneLinkSelection())
        try shot(header, "light-pane-header", size: NSSize(width: 900, height: 40), background: RelayTheme.canvas)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        typealias Index = RelayWorkOverviewIndex
        func fact(_ name: String, _ status: Index.PaneStatus, _ detail: String, minutesAgo: Double) -> Index.PaneFact {
            Index.PaneFact(paneID: UUID(), tabID: UUID(), name: name, workspaceName: "Pan-barley", tabName: "sweep",
                           host: "dandy-07", status: status, detail: detail,
                           changedAt: now.addingTimeInterval(-minutesAgo * 60), hiddenStackMember: false)
        }
        let facts = [fact("smdb-import", .waiting, "Needs input", minutesAgo: 3),
                     fact("metadmg-sweep", .disconnected, "Connection lost", minutesAgo: 41),
                     fact("pan-barley-align", .reconnecting, "Reconnecting", minutesAgo: 6),
                     fact("relay-build", .running, "Working", minutesAgo: 1),
                     fact("notes", .idle, "Exited", minutesAgo: 90)]
        let board = VStack(alignment: .leading, spacing: 0) {
            RelayFleetBoardHeader(counts: Index.PaneCounts(facts), hostCount: 1, filter: .constant(.all), onClose: {})
                .padding(RelayTheme.Space.xl)
            Divider()
            RelayFleetBoardList(facts: facts, filter: .all, now: now, onOpen: { _ in })
                .padding(RelayTheme.Space.xl)
            Spacer(minLength: 0)
        }.relaySurface()
        try shot(board, "light-fleet-board", size: NSSize(width: 720, height: 460), background: RelayTheme.canvas)

        let previous = RelaySettingsNavigation.shared.section
        defer { RelaySettingsNavigation.shared.section = previous }
        RelaySettingsNavigation.shared.section = "general"
        try shot(RelaySettingsView(), "light-settings-general", size: NSSize(width: 940, height: 680),
                 background: RelayTheme.canvas)
    }
}
