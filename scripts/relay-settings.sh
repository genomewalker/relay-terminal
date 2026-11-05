#!/bin/sh
# Native Go helper; compilation never changes the caller's working directory.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/.build/helper-tools"
(cd "$root/remote/relayd" && go build -o "$root/.build/helper-tools/relay-settings" ./cmd/relay-settings)
exec "$root/.build/helper-tools/relay-settings" "$@"
