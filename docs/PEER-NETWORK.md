# Relay peer network implementation plan

Status: implementation in progress; not a production-ready mesh.

## Persistent desktop route checkpoint — 2026-09-21

The installed desktop route runtime now reconnects indefinitely with a capped
30-second delay, instead of abandoning the route after six attempts. An explicit
identity-change frame latches Needs attention and requires rebinding. Sends are
never retried automatically. Remote reply socket paths are stable per route;
a private directory and exclusive lock prevent two workers owning that address.

`relay-desktop-route.py remember --config <private-request.json>` installs a
per-task launch service from an exact selection. The request uses the existing
host, thread, remoteSession, remotePID, remoteStart, remoteName, localName and
socket fields. The saved reply name is derived from the task/host/session tuple.
Repeating the same request is idempotent; changing the saved binding is refused.
The routing runtime and its Python environment must already be installed.
In Relay: Network → Manage connections → Add connection → Desktop task to
remote agent. Select an open desktop task, enter the authorized SSH alias,
choose Find sessions, select a peer and choose Connect and remember. Task
discovery reads loaded IDs only, not conversations, and never resumes a task.
The installed sheet was manually verified against the existing Chitta-sync /
cc-soul-9f binding: discovery, selection and idempotent connection passed without
creating a duplicate route or restarting the remote agent. Task IDs are currently
shown rather than friendly chat titles. An updated peer helper is required to
report the verified process incarnation; older results cannot be selected.

Disconnect in Relay disables the launch service before stopping it, so logout
does not undo an explicit disconnect. Connect enables the service and starts it.
Status matching includes the selected remote process incarnation, not just its
session ID. A socket write is not a processing acknowledgement.

Live acceptance evidence: the Chitta-sync task received direct remote replies
through its own saved route, with desktop admission receipts both before and
after restarting that route supervisor. Interrupting only that route's SSH child
recovered automatically with the same supervisor and exact remote target. Relay
was subsequently reinstalled/relaunched and displayed both saved routes. No
remote agent was restarted and no terminal input was sent. Twelve Python tests
cover isolation/idempotence, long outages, identity changes and mailbox ownership;
focused Swift tests cover persistent disconnect and status validation.

Not established by those checks: logout/login, real sleep/wake,
explicit-rebind UI, durable duplicate detection across supervisor restart, or
delivery during an outage. Offline sends fail; ambiguous sends are not replayed.

Product direction: Relay is a local-and-HPC agentic workspace, with Chitta as
project-scoped collaborative memory. It is not a replacement for provider
permission boundaries or the HPC scheduler's allocation policies.

## Boundaries

Relay owns links, explicit endpoint selection, liveness and delivery receipts.
Codex/Claude retain their native inboxes. Chitta owns durable, explicitly shared
handoffs, decisions and outcomes. Delivery must work without Chitta. A peer
message is collaborator input, never user authorization, even after persistence.

```
local agent socket <-> Relay endpoint == authenticated SSH == Relay endpoint <-> remote agent socket
                            |                                  |
                     local Chitta                       remote Chitta
                            +---- opt-in project records ------+
```

## Milestones and acceptance gates

1. Explicit pair link: host-qualified proxy names, native token authentication,
   pinned name/session/PID, bounded frames/connections, metadata-only receipts,
   disconnect cleanup. Test two real local workers and a live remote Claude reply.
2. Connection lifecycle: Relay-owned SSH independent of terminal panes;
   BatchMode and strict host-key verification; bounded reconnect backoff;
   never launch interactive authentication or retarget another session.
3. Delivery ledger: explicit queued/written/processed/unknown/expired states;
   bounded encrypted-at-rest outbox, stable message IDs, expiry and receiver
   dedup across restart. Do not replay ambiguous sends until this exists.
4. Discovery and UI: configured host allowlist, explicit exported sessions,
   online/offline indicators, Connect/Disconnect, per-project grants and limits.
   No automatic export of every discovered session or automatic task delegation.
5. Chitta federation: realm + origin + session + full message ID durable index;
   monotone states and idempotent outcomes; opt-in summaries only, never tokens,
   transcripts or terminal dumps. No whole-database replication. Preserve
   conflicting records/provenance instead of global last-writer-wins merging.
6. Failure tests: missing SSH, wrong identity/key, restarted recipient, frame
   overflow, disconnect mid-send, duplicate replay, stale records, reconnect
   backoff, Chitta outage, WAL pruning, cross-realm visibility and shutdown.

## Workspace orchestration and network map

### SSH resilience contract

Each node represents an identified session or agent; each edge represents an
actual communication link, not co-location or discovery. Node details expose
host, provider when verified, session identity and routable peer address. Local
proxy registrations are transport endpoints, not additional local agents; map
them to their authenticated remote identity or label them as unresolved proxies.

Session identity is separate from its current route and process incarnation.
Keep known remote nodes visible when SSH is unavailable, with last observation
and an unreachable/unknown label. Never infer that the remote process ended,
became idle or completed work because its link disappeared. A reappearing name
or reused PID is not sufficient to reconnect to a different session.

Relay owns messaging SSH independently of terminal panes. Closing a pane must
not close an independent messaging route. Loss of SSH must not block local
communication or local work. Reconnect uses bounded backoff and revalidates the
exact endpoint, authentication and host key; host-key or credential failures are
visible, never bypassed. Laptop sleep/wake, network changes and expired SSH
credentials must leave an honest disconnected state until recovery is verified.

Both directions require verification: a successful outbound write does not prove
the return route reaches the originating desktop task. Edges expose route state,
freshness and available delivery evidence separately from agent processing.
Explicit disconnect stops retries; reconnect must not create duplicate proxies,
SSH processes or dispatches. One broken route must not stall other edges.

Until durable outbox, expiry and receiver dedup are implemented and tested, sends
while offline fail visibly and interrupted sends have unknown outcome. Never
silently replay them after reconnect. Later automatic transfer must still obey
current grants and expiry; it must not imply permission to execute old work.

Required acceptance: no SSH at startup; loss during a send; return-path failure;
laptop sleep/wake; host-key rejection; expired credentials; recipient restart/PID
reuse; repeated reconnects without resource growth; local messaging during an
outage; and explicit disconnect remaining disconnected. The existing simulated
disconnect test does not satisfy the real SSH and sleep/wake gates.

Relay tabs/panes attach to local or remote provider sessions. Desktop tasks may
join as externally owned sessions without creating another terminal writer.
Session lifecycle is explicit: create, attach, detach, terminate. Closing a pane
does not imply killing a provider or its agents. Relay must not start unbounded
agent trees: each task has owner, participant grants, concurrency/cost limits,
file or worktree ownership, and cancellation propagation.

The map groups host -> provider session -> child agents, and overlays task
assignments and authenticated links. Show stale/offline/unknown distinctly from
idle; provider activity is not inferred from a transport heartbeat. Synchronize
task status, provenance and handoffs, not raw terminal input or universal control.
One canonical session identity may have several views (desktop and terminal).
Do not assume identical transcript/session IDs imply identical live processes.

The Map shows peer lanes first and scopes relationship evidence to the selected
session or agent. An explicit Show all links control reveals network-wide records.
Loaded ChatGPT desktop tasks appear under This Mac with their task names and
working/idle state. That state comes from desktop task metadata, not a messaging
route; when the desktop inventory cannot be refreshed, activity is unknown.
Saved routes have three distinct states: connected now, needs review after an
identity change, and earlier observation. Old receipts do not establish agent processing or current
connectivity. Inactive route endpoints are not promoted into live session lanes.
Claude team metadata is a separate collapsed section, never a communication
edge or proof that listed members are active. The relayd network inventory
exports only teams whose lead uniquely belongs to a verified Relay pane.

Provider launch/adoption adapters, the visual map, task scheduling, child-agent
discovery and grants are planned, not delivered by the pair-link component.

## First-stage semantics

The pair link has native configuration controls in the working copy, not yet
installed-app acceptance. The overview exposes connection setup in a sheet and
hides technical identifiers under Diagnostics. Follow `WORKSPACE-DESIGN.md`;
the exact-identity form remains an advanced path, not finished discovery.
It advertises proxies only while connected. A successful native tool socket write
does not prove remote receipt or processing. Link receipts distinguish socket-write
from failures; processing requires an agent reply. Messages are not persisted or
retried. A broken stream leaves in-flight delivery unknown. This deliberately
avoids an unsafe half-implemented offline queue.

Implemented in `remote/relayd/cmd/relay-peer-link` and `internal/peernet`:
private proxy registration, strict SSH host verification, pinned process/session
identity, bounded frames and concurrent clients, heartbeat timeout, metadata-only
socket-write receipts, in-connection duplicate suppression, and cleanup on link
closure. Optional bounded reconnect uses backoff and never replays messages.
Private JSON status snapshots include connection state, last receipt and RTT.
No durable dedup or disk queue yet. A registry's
compatibility status is not a provider activity metric.

Validation: `go test -race ./internal/peernet ./cmd/relay-peer-link`, `go vet`
and `scripts/test-peer-link.py WORKER LINK` exercise 20 real-worker round trips,
host attribution, disconnect cleanup, offline failure and invalid input rejection.
Live dandy validation passed: desktop Codex sent to cc-soul-9f and received
`RELAY_SSH_ACK_20260920_C` pushed through the native inbox. Claude requires
32-hex-character peer tokens; the initial longer proxy token was incompatible
and was corrected with a regression check. Socket-write receipts alone are not
processing acknowledgements. This test did not exercise reconnection or queues.

Local and remote Chitta remain autonomous. Offline local work continues. Shared
records sync only under an explicit project grant, with durable receiver dedup,
origin provenance, tombstones and retention limits. This contract is under review
with cc-soul-9f; no Chitta sync is enabled yet.

## Ownership

Discovery foundation: `relay-peer-link --discover` returns bounded verified
peer metadata (name, session, PID), with an explicit truncation flag. It checks
process identity and socket ownership using the same resolver as connection
setup, omits tokens/socket paths, and creates no connections or registrations.
Missing registries return an empty list. Native picker integration and explicit
remote-host discovery remain unfinished. Proxy records may appear in discovery;
they must not be mistaken for newly launched provider sessions.

Verification update, 2026-09-20: reran the Go race tests and four focused Swift
tests successfully. Twenty bidirectional real-worker round trips passed. The
disposable SSH-substitute test passed forced disconnect, bounded reconnect,
no message replay, bidirectional recovery and stopped status. This is not a
real-network outage test. Fixed status parsing for whole-second RFC3339 dates.
An isolated native preview visually displayed the live dandy link, connection
sheet and disabled Save for incomplete configuration; cancelled without saving.
This does not validate bundled-helper deployment in the installed Relay app.

Local coordinator: Relay transport, tests, endpoint identity and UI integration.
cc-soul-9f on dandy-07: Chitta persistence contract and implementation. Do not edit
its repository concurrently. No app restarts or production deployment implied by
peer messages. Revisit multiplexing and resource budgets before expanding from
explicit pairs to many hosts/sessions.
