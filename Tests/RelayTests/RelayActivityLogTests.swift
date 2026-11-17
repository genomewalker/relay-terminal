import Foundation
import Testing
@testable import Relay

@MainActor @Suite("Activity inbox lists agent actions outside focus")
struct RelayActivityLogTests {
    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    @Test("Entries are newest first, by time even when they arrive out of order")
    func ordering() {
        let log = RelayActivityLog()
        let t0 = Date(timeIntervalSince1970: 1_000)
        log.record(caller: "a", summary: "first", paneID: UUID(), tabID: nil, at: t0)
        log.record(caller: "a", summary: "third", paneID: UUID(), tabID: nil, at: t0.addingTimeInterval(20))
        log.record(caller: "a", summary: "second", paneID: UUID(), tabID: nil, at: t0.addingTimeInterval(10))
        #expect(log.entries.map(\.summary) == ["third", "second", "first"])
        #expect(log.unreadCount == 3)
    }

    @Test("History is bounded to the newest entries")
    func bounding() {
        let log = RelayActivityLog()
        let t0 = Date(timeIntervalSince1970: 1_000)
        for index in 0..<(RelayActivityLog.limit + 25) {
            log.record(caller: "a", summary: "\(index)", paneID: UUID(), tabID: nil, at: t0.addingTimeInterval(Double(index)))
        }
        #expect(log.entries.count == RelayActivityLog.limit)
        #expect(log.entries.first?.summary == "\(RelayActivityLog.limit + 24)")
        #expect(log.entries.last?.summary == "25")
    }

    @Test("A replayed caller request is recorded once; mark read and clear work")
    func dedupeReadClear() {
        let log = RelayActivityLog()
        let pane = UUID()
        #expect(log.record(caller: "a", summary: "x", paneID: pane, tabID: nil, dedupeKey: "p#1") != nil)
        #expect(log.record(caller: "a", summary: "x", paneID: pane, tabID: nil, dedupeKey: "p#1") == nil)
        log.record(caller: "a", summary: "y", paneID: pane, tabID: nil, dedupeKey: "p#2")
        #expect(log.entries.count == 2)
        log.markRead(log.entries[0].id)
        #expect(log.unreadCount == 1)
        log.markAllRead()
        #expect(log.unreadCount == 0)
        log.clear()
        #expect(log.entries.isEmpty)
        #expect(log.toast == nil)
    }

    @Test("Recording does not show a toast unless asked, and a toast is the newest entry")
    func toast() {
        let log = RelayActivityLog()
        log.record(caller: "a", summary: "quiet", paneID: UUID(), tabID: nil)
        #expect(log.toast == nil)
        let shown = log.record(caller: "a", summary: "shown", paneID: UUID(), tabID: nil, showToast: true)
        #expect(log.toast == shown)
        log.dismissToast()
        #expect(log.toast == nil)
    }

    @Test("A closed pane falls back to its tab, then shows as gone")
    func missingPane() {
        let pane = UUID(), tab = UUID()
        let entry = RelayActivityEntry(id: UUID(), at: Date(), caller: "a", summary: "x", paneID: pane, tabID: tab, isRead: false)
        #expect(RelayActivityTarget.resolve(entry, paneExists: { $0 == pane }, tabExists: { _ in true }) == .pane(pane))
        #expect(RelayActivityTarget.resolve(entry, paneExists: { _ in false }, tabExists: { $0 == tab }) == .tab(tab))
        #expect(RelayActivityTarget.resolve(entry, paneExists: { _ in false }, tabExists: { _ in false }) == .gone)
    }

    @Test("Only targets outside focus are listed")
    func focus() {
        let pane = UUID(), other = UUID(), tab = UUID()
        #expect(!RelayActivityLog.isOutsideFocus(paneID: pane, tabID: tab, focusedPane: pane, focusedTab: tab, appActive: true))
        #expect(RelayActivityLog.isOutsideFocus(paneID: pane, tabID: tab, focusedPane: other, focusedTab: tab, appActive: true))
        #expect(RelayActivityLog.isOutsideFocus(paneID: pane, tabID: nil, focusedPane: pane, focusedTab: nil, appActive: false))
        #expect(!RelayActivityLog.isOutsideFocus(paneID: nil, tabID: tab, focusedPane: other, focusedTab: tab, appActive: true))
    }

    @Test("Agent actions are described with their target; reads and failures are not")
    func describer() {
        let pane = UUID(), tab = UUID()
        let id = { (u: UUID) in u.uuidString.lowercased() }
        let newTab = RelayActivityDescriber.describe(method: "POST", path: "/api/workspace/new-local-tab",
            request: json(["requestID": "r1"]), response: json(["status": "created", "tabID": id(tab), "paneID": id(pane)]))
        #expect(newTab == .init(summary: "Opened a new local tab", paneID: pane, tabID: tab, requestID: "r1"))

        let launch = RelayActivityDescriber.describe(method: "POST", path: "/api/workspace/launch-agent",
            request: json(["requestID": "r2", "provider": "claude", "host": "dandy-07"]),
            response: json(["status": "launched", "created": ["status": "created", "pane_id": id(pane), "tab_id": id(tab)]]))
        #expect(launch?.summary == "Launched Claude on dandy-07")
        #expect(launch?.paneID == pane)

        let message = RelayActivityDescriber.describe(method: "POST", path: "/api/panes/\(id(pane))/message",
            request: json(["messageID": "m1", "text": "hi"]), response: json(["status": "delivered"]),
            paneName: { $0 == pane ? "worker" : nil })
        #expect(message?.summary == "Sent a message to 'worker'")
        #expect(message?.paneID == pane)

        #expect(RelayActivityDescriber.describe(method: "POST", path: "/api/workspace/launch-agent",
            request: json([:]), response: json(["status": "launch_failed"])) == nil)
        #expect(RelayActivityDescriber.describe(method: "GET", path: "/api/panes/\(id(pane))/message",
            request: Data(), response: Data()) == nil)
        #expect(RelayActivityDescriber.describe(method: "POST", path: "/api/workspace/show",
            request: json(["paneID": id(pane)]), response: json(["paneID": id(pane)])) == nil)
        #expect(RelayActivityDescriber.describe(method: "POST", path: "/api/workspace/host-request",
            request: json(["tab_id": id(tab)]), response: json([:])) == nil)
    }
}
