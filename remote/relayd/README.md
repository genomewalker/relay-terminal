# relayd

`relayd` is Relay's remote session supervisor. It has no UI and opens no network port. The first `relayd attach` starts a per-user supervisor listening on a mode-0600 Unix socket; later attach processes proxy the versioned binary protocol between that socket and an SSH stdio tunnel.

Each pane is owned by a detached worker process with its own mode-0600 Unix socket. The worker owns the PTY and retains the latest 8 MiB of terminal output with monotonic sequence numbers. Sessions continue when viewers disconnect or the supervisor is killed.

Workers write atomic mode-0600 manifests under `$XDG_STATE_HOME/relay/workers`, falling back to `~/.local/state/relay/workers`. A new supervisor verifies the node boot ID, worker PID start time, and authenticated worker-socket handshake before proxying a connection. PID alone is not accepted as worker identity.

When a native Relay pane is split, the new session can name its parent session. On Linux, `relayd` reads the parent shell's current directory and starts the child PTY there. The remote daemon owns processes, not layout—the split tree remains native macOS state.

Agent lifecycle JSON is carried as a separate `AgentEvent` frame, never printed into the terminal byte stream. `relayd agent claude` launches Claude Code with a generated hook settings file that forwards permission, tool, notification, subagent, stop, and session events to the owning Relay session.

The only non-standard-library dependency is `creack/pty`, which supplies the OS pseudo-terminal calls. Tabs and layout belong to the Mac app; PTYs, replay, and agent-event fan-out belong to pane workers. If a pane worker itself dies, its open PTY cannot be reconstructed from disk.
