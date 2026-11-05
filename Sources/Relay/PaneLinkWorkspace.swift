import Foundation

struct PaneLinkTarget: Identifiable {
    let id: UUID
    let name: String
    let context: String
}

enum PaneLinkLabel {
    static func make(provider: String, tab: String, customName: String?, ordinal: Int?) -> String {
        if let name = customName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(name.prefix(70))
        }
        let base = provider + " · " + String(tab.prefix(48))
        return ordinal.map { base + " · Pane " + String($0) } ?? base
    }
}

@MainActor extension WorkspaceModel {
    func paneLinkLabel(for id: UUID) -> String {
        guard let pane = panes[id] else { return "Unavailable pane" }
        guard let tab = tabs.first(where: { $0.allPaneIDs.contains(id) }) else {
            return String(pane.displayName.prefix(70))
        }
        let sameProvider = tab.allPaneIDs.filter { panes[$0]?.detector.kind == pane.detector.kind }
        let ordinal = sameProvider.count > 1 ? sameProvider.firstIndex(of: id).map { $0 + 1 } : nil
        return PaneLinkLabel.make(provider: pane.harnessLabel, tab: tab.name,
            customName: pane.customName, ordinal: ordinal)
    }
    func paneLinkTargets(excluding ids: Set<UUID>) -> [PaneLinkTarget] {
        var seen: Set<UUID> = []
        return tabs.sorted { $0.id == selectedTabID && $1.id != selectedTabID }.flatMap { tab in
            tab.allPaneIDs.compactMap { id -> PaneLinkTarget? in
                guard !ids.contains(id), seen.insert(id).inserted,
                      let pane = panes[id], pane.contentKind == .terminal else { return nil }
                let session = sessionDisplayName(tab.sessionID, fallback: pane.profile.name)
                return PaneLinkTarget(id: id, name: paneLinkLabel(for: id),
                    context: session + " / " + tab.name + " / " + String(id.uuidString.prefix(6)).lowercased())
            }
        }
    }
    func refreshPaneLinkMemberships() {
        let selection = paneLinkSelection
        guard !selection.refreshingLinks else { return }
        selection.refreshingLinks = true
        let revision = selection.membershipRevision
        Task { @MainActor [weak self] in
            defer { selection.refreshingLinks = false }
            guard let self else { return }
            do {
                let rows = try await RelayPaneMessaging.shared.savedLinks(workspace: self)
                // Prefer daemon records; retain legacy membership only when its
                // pane pair has no daemon record. None of these proves liveness.
                var links: [PaneLinkMembership] = []
                var pairs: Set<Set<UUID>> = []
                let ordered = rows.sorted { ($0["authority"] as? String == "relayd") && ($1["authority"] as? String != "relayd") }
                for row in ordered {
                    guard let link = PaneLinkMembership(record: row),
                          link.paneIDs.allSatisfy({ self.panes[$0] != nil }), pairs.insert(Set(link.paneIDs)).inserted else { continue }
                    links.append(link)
                }
                selection.replaceMemberships(links, ifRevision: revision, allSaved: rows.compactMap(PaneLinkMembership.init(record:)))
            } catch { selection.linkManagementError = "Saved links could not be loaded. Try Refresh." }
        }
    }
    func removePaneLink(_ id: String) {
        guard paneLinkSelection.removingLinkIDs.insert(id).inserted else { return }
        paneLinkSelection.linkManagementError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { paneLinkSelection.removingLinkIDs.remove(id) }
            do {
                let result = try await RelayPaneMessaging.shared.disconnect(linkID: id, workspace: self)
                guard ["retired", "not_found"].contains(result["status"] ?? "") else {
                    throw RemoteCatalogError.failed("The link could not be removed. Refresh to check its state.")
                }
                paneLinkSelection.forgetMembership(id)
            } catch { paneLinkSelection.linkManagementError = error.localizedDescription }
        }
    }
}

@MainActor extension WorkspaceModel {
    private var attachedLinkPaneIDs: Set<UUID> {
        Set(tabs.flatMap(\.allPaneIDs)).intersection(Set(panes.keys))
    }

    func reviewDetachedPaneLinks() {
        guard !paneLinkSelection.cleanupRunning else { return }
        paneLinkSelection.cleanupResult = nil
        paneLinkSelection.cleanup.review(paneLinkSelection.allSavedMemberships, attached: attachedLinkPaneIDs)
    }

    func confirmDetachedPaneLinks() {
        let selection = paneLinkSelection
        guard !selection.cleanupRunning else { return }
        let approved = selection.cleanup.confirm(current: selection.allSavedMemberships, attached: attachedLinkPaneIDs)
        guard !approved.isEmpty else { selection.cleanupResult = "No detached-pane links to remove."; return }
        selection.cleanupRunning = true
        selection.linkManagementError = nil
        Task { @MainActor [weak self] in
            defer { selection.cleanupRunning = false }
            guard let self else { return }
            var removed = 0
            var skipped = 0
            do {
                for link in approved {
                    let rows = try await RelayPaneMessaging.shared.savedLinks(workspace: self)
                    let current = rows.compactMap(PaneLinkMembership.init(record:))
                    guard DetachedPaneLinkCleanup.canRemove(link, current: current, attached: self.attachedLinkPaneIDs) else {
                        skipped += 1; continue
                    }
                    let result = try await RelayPaneMessaging.shared.disconnect(linkID: link.id, workspace: self, beforeRetire: {
                        guard DetachedPaneLinkCleanup.canRemove(link, current: current, attached: self.attachedLinkPaneIDs) else {
                            throw RemoteCatalogError.failed("A pane was reattached. Review the remaining links again.")
                        }
                    })
                    guard ["retired", "not_found"].contains(result["status"] ?? "") else {
                        throw RemoteCatalogError.failed("Removal was not confirmed. Refresh before trying again.")
                    }
                    selection.forgetMembership(link.id)
                    if result["status"] == "retired" { removed += 1 } else { skipped += 1 }
                }
                selection.cleanupResult = "Removed \(removed) links. Skipped \(skipped) links after rechecking."
            } catch {
                selection.linkManagementError = "Removed \(removed) links, then stopped: " + error.localizedDescription
            }
            self.refreshPaneLinkMemberships()
        }
    }
}
