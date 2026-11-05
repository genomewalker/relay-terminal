import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct RelayAutoLinkerTests {
    final class FakeLinks {
        var links: [RelayAutoLinkPair: String] = [:]
        var failConnect = false
        var calls: [String] = []
    }

    static let tab = UUID(), otherTab = UUID(), owner = UUID()
    static let a = UUID(), b = UUID(), c = UUID(), shell = UUID()

    func make(_ fake: FakeLinks, panes: @escaping () -> [RelayAutoLinkPane]) throws -> (RelayAutoLinker, WorkspaceModel, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "relay.tests.auto-link." + UUID().uuidString))
        let linker = RelayAutoLinker(defaults: defaults)
        linker.panesProvider = { _ in panes() }
        linker.existingLinks = { _ in fake.links }
        linker.connect = { pair, _ in
            fake.calls.append("link " + pair.key)
            if fake.failConnect { throw RemoteCatalogError.failed("agent changed") }
            fake.links[pair] = "id-" + pair.key
        }
        linker.disconnect = { id, _ in
            fake.calls.append("unlink " + id)
            fake.links = fake.links.filter { $0.value != id }
        }
        return (linker, WorkspaceModel(restoreSavedWorkspace: false), defaults)
    }

    static var layout: [RelayAutoLinkPane] {
        [.init(id: a, tab: tab, workspace: owner, agent: true), .init(id: b, tab: tab, workspace: owner, agent: true),
         .init(id: shell, tab: tab, workspace: owner, agent: false), .init(id: c, tab: otherTab, workspace: owner, agent: true)]
    }

    @Test("Tab scope links its agents, keeps manual links and honours the user's unlink")
    func lifecycle() async throws {
        let fake = FakeLinks()
        let ab = RelayAutoLinkPair(Self.a, Self.b)!, ac = RelayAutoLinkPair(Self.a, Self.c)!
        fake.links[ac] = "manual-ac"
        let (linker, workspace, defaults) = try make(fake) { Self.layout }
        defer { workspace.shutdown() }
        linker.toggle(.tab(Self.tab), workspace: workspace)
        await linker.reconcile()
        #expect(fake.links[ab] != nil && fake.links.count == 2)
        #expect(defaults.stringArray(forKey: "relay.auto-link.owned.v1") == [ab.key])
        #expect(defaults.stringArray(forKey: "relay.auto-link.scopes.v1") == [RelayAutoLinkScope.tab(Self.tab).key])

        fake.links[ab] = nil // the user removed it
        await linker.reconcile()
        #expect(fake.links[ab] == nil && linker.ownedForTesting.suppressed == [ab])

        linker.toggle(.workspace(Self.owner), workspace: workspace)
        await linker.reconcile()
        // a-b stays suppressed; b-c is new; a-c is manual and untouched.
        #expect(fake.links[ab] == nil && fake.links[RelayAutoLinkPair(Self.b, Self.c)!] != nil && fake.links[ac] == "manual-ac")

        linker.toggle(.tab(Self.tab), workspace: workspace)
        linker.toggle(.workspace(Self.owner), workspace: workspace)
        await linker.reconcile()
        #expect(fake.links == [ac: "manual-ac"], "turning scopes off removes only what auto-link made")
        #expect(linker.ownedForTesting == .init())
        #expect(!fake.calls.contains("unlink manual-ac"))
    }

    @Test("A failed link is not owned, is reported, and is retried later")
    func failure() async throws {
        let fake = FakeLinks()
        fake.failConnect = true
        let (linker, workspace, _) = try make(fake) { Self.layout }
        defer { workspace.shutdown() }
        linker.toggle(.tab(Self.tab), workspace: workspace)
        await linker.reconcile()
        #expect(fake.links.isEmpty && linker.ownedForTesting.owned.isEmpty && linker.lastError?.contains("agent changed") == true)
        fake.failConnect = false
        await linker.reconcile()
        #expect(fake.links.count == 1 && linker.lastError == nil)
    }

    @Test("Scopes and ownership survive a restart; malformed saved keys are ignored")
    func persistence() async throws {
        let fake = FakeLinks()
        let (linker, workspace, defaults) = try make(fake) { Self.layout }
        defer { workspace.shutdown() }
        linker.toggle(.tab(Self.tab), workspace: workspace)
        await linker.reconcile()
        var scopes = defaults.stringArray(forKey: "relay.auto-link.scopes.v1") ?? []
        scopes.append("pane:" + UUID().uuidString.lowercased())
        defaults.set(scopes, forKey: "relay.auto-link.scopes.v1")
        let restarted = RelayAutoLinker(defaults: defaults)
        #expect(restarted.scopes == [.tab(Self.tab)])
        #expect(restarted.ownedForTesting.owned == [RelayAutoLinkPair(Self.a, Self.b)!])
    }

    @Test("Broadcast is off until the user allows it, apart from auto-link, and never for an unknown owner")
    func broadcastGrants() throws {
        let defaults = try #require(UserDefaults(suiteName: "relay.tests.broadcast." + UUID().uuidString))
        let linker = RelayAutoLinker(defaults: defaults)
        #expect(linker.broadcastGrants(tab: Self.tab, workspace: Self.owner).isEmpty)
        let workspace = WorkspaceModel(restoreSavedWorkspace: false)
        defer { workspace.shutdown() }
        linker.toggle(.tab(Self.tab), workspace: workspace)
        linker.toggle(.workspace(Self.owner), workspace: workspace)
        #expect(linker.broadcastGrants(tab: Self.tab, workspace: Self.owner).isEmpty)
        linker.toggleBroadcast(.workspace(Self.owner))
        #expect(linker.broadcastGrants(tab: Self.tab, workspace: Self.owner) == ["workspace"])
        #expect(linker.broadcastGrants(tab: Self.tab, workspace: nil).isEmpty)
        #expect(linker.broadcastGrants(tab: Self.otherTab, workspace: UUID()).isEmpty)
        linker.toggleBroadcast(.tab(Self.tab))
        let restarted = RelayAutoLinker(defaults: defaults)
        #expect(restarted.broadcastGrants(tab: Self.tab, workspace: Self.owner) == ["tab", "workspace"])
        restarted.toggleBroadcast(.tab(Self.tab))
        #expect(restarted.broadcastGrants(tab: Self.tab, workspace: nil).isEmpty)
    }
}
