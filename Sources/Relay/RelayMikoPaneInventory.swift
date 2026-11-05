import Foundation

extension RelayAssistantSnapshot {
    /// A complete inventory can be traversed without flooding the model. UUID
    /// ordering keeps UI selection/reordering from changing page boundaries.
    func panePage(query: String?, offset: Int) -> [String: RelayPaneHealthJSON] {
        let needle = query?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let tabNames = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.name.lowercased()) })
        let matches = panes.filter { pane in
            needle.isEmpty ||
                [pane.title, pane.host, pane.kind, pane.connection, pane.account ?? ""]
                    .contains { $0.lowercased().contains(needle) } ||
                (tabNames[pane.tabID]?.contains(needle) ?? false) ||
                (needle.count >= 8 && (pane.id.uuidString.lowercased().hasPrefix(needle) || pane.tabID.uuidString.lowercased().hasPrefix(needle)))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        // Counts come from Relay's complete internal map, not from pages the
        // model must remember or aggregate across reasoning windows.
        struct Bucket: Hashable { let host: String; let kind: String; let account: String? }
        let buckets = Dictionary(grouping: panes) { Bucket(host: $0.hostAlias ?? $0.host, kind: $0.kind, account: $0.account) }
        let grouped = buckets.keys.sorted {
            ($0.host, $0.kind, $0.account ?? "") < ($1.host, $1.kind, $1.account ?? "")
        }.prefix(32).map { key -> RelayPaneHealthJSON in
            .object(["host": .string(key.host), "kind": .string(key.kind),
                "account": key.account.map(RelayPaneHealthJSON.string) ?? .null,
                "count": .integer(Int64(buckets[key]?.count ?? 0))])
        }
        let identity: RelayPaneHealthJSON = .array(panes.sorted { $0.id.uuidString < $1.id.uuidString }.map { pane in
            .object(["pane_id": .string(pane.id.uuidString.lowercased()), "tab_id": .string(pane.tabID.uuidString.lowercased()),
                "host": .string(pane.hostAlias ?? pane.host), "kind": .string(pane.kind),
                "account": pane.account.map(RelayPaneHealthJSON.string) ?? .null])
        })
        let inventoryID = RelayPaneHealthJSON.digest(identity)
        let summary: RelayPaneHealthJSON = .object(["source": .string("relay_workspace_map"),
            "pane_count": .integer(Int64(panes.count)), "tab_count": .integer(Int64(Set(panes.map(\.tabID)).count)),
            "by_host_kind_account": .array(grouped), "group_count": .integer(Int64(buckets.count)),
            "groups_truncated": .bool(buckets.count > 32),
            "note": .string("Account labels and cached activity are map metadata. Verify fresh native process/session ownership before acting.")])
        let start = min(max(0, offset), matches.count)
        var rows: [RelayPaneHealthJSON] = []
        var next = start
        func result() -> [String: RelayPaneHealthJSON] {
            ["inventory_id": .string(inventoryID), "inventory_summary": summary,
             "panes": .array(rows), "count": .integer(Int64(matches.count)),
             "offset": .integer(Int64(start)), "truncated": .bool(next < matches.count),
             "next_offset": next < matches.count ? .integer(Int64(next)) : .null]
        }
        while next < matches.count && rows.count < 32 {
            rows.append(paneJSON(matches[next]))
            next += 1
            // Tool results are limited to 8 KiB by the host. Leave room for
            // the envelope and keep valid JSON instead of clipping a page.
            if ((try? RelayPaneHealthJSON.data(RelayPaneHealthJSON.object(result())))?.count ?? Int.max) > 7_000 {
                rows.removeLast()
                next -= 1
                if rows.isEmpty {
                    return ["error": .string("One pane exceeds the page size; inspect its exact ID."),
                            "count": .integer(Int64(matches.count)), "offset": .integer(Int64(start))]
                }
                break
            }
        }
        return result()
    }
}
