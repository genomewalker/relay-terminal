import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Relay

@Suite("relay_browser", .serialized)
@MainActor struct RelayBrowserAgentTests {
    typealias Proposal = MCPDirectTabRequests.BrowserProposal

    static func proposal(_ action: RelayBrowserAgentAction, url: String? = nil, ref: Int? = nil, text: String? = nil,
                         key: String? = nil, dy: Int? = nil, id: UUID = UUID(), pane: UUID = UUID(), instance: UUID = UUID()) -> Proposal {
        Proposal(instance: instance, requestID: id, paneID: pane, action: action, url: url, ref: ref, text: text,
                 submit: nil, key: key, dy: dy)
    }

    @Test func eachActionTakesOnlyWhatItCanUse() {
        #expect(Self.proposal(.open, url: "http://localhost:5173/").isValid)
        #expect(!Self.proposal(.open).isValid)
        for refused in ["file:///etc/hosts", "javascript:alert(1)", "https://u:p@example.org/", "/tmp/x"] {
            #expect(!Self.proposal(.open, url: refused).isValid, "\(refused)")
        }
        #expect(Self.proposal(.click, ref: 1).isValid)
        #expect(!Self.proposal(.click).isValid && !Self.proposal(.click, ref: 0).isValid && !Self.proposal(.click, ref: 201).isValid)
        #expect(Self.proposal(.type, ref: 2, text: "line one\nline two\t").isValid)
        #expect(!Self.proposal(.type, ref: 2, text: "a\u{1b}[31m").isValid)        // no terminal control bytes
        #expect(!Self.proposal(.type, ref: 2, text: String(repeating: "x", count: 4097)).isValid)
        #expect(Self.proposal(.press, key: "Enter").isValid && !Self.proposal(.press, key: "F13").isValid)
        #expect(Self.proposal(.scroll, dy: -400).isValid && !Self.proposal(.scroll).isValid)
        #expect(Self.proposal(.read).isValid && Self.proposal(.capture).isValid)
    }

    @Test func readingNeedsNavigateAndChangingAlsoNeedsInput() async throws {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        let paneID = try #require(workspace.activePaneID)
        let instance = UUID()
        let handler = MCPDirectTabRequests()
        var performed: [RelayBrowserAgentAction] = []
        let page = RelayBrowserAgentPage(url: "http://localhost:5173/", title: "t", loading: false, waitingForUser: nil, error: nil,
                                         text: "", textTruncated: false, elements: [], elementsTruncated: false, scrollY: 0, scrollHeight: 0)
        func call(_ proposal: Proposal, _ permits: @escaping (MCPWorkspaceCapability) -> Bool) async throws -> RelaySidePanelHTTPResponse {
            await handler.browser(try JSONEncoder().encode(proposal), instance: instance, permits: permits, workspace: workspace) { _, pane, p in
                #expect(pane.id == paneID)
                performed.append(p.action)
                return (page, nil)
            }
        }
        let navigate: (MCPWorkspaceCapability) -> Bool = { $0 == .navigate }
        let both: (MCPWorkspaceCapability) -> Bool = { $0 == .navigate || $0 == .input }
        #expect(try await call(Self.proposal(.read, pane: paneID, instance: instance), { _ in false }).status == 403)
        #expect(try await call(Self.proposal(.read, pane: paneID, instance: instance), navigate).status == 200)
        #expect(try await call(Self.proposal(.click, ref: 1, pane: paneID, instance: instance), navigate).status == 403)
        #expect(performed == [.read])

        let click = Self.proposal(.click, ref: 1, pane: paneID, instance: instance)
        #expect(try await call(click, both).status == 200)
        #expect(try await call(click, both).status == 200)       // a repeat returns the saved result
        #expect(performed == [.read, .click])                      // and does not click twice
        var other = click; other.ref = 2
        #expect(try await call(other, both).status == 409)         // same ID, different action
        #expect(try await call(Self.proposal(.read, pane: paneID), both).status == 400)        // stale instance
        #expect(try await call(Self.proposal(.read, pane: UUID(), instance: instance), both).status == 409) // unknown pane
        var extra = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.proposal(.read, pane: paneID, instance: instance))) as? [String: Any])
        extra["script"] = "alert(1)"
        let refused = await handler.browser(try JSONSerialization.data(withJSONObject: extra), instance: instance, permits: both,
                                            workspace: workspace) { _, _, _ in performed.append(.read); return (page, nil) }
        #expect(refused.status == 400)
        #expect(performed == [.read, .click])
    }

    @Test func anAgentReadsClicksAndTypesInARealPage() async throws {
        let session = RelayBrowserSession(profile: .local, directory: nil, store: .nonPersistent())
        let html = """
        <title>Form</title><h1>Hello agent</h1>
        <form onsubmit="event.preventDefault(); document.getElementById('out').textContent = 'sent ' + document.getElementById('q').value">
          <input id=q name=q placeholder="Search"><input type=password id=p value="secret">
          <button type=submit>Go</button></form>
        <button id=b onclick="this.textContent='clicked'">Press me</button><p id=out></p>
        <script>document.getElementById('q').addEventListener('input', e => document.title = 'typed ' + e.target.value)</script>
        """
        session.webView.loadHTMLString(html, baseURL: nil)
        for _ in 0..<100 where session.webView.isLoading || session.webView.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        var page = await session.agentPage()
        #expect(page.text.contains("Hello agent"))
        let search = try #require(page.elements.first { $0.name == "Search" })
        let password = try #require(page.elements.first { $0.kind == "input:password" })
        #expect(password.value == nil)                               // a password is never read back
        let press = try #require(page.elements.first { $0.name == "Press me" })

        try await session.agentClick(press.ref)
        try await session.agentType(search.ref, text: "relay", submit: true)
        page = await session.agentPage()
        #expect(page.text.contains("clicked"))
        #expect(page.text.contains("sent relay"))                    // submit ran the form's own handler
        #expect(page.title == "typed relay")                         // frameworks see the input event

        // Page scripts cannot see or replace the agent's element references.
        let seen = try await session.webView.callAsyncJavaScript("return typeof globalThis.__relayRefs", contentWorld: .page) as? String
        #expect(seen == "undefined")
        await #expect(throws: RelayBrowserAgentError.staleRef(150)) { try await session.agentClick(150) }
        let capture = try await session.agentCapture()
        #expect(capture.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func conversationWebLinksOpenInTheRelayBrowser() {
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        guard let pane = workspace.activePaneID.flatMap({ workspace.panes[$0] }) else { Issue.record("no pane"); return }
        var opened: [URL] = []
        let web = URL(string: "https://example.org/a")!
        var profiles: [ConnectionProfile] = []
        let took = RelayAgentLinks.open(web, pane: pane) { url, profile, _ in opened.append(url); profiles.append(profile) }
        #expect(took && profiles == [pane.profile])
        #expect(RelayAgentLinks.open(URL(string: "mailto:a@b.org")!, pane: pane) { url, _, _ in opened.append(url) } == false)
        #expect(opened == [web])
    }

    @Test func eachHostKeepsItsOwnLogins() {
        var remote = ConnectionProfile.local
        remote.kind = .ssh
        remote.id = UUID()
        #expect(RelayBrowserSession.storeIdentifier(.local) == RelayBrowserSession.localStore)
        #expect(RelayBrowserSession.storeIdentifier(remote) == remote.id)
        #expect(RelayBrowserSession.storeIdentifier(remote) != RelayBrowserSession.storeIdentifier(.local))
    }
}
