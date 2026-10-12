import Foundation

struct WorkspaceNavigationState: Codable {
    enum Group: String { case session, tab }
    private(set) var expandedGroups: [String: Bool] = [:]
    private(set) var lastSelectedTabs: [String: UUID] = [:]

    func isExpanded(_ group: Group, id: UUID) -> Bool {
        expandedGroups[key(group, id)] ?? false
    }

    mutating func toggle(_ group: Group, id: UUID) {
        expandedGroups[key(group, id)] = !isExpanded(group, id: id)
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

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return state
    }

    static func updating(defaults: UserDefaults = .standard, _ change: (inout Self) -> Void) -> Self {
        var state = load(defaults: defaults)
        change(&state)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: storageKey) }
        return state
    }

    private static let storageKey = "relay.workspace.navigation-state.v1"
    private func key(_ group: Group, _ id: UUID) -> String { group.rawValue + ":" + id.uuidString }
}
