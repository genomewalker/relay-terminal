import Foundation

/// Metadata only: indexing never reads terminal transcripts or acknowledges alerts.
enum RelayWorkOverviewIndex {
    enum Group: Int, CaseIterable, Sendable {
        case attention, visited, current, actions, recent, other
        var title: String {
            switch self {
            case .attention: "Needs attention"
            case .visited: "Recent"
            case .current: "Current work"
            case .actions: "Settings and tools"
            case .recent: "Last recorded changes"
            case .other: "All work"
            }
        }
    }
    enum Destination: Equatable, Sendable {
        case workspace(UUID), tab(UUID), pane(UUID, UUID)
        case settings(String), controlCenter, askMiko, fleetBoard
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
        /// When the user last opened this pane, across all workspaces. Nil
        /// for the active pane: Recent lists where you can go back to.
        var lastVisitedAt: Date? = nil
        /// Decayed visit weight, from `PaneVisitHistory.frecency`.
        var frecency: Double = 0
        var isActivePane = false
        /// Set by `results` for the most recently visited panes.
        var listedAsRecent = false
        var group: Group {
            if needsAttention { return .attention }
            if listedAsRecent { return .visited }
            if isCurrent { return .current }
            switch destination {
            case .settings, .controlCenter, .askMiko, .fleetBoard: return .actions
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
        entries.append(Entry(id: "action:fleet", title: RelayCommand.fleetBoard.label, location: "Every pane on every host",
            status: "Open board", details: "List every pane by status: waiting on you, disconnected, running, idle. Opening it acknowledges nothing.",
            symbol: "rectangle.grid.1x2", destination: .fleetBoard,
            searchFields: ["fleet board agents running waiting disconnected idle hosts overview"],
            needsAttention: false, isCurrent: false, changedAt: nil))
        entries.append(Entry(id: "action:miko", title: "Ask Miko", location: "Workspace assistant",
            status: "Open composer", details: "Open Miko without sending a message. Your existing conversation and draft are preserved; enter your request in the composer.",
            symbol: "sparkles", destination: .askMiko, searchFields: ["assistant help", query],
            needsAttention: false, isCurrent: false, changedAt: nil))
        return entries
    }

    static let recentLimit = 8

    /// A pane's state in the shared vocabulary (`PaneDisplayState`). Agent
    /// approvals and a program's own report take precedence and say so.
    static func paneStatus(phase: AgentPhase, approvals: Int, programState: String?, programReportCurrent: Bool) -> String {
        if approvals > 0 {
            return PaneDisplayState.needsInput.label + " · \(approvals) approval" + (approvals == 1 ? "" : "s")
        }
        guard let programState else { return phase.label }
        return RelayProgramStatusBadge.label(for: programState) + " · program report" + (programReportCurrent ? "" : " (stale)")
    }

    struct Section: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    /// Without a query, the visible order is grouped and Recent lists the
    /// most recently visited panes (frecency breaks ties). With a query,
    /// one list ranked by match quality, then frecency.
    static func results(_ entries: [Entry], query: String) -> [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches = entries.filter { entry in
            let fields = [entry.title, entry.location, entry.status] + entry.searchFields
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }
        let recent = matches.indices
            .filter { matches[$0].lastVisitedAt != nil && !matches[$0].isActivePane && !matches[$0].needsAttention }
            .sorted { visitedBefore(matches[$0], matches[$1]) }
            .prefix(recentLimit)
        for index in matches.indices { matches[index].listedAsRecent = recent.contains(index) }
        let exactControl: (Entry) -> Bool = {
            $0.destination == .controlCenter && $0.title.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        return matches.sorted { lhs, rhs in
            if exactControl(lhs) != exactControl(rhs) { return exactControl(lhs) }
            if !terms.isEmpty {
                let quality = (matchQuality(lhs, query: trimmed, terms: terms), matchQuality(rhs, query: trimmed, terms: terms))
                if quality.0 != quality.1 { return quality.0 < quality.1 }
                if lhs.frecency != rhs.frecency { return lhs.frecency > rhs.frecency }
            }
            if lhs.group != rhs.group { return lhs.group.rawValue < rhs.group.rawValue }
            if lhs.group == .visited { return visitedBefore(lhs, rhs) }
            // Exact destinations should precede the general assistant fallback.
            if lhs.group == .actions, (lhs.destination == .askMiko) != (rhs.destination == .askMiko) {
                return rhs.destination == .askMiko
            }
            if lhs.changedAt != rhs.changedAt { return (lhs.changedAt ?? .distantPast) > (rhs.changedAt ?? .distantPast) }
            return titleOrder(lhs, rhs)
        }
    }

    /// Lower is better: exact title, title prefix, every word in the title,
    /// every word in title/location/status, then other metadata only.
    static func matchQuality(_ entry: Entry, query: String, terms: [String]) -> Int {
        let title = entry.title
        if title.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 0 }
        if title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 1 }
        if terms.allSatisfy({ title.localizedStandardContains($0) }) { return 2 }
        let visible = [title, entry.location, entry.status]
        if terms.allSatisfy({ term in visible.contains { $0.localizedStandardContains(term) } }) { return 3 }
        return 4
    }

    /// Display sections in `results` order, so arrow keys follow what is shown.
    static func sections(_ rows: [Entry], query: String) -> [Section] {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rows.isEmpty ? [] : [Section(title: "Best matches", entries: rows)]
        }
        return Group.allCases.compactMap { group in
            let members = rows.filter { $0.group == group }
            return members.isEmpty ? nil : Section(title: group.title, entries: members)
        }
    }

    private static func visitedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.lastVisitedAt != rhs.lastVisitedAt { return (lhs.lastVisitedAt ?? .distantPast) > (rhs.lastVisitedAt ?? .distantPast) }
        if lhs.frecency != rhs.frecency { return lhs.frecency > rhs.frecency }
        return titleOrder(lhs, rhs)
    }

    private static func titleOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let order = lhs.title.localizedStandardCompare(rhs.title)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    /// Without a query, Return goes back to the previously visited pane,
    /// like Command-Tab; otherwise to the best match.
    static func defaultSelectionID(in entries: [Entry], query: String) -> String? {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let previous = entries.first(where: { $0.group == .visited }) { return previous.id }
        return entries.first?.id
    }

    /// Stable identity prevents a live reorder from silently changing the Enter target.
    static func selectedID(_ selection: String?, in entries: [Entry], query: String = "") -> String? {
        selection.flatMap { id in entries.contains(where: { $0.id == id }) ? id : nil }
            ?? defaultSelectionID(in: entries, query: query)
    }
    static func movedSelection(_ selection: String?, by offset: Int, in entries: [Entry], query: String = "") -> String? {
        guard !entries.isEmpty else { return nil }
        let id = selectedID(selection, in: entries, query: query)
        let index = entries.firstIndex { $0.id == id } ?? 0
        return entries[min(max(index + offset, 0), entries.count - 1)].id
    }
}
