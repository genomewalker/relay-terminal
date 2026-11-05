#!/usr/bin/env bash
set -euo pipefail

target_host="${1:?usage: scripts/install-relayd.sh <ssh-host> [--no-restart]}"
upgrade_supervisor=1
case "${2:-}" in
    "") ;;
    --no-restart) upgrade_supervisor=0 ;;
    *) echo "usage: scripts/install-relayd.sh <ssh-host> [--no-restart]" >&2; exit 2 ;;
esac
if [[ $# -gt 2 ]]; then
    echo "usage: scripts/install-relayd.sh <ssh-host> [--no-restart]" >&2
    exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
relayd_version="${RELAYD_VERSION:-${RELAY_VERSION:-0.5.3}}"
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
    go build -trimpath -ldflags="-s -w -X main.relaydVersion=$relayd_version" \
    -o "$build_dir/relayd" ./cmd/relayd

payload_hash="$(shasum -a 256 "$build_dir/relayd" | awk '{print $1}')"
upload_token="$(date +%s)-$$"
remote_upload=".local/share/relay/relayd-upload-$upload_token"
ssh "$target_host" 'mkdir -p ~/.local/bin ~/.local/share/relay/bin ~/.local/share/relay/shims'
scp "$build_dir/relayd" "$target_host:~/$remote_upload"
ssh "$target_host" sh -s -- "$go_arch" "$remote_upload" "$payload_hash" "$upgrade_supervisor" "$upload_token" <<'REMOTE_INSTALL'
set -eu
umask 077
architecture="$1"
upload="$HOME/$2"
expected_hash="$3"
upgrade_supervisor="$4"
upload_token="$5"
bin_dir="$HOME/.local/bin"
relay_root="$HOME/.local/share/relay"
payload_dir="$relay_root/bin"
shim_dir="$relay_root/shims"
lock_dir="$relay_root/install.lock"
temporary_launcher=
lock_owned=0
cleanup() {
    rm -f "$upload" "$temporary_launcher"
    if [ "$lock_owned" = 1 ]; then rmdir "$lock_dir" 2>/dev/null || true; fi
}
trap cleanup EXIT HUP INT TERM
lock_wait=0
while ! mkdir "$lock_dir" 2>/dev/null; do
    lock_wait=$((lock_wait + 1))
    if [ "$lock_wait" -ge 300 ]; then
        echo "another Relay installation is still running" >&2
        exit 1
    fi
    sleep 0.1
done
lock_owned=1
if command -v sha256sum >/dev/null 2>&1; then
    actual_hash="$(sha256sum "$upload" | awk '{print $1}')"
else
    actual_hash="$(shasum -a 256 "$upload" | awk '{print $1}')"
fi
if [ "$actual_hash" != "$expected_hash" ]; then
    echo "uploaded relayd checksum mismatch" >&2
    exit 1
fi
chmod 700 "$upload"
if [ -f "$payload_dir/relayd-linux-$architecture" ]; then
    # Keep the prior executable recoverable even when the supervisor handoff
    # refuses because jobs are active. Never overwrite a prior backup.
    previous_backup="$payload_dir/relayd-linux-$architecture.before-$upload_token"
    if [ -e "$previous_backup" ]; then
        echo "previous payload backup already exists; installation deferred" >&2
        exit 1
    fi
    cp -p "$payload_dir/relayd-linux-$architecture" "$previous_backup"
fi
mv -f "$upload" "$payload_dir/relayd-linux-$architecture"
temporary_launcher="$(mktemp "$bin_dir/.relayd-launcher.XXXXXX")"
cat > "$temporary_launcher" <<'RELAY_LAUNCHER'
#!/bin/sh
set -eu
case "$(uname -m 2>/dev/null || printf unknown)" in
    x86_64|amd64) relay_arch=amd64 ;;
    aarch64|arm64) relay_arch=arm64 ;;
    *) echo "relayd: unsupported architecture" >&2; exit 1 ;;
esac
relay_payload="$HOME/.local/share/relay/bin/relayd-linux-$relay_arch"
[ -x "$relay_payload" ] || { echo "relayd: payload for $relay_arch is not installed" >&2; exit 1; }
RELAY_INVOKED_AS="${RELAY_INVOKED_AS:-$(basename "$0")}"
export RELAY_INVOKED_AS
exec "$relay_payload" "$@"
RELAY_LAUNCHER
chmod 700 "$temporary_launcher"
mv -f "$temporary_launcher" "$bin_dir/relayd"
# relayd installs or repairs its own claude/codex launchers: missing ones are
# written, stale Relay ones fixed, and any file Relay did not write is kept.
if ! "$bin_dir/relayd" agent-launchers --repair >/dev/null; then
    echo "Relay could not install its claude/codex launchers on this host; Settings > Agent Accounts shows why." >&2
fi
printf 'relay-managed-v1\n' > "$relay_root/managed-v1"
if [ ! -e "$bin_dir/rcode" ] && [ ! -L "$bin_dir/rcode" ]; then
    ln -s "$bin_dir/relayd" "$bin_dir/rcode"
elif [ -L "$bin_dir/rcode" ]; then
    target="$(readlink "$bin_dir/rcode" 2>/dev/null || true)"
    case "$target" in
        "$bin_dir/relayd"|"$payload_dir/relayd-linux-amd64"|"$payload_dir/relayd-linux-arm64")
            ln -sfn "$bin_dir/relayd" "$bin_dir/rcode" ;;
        *) echo "left existing rcode symlink unchanged: $target" >&2 ;;
    esac
else
    echo "left existing rcode command unchanged" >&2
fi
"$bin_dir/relayd" --version
if [ "$upgrade_supervisor" = 0 ]; then
    echo "Installed helper; running supervisor and workers left unchanged."
elif ! "$bin_dir/relayd" upgrade-supervisor --force; then
    echo "Helper staged, but supervisor upgrade was refused; running jobs and workers were retained." >&2
    echo "After the blocker is resolved, run: ~/.local/bin/relayd upgrade-supervisor --force" >&2
    exit 1
else
    # Move live pane workers onto the new relayd in place (same PID, shell and
    # PTY), detached so a host with many panes does not hold this install open.
    # Workers already on it and legacy workers are left as they are; busy panes
    # (mid-edit or mid-rotation) are retried 10 times, 30 s apart. The receipt
    # lists each pane's result.
    receipt="$relay_root/upgrade-workers-last.json"
    ( nohup sh -c '"$1" upgrade-workers > "$2.tmp" 2>&1; mv -f "$2.tmp" "$2"' upgrade-workers "$bin_dir/relayd" "$receipt" \
        </dev/null >/dev/null 2>&1 & )
fi
REMOTE_INSTALL
