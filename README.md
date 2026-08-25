# Relay

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

- Native macOS tabs, recursive splits, draggable dividers, drag-to-swap tiled panes, floating panes, focus, selection, and right-click menus
- GhosttyKit terminal rendering with Metal, true color, Unicode, links, and mouse protocols
- Detached per-pane workers with atomic manifests and supervisor-crash recovery
- Persistent remote PTYs with detach/reattach and an 8 MiB output replay ring
- Remote split creation with parent-session working-directory inheritance on Linux HPC nodes
- `~/.ssh/config` host discovery, including `Include` files; OpenSSH still resolves ProxyJump, IdentityFile, HostName, User, and Port
- Saved manual host profiles and direct SSH fallback
- Structured Claude hook event transport plus Claude/Codex output heuristics
- Native session-rail states for working, ready, needs input, exited, and active Claude subagents
- Identity-aware subagent rows nested beneath their owning Claude/Codex pane
- Sequence-based reconnect with bounded input buffering and retained terminal surfaces
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

To launch Claude with structured Relay hooks inside a Relay pane:

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

Drag a tiled pane by its connection header and drop it over another tiled pane to swap their positions. The two remote PTYs keep their identities and continue running during the move.

## Near-term gaps

- Explicit terminate/delete session RPC and remote session garbage collection
- Native agent-pane renderer backed by Codex app-server and Claude bidirectional stream-json
- Web workspace panes backed by an SSH-forwarded Code-OSS/OpenVSCode server
- One multiplexed transport per node plus a persisted local event/screen cache
- Durable agent-state snapshots across a disconnected period
- Production Xcode packaging, bundled Ghostty resources, signing, and notarization

## License

No project license has been selected. Public source visibility does not grant redistribution rights. Third-party packages retain their own licenses.
