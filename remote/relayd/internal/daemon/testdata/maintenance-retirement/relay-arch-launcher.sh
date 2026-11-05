#!/bin/sh
set -eu
case "$(uname -m 2>/dev/null || printf unknown)" in
    x86_64|amd64) relay_arch=amd64 ;;
    aarch64|arm64) relay_arch=arm64 ;;
    *) printf 'relayd: unsupported architecture: %s\n' "$(uname -m 2>/dev/null || printf unknown)" >&2; exit 1 ;;
esac
relay_payload="$HOME/.local/share/relay/bin/relayd-linux-$relay_arch"
if [ ! -x "$relay_payload" ]; then
    printf 'relayd: the %s payload is not installed in this shared home; install it from this node first\n' "$relay_arch" >&2
    exit 1
fi
RELAY_INVOKED_AS="${RELAY_INVOKED_AS:-$(basename "$0")}"
export RELAY_INVOKED_AS
exec "$relay_payload" "$@"
