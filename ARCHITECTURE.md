# Relay architecture

Relay keeps terminal presentation native to macOS while durable processes live on the remote node.

## Ownership model

```text
Mac: Relay.app                         Remote node: relayd
-------------------------------        --------------------------------
window, sidebar and command UI   SSH   one per-user supervisor
native tabs and split geometry  <----> durable session catalog
Ghostty terminal surfaces              pane workers owning PTYs/processes
mouse, selection and previews          output replay and agent events
```

There is one `relayd` supervisor per Unix user per node. The supervisor must not own interactive PTY file descriptors. A product-level Relay session is not a PTY:

```text
node
└── session (durable project/workspace)
    ├── tab
    │   ├── tiled pane -> detached relay-worker -> PTY -> shell/agent
    │   └── floating pane -> detached relay-worker -> PTY -> shell/agent
    └── tab
        └── pane -> detached relay-worker -> PTY -> shell/agent
```

A split or floating pane belongs to the selected tab and therefore to the selected session. It creates a new remote PTY worker, normally inheriting the active pane's node, environment policy, and working directory. Only geometry and rendering are local.

## Pane renderers

Relay has two renderer classes sharing the same node/session/tab/pane lifecycle:

- **Terminal pane** — a GhosttyKit/Metal cell surface for shells, editors, REPLs, and arbitrary TUIs.
- **Agent pane** — a native message timeline with a separately anchored composer, inline artifacts, approvals, tool calls, and expandable subagent activity.

Codex agent panes consume Codex app-server item events. Claude agent panes consume Claude Code's bidirectional `stream-json` SDK interface. Their processes remain remote and durable; only presentation and input composition move to native macOS controls. Raw Claude/Codex TUI mode remains available inside a terminal pane, but Relay does not attempt to infer message layout from VT cursor movement.

Artifact events are ordered against the agent/output sequence that produced them. Relay caches decoded artifacts locally and renders them as message children, never as a late overlay at the terminal's current cursor.

## Latency and reconnection

Local geometry, focus, scrolling, composition, and input enqueue must never wait for the node. Remote output uses monotonically increasing sequence numbers. A transient disconnect preserves the local surface, buffers bounded input, reconnects with exponential backoff, and asks only for frames after the last acknowledged sequence.

The production transport is one multiplexed connection per node. Per-pane SSH processes are a bootstrap implementation and must not become the long-term session boundary. A persisted local event cache provides immediate cold-start rendering; the node then supplies only the missing suffix.

## Persistence and recovery

The supervisor stores a lightweight catalog under `$XDG_STATE_HOME/relay`, falling back to `~/.local/state/relay`. It records session, tab, pane, title, command, working directory, layout metadata, timestamps, and worker socket identity. Terminal screen cells are not persisted as UI state.

Each pane runs as a worker process separate from the supervisor. This lets the supervisor restart and rebuild its catalog without terminating the PTYs. On hosts with `systemd --user`, Relay may use it; the portable fallback is a detached worker and a permission-`0600` Unix socket under `$XDG_RUNTIME_DIR`.

Workers publish atomic permission-`0600` manifests containing the session UUID, worker PID, Linux process start time, node boot ID, socket path, protocol version, command policy, and last output sequence. On startup, the supervisor rejects stale PID/boot-ID combinations and handshakes with each worker socket before re-registering it; PID alone is never identity.

If the supervisor crashes or is upgraded, the workers and their PTYs continue. If an individual worker crashes, its PTY is lost because an open kernel file descriptor cannot be reconstructed from a disk record. Workers therefore stay deliberately tiny and, where the cluster permits it, outside the memory-heavy agent's cgroup. Node reboot recovery belongs to the scheduler/checkpoint layer.

The current implementation uses a per-user supervisor, detached per-pane workers, atomic worker manifests, boot/PID/socket identity validation, and sequence-based reattachment. Local workspace snapshots now model session -> tabs -> panes. Remote workspace-level catalog metadata and explicit worker garbage collection remain to be added.

## Quick editor panes

The editor is a separate pane renderer, not a terminal escape-sequence feature:

```text
Relay editor pane (bundled Monaco in WKWebView)
        │ Relay's SSH transport
        ▼
relayd file RPC -> remote filesystem
```

Editor panes participate in the same tab, split, floating, zoom, and persistence model as terminal and agent panes. Monaco is bundled with the Mac app and supplies syntax highlighting, multiple cursors, find/replace, minimap, diff rendering, and editor keybindings. There is no Node process, web server, or editor renderer on the cluster.

`rcode file` sends a structured open-file event from a Relay-managed remote shell to the Mac app. `rcode --diff file` compares the working file with Git `HEAD`; two path arguments compare arbitrary files. Reads and saves go through `relayd`, and saves include the open-time modification timestamp so an external change is never overwritten silently.

The quick editor deliberately does not reproduce the VS Code workbench, extension host, debugger, or integrated terminal. Shells and agents remain durable Relay terminal panes beside the editor.

## Agent activity

Relay worker shells prepend a private shim directory to `PATH`. Invoking `claude` or `codex` in those shells runs the real binary with Relay hook configuration; shells opened outside Relay are unchanged. Hook payloads travel in `AgentEvent` frames beside terminal output and drive the pane's working/ready/approval state, recent activity tree, and nested subagent rows. Raw terminal text is never presented as an activity-tree item. A Linux process-tree monitor and throttled output heuristics identify agents launched outside the shim path, but show only stable lifecycle state until structured events are available. Selecting an agent, activity, or subagent in the session rail selects its tab and raises its tiled or floating terminal pane.

## Attach flow

1. Relay opens one SSH transport to the selected node and asks `relayd` to list sessions.
2. The user resumes a session or creates one.
3. Relay receives the session manifest and reconstructs native tabs, split trees, and floating windows.
4. Each native terminal surface attaches to its pane worker's byte/event stream.
5. Layout edits update the remote manifest; terminal bytes never contain Relay UI chrome.

Only one client holds the input/layout lease for a pane by default. Additional clients attach read-only until the user explicitly takes control. This avoids two clients racing terminal input or layout updates.

## UI model

The sidebar is a session manager, grouped as node -> session. It shows detached/running state, active agents, attention requests, and last activity. Selecting a session restores its tabs in the native top strip. Selecting a tab restores its tiled and floating panes.

In macOS full screen, Relay hides the expanded session rail and reduces chrome to a compact tab/command strip plus slim pane identity bars. A persistent control reopens the session manager. The terminal remains the visual focus.
