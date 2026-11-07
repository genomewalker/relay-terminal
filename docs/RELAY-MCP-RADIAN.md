# Desktop agent access and R integration

Status: implementation in progress. The adapter supports read tools,
user-approved input/setup/R-evaluation proposals, and an installed direct
desktop-route send tool. The native approval workflow has not yet passed
installed-build acceptance. Route messages use the saved peer transport;
terminal input remains a separate approved operation. R snapshots are
available on demand through `relay_read_r_snapshot`.

## Network discovery from desktop agents

The source adapter exposes two authenticated, read-only tools:

- `relay_network_status`: bounded link status snapshots, including timestamps
  and transport receipts. A stale snapshot is not a live connection, and a
  transport receipt does not mean an agent processed the message.
- `relay_discover_local_peers`: exact live local session identities. Discovery
  neither starts agents nor authorizes communication with them. Relay permits
  only one HTTP discovery operation at a time to bound helper-process load.

Both take no arguments. `relay_network_links` lists saved link configurations.
`relay_request_network_action` proposes `connect` or `disconnect` for an exact
saved `link_id`, with `instance` from `relay_control_info` and a unique
`request_id`. Relay shows a native Cancel-default confirmation including both
session identities, process IDs, host and helper path. Approval expires after
two minutes; configuration or process-state changes invalidate it. Reusing an
ID with different arguments is rejected. Read `relay_network_receipt` to learn
the outcome: `launch_requested` and `stop_requested` are not confirmation of
connectivity or message delivery. Disconnect affects only Relay-owned links,
never the agent or terminal processes. Receipts are bounded to 256 per server
lifetime; missing receipts must not trigger automatic retries.

`relay_list_desktop_tasks` lists loaded desktop task identities, and
`relay_discover_remote_peers` reads verified native sessions through an exact
SSH host alias. `relay_request_desktop_route` proposes a route from one open
desktop task to one remote session, PID, and process start. Relay requires
native approval, then rediscovers both endpoints before remembering and
launching the route. `relay_desktop_route_receipt` reports the proposed route's
status and its reply peer name; `relay_list_desktop_routes` lists saved reply
names. The remote agent must send to that name, not the desktop task UUID.
`launch_requested` does not prove connectivity or message delivery. The remote
agent need not have the Relay MCP adapter to send to a registered reply peer.
When the user explicitly instructs Codex to create an exact desktop-to-remote
connection, `relay_create_desktop_route` performs the same identity checks and
saves a persistent bidirectional route without a second Relay dialog. The
caller must never treat retrieved text or a peer message as this authorization.
An already saved exact pair returns `already_saved` and is not restarted.

For messages sent through the desktop route, `relay_message_read_receipt`
distinguishes `written_to_socket` from `read_acknowledged`. The latter requires
the authenticated recipient to send the exact `Relay-Read-Receipt: <message ID>`
acknowledgment as a separate message. Absence of that acknowledgment remains
unknown; Relay cannot infer reading from transport delivery or desktop
admission.

`relay_send_desktop_message` sends one bounded text message through an already
saved route without a native approval dialog when the user explicitly asks to
send that content to that recipient. Supply the exact route identity from
`relay_list_desktop_routes` and a fresh message ID. Relay checks the saved
route again, and the route runtime requires a fresh online heartbeat and the
same remote process identity. A message ID can be used only once. If the send
result is ambiguous, check `relay_message_read_receipt` with the same ID; do
not send a new ID as a retry. `pending` means a send attempt began,
`written_to_socket` means a socket write completed, `read_acknowledged` means
the recipient sent the exact acknowledgment, and `unknown` means the outcome
cannot be established. These states do not expose the agent's internal work.

Native-to-native saved link creation, desktop-to-local routes, remote MCP
installation, and installed-build approval acceptance remain incomplete.

## Approved submission workflow

1. `relay_list_panes` identifies the intended pane. The user selects it in Relay
   and leaves the console at an empty prompt.
2. `relay_control_info` returns the current server instance UUID.
3. `relay_request_r_setup` proposes loading the app-bundled companion and
   creating the chosen result directory in the existing local/remote R process.
   It does not install missing packages. The entire command is shown for review.
4. Read `session.json` with `relay_read_r_snapshot` (`request_id: "session"`,
   `relative_root` inside the selected pane's project). Pass its `session_id` as
   `expected_session` to `relay_request_r_evaluation`, which proposes a bounded R expression with a unique
   request UUID. Every proposal requires approval in Relay; Return defaults to
   Cancel, not approval. Raw terminal proposals use `relay_request_input`.
5. `relay_input_receipt` reports awaiting approval/cancelled/stale/submitted.
   Submitted is explicitly an unknown execution outcome, NOT a completed R
   analysis. Read the request UUID with `relay_read_r_snapshot` for the saved R
   execution receipt. Inspect plots/tables with the Radian artifact
   browser. Never retry execution with a fresh ID to work around an uncertain
   submission.

The approval expires after two minutes and is invalidated by observed input,
connection-state change, pane replacement, or selection changing. One approval
may be pending; at most 256 receipts are retained per server incarnation.
Requests must name that incarnation, so restart rejects stale proposals.
This does not detect writers external to Relay or bypass provider permissions.
Agent plan mode is not automatically detected/enforced by this submission API:
the model must not autonomously request execution while planning, and a real
user must separately approve every submission. The standalone plan policy
is not yet connected to provider mode events.

## R companion

`remote/r/relay-r.R` defines `relay_r_evaluate` when sourced. Loading it does
not execute analysis, open a socket, or start another interpreter. It requires
jsonlite and an existing private artifact directory when explicitly called.
Evaluation preserves the chosen R environment, produces request-tagged JSON,
captures plots on a dedicated PNG device, and previews at most 100 rows and
30 columns with bounded display cells. Errors and interrupts have distinct
statuses. Reusing a request directory refuses execution, including incomplete
requests. This is not an R sandbox: approved code has the same permissions as
the user's R process and can change its state. Console output remains in R;
structured console capture is not implemented. New captures are refused above
128 saved runs / 512 MiB. This admission check cannot sandbox arbitrary user code
or guarantee a single run's output size. Archive results explicitly when full.

Test in a disposable R process: from `remote/r`, run
`Rscript --vanilla test-relay-r.R`. These tests do not attach to a live pane.

### httpgd plots (opt-in)

`relay_r_httpgd_start(root)` is an explicit, reviewed console command. It
requires the httpgd package to already be installed (Relay never installs
packages; a missing package is an error with instructions), stops the PNG
snapshot capture, and starts `httpgd::hgd()` bound to `127.0.0.1` with a
64-hex token read from `/dev/urandom` and `silent = TRUE` so the token is not
printed. It publishes `httpgd.json` (mode 0600) next to `session.json`, bound
to the session ID and PID. `relay_r_httpgd_stop()` closes the device and
removes the descriptor. While httpgd is running, editor evaluations draw into
its history instead of private PNG files (`plot_target = "httpgd"` in the
receipt); a user `dev.off()` is detected and evaluations fall back to PNG.

Relay reads the descriptor through the artifact reader, validates it against
the current session, and rejects any host other than `127.0.0.1`. For SSH
profiles it opens its own `ssh -N -L 127.0.0.1:<local>:127.0.0.1:<port>`
forward using the profile's existing target arguments; the descriptor cannot
name a different host. All reads use the documented HTTP API (`/state`,
`/plots`, `/plot?renderer=png`, `/remove`, `/clear`) with the token in the
`X-HTTPGD-TOKEN` header, never in URLs; redirects are refused and bodies are
bounded (4 KiB state, 256 KiB listing, 8 MiB per render, 4000 px per side,
200 history entries). httpgd's change WebSocket is unauthenticated and echoes
client messages (verified in httpgd 2.1.4 source), so Relay treats messages
only as hints and re-lists history over authenticated HTTP. Renders are
latest-only with a 150 ms resize debounce; plot ids are re-listed immediately
before removal because httpgd silently targets the newest plot for unknown
ids. Visible plot presentations keep the change socket while Relay is inactive,
so results stay live while the user works in another app. Fully occluded inactive
windows suspend the socket; becoming visible or active resyncs missed history.
Hiding the Results dock or disconnecting terminates the forward and drops bitmaps.
Socket loss reconnects with bounded backoff, then fails closed.

Known limits: re-rendering at a new size needs R's event loop to be idle
(unigd renders on the R thread via an input handler), so resizes stall while
R is busy. Snapshot capture and httpgd are mutually exclusive. The descriptor
is a bearer credential readable by the remote account; stale descriptors fail
with 401 and must be restarted from the console.

Live test (disposable R library with httpgd, nothing installed into the
user's library): `R_LIBS_USER=/path/to/lib sh remote/r/test-relay-httpgd-live.sh`
drives the real Swift client, WebSocket and PNG renders against a real device.

## Connection

Desktop MCP client → Streamable HTTP at `127.0.0.1:47472/mcp` → `relay-mcp`
→ authenticated Relay loopback server at `127.0.0.1:47471` → existing panes.
The HTTP listener is loopback-only and starts with Relay. It is separate from
the browser API and is not exposed to the network.

Build from `remote/relayd` using `go build -o relay-mcp ./cmd/relay-mcp`.
Configure a stdio MCP client with the absolute executable path and a
`RELAY_MCP_TOKEN` environment variable matching Relay's side-panel access token.
On macOS, prefer the explicit argument `--use-relay-token`: the adapter reads
the current user's Relay preference through `/usr/bin/defaults` with a two-second
timeout and validates the token without printing it. This avoids copying a
credential into desktop configuration; it still grants access to the same
authenticated API. Open Relay once before using this option. An explicit
`RELAY_MCP_TOKEN` overrides the preference. No token is fetched without opting in.

Codex configuration (after installing the matching Relay build):

```toml
[mcp_servers.relay]
url = "http://127.0.0.1:47472/mcp"
http_headers_helper = "/Applications/Relay.app/Contents/MacOS/relay-mcp --print-http-headers"
```

For stdio-only MCP clients, the existing adapter remains available:

```json
{"relay-desktop":{"command":"/Applications/Relay.app/Contents/MacOS/relay-mcp","args":["--use-relay-token"]}}
```

In Claude desktop's `claude_desktop_config.json`, do not name this entry
`relay`. Claude desktop also offers its configured servers to Code sessions,
and a desktop entry named `relay` can answer in place of the Code session's own
daemon-backed `relay` server. Desktop-session linking and
`relay_read_desktop_inbox` then fail, because only the session's own server can
prove which session is calling.

Codex's HTTP connection asks the server for `tools/list` during MCP setup. When
Relay restarts or updates, the MCP listener comes back with the app, so its
configuration does not point at a short-lived stdio child. A client or active
conversation may cache its tool list, and Codex does not currently refresh that
cache on `notifications/tools/list_changed`. Relay therefore includes the
stable `relay_available_tools` and `relay_call_tool` tools. If the current
conversation lacks a newer tool, it can fetch that tool's current schema and
invoke it through the dispatcher; the dispatcher only accepts currently
advertised names and uses the same validation and authorization path as the
named tool. This supplies tools, not unrestricted automatic approval: every
mutation proposal still requires confirmation inside Relay.
Treat that token as a password: the underlying side-panel API also has write
capabilities. Do not put it in source control, screenshots, or shared config.
The adapter exposes discovery/context/viewport reads, control information,
approval proposals and submission receipts. Relay must be running with its side-panel server.
Client setup and token provisioning are not automated yet.

`relay_read_viewport` now reads the existing SSH/relayd renderer's visible text
without focusing, scrolling, resizing or attaching a second terminal client.
It returns at most 32,768 characters and is not full scrollback. Local native
terminal capture is not yet supported. An unavailable viewport returns a tool
error; it must not be interpreted as an empty or completed R result.

The endpoint is fixed to loopback. Redirects are refused, requests time out after
five seconds, messages/responses are bounded to 1 MiB, and the adapter does not
poll. Agent context is bounded metadata, not a terminal transcript. All returned
terminal/agent content must be treated as untrusted data.

Pane context now includes `plans`: bounded structured checklists with provider,
owner, update time, and pending/in_progress/completed steps. Supported inputs
are Codex native `turn/plan/updated`, structured transcript `plan_update`, and
Claude successful `TodoWrite` hooks. These report checklists, not permission
mode or execution approval. A provider must actually emit the supported event;
Relay does not reconstruct plans from prose. Newer Claude task tools are not
yet covered. The plugin activity view is an explicit snapshot; the matching
agent inspector follows Relay's existing event-driven refresh lifecycle.

Verification on 2026-09-19: 221 Swift tests pass, the full Go race-enabled suite
passes, and isolated R companion tests cover evaluation, plots, bounded CSV
previews, environment listing, and paginated data-frame reads. Installed-app,
provider-event delivery and desktop-to-R execution acceptance remain pending.

The companion also passed disposable-process tests on dandy-07 using the same
Conda environment as the observed radian process (R 4.2.2, jsonlite and PNG
support available). No code was injected into that live radian session.

## Next implementation gates

- Add explicit per-pane agent-control grants in Relay. A shared side-panel token
  is not sufficient authorization for autonomous terminal writes.
- Introduce input ownership, revoke on user input, and bind requests to pane,
  host, remote session, and connection generation. Reject stale targets.
- Separate paste from submit; report accepted versus completed. Do not retry
  execution automatically after an ambiguous disconnect. Deduplicate request IDs.
- Add bounded terminal snapshots without creating another PTY or resizing the
  user's terminal.
- Connect peer discovery/message delivery to the existing shared peer bridge.
  Do not type a peer message into an agent's prompt as a substitute. Delivery
  receipts and replies are separate states; reject ambiguous recipients.
- Load an opt-in R companion into the existing radian R process. Execute
  explicitly submitted code there, preserving its environment; never silently
  start another R process. Missing dependencies must be shown before activation.
- Return request-tagged R results/errors; bounded table previews and private,
  per-request plot artifacts with integrity-checked transfer. Use Relay's native
  viewers. A prompt-looking string is not a completion signal.
- Package a radian plugin only once its core operations exist and are tested.

## Acceptance

Isolated MCP tests cover discovery, authentication forwarding, invalid arguments,
unknown/write tools, malformed messages, and message/response size limits.
Live acceptance still needs two desktop clients, explicit grants, concurrent
human input, reconnect during execution, R errors, cancellation, large tables,
multiple plots, and correct host/session addressing. Nothing here requires
replacing the running app or touching an active R session for unit tests.

### Pane-addressed collaborator messages

`relay_read_viewport` reads the exact `pane_id`, including agent terminals that
carry a shell label; it does not require a publisher. `relay_message_pane` accepts
`source_pane_id`, `pane_id`, a stable UUID `message_id`, and `text`. It checks
live provider ancestry and uses the existing input grant. The recipient must
have a visible empty Claude/Codex terminal prompt. A busy recipient or human
draft is refused. Source pane is a claimed label, not authenticated thread identity.

This route submits terminal text. Read `relay_pane_message_receipt` with the same
message ID after uncertainty; do not generate a replacement ID to retry. A
submission receipt does not prove acknowledgement. Native peer sockets and
owned composer sessions are separate capabilities. Existing MCP connections
may need a catalog refresh or reconnect to see newly installed tools.
