# Relay

Relay is a native macOS workspace for durable shells and agents running on remote nodes.

From a Relay-managed remote shell, `rcode file.py` opens the file in a floating Monaco pane over the terminal. Use `rcode --diff file.py` for a Git `HEAD` comparison or `rcode --diff old.py new.py` for a two-file comparison. The editor renders locally; only file operations run remotely.

Relay is a macOS terminal workspace for remote HPC systems. Shells and agents run on the selected remote node. Tabs, splits, mouse interaction, context menus, and rendering are handled by the Mac application.

## Current architecture

```text
Relay.app (macOS)
  native tabs + split tree + session rail
  GhosttyKit Metal terminal surface per pane
                 │ framed protocol over `ssh -T`
                 ▼
relayd supervisor (remote, static Go binary)
  manifest discovery + connection proxy
                 │ private Unix socket
                 ▼
relay worker per pane
  durable session UUID → PTY → shell / Claude / Codex
  output replay + resize/input + structured agent events
```

A local pane maps one-to-one to a durable remote `relayd` session UUID. Splitting a remote pane creates another PTY on the same remote host and asks it to inherit the parent shell's working directory; only the visual divider is local. Closing a remote pane detaches it, so the process survives and the saved workspace can reattach later.

`relayd` and its pane workers listen only on mode-0600 Unix sockets owned by the remote user. SSH remains the authentication and transport layer; Relay opens no remote TCP port. Killing the supervisor does not close pane PTYs. A replacement supervisor validates each worker's node boot ID, PID start time, manifest, and socket handshake before reattaching.

## What works

- Native session-scoped tabs, recursive splits, draggable dividers, four-edge pane docking, floating panes, focus, selection, rename actions, and right-click menus
- GhosttyKit terminal rendering with Metal, true color, Unicode, links, and mouse protocols
- Detached per-pane workers with atomic manifests and supervisor-crash recovery
- Persistent remote PTYs with detach/reattach and an 8 MiB output replay ring
- Remote split creation with parent-session working-directory inheritance on Linux HPC nodes
- `~/.ssh/config` host discovery, including `Include` files; OpenSSH still resolves ProxyJump, IdentityFile, HostName, User, and Port
- Saved manual host profiles and direct SSH fallback
- Structured Claude and Codex hook events for normal agent launches inside Relay, with process-tree and output fallback detection
- Native session-rail states for working, ready, needs input, exited, and active Claude subagents
- A clickable agent-thread tree with structured tool events and identity-aware subagents; raw terminal lines never enter the sidebar
- Node-scoped remote catalogs that discover validated detached panes before starting a new shell; older panes migrate as recoverable entries
- Sequence-based output reconnect plus acknowledged, deduplicated input for new workers; old workers remain protocol-compatible
- Persistent bounded agent-event journals with cursor replay, including a supervisor compatibility index for older workers
- Inline Kitty-graphics rendering or dismissible native previews for PNG/JPEG/GIF/WebP files referenced by remote Codex or Claude output
- Live macOS Settings (`⌘,`) for font, size, terminal padding, palette, interface density, full-screen chrome, and artifact previews
- Workspace restoration using stable pane/session UUIDs

Relay deliberately does not run Zellij or tmux for its layout. They can still run inside a pane, but doing so gives their text UI control of that pane again.

## Build and run

Requirements: macOS 14+, Xcode 16+, and Go 1.24+ for building the remote daemon.

```bash
swift test
./scripts/build-app.sh release
open Relay.app
```

Install or update the static remote daemon:

```bash
./scripts/install-relayd.sh <ssh-host>
```

The binary is installed as `~/.local/bin/relayd` with user-only execute permissions. The first Relay connection starts the per-user daemon automatically.

The installer adds Relay-only `claude` and `codex` shims to remote shells created by Relay. They launch the real commands with structured hooks; normal SSH shells keep their existing `PATH`. An explicit launch also works:

```bash
relayd agent claude
```

## Keyboard

- `⌘D`: split right
- `⇧⌘D`: split down
- `⌘W`: detach/close the active pane
- `⌥⌘[` / `⌥⌘]`: previous/next pane
- `⇧⌘Return`: zoom/restore the active pane
- `⌥⌘P`: float/dock the active pane
- `⇧⌘[` / `⇧⌘]`: previous/next tab
- `⌘,`: settings

Drag a pane by its connection header and drop it near another pane's left, right, top, or bottom edge to dock it there. Drop in the center to swap tiled panes. The remote PTYs keep their identities and continue running during the move.

## Near-term gaps

- Explicit terminate/delete session RPC and remote session garbage collection
- Native agent-pane renderer backed by Codex app-server and Claude bidirectional stream-json
- One multiplexed transport per node plus a persisted local event/screen cache
- Durable remote layout mutations; detailed split/floating geometry currently remains in the Mac workspace snapshot
- Input/layout leases for simultaneous controlling clients
- Production Xcode packaging, bundled Ghostty resources, signing, and notarization

## License

No project license has been selected. Public source visibility does not grant redistribution rights. Third-party packages retain their own licenses.
