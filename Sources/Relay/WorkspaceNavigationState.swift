import Foundation

struct WorkspaceNavigationState: Codable {
    enum Group: String { case session, tab }
    /// Sidebar order: as arranged, or by recency-weighted use.
    enum SortMode: String, Codable, CaseIterable { case manual, mostUsed }
    /// Use decays by half every `usageHalfLife`; each selection adds one.
    struct Usage: Codable, Equatable {
        var score: Double
        var at: Date
    }
    static let usageHalfLife: TimeInterval = 3 * 86_400
    static let usageLimit = 512

    private(set) var expandedGroups: [String: Bool] = [:]
    private(set) var lastSelectedTabs: [String: UUID] = [:]
    // Optional so state saved by earlier builds still decodes.
    private var usage: [String: Usage]?
    private var sort: SortMode?
    var sortMode: SortMode {
        get { sort ?? .manual }
        set { sort = newValue }
    }
    /// Workspaces navigator order: as arranged, or needing attention, then
    /// most recently used. Separate from `sortMode`, which is the
    /// Connections list.
    enum NavigatorSort: String, Codable, CaseIterable { case attention, manual }
    private var navigatorSort: NavigatorSort?
    var navigatorSortMode: NavigatorSort {
        get { navigatorSort ?? .attention }
        set { navigatorSort = newValue }
    }
    /// Only the user's click collapses or expands the inbox; new rows never do.
    private var attentionInboxCollapsed: Bool?
    var isAttentionInboxCollapsed: Bool {
        get { attentionInboxCollapsed == true }
        set { attentionInboxCollapsed = newValue }
    }
    /// The workspace the window shows; independent of the selected tab, so
    /// an empty workspace can be shown and a moved tab never drags it along.
    var visibleWorkspace: UUID?

    func isExpanded(_ group: Group, id: UUID) -> Bool {
        expandedGroups[key(group, id)] ?? false
    }

    mutating func toggle(_ group: Group, id: UUID) {
        expandedGroups[key(group, id)] = !isExpanded(group, id: id)
    }

    /// Collapse or expand all: every listed group gets the same state.
    mutating func setExpanded(_ group: Group, ids: [UUID], expanded: Bool) {
        for id in ids { expandedGroups[key(group, id)] = expanded }
    }

    /// Expand all or collapse all: every tab and every session that owns one.
    mutating func setAllExpanded(tabs: [(id: UUID, sessionID: UUID)], expanded: Bool) {
        var sessions: [UUID] = []
        for tab in tabs where !sessions.contains(tab.sessionID) { sessions.append(tab.sessionID) }
        setExpanded(.session, ids: sessions, expanded: expanded)
        setExpanded(.tab, ids: tabs.map(\.id), expanded: expanded)
    }

    /// When the row was last selected, if it was.
    func lastUse(_ group: Group, id: UUID) -> Date? { usage?[key(group, id)]?.at }

    func usageScore(_ group: Group, id: UUID, now: Date = Date()) -> Double {
        guard let entry = usage?[key(group, id)] else { return 0 }
        return Self.decayed(entry, now: now)
    }

    mutating func noteUse(_ group: Group, id: UUID, now: Date = Date()) {
        noteUse([(group, id)], now: now)
    }

    /// Notes several rows used together, such as a tab and its session.
    mutating func noteUse(_ rows: [(Group, UUID)], now: Date = Date()) {
        var entries = usage ?? [:]
        var fresh: [String: Usage] = [:]
        for (group, id) in rows {
            let name = key(group, id)
            fresh[name] = Usage(score: (entries[name].map { Self.decayed($0, now: now) } ?? 0) + 1, at: now)
        }
        entries.merge(fresh) { _, new in new }
        if entries.count > Self.usageLimit {
            // Forget the least used, so the stored state stays small; rows
            // just used always stay, or recent-use order would lose them.
            let kept = entries.filter { fresh[$0.key] == nil }
                .sorted { Self.decayed($0.value, now: now) > Self.decayed($1.value, now: now) }
                .prefix(max(Self.usageLimit - fresh.count, 0))
            entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
            entries.merge(fresh) { _, new in new }
        }
        usage = entries
    }

    /// Sidebar order for one level: pinned rows first, each part kept as
    /// arranged or, in most-used mode, by decayed use (ties keep arrangement).
    func ordered(_ group: Group, ids: [UUID], pinned: (UUID) -> Bool, now: Date = Date()) -> [UUID] {
        func arrange(_ part: [UUID]) -> [UUID] {
            guard sortMode == .mostUsed else { return part }
            let scores = part.map { usageScore(group, id: $0, now: now) }
            return part.indices.sorted { (scores[$0], -$0) > (scores[$1], -$1) }.map { part[$0] }
        }
        return arrange(ids.filter(pinned)) + arrange(ids.filter { !pinned($0) })
    }

    private static func decayed(_ entry: Usage, now: Date) -> Double {
        entry.score * pow(0.5, max(0, now.timeIntervalSince(entry.at)) / usageHalfLife)
    }

    mutating func remember(tabID: UUID, sessionID: UUID) {
        lastSelectedTabs[sessionID.uuidString] = tabID
    }

    func preferredTab(in sessionID: UUID, available: [UUID]) -> UUID? {
        if let remembered = lastSelectedTabs[sessionID.uuidString], available.contains(remembered) {
            return remembered
        }
        return available.first
    }

    static func adjacentTab(current: UUID?, ordered: [UUID], offset: Int) -> UUID? {
        guard !ordered.isEmpty else { return nil }
        let index = current.flatMap { ordered.firstIndex(of: $0) } ?? 0
        let step = offset % ordered.count
        return ordered[(index + step + ordered.count) % ordered.count]
    }

    static func load(defaults: UserDefaults = RelayStateProfile.defaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return state
    }

    static func updating(defaults: UserDefaults = RelayStateProfile.defaults, _ change: (inout Self) -> Void) -> Self {
        var state = load(defaults: defaults)
        change(&state)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: storageKey) }
        return state
    }

    private static let storageKey = "relay.workspace.navigation-state.v1"
    private func key(_ group: Group, _ id: UUID) -> String { group.rawValue + ":" + id.uuidString }
}
