import Foundation
import Testing
@testable import Relay

@Suite struct RelayBrowserRoutingTests {
    private func url(_ s: String) -> URL { URL(string: s)! }
    private func route(_ s: String, remote: Bool, _ tunnels: [Int: Int] = [:]) -> RelayBrowserRouting.Route {
        RelayBrowserRouting.route(url(s), remote: remote, tunnels: tunnels)
    }

    @Test func localPanesBrowseLikeAnyBrowser() {
        #expect(route("http://localhost:5173/", remote: false) == .load(url("http://localhost:5173/")))
        #expect(route("https://example.org/a", remote: false) == .load(url("https://example.org/a")))
    }

    @Test func remoteLocalhostIsTheHostsAndIsCarried() {
        #expect(route("http://localhost:5173/app?x=1", remote: true) == .tunnel(hostPort: 5173))
        #expect(route("http://127.0.0.1/", remote: true) == .tunnel(hostPort: 80))
        #expect(route("http://0.0.0.0:8000/", remote: true) == .tunnel(hostPort: 8000))
        #expect(route("http://[::1]:9000/", remote: true) == .tunnel(hostPort: 9000))
        // Once carried, the host port loads from its Mac port, same or not.
        #expect(route("http://localhost:5173/app?x=1", remote: true, [5173: 5173]) == .load(url("http://127.0.0.1:5173/app?x=1")))
        #expect(route("http://localhost:80/", remote: true, [80: 50111]) == .load(url("http://127.0.0.1:50111/")))
        // A page served through the tunnel links to its own Mac-side origin.
        #expect(route("http://127.0.0.1:50111/next", remote: true, [80: 50111]) == .load(url("http://127.0.0.1:50111/next")))
        // The internet loads directly, as in a local pane.
        #expect(route("https://example.org/", remote: true) == .load(url("https://example.org/")))
    }

    @Test func unsafeOrExcessAddressesAreBlocked() {
        if case .blocked = route("http://user:pw@example.org/", remote: true) {} else { Issue.record("credentials allowed") }
        if case .blocked = route("file:///etc/hosts", remote: false) {} else { Issue.record("file URL allowed") }
        let full = Dictionary(uniqueKeysWithValues: (0..<RelayBrowserRouting.maxTunnels).map { (3000 + $0, 3000 + $0) })
        if case .blocked = route("http://localhost:9999/", remote: true, full) {} else { Issue.record("tunnel limit ignored") }
        #expect(RelayBrowserRouting.preferredMacPort(hostPort: 5173) == 5173)
        #expect(RelayBrowserRouting.preferredMacPort(hostPort: 80) == nil)
    }

    /// The guard blocks every Mac loopback form, allowing only carried ports.
    @Test func macGuardBlocksLoopbackExceptCarriedPorts() throws {
        let json = RelayBrowserRouting.macGuardRules(macPorts: [5173])
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: String]]])
        let blocks = rules.filter { $0["action"]?["type"] == "block" }.compactMap { $0["trigger"]?["url-filter"] }
        let allows = rules.filter { $0["action"]?["type"] == "ignore-previous-rules" }.compactMap { $0["trigger"]?["url-filter"] }
        func matches(_ patterns: [String], _ s: String) -> Bool {
            patterns.contains { s.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        for mac in ["http://localhost:22/", "http://LOCALHOST/", "http://a.localhost/", "ws://127.0.0.1:8080/",
                    "http://127.1.2.3/", "http://[::1]:631/", "http://0.0.0.0:7000/", "http://[::ffff:127.0.0.1]/"] {
            #expect(matches(blocks, mac) && !matches(allows, mac), "\(mac)")
        }
        for carried in ["http://127.0.0.1:5173/", "ws://127.0.0.1:5173/hmr", "http://localhost:5173/x"] {
            #expect(matches(allows, carried), "\(carried)")
        }
        #expect(!matches(allows, "http://127.0.0.1:51730/"))
        #expect(!matches(blocks, "https://example.org/localhost/"))
        #expect(rules.first?["action"]?["type"] == "block") // blocks precede the exceptions
    }
}
