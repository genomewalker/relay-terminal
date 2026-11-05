#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/.build/helper-tools"
(cd "$root/remote/relayd" && go build -o "$root/.build/helper-tools/relay-repair-codehost" ./cmd/relay-repair-codehost)
exec "$root/.build/helper-tools/relay-repair-codehost" "$@"
