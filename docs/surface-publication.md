# Durable native surfaces

Installed production API (2 October 2026); isolated HTTP and restart recovery checks passed. Native visual acceptance remains pending. All requests use the installation
credential in `x-relay-token` and a registered client credential in
`x-relay-caller-token`. Registration identifies a client; thread labels are
claims, not verified provider identities. Never put credentials in URLs or logs.

## Publish

`POST /api/surfaces/publish` accepts at most 1 MiB of JSON:

```json
{
  "paneID": "<existing pane UUID>",
  "surfaceID": "<new surface UUID>",
  "generation": "<new generation UUID>",
  "revision": 1,
  "expectedRevision": 0,
  "operation": "snapshot",
  "content": {
    "kind": "status", "title": "Analysis", "text": "Preparing results",
    "status": "running", "columns": [], "rows": []
  }
}
```

The backend assigns ownership from the resolved pane, its profile host and the
authenticated client. Payload ownership cannot change that assignment. Publishing
requires the layout grant and an unpaused client. Content supports text, status,
table, diff, image, equation, diagram and markdown, with bounded validation.

For an update retain surfaceID/generation, set expectedRevision to the committed
revision, and revision to expectedRevision + 1. An exact duplicate acknowledges
the existing commit. Changing ownership/generation or submitting stale revisions
fails. Close uses operation `close`, the next revision, and absent/null content.
Closed IDs remain tombstones and cannot be reused; create a new ID instead.
The ledger supports 128 lifetime surface IDs and an 8 MiB aggregate limit.

Success returns status `committed`, surface_id and revision (a decimal string).
401 means installation authentication failed; 403 means publisher/grant denial;
400 means malformed request/unresolved pane; 409 means publication rejection.
503 may mean an audit failed after commit: read status before deciding to retry.
Neither an HTTP timeout nor an error proves that publication did not commit.

## Recover current state

`POST /api/surfaces/status` and `POST /api/surfaces/content` accept at most 4096
bytes: `{"paneID":"<existing pane UUID>"}`. A paused registered client can read.
Reads are scoped to its own surfaces on that exact pane and host, sorted by
surface ID. Each result includes surfaceID, generation, revision and operation.
Content reads also include the validated content for open snapshots. Close
records retain revision/generation, with no content. Status omits content.
The complete response is bounded by the store's 8 MiB aggregate limit.

A read securely reloads the atomic checkpoint, so another writer's commit is
visible without restarting. Corrupt, inaccessible or unexpectedly missing
checkpoints return 503, rather than an empty success. Empty results mean there
are no admitted surfaces for that client/pane/host. Responses use no-store.

Native panes restore open snapshots at workspace startup and pane insertion;
publication and successful reads refresh the native rich-content view. The
client must explicitly recover status after reconnect. There is currently no
push subscription or patch operation. Credentials and pane/provider sessions
are never adopted or replayed as part of restore.

## MCP helper (deployed)

`relay_publish_surface` accepts pane_id, surface_id, generation, revision,
expected_revision, operation and snapshot content. It normalizes missing common
content fields to empty values. Close has no content. `relay_read_surfaces`
accepts pane_id and optional include_content (false by default). They require
`RELAY_MCP_CALLER_TOKEN` or an explicit caller_token, in addition to the helper's
installation credential. Credentials are not ownership fields and do not appear
in response text. Reads support the ledger's 8 MiB response bound; other helper
responses retain their existing 1 MiB limit. MCP envelopes allow 64 KiB overhead
above the 1 MiB publication limit; the native body limit remains 1 MiB.

The Rich content window's “Refresh saved content” reloads the checkpoint. If a
read fails it displays an error and retains the last view as potentially stale.
Actual stdio-helper checks against a private native app passed with two registered
clients publishing a fresh R computation table and a bridge status card. A real Codex provider also passed publish/read with an exact one-time tool
confirmation. Visual acceptance on screen remains pending.

## New owned Codex conversations (deployed)

The opt-in “Relay surface tools for this conversation” binds the packaged stdio
helper to a fresh registered client and the exact existing container pane. It is
currently available for local Codex conversations with input/layout grants.
The helper catalog exposes the pane as a constant; a different pane is rejected
before HTTP dispatch. Other sessions and the user's global Codex configuration
are untouched. The binding is frozen in the private launch reservation.

Binding credentials travel on the private provider pipe and into the helper's
environment. Copies in either direction of the owned content journal are
redacted, including thread configuration and provider echoes. Pause that client
through caller management to prevent further publications without stopping the
owned conversation or native user input.

MCP tool confirmations are associated with the exact live owned connection,
thread, active turn and request ID. The native card displays the server, prompt
and tool arguments with credential fields hidden. “Allow once” consumes the
request before writing; uncertain replies are not replayed. Session/permanent
trust is not offered. Current confirmation support covers bounded form-mode MCP
tool approvals with an empty object schema. URL flows and general input forms
remain unsupported; SDK and remote owned-tool binding remain pending.

A source-build acceptance run also passed through a fresh detached owned Codex
worker: same-owner reconnect, publication and recovery read, credential-redacted
journal, foreign-owner rejection, one-time approval with replay rejection, and
return to idle. Owned-first startup initializes the private worker catalog before
reservation, without requiring a prior terminal worker. These owned changes are deployed. A second real owned-provider acceptance run
passed using the installed daemon and MCP helper.
