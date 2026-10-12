# Pro contract migration — 22 September 2026

Authority: WORKSPACE-DESIGN.md. This is implementation tracking, not a new
design or a claim of complete acceptance.

| Area | Current evidence | Next acceptance gate |
| --- | --- | --- |
| Network destination and pane-first links | Implemented; previous scoped UI checks recorded in contract | Full navigation/focus/100-cycle acceptance |
| Shared icon actions | R actions plus plugin secondary actions in source | Installed normal/narrow widths, keyboard and VoiceOver |
| Plugin manager | Seven manifests pass isolated install/enable/revoke tests | Installed workflow for every plugin; permission revocation while open |
| Context dock | Target architecture documented, not consolidated | Files/Artifacts/Transfers then Changes, retaining old entry points during QA |
| R workspace | Layout/process preservation component tests pass | Full local and dandy-07 workflow, plots/objects/help and editing |
| Workspace grouping | Existing host grouping retained | Explicit versioned, reversible migration before changing saved navigation |
| MCP | Pane controls installed; editor mirror and plugin inventory tested in source | Install candidate and refresh clients, then test typed write APIs separately |
| Performance/redraw | Bounded remote TUI resize/reconnect/exit evidence | Prolonged network-loss and plugins-on/off performance baseline |

The current focused Swift run passed 37 tests. This is not the full suite and
does not resolve historical terminal-test failures by implication. The Go MCP
suite also passes. No plugin release or website update was published.

Secondary plugin operations use RelayIconAction (tooltip, accessible name,
28-point target). Review/permission actions keep text. New plugin windows or
another plugin navigation hierarchy are not the migration strategy.

MCP inventory validates the current store and reports enabled, supported,
declared permission and operation data. It grants nothing and runs no plugin.
Editor reads expose a bounded native mirror, not synchronous editor state or a
write precondition. Installation/activation mutations require separate typed
review, receipt and revision checks; do not bolt them onto the read endpoints.
