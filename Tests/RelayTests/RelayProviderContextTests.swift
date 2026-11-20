import AppKit
import Foundation
import Testing
@testable import Relay

private func contextFixture(pane: UUID, usage: [String: Int]?) throws -> Data {
    var value: [String: Any] = ["version": 1, "binding": [
        "pane_id": pane.uuidString.lowercased(), "provider": "codex", "process_id": 42,
        "process_start": "kernel:12", "session_id": "current", "source_identity": "4:26"
    ]]
    value["context_usage"] = usage
    return try JSONSerialization.data(withJSONObject: value)
}

@Test func providerContextMatchesExactSessionAndPreservesZero() throws {
    let pane = UUID()
    let data = try contextFixture(pane: pane, usage: ["used_tokens": 0, "limit_tokens": 272_000])
    let context = try #require(try RelayProviderContext.decode(data, hostID: "host", paneID: pane, provider: .codex))
    #expect(context.usedTokens == 0)
    #expect(context.limitTokens == 272_000)
    #expect(context.matches(context.binding))
    let other = RelayAgentConversationBinding(hostID: "host", paneID: pane, provider: "codex",
        processID: 42, processStart: "kernel:12", sessionID: "previous", sourceIdentity: "4:26")
    #expect(!context.matches(other))
    #expect(try RelayProviderContext.decode(data, hostID: "host", paneID: UUID(), provider: .codex) == nil)
    #expect(try RelayProviderContext.decode(data, hostID: "host", paneID: pane, provider: .claude) == nil)
}

@Test func providerContextMissingOrInvalidValuesStayUnknown() throws {
    let pane = UUID()
    for usage in [nil, ["used_tokens": 24], ["used_tokens": -1, "limit_tokens": 400], ["used_tokens": 42, "limit_tokens": 0]] {
        let data = try contextFixture(pane: pane, usage: usage)
        let context = try #require(try RelayProviderContext.decode(data, hostID: "host", paneID: pane, provider: .codex))
        #expect(context.label == RelayProviderContext.unknown)
    }
}

@Test func providerContextDemandWaitsForCancelledReaderBeforeHandoff() {
    var demand = RelayProviderContextDemand<Int>()
    let first = UUID(), second = UUID()
    demand.set(first, key: 1)
    #expect(demand.reconcile(1) == .start(1))
    demand.set(second, key: 1)
    #expect(demand.reconcile(1) == .none)
    demand.set(first, key: nil)
    #expect(demand.reconcile(1) == .none)
    demand.set(second, key: nil)
    #expect(demand.reconcile(1) == .cancel)
    demand.set(first, key: 2)
    #expect(demand.reconcile(2) == .none)
    demand.didStop()
    #expect(demand.reconcile(2) == .start(2))
}

@MainActor @Test("Only presented panes fetch, and two windows share one pane refresh", .timeLimit(.minutes(1)))
func providerContextVisibleConsumersShareActualRefresh() async throws {
    _ = NSApplication.shared
    let pane = PaneModel(profile: .local)
    pane.connectionState = .connected
    pane.setAgentKind(.codex)
    let key = try #require(pane.providerContextKey)
    var calls = 0
    pane.providerContextCapture = { _, _ in
        calls += 1
        return nil
    }

    let size = CGSize(width: 320, height: 200)
    let first = RelayProviderContextWindowReader.Coordinator()
    let second = RelayProviderContextWindowReader.Coordinator()
    let hiddenR = RelayProviderContextWindowReader.Coordinator()
    func window(_ coordinator: RelayProviderContextWindowReader.Coordinator, presented: Bool,
                size: CGSize) -> (NSWindow, RelayWindowVisibilityView) {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 200, y: 200), size: CGSize(width: 320, height: 200)),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let reader = RelayWindowVisibilityView(frame: .zero)
        // Unit-test windows do not run the app event loop. Drive occlusion explicitly.
        reader.occlusionVisible = { _ in true }
        if RelayProviderContextWindowReader.presentsContent(size: size, presented: presented, covered: false) {
            coordinator.watch(reader)
            coordinator.configure(pane, key: key)
        }
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(reader)
        return (window, reader)
    }
    let (a, ar) = window(first, presented: true, size: size)
    let (b, br) = window(second, presented: true, size: size)
    let (r, rr) = window(hiddenR, presented: false, size: .zero)
    defer {
        for (win, read, coordinator) in [(a, ar, first), (b, br, second), (r, rr, hiddenR)] {
            read.detach()
            coordinator.detach()
            win.contentView = nil
            win.close()
        }
    }
    func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    #expect(!RelayProviderContextWindowReader.presentsContent(size: size, presented: false, covered: false))
    #expect(!RelayProviderContextWindowReader.presentsContent(size: .zero, presented: true, covered: false))
    #expect(!RelayProviderContextWindowReader.presentsContent(size: size, presented: true, covered: true))
    r.orderFront(nil)
    rr.evaluate()
    await settle()
    #expect(calls == 0, "a hidden R mount and ordered-out windows cannot fetch")

    a.orderFront(nil)
    ar.evaluate()
    await settle()
    #expect(calls == 1)
    b.orderFront(nil)
    br.evaluate()
    // A hidden stack member/tab relinquishes its view while the other
    // presentation remains mounted, so the shared refresh stays live.
    await settle()
    ar.removeFromSuperview()
    await settle()
    #expect(calls == 1, "a second mount and handoff do not start an extra read")

    br.occlusionVisible = { _ in false }
    br.evaluate()
    await settle()
    #expect(calls == 1)
    br.occlusionVisible = { _ in true }
    br.evaluate()
    await settle()
    #expect(calls == 2, "the first visible consumer after occlusion starts one refresh")

    b.miniaturize(nil)
    br.evaluate()
    await settle()
    #expect(calls == 2)
    b.deminiaturize(nil)
    b.orderFront(nil)
    br.evaluate()
    await settle()
    #expect(calls == 3, "deminiaturizing resumes exactly one refresh")
}
