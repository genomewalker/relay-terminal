# Relay production architecture

## Contract

Relay is a native macOS terminal and workspace UI. Remote shells, editors, and
agents keep running on the selected SSH node. The remote side owns process
lifetime and durable identity; the Mac owns presentation, layout interaction,
and a local cache.

The product hierarchy is:

```
node
└── session (durable workspace)
    ├── tab
    │   ├── pane broker -> PTY -> shell/agent process tree
    │   └── editor pane -> remote file RPC
    └── tab
        └── pane broker -> PTY -> shell/agent process tree
```

A split creates another pane broker and PTY on the same node, inside the same
session and tab. A new tab creates its first remote pane inside the same session.
Detaching a Mac view never terminates a pane. Termination and deletion are
explicit, distinct operations.

## Components

### macOS app

- AppKit/SwiftUI workspace chrome and native drag, split, float, zoom, search,
  menus, settings, notifications, and accessibility.
- Ghostty's Metal terminal surface is a renderer/parser only. It does not own a
  remote process.
- A node connection manager multiplexes logical channels over an SSH control
  connection. Pane channels carry framed terminal data, not another terminal
  multiplexer UI.
- A local cache stores the last remote catalog revision, pane output sequence,
  event cursor, and unsent idempotent control operations.

### relayd supervisor

- One per Unix user and node, reached only through SSH stdio and a mode-0600
  Unix socket.
- Owns the remote catalog and validates worker identity using PID, process start
  time, node boot ID, token, and private socket.
- Starts, attaches, lists, renames, terminates, and garbage-collects pane
  brokers. It does not own PTYs.
- Reconstructs its in-memory state from atomic catalog and manifest files after
  restart.

### pane broker

- One small detached process per terminal pane.
- Sole owner of the PTY master and shell process group.
- Maintains bounded output replay, a persistent event journal, attachment
  leases, and process state.
- Has no UI and performs no parsing of full-screen terminal output for layout.

This broker is the tmux-like persistence boundary. If the app, SSH connection,
or supervisor dies, the broker and shell continue. If the broker itself dies,
the kernel closes its PTY master and the original terminal cannot be recreated
from disk. A manifest can recover identity and history, but not an open file
descriptor. Production hardening therefore keeps the broker minimal, isolates
it from agent memory limits where the scheduler permits, and reports this
failure honestly instead of claiming a false reattach.

### agent and artifact services

- Codex and Claude adapters emit normalized, versioned lifecycle events with a
  stable `agent_id`, optional `parent_agent_id`, monotonic event sequence, and
  original provider payload.
- Events are appended to a mode-0600 journal and periodically compacted into a
  snapshot plus suffix. The UI pages history by cursor; it never requires an
  unbounded sidebar model.
- The preferred adapters are provider-native structured streams. CLI hooks and
  transcript observation remain compatibility inputs and are marked with their
  provenance.
- Images and files are out-of-band artifacts. The terminal stream contains only
  a lightweight reference; the Mac fetches and renders the artifact inline at
  an anchored terminal row or in the native inspector.

## Durable identity and storage

Default state root: `${XDG_STATE_HOME:-~/.local/state}/relay`.

```
catalog.json                 atomic workspace catalog, schema + revision
workers/<pane-id>.json       atomic broker identity and latest state
events/<pane-id>.jsonl       append-only normalized agent events
snapshots/<pane-id>.json     compacted agent/thread snapshot
logs/<pane-id>.log           bounded diagnostic log
```

Identifiers are UUID strings and never inferred from labels or PIDs:

- `node_id`: installation identity for a remote account/node
- `session_id`: durable workspace
- `tab_id`: durable tab within a session
- `pane_id`: durable terminal/editor pane; the existing worker session ID
- `agent_id`: provider ID when stable, otherwise a Relay-generated ID persisted
  in the event index

Catalog updates use compare-and-swap revisions. Files are written to a private
temporary file, synced, renamed atomically, and the containing directory is
synced on platforms that support it. Unknown fields are preserved across
migrations.

## Wire protocol

The connection handshake advertises a protocol version and capabilities. New
features are capability-gated so a new app can safely attach to an old worker.

Logical channels:

- catalog: list/watch/mutate sessions, tabs, panes
- terminal: output sequence, input, resize, status, detach
- events: cursor-based normalized agent event pages and live tail
- artifacts: metadata, ranged content, cancellation
- files: workspace, directory, read, conditional write, diff

Terminal output is ordered by a broker sequence and replayed after the last
committed client sequence. Resize is last-value-wins. Control mutations carry
operation IDs and are idempotent. Interactive keystrokes are not silently
replayed after an ambiguous disconnect: Relay either receives a broker ACK or
shows that input delivery is uncertain. This avoids duplicate commands.

Only one attachment holds the input/layout lease for a pane. Other attachments
are read-only until they explicitly take the lease. Lease ownership never
changes merely because a second window observes the pane.

## Performance and scale budgets

- Local selection, split-layout computation, tab changes, and cached catalog
  search: no network dependency; target under one display frame, with core model
  mutations benchmarked below 1 ms at 100 panes/agents.
- Keystroke enqueue: constant-time and non-blocking on the main thread.
- Remote echo: network-bound and therefore not described as sub-millisecond.
- Catalog: 1,000 sessions, 10,000 panes; paged and incrementally updated.
- Agent UI: 100+ live subagents per pane; virtualized, collapsed by default,
  searchable, with active/needs-input groups ahead of completed history.
- Replay and journals are bounded. Slow clients are disconnected and resume by
  cursor instead of applying unbounded backpressure to a shell.

## Failure behavior

| Failure | Processes | Reattach behavior |
|---|---|---|
| macOS app/window exits | survive | catalog discovery + sequence replay |
| SSH/network drops | survive | reconnect, replay output/events, latest resize |
| relayd supervisor exits | survive | new supervisor validates manifests/brokers |
| observer/parser exits | survive | restart from persistent event cursor |
| pane broker exits | PTY/session normally exits | report lost broker; history remains; no false recovery |
| remote node reboots | exit | catalog marks prior boot entries stale |
| disk full/corrupt journal | process continues | bounded diagnostics; rebuild event index from provider sources where possible |

## Security

- No listening TCP port. SSH is the authentication and encryption boundary.
- State directories are 0700; sockets, manifests, event journals, and tokens are
  0600. Tokens never appear in process arguments.
- Every PID is checked with process start time and boot ID before signalling.
- Artifact and file RPCs canonicalize paths and enforce explicit size limits.
- Catalog deletion never signals a process unless identity validation succeeds.

## Migration

1. Add optional hierarchy metadata to worker handshakes and manifests. Existing
   manifests load unchanged and are listed as unfiled panes.
2. Build a catalog from validated manifests; merge later metadata updates by
   pane ID without restarting brokers.
3. Introduce capability negotiation and persistent event cursors. Old workers
   continue through the compatibility observer.
4. Move the app from one SSH child per logical observer to a node-level
   multiplexed transport without changing remote identities.
5. Add explicit terminate/delete/GC only after catalog recovery and identity
   tests pass.

## Release gates

- Restart the macOS app, SSH master, and supervisor independently while a shell
  and both agent CLIs run; output and events resume without losing identity.
- Migrate existing remote workers in place without killing their shell
  process groups.
- Load 100 active and 500 completed agents, 100 sessions, and 1,000 catalog
  entries; interaction remains responsive and memory stays bounded.
- Inject truncated manifests, stale PIDs, PID reuse, corrupt journals, slow
  readers, network flapping, and disk-write failures.
- Verify detach versus terminate, lease behavior, conditional editor writes,
  inline image anchoring, VoiceOver labels, keyboard navigation, and reduced
  motion.
