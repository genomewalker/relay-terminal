#!/bin/sh
# Check a staged native helper against an explicit disposable /tmp fixture.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/.build/helper-tools"
(cd "$root/remote/relayd" && go build -buildvcs=false -o "$root/.build/helper-tools/relay-verify-plugin" ./cmd/relay-verify-plugin)
exec "$root/.build/helper-tools/relay-verify-plugin" "$@"
