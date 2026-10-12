# Local terminal creation through MCP

Installed and manually verified on 2026-09-20. The first installed test exposed
missing approval-window selection when Relay was not key/main; the corrected
build selects an existing visible main-capable window and brings the approval
forward. Cancel returned `cancelled` without creating a pane. Approval opened a
visible Local shell tab; a repeated request returned the same tab/pane IDs with
no second dialog or tab. This does not validate local command-output capture.

1. Read `relay_control_info` for the current instance.
2. Call `relay_request_local_pane` with that `instance` and a new UUID
   `request_id`. Relay presents native approval, with Cancel as default.
3. Read `relay_local_pane_receipt` using the same request ID. `created` includes
   the exact `tabID` and `paneID`; it does not prove the shell is ready.
4. Use the existing separately approved input flow for the returned pane.

No command, working directory or environment overrides are accepted. Existing
panes are preserved; creating a tab selects it. Approvals expire after two
minutes. Duplicate IDs return the original receipt and never create another tab.
An unknown receipt after a restart is ambiguous: inspect panes, never blindly
retry with a new ID. There are at most 256 receipts per app lifetime and one
outstanding local-pane approval. No available approval window means no creation.

Verified automatically: cancellation, unavailable presenter/retry, stale instance,
duplicate completion and repeated request, returned identities, authenticated
HTTP routing, and rejection of additional command parameters.

Not yet provided: local terminal output capture or tracked shell command
completion. Do not present input submission or tab creation as command success.
