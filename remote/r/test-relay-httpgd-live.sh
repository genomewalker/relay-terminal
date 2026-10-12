#!/bin/sh
# Live httpgd integration: runs the real companion in a disposable R process
# and drives Relay's Swift client against it. Requires an R library with
# httpgd; pass it via R_LIBS_USER (for example a temporary install). Nothing
# is installed and no existing R session is touched.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
project="$(cd "$here/../.." && pwd)"
rscript="${RSCRIPT:-Rscript}"
work="$(mktemp -d "${TMPDIR:-/tmp}/relay-httpgd-live.XXXXXX")"
rpid=""
cleanup() {
    if [ -n "$rpid" ]; then
        kill "$rpid" 2>/dev/null || true
        wait "$rpid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

if ! "$rscript" -e 'quit(status = if (nzchar(system.file(package = "httpgd"))) 0 else 1)'; then
    echo "SKIP: httpgd is not installed in this R library (set R_LIBS_USER to a disposable library)"
    exit 0
fi

cat > "$work/session.R" <<EOF
source("$here/relay-r.R")
root <- "$work/results"
relay_r_connect(root)
relay_r_httpgd_start(root)
plot(1:3)
trigger <- "$work/plot-request"
stop_file <- "$work/stop"
for (i in seq_len(600)) {
  Sys.sleep(0.1)
  if (file.exists(trigger)) { unlink(trigger); plot(rnorm(10)) }
  if (file.exists(stop_file)) break
}
relay_r_httpgd_stop()
EOF
"$rscript" "$work/session.R" > "$work/r.log" 2>&1 &
rpid=$!
for _ in $(seq 1 100); do
    [ -f "$work/results/httpgd.json" ] && break
    sleep 0.2
done
[ -f "$work/results/httpgd.json" ] || { echo "httpgd descriptor was not published"; cat "$work/r.log"; exit 1; }
if grep -q "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["token"])' "$work/results/httpgd.json")" "$work/r.log"; then
    echo "token leaked into console output"; exit 1
fi
cd "$project"
# Same build-system selection as scripts/build-app.sh.
build_system=""
if swift build --help | /usr/bin/grep -q -- '--build-system'; then build_system="--build-system native"; fi
# shellcheck disable=SC2086
RELAY_HTTPGD_LIVE_DIR="$work" swift test $build_system --disable-xctest --filter httpgdLiveDevice
touch "$work/stop"
wait "$rpid" || true
[ ! -f "$work/results/httpgd.json" ] || { echo "descriptor survived relay_r_httpgd_stop"; exit 1; }
echo "Live httpgd integration passed"
