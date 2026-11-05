import Foundation

extension WorkspaceModel {
    /// Schema 3. The canonical structure is ownership: `workspaces` (each
    /// workspace's tabs, in order) and `navigation.breadcrumbs` (all ›
    /// workspace › tab › pane), the same records the UI bar and
    /// relay_list_panes use. The legacy organization group projection is
    /// presentation metadata only, under `legacy_group_outline` and
    /// `navigation.group_breadcrumbs`; it can disagree with ownership (a tab
    /// is filed by its owner, while its legacy group is still its birth
    /// session) and must not be used to plan moves.
    func workspaceOrganizationControlState() throws -> [String: Any] {
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: encoder.encode(value))
        }
        let target = organizationTargetJSON
        func outline(_ node: WorkspaceOutlineNode) -> [String: Any] {
            switch node {
            case let .group(group, children):
                ["kind": "group", "id": group.id.uuidString.lowercased(), "name": group.name,
                 "collapsed": group.collapsed, "children": children.map(outline)]
            case let .ungrouped(children):
                ["kind": "ungrouped", "children": children.map(outline)]
            case let .tab(id):
                ["kind": "tab", "id": id.uuidString.lowercased()]
            }
        }
        func id(_ value: UUID) -> String { value.uuidString.lowercased() }
        var navigation = target(organization.current)
        navigation["can_go_back"] = organization.canGoBack
        navigation["can_go_forward"] = organization.canGoForward
        navigation["breadcrumbs"] = ownershipBreadcrumbs(for: organization.current)
        navigation["group_breadcrumbs"] = organization.breadcrumb(for: organization.current).map(target)
        let layouts: [[String: Any]] = try tabs.map { tab in
            ["id": tab.id.uuidString.lowercased(),
             "workspace_id": workspaceID(forTab: tab.id).map(id) as Any,
             "session_id": tab.sessionID.uuidString.lowercased(),
             "visible_layout": try json(tab.layout),
             "stacks": try json(tab.stacks),
             "floating_panes": try json(tab.floatingPanes),
             "pane_ids": tab.allPaneIDs.map { $0.uuidString.lowercased() }]
        }
        let workspaces: [[String: Any]] = ownership.orderedWorkspaces.map { record in
            ["id": id(record.id), "name": record.name, "is_inbox": record.isInbox,
             "tab_ids": ownership.tabIDs(in: record.id).map(id)]
        }
        return ["schema_version": 3,
                "canonical_structure": "workspaces",
                "workspaces": workspaces,
                "organization": try json(organization.snapshot),
                "legacy_group_outline": organization.outline().map(outline),
                "navigation": navigation,
                "tabs": layouts]
    }

    func organizationTargetJSON(_ value: WorkspaceNavigationTarget) -> [String: Any] {
        var result: [String: Any] = ["title": organization.title(for: value)]
        switch value {
        case .all: result["kind"] = "all"
        case let .group(id): result["kind"] = "group"; result["id"] = id.uuidString.lowercased()
        case let .tab(id): result["kind"] = "tab"; result["id"] = id.uuidString.lowercased()
        case let .pane(id): result["kind"] = "pane"; result["id"] = id.uuidString.lowercased()
        }
        return result
    }

    /// all › workspace › tab › pane, from ownership records only: the same
    /// source as the UI bar. A legacy-only group has no ownership position
    /// and is reported as itself under All.
    func ownershipBreadcrumbs(for value: WorkspaceNavigationTarget) -> [[String: Any]] {
        func workspaceCrumb(_ workspaceID: UUID) -> [String: Any]? {
            ownership.workspace(workspaceID).map { ["kind": "workspace", "id": $0.id.uuidString.lowercased(), "title": $0.name] }
        }
        let all = organizationTargetJSON(.all)
        switch value {
        case .all:
            return [all]
        case let .group(groupID):
            return [all, workspaceCrumb(groupID) ?? organizationTargetJSON(value)]
        case let .tab(tabID):
            return [all] + [workspaceID(forTab: tabID).flatMap(workspaceCrumb)].compactMap { $0 } + [organizationTargetJSON(value)]
        case let .pane(paneID):
            guard let tab = tabs.first(where: { $0.allPaneIDs.contains(paneID) }) else { return [all, organizationTargetJSON(value)] }
            return [all] + [workspaceID(forTab: tab.id).flatMap(workspaceCrumb)].compactMap { $0 }
                + [organizationTargetJSON(.tab(tab.id)), organizationTargetJSON(value)]
        }
    }
}
