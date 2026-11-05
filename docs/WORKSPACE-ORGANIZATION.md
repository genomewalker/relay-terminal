# Workspace organization

The navigator has **Workspaces** and **Connections** tabs. Workspaces lets you
organize existing tabs into nested projects and tasks. Connections retains the
host and session controls. Moving a tab into a project changes its presentation;
its session owner, host, pane IDs and running conversations stay the same.

The overview shows each tab's split layout, floating panes and pane stacks.
Choose a tab title to open its canvas, or choose a pane miniature to focus that
pane. Previews read pane metadata and do not create terminal views or start
background panes. Back, Forward, Parent and the breadcrumb trail navigate the
same workspace tree. Selecting a tab or pane through an existing shortcut or MCP
tool leaves the overview, including when that ID was already selected.

## Groups and saved views

Use **New workspace** to create a project or task. A group's context menu can
create a child, rename it or ungroup it. Ungrouping moves its contents to its
parent. Drag tabs onto groups, or onto another tab in the navigator to place
them before it. Drag a group onto another group to nest it. Groups can contain
tabs from different hosts and sessions.

Expand a tab in the navigator to see its panes. Drag a pane onto a workspace
or task to give it a tab there; a single-pane tab is reused. The same pane,
runtime, draft and remote birth IDs are retained. Drop a pane onto a compatible
tab to tile it there, or onto another pane to stack it. Pane headers, stack tabs,
navigator rows and overview miniatures share the same drag payload. Workspace
and tab context menus provide explicit move actions as well.

**Sort** orders workspace names and tabs by name or by host then name. This is
a one-time reorder, so a later manual move remains where you put it.

**Pinned**, available in the navigation bar and the Workspace menu, gathers tab
and pane shortcuts from every project and host. Use its current-tab/current-pane
actions, a row's context menu, or drop a tab or pane onto Pinned. Opening a pinned
pane reveals its existing tab and any hidden stack member. Pins follow the same
IDs through regrouping and stacking; closing an item removes its shortcut.

**Saved views** captures the current navigation target, selected stack members,
collapsed groups and pane zoom. Applying a view changes presentation and skips
closed targets. It does not restart a provider or replay terminal input.

## Pane stacks

Drag a tiled pane's header into another tiled pane's centre to stack them.
The strip above the slot selects its visible member. Right-click a member to
reorder it, unstack it or close it. Edge drops keep the split layout behaviour.
A floating pane dropped in a tiled pane's centre docks beside it.

**Workspace → Stack active pane with…** provides a keyboard accessible chooser.
Choose a row, then select **Stack panes**. Moves between tabs require the same
connection session and must leave a pane in the source tab. Floating panes must
be docked before joining a stack. Bound R presentations are kept together.

Drafts, attachments and send state belong to the pane. Switching a stack member
or opening the overview keeps them alive. Uploads continue while a pane is
hidden; closing the pane cancels its uploads. An uncertain submission stays held
until you check the original terminal and explicitly enable sending again.
Enabling Send retains the draft and never submits it automatically.

## Default shortcuts

| Action | Shortcut |
| --- | --- |
| All workspaces | Control–Command–O |
| Back / Forward | Control–Command–Left / Right |
| Parent workspace | Control–Command–Up |
| Stack chooser | Control–Command–G |
| Unstack active pane | Control–Command–U |
| Previous / next stack member | Control–Command–[ / ] |
| Save current view | Control–Command–Shift–S |
| Open saved view | Control–Command–Shift–O |

These commands also appear in the Workspace menu and the shortcut preferences.

## Persistence and MCP

Existing sessions initially appear as session groups, retaining their tab order.
No projects or stacks are inferred. `organization-v2.json` stores groups,
placements and saved views under the workspace lock, with per-entity three-way
merges. The first v2 write preserves `workspace-v1.pre-v2-backup.json`.

`workspace-v1.json` continues to contain every pane in a legacy split layout.
Optional `visibleLayout` and `stacks` fields describe the stack presentation.
They are accepted only when their deterministic legacy projection exactly
matches `layout`; an older writer's layout edit therefore wins safely.

Pane snapshots also retain optional original workspace and tab IDs. Moving a
pane to a task creates its presentation tab in the pane's original session.
Restore and close/reopen use the saved birth IDs; a host catalog's verified
birth record takes precedence when available. Older snapshots fall back to
their tab membership. Partial or malformed birth IDs fail validation.

`relay_workspace_organization` reads the current tree, navigation and layouts,
including hidden stack members. Existing pane discovery retains canonical
session ownership. `relay_workspace_action` additionally accepts `overview`,
`back`, `forward` and `up` under the navigation grant. These actions use the
existing request ledger and report the resulting selected tab and pane IDs.
