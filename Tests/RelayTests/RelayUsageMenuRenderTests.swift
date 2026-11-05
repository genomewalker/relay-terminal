import AppKit
import SwiftUI
import XCTest
@testable import Relay

final class RelayUsageMenuRenderTests: XCTestCase {
    @MainActor func testUsageMenuShowsAllWindowsOffscreen() async throws {
        _ = NSApplication.shared
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = try RelaySubscriptionQuota.codex(response: Data(#"{"rateLimits":{"limitId":"codex","planType":"self_serve_business_prolite","primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":1800010000},"secondary":{"usedPercent":91,"windowDurationMins":10080,"resetsAt":1800050000}}}"#.utf8), now: now)
        let entry = RelaySubscriptionQuotaStore.Entry(id: "codex", hosts: ["This Mac", "dandy-07"], provider: .codex, accountScope: nil, quota: quota)
        let unavailable = RelaySubscriptionQuotaStore.Entry(id: "unknown", hosts: ["This Mac"], provider: .claude, accountScope: nil, quota: nil)
        let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Text("Account usage").font(.headline)
            RelaySubscriptionQuotaRow(entry: entry, now: now)
            Divider()
            RelaySubscriptionQuotaRow(entry: unavailable, now: now)
        }.padding(16).frame(width: 330).background(RelayTheme.surface))
        view.frame = NSRect(x: 0, y: 0, width: 330, height: 440)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        await Task.yield(); window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
        await Task.yield(); view.displayIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(quota.windows.count, 2)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1500)
        if let path = ProcessInfo.processInfo.environment["RELAY_USAGE_SNAPSHOT"] { try png.write(to: URL(fileURLWithPath: path)) }
    }
}
