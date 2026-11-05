import Foundation

/// Native owner review. A confirmation consumes exactly the records displayed;
/// records added later and panes reattached since review cannot be removed.
struct DetachedPaneLinkCleanup {
    private(set) var reviewed: [PaneLinkMembership]?

    static func candidates(_ links: [PaneLinkMembership], attached: Set<UUID>) -> [PaneLinkMembership] {
        var seen: Set<String> = []
        return links.filter {
            $0.paneIDs.count == 2 && Set($0.paneIDs).count == 2
                && !$0.paneIDs.allSatisfy(attached.contains) && seen.insert($0.id).inserted
        }
    }

    mutating func review(_ links: [PaneLinkMembership], attached: Set<UUID>) {
        reviewed = Self.candidates(links, attached: attached)
    }

    mutating func cancel() { reviewed = nil }

    mutating func confirm(current: [PaneLinkMembership], attached: Set<UUID>) -> [PaneLinkMembership] {
        guard let reviewed else { return [] }
        self.reviewed = nil
        return reviewed.filter { Self.canRemove($0, current: current, attached: attached) }
    }

    static func canRemove(_ approved: PaneLinkMembership, current: [PaneLinkMembership], attached: Set<UUID>) -> Bool {
        // Same identity and endpoint pair must still be present. Availability
        // flags describe transport, not whether a pane is attached in Relay.
        let matches = current.filter { $0.id == approved.id }
        return matches.count == 1
            && Set(matches[0].paneIDs) == Set(approved.paneIDs)
            && candidates([approved], attached: attached).count == 1
    }
}
