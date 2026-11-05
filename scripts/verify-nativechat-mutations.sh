#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root/remote/relayd"
exec go run ./cmd/relay-verify-nativechat "$@"
