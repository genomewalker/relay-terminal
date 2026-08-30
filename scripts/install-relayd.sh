#!/usr/bin/env bash
set -euo pipefail

target_host="${1:?usage: scripts/install-relayd.sh <ssh-host>}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
relayd_version="${RELAYD_VERSION:-${RELAY_VERSION:-0.5.2}}"
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
ssh "$target_host" sh -s -- "$go_arch" "$remote_upload" "$payload_hash" <<'REMOTE_INSTALL'
set -eu
umask 077
architecture="$1"
upload="$HOME/$2"
expected_hash="$3"
bin_dir="$HOME/.local/bin"
relay_root="$HOME/.local/share/relay"
payload_dir="$relay_root/bin"
shim_dir="$relay_root/shims"
lock_dir="$relay_root/install.lock"
temporary_launcher=
temporary_claude_shim=
temporary_codex_shim=
lock_owned=0
cleanup() {
    rm -f "$upload" "$temporary_launcher" "$temporary_claude_shim" "$temporary_codex_shim"
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
temporary_claude_shim="$(mktemp "$shim_dir/.claude-shim.XXXXXX")"
temporary_codex_shim="$(mktemp "$shim_dir/.codex-shim.XXXXXX")"
cat > "$temporary_claude_shim" <<'RELAY_CLAUDE_SHIM'
#!/bin/sh
set -eu
RELAY_INVOKED_AS=claude
export RELAY_INVOKED_AS
exec "$HOME/.local/bin/relayd" "$@"
RELAY_CLAUDE_SHIM
cat > "$temporary_codex_shim" <<'RELAY_CODEX_SHIM'
#!/bin/sh
set -eu
RELAY_INVOKED_AS=codex
export RELAY_INVOKED_AS
exec "$HOME/.local/bin/relayd" "$@"
RELAY_CODEX_SHIM
chmod 700 "$temporary_claude_shim" "$temporary_codex_shim"
mv -f "$temporary_claude_shim" "$shim_dir/claude"
mv -f "$temporary_codex_shim" "$shim_dir/codex"
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
if ! "$bin_dir/relayd" upgrade-supervisor --force; then
    sleep 1
    "$bin_dir/relayd" upgrade-supervisor
fi
REMOTE_INSTALL
