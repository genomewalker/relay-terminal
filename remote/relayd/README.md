# relayd

`relayd` is Relay's remote session supervisor. It has no UI and opens no network port. The first `relayd attach` starts a per-user supervisor listening on a mode-0600 Unix socket; later attach processes proxy the versioned binary protocol between that socket and an SSH stdio tunnel.

Each pane is owned by a detached worker process with its own mode-0600 Unix socket. The worker owns the PTY and retains the latest 8 MiB of terminal output with monotonic sequence numbers. Sessions continue when viewers disconnect or the supervisor is killed.

Workers write atomic mode-0600 manifests under `$XDG_STATE_HOME/relay/workers`, falling back to `~/.local/state/relay/workers`. A new supervisor verifies the node boot ID, worker PID start time, and authenticated worker-socket handshake before proxying a connection. PID alone is not accepted as worker identity.

When a native Relay pane is split, the new session can name its parent session. On Linux, `relayd` reads the parent shell's current directory and starts the child PTY there. The remote daemon owns processes, not layout—the split tree remains native macOS state.

Agent lifecycle JSON is carried as a separate `AgentEvent` frame, never printed into the terminal byte stream. The installer places `claude` and `codex` shims in a directory prepended only to Relay worker shells. Those shims execute the real agent binaries with generated hook settings that forward tool, permission, notification, subagent, stop, and session events to the owning Relay pane. Process-tree detection remains a fallback.

The only non-standard-library dependency is `creack/pty`, which supplies the OS pseudo-terminal calls. Tabs and layout belong to the Mac app; PTYs, replay, and agent-event fan-out belong to pane workers. If a pane worker itself dies, its open PTY cannot be reconstructed from disk.

## Remote quick editor

The installer also creates `~/.local/bin/rcode` as a symlink to `relayd`. From a Relay-managed shell:

```sh
rcode analysis.py
rcode --diff analysis.py
rcode --diff old.py new.py
```

The command sends an open-file event to Relay. Monaco renders locally on macOS; the remote binary only lists, reads, and atomically saves files. Writes carry the modification timestamp observed at open time and fail if another process changed the file first. No Node or VS Code server runs on the remote host.
