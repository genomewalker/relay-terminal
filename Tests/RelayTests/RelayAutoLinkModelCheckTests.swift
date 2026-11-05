import Foundation
import Testing
@testable import Relay

/// Exhaustive bounded check of auto-link against the real policy. Every
/// sequence of user and Relay operations up to `depth` steps is explored over
/// 3 panes, 3 tabs (two owned by workspace 0, one with unknown ownership), a
/// second workspace that owns no tab, and an agent cap of 2, with these safety
/// properties checked after every step:
///  - manual: a reconcile never removes a link someone else made;
///  - scope: a reconcile links only two present agent panes sharing an enabled
///    scope that is within the cap (independent oracle, not the policy);
///  - user wins: a link the user removed is not recreated while still wanted;
///  - books: auto-link owns exactly the existing links it made;
///  - converge: after a fully successful reconcile every wanted, unsuppressed
///    pair is linked and every auto-made link is wanted.
@Suite struct RelayAutoLinkModelCheckTests {
    static let panes = (0..<3).map { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0 + 1))! }
    static let tabs = (0..<3).map { UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", $0 + 1))! }
    static let workspaces = (0..<2).map { UUID(uuidString: String(format: "00000000-0000-4000-a000-%012d", $0 + 1))! }
    /// Tab 2's owner is unknown: its panes must be in no workspace scope.
    static func workspace(ofTab tab: Int) -> UUID? { tab < 2 ? workspaces[0] : nil }
    static let scopes: [RelayAutoLinkScope] = tabs.map { .tab($0) } + workspaces.map { .workspace($0) }
    static let pairs: [RelayAutoLinkPair] = [(0, 1), (0, 2), (1, 2)].map { RelayAutoLinkPair(panes[$0.0], panes[$0.1])! }
    static let limit = 2

    enum Origin: Hashable { case manual, auto }

    struct World: Hashable {
        var placement: [Int?] = [nil, nil, nil] // tab index
        var agent: [Bool] = [false, false, false]
        var scopes: Set<RelayAutoLinkScope> = []
        var links: [RelayAutoLinkPair: Origin] = [:]
        var state = RelayAutoLinkState()
        /// Ground truth of pairs the user unlinked after auto-link made them.
        var userRemoved: Set<RelayAutoLinkPair> = []

        var policyPanes: [RelayAutoLinkPane] {
            (0..<3).compactMap { i in
                placement[i].map { RelayAutoLinkPane(id: panes[i], tab: tabs[$0], workspace: workspace(ofTab: $0), agent: agent[i]) }
            }
        }

        /// Independent oracle for the pairs auto-link may hold.
        var oracle: Set<RelayAutoLinkPair> {
            var result = Set<RelayAutoLinkPair>()
            for scope in scopes {
                let members = (0..<3).filter { i in
                    guard agent[i], let tab = placement[i] else { return false }
                    switch scope {
                    case .tab(let id): return tabs[tab] == id
                    case .workspace(let id): return workspace(ofTab: tab) == id
                    }
                }
                guard members.count <= limit else { continue }
                for a in members { for b in members where a < b { result.insert(RelayAutoLinkPair(panes[a], panes[b])!) } }
            }
            return result
        }
    }

    enum Failure: CaseIterable { case none, links, unlinks }

    enum Step: Hashable {
        case toggle(Int), place(Int, Int?), agent(Int), userLink(Int), userUnlink(Int), reconcile(Int)
    }

    static let steps: [Step] = scopes.indices.map { .toggle($0) }
        + (0..<3).flatMap { p in ([nil] + (0..<3).map { Optional($0) }).map { Step.place(p, $0) } }
        + (0..<3).map { .agent($0) } + (0..<3).map { .userLink($0) } + (0..<3).map { .userUnlink($0) }
        + Failure.allCases.indices.map { .reconcile($0) }

    /// Applies one step; returns a violated property name, or nil.
    static func apply(_ step: Step, to world: inout World) -> String? {
        switch step {
        case .toggle(let i):
            if world.scopes.remove(scopes[i]) == nil { world.scopes.insert(scopes[i]) }
        case .place(let p, let tab):
            world.placement[p] = tab
        case .agent(let p):
            world.agent[p].toggle()
        case .userLink(let i):
            // Mirrors RelayPaneMessaging.connect(automatic: false).
            world.state = RelayAutoLinkPolicy.disown(pairs[i], world.state)
            world.links[pairs[i]] = .manual
            world.userRemoved.remove(pairs[i])
        case .userUnlink(let i):
            if let origin = world.links.removeValue(forKey: pairs[i]), origin == .auto { world.userRemoved.insert(pairs[i]) }
        case .reconcile(let f):
            let failure = Failure.allCases[f]
            let wanted = world.oracle
            world.userRemoved.formIntersection(wanted)
            let plan = RelayAutoLinkPolicy.plan(scopes: world.scopes, panes: world.policyPanes,
                                                existing: Set(world.links.keys), state: world.state, limit: limit)
            var state = plan.state
            for pair in plan.unlink {
                if world.links[pair] == .manual { return "manual" }
                guard failure != .unlinks else { continue }
                world.links[pair] = nil
                state.owned.remove(pair)
            }
            for pair in plan.link {
                if !wanted.contains(pair) { return "scope" }
                if world.userRemoved.contains(pair) { return "user wins" }
                guard failure != .links else { continue }
                world.links[pair] = .auto
                state.owned.insert(pair)
            }
            world.state = state
            let auto = Set(world.links.filter { $0.value == .auto }.keys)
            if world.state.owned != auto { return "books" }
            if failure == .none {
                let missing = wanted.subtracting(world.links.keys).subtracting(world.userRemoved)
                if !missing.isEmpty || !auto.isSubset(of: wanted) { return "converge" }
            }
        }
        return nil
    }

    @Test("Auto-link safety holds for every bounded sequence")
    func exhaustive() {
        let depth = Int(ProcessInfo.processInfo.environment["AUTO_LINK_DEPTH"] ?? "") ?? 10
        let started = Date()
        var frontier: Set<World> = [World()]
        var seen: Set<World> = [World()]
        var transitions = 0
        for _ in 0..<depth {
            var next: Set<World> = []
            for world in frontier {
                for step in Self.steps {
                    var copy = world
                    transitions += 1
                    if let violation = Self.apply(step, to: &copy) {
                        Issue.record("\(violation) violated by \(step) from \(world)")
                        return
                    }
                    if seen.insert(copy).inserted { next.insert(copy) }
                }
            }
            frontier = next
        }
        print("auto-link model check: depth \(depth), \(seen.count) states, \(transitions) transitions, \(Int(Date().timeIntervalSince(started)))s")
        #expect(depth < 10 || seen.count > 100_000)
    }

    @Test("Scope and pair keys round-trip and reject anything else")
    func keys() {
        for scope in Self.scopes { #expect(RelayAutoLinkScope(key: scope.key) == scope) }
        for pair in Self.pairs { #expect(RelayAutoLinkPair(key: pair.key) == pair) }
        let id = "abcdef00-0000-4000-8000-00000000000a" // has letters, so uppercasing changes it
        for bad in ["", "tab", "tab:", "pane:" + id, "tab:" + id.uppercased(), "tab:" + id + ":x", "workspace: " + id, "session:" + id] {
            #expect(RelayAutoLinkScope(key: bad) == nil)
        }
        #expect(RelayAutoLinkPair(key: Self.pairs[0].second.uuidString.lowercased() + "+" + Self.pairs[0].first.uuidString.lowercased()) == nil)
        #expect(RelayAutoLinkPair(key: id + "+" + id) == nil)
        #expect(RelayAutoLinkPair(Self.panes[0], Self.panes[0]) == nil)
    }

    @Test("A scope over the cap is held whole, never partly linked")
    func capHolds() {
        let tab = Self.tabs[0], owner = Self.workspaces[0]
        let panes = (0..<9).map { _ in RelayAutoLinkPane(id: UUID(), tab: tab, workspace: owner, agent: true) }
        let plan = RelayAutoLinkPolicy.plan(scopes: [.tab(tab)], panes: panes, existing: [], state: .init())
        #expect(plan.link.isEmpty && plan.held[RelayAutoLinkScope.tab(tab).key]?.contains("9 agent panes") == true)
        let eight = RelayAutoLinkPolicy.plan(scopes: [.tab(tab)], panes: Array(panes.prefix(8)), existing: [], state: .init())
        #expect(eight.link.count == 28 && eight.held.isEmpty)
    }
}
