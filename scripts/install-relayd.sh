#!/usr/bin/env bash
set -euo pipefail

target_host="${1:?usage: scripts/install-relayd.sh <ssh-host>}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
remote_arch="$(ssh "$target_host" uname -m)"

case "$remote_arch" in
    x86_64|amd64) go_arch="amd64" ;;
    aarch64|arm64) go_arch="arm64" ;;
    *)
        echo "unsupported remote architecture: $remote_arch" >&2
        exit 1
        ;;
esac

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

cd "$project_root/remote/relayd"
CGO_ENABLED=0 GOOS=linux GOARCH="$go_arch" \
    go build -trimpath -ldflags='-s -w' -o "$build_dir/relayd" ./cmd/relayd

ssh "$target_host" 'mkdir -p ~/.local/bin ~/.local/share/relay/shims && chmod 700 ~/.local/bin ~/.local/share/relay/shims'
scp "$build_dir/relayd" "$target_host:~/.local/bin/relayd.next"
ssh "$target_host" 'chmod 700 ~/.local/bin/relayd.next && mv ~/.local/bin/relayd.next ~/.local/bin/relayd && ln -sfn ~/.local/bin/relayd ~/.local/bin/rcode && ln -sfn ~/.local/bin/relayd ~/.local/share/relay/shims/claude && ln -sfn ~/.local/bin/relayd ~/.local/share/relay/shims/codex && ~/.local/bin/relayd --version'

# A running supervisor keeps the inode it started from after the binary is
# replaced. Restart only the validated per-user supervisor; pane workers are
# separate session leaders and remain alive for the new supervisor to recover.
ssh "$target_host" '
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    relay_socket="$XDG_RUNTIME_DIR/relayd.sock"
elif [ -n "${HOME:-}" ]; then
    relay_socket="$HOME/.relay/relayd.sock"
else
    relay_socket="/tmp/relayd-$(id -u).sock"
fi
relay_pid_file="$relay_socket.pid"
relay_supervisor_pid=""
if [ -r "$relay_pid_file" ]; then
    relay_supervisor_pid="$(head -n 1 "$relay_pid_file")"
fi
if [ -z "$relay_supervisor_pid" ]; then
    relay_supervisor_pid="$(pgrep -u "$(id -u)" -f "^.*/relayd daemon --socket $relay_socket$" | head -n 1 || true)"
fi
if [ -n "$relay_supervisor_pid" ] && [ -r "/proc/$relay_supervisor_pid/status" ]; then
    relay_uid="$(id -u)"
    actual_uid="$(awk "/^Uid:/{print \$2}" "/proc/$relay_supervisor_pid/status")"
    actual_command="$(tr "\000" " " < "/proc/$relay_supervisor_pid/cmdline")"
    case "$actual_uid:$actual_command" in
        "$relay_uid:"*"/relayd daemon --socket $relay_socket ")
            kill -TERM "$relay_supervisor_pid"
            relay_wait=0
            while kill -0 "$relay_supervisor_pid" 2>/dev/null && [ "$relay_wait" -lt 40 ]; do
                sleep 0.05
                relay_wait=$((relay_wait + 1))
            done
            ;;
        *)
            echo "refusing to restart unvalidated process $relay_supervisor_pid" >&2
            exit 1
            ;;
    esac
fi
printf "" | ~/.local/bin/relayd node >/dev/null 2>&1 || true
'
