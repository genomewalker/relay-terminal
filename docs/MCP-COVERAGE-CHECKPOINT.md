# MCP coverage checkpoint — 2026-09-22

User goal: operate Relay through MCP without computer automation.

Implemented and installed: WorkspaceControl.swift and its
authenticated HTTP routes, MCP workspace-action/receipt tools, pane backend and
close-behaviour metadata, MCP-WORKSPACE-CONTROL.md. Existing dirty work preserved.

Validation: `go test ./cmd/relay-mcp` passed. Swift targeted run passed all five
workspace/local-pane approval/model tests. Verified exact-target binding,
duplicate/conflicting IDs, stale instance, cancellation, stale target, splitting,
zoom/unzoom across selected panes, and protection of floating neighbours/editors.

Installed and relaunched on 2026-09-22: signature passed, 37 panes restored,
live control endpoint advertised workspace actions. Claude Desktop configured
and restarted; its logs confirm MCP initialization and tools/list completion.
No workspace mutation approval was exercised in the installed-app check.

Next increment implemented, tested, NOT installed: relay_read_editor reads a
bounded native mirror of the open editor including unsaved content, string
revision, document ID, dirty/diff/busy and truncation flags. Explicitly not a
synchronous Monaco read or a write precondition. UTF-8 boundary/UInt64 tests and
workspace regressions passed (four Swift tests); Go MCP suite passed.

Next bounded work:
1. Installed HTTP/MCP verification with a disposable pane, native user approval.
   Do not auto-click or bypass approval. Avoid killing legacy running shells in a
   restart merely to install; inspect and arrange a safe restart first.
2. Typed editor open/read/edit/save/recovery API with revision conflict checks.
3. R workspace activation, objects/tables/plots/help access through the same
   model services used by the UI, with scoped execution policy.
4. Plugin inventory/setup and profile selection APIs; enumerate capabilities.
5. Persistent worker lifecycle with distinct detach vs terminate semantics,
   exact session identity, and authorization separate from pane close.

Do not claim all features exposed or deployed. Existing tools already cover
discovery, input proposals, local tab creation, network proposals/status, and
bounded R setup/evaluation/snapshot reads. These still require the advertised
native approval policy. No arbitrary shell-command or kill endpoint was added.
