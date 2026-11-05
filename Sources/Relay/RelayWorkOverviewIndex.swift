import Foundation

/// Metadata only: indexing never reads terminal transcripts or acknowledges alerts.
enum RelayWorkOverviewIndex {
    enum Group: Int, CaseIterable, Sendable {
        case attention, current, actions, recent, other
        var title: String {
            switch self {
            case .attention: "Needs attention"
            case .current: "Current work"
            case .actions: "Settings and tools"
            case .recent: "Last recorded changes"
            case .other: "All work"
            }
        }
    }
    enum Destination: Equatable, Sendable {
        case workspace(UUID), tab(UUID), pane(UUID, UUID)
        case settings(String), controlCenter, askMiko
    }
    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
        let location: String
        let status: String
        let details: String
        let symbol: String
        let destination: Destination
        let searchFields: [String]
        let needsAttention: Bool
        let isCurrent: Bool
        /// Timestamped activity records only. Pane creation time is not output evidence.
        let changedAt: Date?
        var group: Group {
            if needsAttention { return .attention }
            if isCurrent { return .current }
            switch destination {
            case .settings, .controlCenter, .askMiko: return .actions
            default: break
            }
            return changedAt == nil ? .other : .recent
        }
    }
    /// Public navigation metadata only. Selecting a destination opens controls;
    /// neither indexing nor filtering executes a setting or assistant request.
    static func navigationEntries(query: String) -> [Entry] {
        var entries = RelaySettingsSearch.sections.map { section in
            Entry(id: "settings:" + section.id, title: section.title + " settings",
                  location: "Settings · This Mac", status: "Open settings",
                  details: "Open the \(section.title) section in native Settings. No setting changes until you use its controls.",
                  symbol: section.icon, destination: .settings(section.id),
                  searchFields: ["configure configuration preferences change set settings", RelaySettingsSearch.keywords(for: section.id)],
                  needsAttention: false, isCurrent: false, changedAt: nil)
        }
        entries.append(Entry(id: "action:control", title: "Control Center", location: "Monitoring · Control",
            status: "Open controls", details: "Inspect Miko status, approvals and available controls. Actions retain their existing review and permission checks.",
            symbol: "slider.horizontal.3", destination: .controlCenter,
            searchFields: ["control center monitoring miko approvals tasks pause shepherd supervision"],
            needsAttention: false, isCurrent: false, changedAt: nil))
        entries.append(Entry(id: "action:miko", title: "Ask Miko", location: "Workspace assistant",
            status: "Open composer", details: "Open Miko without sending a message. Your existing conversation and draft are preserved; enter your request in the composer.",
            symbol: "sparkles", destination: .askMiko, searchFields: ["assistant help", query],
            needsAttention: false, isCurrent: false, changedAt: nil))
        return entries
    }

    static func results(_ entries: [Entry], query: String) -> [Entry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            let fields = [entry.title, entry.location, entry.status] + entry.searchFields
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }.sorted { lhs, rhs in
            let exactControl: (Entry) -> Bool = {
                $0.destination == .controlCenter &&
                $0.title.caseInsensitiveCompare(query.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
            if exactControl(lhs) != exactControl(rhs) { return exactControl(lhs) }
            if lhs.group != rhs.group { return lhs.group.rawValue < rhs.group.rawValue }
            // Exact destinations should precede the general assistant fallback.
            if lhs.group == .actions, (lhs.destination == .askMiko) != (rhs.destination == .askMiko) {
                return rhs.destination == .askMiko
            }
            if lhs.changedAt != rhs.changedAt { return (lhs.changedAt ?? .distantPast) > (rhs.changedAt ?? .distantPast) }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
    /// Stable identity prevents a live reorder from silently changing the Enter target.
    static func selectedID(_ selection: String?, in entries: [Entry]) -> String? {
        selection.flatMap { id in entries.contains(where: { $0.id == id }) ? id : nil } ?? entries.first?.id
    }
    static func movedSelection(_ selection: String?, by offset: Int, in entries: [Entry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let id = selectedID(selection, in: entries)
        let index = entries.firstIndex { $0.id == id } ?? 0
        return entries[min(max(index + offset, 0), entries.count - 1)].id
    }
}
