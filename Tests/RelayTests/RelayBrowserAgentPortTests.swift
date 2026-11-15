import AppKit
import Foundation
import Testing
import WebKit
@testable import Relay

/// An agent's page on a host port the browser has not carried yet waits for
/// the user; the user's own opens still carry the port at once.
@MainActor @Suite("Agent-opened host ports ask the user first")
struct RelayBrowserAgentPortTests {
    private static let profile = ConnectionProfile(
        name: "agent-port", kind: .ssh, host: "agent-port.invalid", backend: .relay)
    private static let page = URL(string: "http://localhost:8001/index.html")!

    private func session() -> RelayBrowserSession {
        _ = NSApplication.shared
        return RelayBrowserSession(profile: Self.profile, directory: nil, store: .nonPersistent())
    }

    @Test func anAgentOpenOfANewHostPortWaitsForTheUser() {
        let browser = session()
        defer { browser.close() }
        browser.open(Self.page, byAgent: true)
        #expect(browser.confirm == Self.page)
        #expect(browser.confirmFromAgent)
        #expect(!browser.hasPendingLoad)
        #expect(!browser.busy)
        #expect(browser.portMap.isEmpty)
    }

    @Test func theUsersOwnOpenStillCarriesThePortWithoutAsking() {
        let browser = session()
        defer { browser.close() }
        browser.open(Self.page)
        #expect(browser.confirm == nil)
        #expect(browser.hasPendingLoad)
    }

    @Test func allowingTheAgentsRequestCarriesThePortAndDecliningDoesNot() {
        let allowed = session(), declined = session()
        defer { allowed.close(); declined.close() }
        allowed.open(Self.page, byAgent: true)
        allowed.confirmPort()
        #expect(allowed.confirm == nil && !allowed.confirmFromAgent)
        #expect(allowed.hasPendingLoad)
        declined.open(Self.page, byAgent: true)
        declined.declinePort()
        #expect(declined.confirm == nil && !declined.confirmFromAgent)
        #expect(!declined.hasPendingLoad)
    }

    @Test func relayBrowserOpenRepliesThatItIsWaitingForTheUser() async throws {
        let browser = session()
        defer { browser.close() }
        let reply = try await RelayBrowserController.shared.agent(
            .open, profile: Self.profile, directory: nil, near: nil, docked: browser,
            url: Self.page, ref: nil, text: nil, submit: false, key: nil, dy: nil)
        #expect(reply.page.waitingForUser == Self.page.absoluteString)
        #expect(!browser.hasPendingLoad)
    }
}
