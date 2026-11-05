import Foundation

/// A tab or a navigator workspace (WorkspaceOwnershipSnapshot, never the
/// legacy tab session) whose Claude/Codex panes the user asked Relay to keep
/// linked, or allowed to broadcast. Only the native UI sets scopes; no tool,
/// pane or agent message can.
enum RelayAutoLinkScope: Hashable, Sendable {
    case tab(UUID)
    case workspace(UUID)

    var key: String {
        switch self {
        case .tab(let id): "tab:" + id.uuidString.lowercased()
        case .workspace(let id): "workspace:" + id.uuidString.lowercased()
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]), parts[1] == id.uuidString.lowercased() else { return nil }
        switch parts[0] {
        case "tab": self = .tab(id)
        case "workspace": self = .workspace(id)
        default: return nil
        }
    }
}

struct RelayAutoLinkPair: Hashable, Sendable, Comparable {
    let first: UUID
    let second: UUID

    init?(_ a: UUID, _ b: UUID) {
        guard a != b else { return nil }
        (first, second) = a.uuidString < b.uuidString ? (a, b) : (b, a)
    }

    var key: String { first.uuidString.lowercased() + "+" + second.uuidString.lowercased() }

    init?(key: String) {
        let parts = key.split(separator: "+").map(String.init)
        guard parts.count == 2, let a = UUID(uuidString: parts[0]), let b = UUID(uuidString: parts[1]),
              let pair = RelayAutoLinkPair(a, b), pair.key == key else { return nil }
        self = pair
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.key < rhs.key }
}

struct RelayAutoLinkPane: Hashable, Sendable {
    let id: UUID
    let tab: UUID
    /// The tab's owning workspace; nil when ownership is unknown, and such a
    /// pane is in no workspace scope.
    let workspace: UUID?
    /// A Claude/Codex terminal pane; shells and editors are never linked.
    let agent: Bool
}

/// What auto-link owns. Pairs it created are `owned`; a pair the user removed
/// is `suppressed` and stays unlinked until its scope is turned off.
struct RelayAutoLinkState: Hashable, Sendable {
    var owned: Set<RelayAutoLinkPair> = []
    var suppressed: Set<RelayAutoLinkPair> = []
}

struct RelayAutoLinkPlan: Equatable, Sendable {
    var link: [RelayAutoLinkPair] = []
    var unlink: [RelayAutoLinkPair] = []
    var held: [String: String] = [:]
    /// The ownership to keep before applying `link` and `unlink`.
    var state = RelayAutoLinkState()
}

enum RelayAutoLinkPolicy {
    /// A scope with more agent panes is held, never partly linked: 8 panes
    /// already need 28 links.
    static let maxAgents = 8

    static func desired(scopes: Set<RelayAutoLinkScope>, panes: [RelayAutoLinkPane],
                        limit: Int = maxAgents) -> (pairs: Set<RelayAutoLinkPair>, held: [String: String]) {
        var pairs = Set<RelayAutoLinkPair>()
        var held: [String: String] = [:]
        for scope in scopes {
            let members = panes.filter { pane in
                guard pane.agent else { return false }
                switch scope {
                case .tab(let id): return pane.tab == id
                case .workspace(let id): return pane.workspace == id
                }
            }.map(\.id)
            guard members.count <= limit else {
                held[scope.key] = "\(members.count) agent panes; auto-link keeps at most \(limit) linked"
                continue
            }
            for (i, a) in members.enumerated() {
                for b in members[(i + 1)...] { if let pair = RelayAutoLinkPair(a, b) { pairs.insert(pair) } }
            }
        }
        return (pairs, held)
    }

    /// `existing` is every saved link now, whoever made it. Auto-link adds the
    /// desired pairs that are missing and not suppressed, and removes only pairs
    /// it owns that are no longer desired. A link someone else made is never
    /// removed; an owned link that disappeared was removed by the user, so it
    /// is suppressed rather than recreated.
    /// A link someone made by hand is theirs, even if auto-link made that
    /// pair before: auto-link stops owning it and stops suppressing it.
    static func disown(_ pair: RelayAutoLinkPair, _ state: RelayAutoLinkState) -> RelayAutoLinkState {
        var next = state
        next.owned.remove(pair)
        next.suppressed.remove(pair)
        return next
    }

    static func plan(scopes: Set<RelayAutoLinkScope>, panes: [RelayAutoLinkPane],
                     existing: Set<RelayAutoLinkPair>, state: RelayAutoLinkState,
                     limit: Int = maxAgents) -> RelayAutoLinkPlan {
        let (wanted, held) = desired(scopes: scopes, panes: panes, limit: limit)
        var next = state
        let vanished = next.owned.subtracting(existing)
        next.owned.subtract(vanished)
        next.suppressed.formUnion(vanished.intersection(wanted))
        next.suppressed.formIntersection(wanted)
        let unlink = next.owned.subtracting(wanted)
        let link = wanted.subtracting(existing).subtracting(next.suppressed)
        return RelayAutoLinkPlan(link: link.sorted(), unlink: unlink.sorted(), held: held, state: next)
    }
}

/// Applies the auto-link policy to the live workspace. It reconciles when the
/// user changes a scope and when the panes in an enabled scope change; it does
/// not poll links while nothing changed. Links go through the ordinary
/// RelayPaneMessaging connect/disconnect checks, one pair at a time.
@MainActor final class RelayAutoLinker: ObservableObject {
    static let shared = RelayAutoLinker()

    @Published private(set) var scopes: Set<RelayAutoLinkScope>
    /// Scopes where the user allowed relay_broadcast_message, apart from
    /// auto-link: a link is routing, not permission to fan out.
    @Published private(set) var broadcastScopes: Set<RelayAutoLinkScope>
    @Published private(set) var held: [String: String] = [:]
    @Published private(set) var lastError: String?

    private var state: RelayAutoLinkState
    private let defaults: UserDefaults
    private weak var workspace: WorkspaceModel?
    private var timer: Timer?
    private var inFlight: Task<Void, Never>?
    private var lastInputs: [RelayAutoLinkPane] = []
    /// After a failure, retry at most once a minute rather than every tick.
    private var retryAfter: Date?
    /// Tests replace these; production uses RelayPaneMessaging.
    var panesProvider: @MainActor (WorkspaceModel) -> [RelayAutoLinkPane] = RelayAutoLinker.panes
    var existingLinks: @MainActor (WorkspaceModel) async throws -> [RelayAutoLinkPair: String] = RelayAutoLinker.savedPairs
    var connect: @MainActor (RelayAutoLinkPair, WorkspaceModel) async throws -> Void = { pair, workspace in
        _ = try await RelayPaneMessaging.shared.connect(panes: [pair.first, pair.second], workspace: workspace, automatic: true)
    }
    var disconnect: @MainActor (String, WorkspaceModel) async throws -> Void = { id, workspace in
        _ = try await RelayPaneMessaging.shared.disconnect(linkID: id, workspace: workspace)
    }

    init(defaults: UserDefaults = RelayStateProfile.defaults) {
        self.defaults = defaults
        scopes = Set((defaults.stringArray(forKey: "relay.auto-link.scopes.v1") ?? []).compactMap(RelayAutoLinkScope.init(key:)))
        broadcastScopes = Set((defaults.stringArray(forKey: "relay.broadcast.scopes.v1") ?? []).compactMap(RelayAutoLinkScope.init(key:)))
        state = RelayAutoLinkState(
            owned: Set((defaults.stringArray(forKey: "relay.auto-link.owned.v1") ?? []).compactMap(RelayAutoLinkPair.init(key:))),
            suppressed: Set((defaults.stringArray(forKey: "relay.auto-link.suppressed.v1") ?? []).compactMap(RelayAutoLinkPair.init(key:))))
    }

    func isEnabled(_ scope: RelayAutoLinkScope) -> Bool { scopes.contains(scope) }

    /// Every link made through Relay other than by auto-link reports here.
    func noteManualLink(_ a: UUID, _ b: UUID) {
        guard let pair = RelayAutoLinkPair(a, b) else { return }
        state = RelayAutoLinkPolicy.disown(pair, state)
        save()
    }

    func allowsBroadcast(_ scope: RelayAutoLinkScope) -> Bool { broadcastScopes.contains(scope) }

    /// Native UI only: the user's own menu choice.
    func toggleBroadcast(_ scope: RelayAutoLinkScope) {
        if broadcastScopes.remove(scope) == nil { broadcastScopes.insert(scope) }
        save()
    }

    /// The broadcast scopes the user allowed for one tab, as /api/state
    /// reports them to relay-mcp.
    func broadcastGrants(tab: UUID, workspace: UUID?) -> [String] {
        (allowsBroadcast(.tab(tab)) ? ["tab"] : []) + (workspace.map { allowsBroadcast(.workspace($0)) } == true ? ["workspace"] : [])
    }

    /// Native UI only: the user's own menu choice.
    func toggle(_ scope: RelayAutoLinkScope, workspace: WorkspaceModel) {
        if scopes.remove(scope) == nil { scopes.insert(scope) }
        save()
        attach(workspace)
        Task { await reconcile() }
    }

    func attach(_ workspace: WorkspaceModel) {
        self.workspace = workspace
        guard timer == nil else { return }
        // Comparing pane facts is local and cheap; links are read only when they differ.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let workspace = self.workspace, !self.scopes.isEmpty || !self.state.owned.isEmpty else { return }
                let due = self.retryAfter.map { Date() >= $0 } ?? false
                if due || self.panesProvider(workspace) != self.lastInputs { await self.reconcile() }
            }
        }
    }

    static func panes(_ workspace: WorkspaceModel) -> [RelayAutoLinkPane] {
        workspace.tabs.flatMap { tab in
            tab.allPaneIDs.compactMap { id in
                workspace.panes[id].map { pane in
                    RelayAutoLinkPane(id: id, tab: tab.id, workspace: workspace.workspaceID(forTab: tab.id),
                                      agent: pane.contentKind == .terminal && (pane.kind == .claude || pane.kind == .codex))
                }
            }
        }
    }

    static func savedPairs(_ workspace: WorkspaceModel) async throws -> [RelayAutoLinkPair: String] {
        var result: [RelayAutoLinkPair: String] = [:]
        for link in try await RelayPaneMessaging.shared.savedLinks(workspace: workspace) {
            guard let id = link["id"] as? String, let members = link["members"] as? [[String: Any]], members.count == 2,
                  let a = (members[0]["paneID"] as? String).flatMap(UUID.init(uuidString:)),
                  let b = (members[1]["paneID"] as? String).flatMap(UUID.init(uuidString:)),
                  let pair = RelayAutoLinkPair(a, b) else { continue }
            result[pair] = id
        }
        return result
    }

    /// Runs one full pass after any pass already in flight, so passes never
    /// overlap and every caller observes a pass that started after its call.
    func reconcile() async {
        let previous = inFlight
        let task = Task { await previous?.value; await reconcileOnce() }
        inFlight = task
        await task.value
    }

    private func reconcileOnce() async {
        guard let workspace else { return }
        let panes = panesProvider(workspace)
        do {
            let existing = try await existingLinks(workspace)
            let plan = RelayAutoLinkPolicy.plan(scopes: scopes, panes: panes, existing: Set(existing.keys), state: state)
            state = plan.state
            var failures: [String] = []
            for pair in plan.unlink {
                guard let id = existing[pair] else { state.owned.remove(pair); continue }
                do { try await disconnect(id, workspace); state.owned.remove(pair) }
                catch { failures.append(error.localizedDescription) }
            }
            for pair in plan.link {
                do { try await connect(pair, workspace); state.owned.insert(pair) }
                catch { failures.append(error.localizedDescription) }
            }
            held = plan.held
            lastError = failures.first.map { "\(failures.count) auto-link change(s) failed; first: " + String($0.prefix(200)) }
            lastInputs = panes
            retryAfter = failures.isEmpty ? nil : Date().addingTimeInterval(60)
        } catch {
            lastError = "Saved links unavailable: " + String(error.localizedDescription.prefix(200))
            lastInputs = panes
            retryAfter = Date().addingTimeInterval(60)
        }
        save()
    }

    private func save() {
        defaults.set(scopes.map(\.key).sorted(), forKey: "relay.auto-link.scopes.v1")
        defaults.set(broadcastScopes.map(\.key).sorted(), forKey: "relay.broadcast.scopes.v1")
        defaults.set(state.owned.map(\.key).sorted(), forKey: "relay.auto-link.owned.v1")
        defaults.set(state.suppressed.map(\.key).sorted(), forKey: "relay.auto-link.suppressed.v1")
    }

    var ownedForTesting: RelayAutoLinkState { state }
}
