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
