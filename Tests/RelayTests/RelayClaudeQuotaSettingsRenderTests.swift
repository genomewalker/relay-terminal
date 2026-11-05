import AppKit
import SwiftUI
import XCTest
@testable import Relay

final class RelayClaudeQuotaSettingsRenderTests: XCTestCase {
    @MainActor func testSettingsRendersOffscreen() async throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RelayClaudeQuotaSettingsView(configuredHosts: ["local", "dandy-07"])
            .padding(20).frame(width: 650, height: 590, alignment: .topLeading).background(RelayTheme.surface))
        view.frame = NSRect(x: 0, y: 0, width: 650, height: 590)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        // Let SwiftUI commit its first body/layout transactions before the
        // AppKit bitmap read. The window remains unordered and off-screen.
        await Task.yield()
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        await Task.yield()
        view.displayIfNeeded()
        XCTAssertFalse(window.isVisible, "UI tests stay off-screen")
        XCTAssertGreaterThan(view.fittingSize.height, 100)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        var colors = Set<String>()
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 11) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 11) {
                if let color = bitmap.colorAt(x: x, y: y) { colors.insert(color.description) }
            }
        }
        XCTAssertGreaterThan(colors.count, 8, "controls and text must actually render")
        if let path = ProcessInfo.processInfo.environment["QF_SETTINGS_SNAPSHOT"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
