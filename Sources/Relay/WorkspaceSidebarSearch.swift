import Foundation

/// One sidebar search result: a tab, or one of its panes.
struct WorkspaceSidebarSearchHit: Identifiable {
    let id: String
    let tab: TabModel
    let pane: PaneModel?
    let detail: String
}

extension WorkspaceModel {
    /// Sidebar search over tab, session and pane names, IDs (full or partial,
    /// any case), hosts, paths, and the visible text of connected panes.
    func sidebarSearch(_ rawQuery: String, limit: Int = 100) -> [WorkspaceSidebarSearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let needle = query.lowercased()
        func matches(_ fields: [String]) -> Bool {
            fields.contains { $0.localizedStandardContains(query) }
        }

        var hits: [WorkspaceSidebarSearchHit] = []
        for tab in tabs {
            // Past `limit` results only IDs are still matched (no pane text
            // is read), so an ID listed first below is never cut off.
            if hits.count >= limit {
                if tab.id.uuidString.localizedStandardContains(query) {
                    hits.append(WorkspaceSidebarSearchHit(
                        id: "\(tab.id.uuidString):tab", tab: tab, pane: nil,
                        detail: "Tab ID · \(tab.id.uuidString.lowercased())"
                    ))
                }
                for paneID in paneIDs(inTab: tab.id) where paneID.uuidString.localizedStandardContains(query) {
                    guard let pane = panes[paneID] else { continue }
                    hits.append(WorkspaceSidebarSearchHit(
                        id: "\(tab.id.uuidString):\(paneID.uuidString)", tab: tab, pane: pane,
                        detail: "\(pane.displayName) · Pane ID · \(paneID.uuidString.lowercased())"
                    ))
                }
                continue
            }
            let sessionName = sessionDisplayName(tab.sessionID, fallback: tab.name)
            let tabMatches = matches([tab.name, tab.id.uuidString, tab.sessionID.uuidString, sessionName])
            if tabMatches {
                hits.append(WorkspaceSidebarSearchHit(
                    id: "\(tab.id.uuidString):tab", tab: tab, pane: nil,
                    detail: "Session · \(sessionName) · Tab ID · \(tab.id.uuidString.lowercased())"
                ))
            }
            for paneID in paneIDs(inTab: tab.id) {
                guard let pane = panes[paneID] else { continue }
                let location = [pane.directory, pane.editorRuntime.directoryPath,
                                pane.editorRuntime.workspacePath, pane.editorRuntime.currentPath]
                    .compactMap { $0 }
                let metadataMatches = matches([
                    pane.id.uuidString, pane.displayName, pane.title, pane.profile.name,
                    pane.profile.host, pane.profile.user, pane.profile.destination,
                    pane.profile.connectionKey, pane.activitySummary, pane.phase.rawValue,
                    pane.contentKind.rawValue
                ] + location)

                var textExcerpt: String?
                if needle.count >= 2 {
                    var content: String?
                    if pane.contentKind == .terminal, pane.connectionState == .connected {
                        content = pane.runtime.sidePanelViewportText()
                    } else if pane.contentKind == .editor {
                        content = pane.editorRuntime.controlSnapshot().content
                    }
                    if !pane.recentConversationContext.isEmpty {
                        content = [content, pane.recentConversationContext.joined(separator: "\n")]
                            .compactMap { $0 }.joined(separator: "\n")
                    }
                    if let content,
                       let line = content.split(whereSeparator: \.isNewline)
                        .map(String.init).first(where: { $0.localizedStandardContains(query) }) {
                        let compact = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if compact.count > 100, let range = compact.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
                            let start = compact.index(range.lowerBound, offsetBy: -min(36, compact.distance(from: compact.startIndex, to: range.lowerBound)), limitedBy: compact.startIndex) ?? compact.startIndex
                            let end = compact.index(range.upperBound, offsetBy: min(48, compact.distance(from: range.upperBound, to: compact.endIndex)), limitedBy: compact.endIndex) ?? compact.endIndex
                            textExcerpt = "…\(compact[start..<end])…"
                        } else {
                            textExcerpt = String(compact.prefix(100))
                        }
                    }
                }

                guard metadataMatches || textExcerpt != nil else { continue }
                let detail: String
                if let textExcerpt {
                    detail = "Text · \(pane.displayName) · \(textExcerpt)"
                } else if !location.isEmpty {
                    detail = "\(pane.displayName) · \(location.joined(separator: " · "))"
                } else {
                    detail = "\(pane.displayName) · \(pane.profile.name) · Pane ID · \(pane.id.uuidString.lowercased())"
                }
                hits.append(WorkspaceSidebarSearchHit(id: "\(tab.id.uuidString):\(pane.id.uuidString)", tab: tab, pane: pane, detail: detail))
            }
        }
        // An ID typed or pasted in full or in part lists its own tab or pane first.
        let idMatches = { (hit: WorkspaceSidebarSearchHit) in
            (hit.pane?.id ?? hit.tab.id).uuidString.localizedStandardContains(query)
        }
        return hits.filter(idMatches) + hits.filter { !idMatches($0) }
    }

}
