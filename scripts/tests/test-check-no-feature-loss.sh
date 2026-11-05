#!/bin/bash
# Fixture apps for check-no-feature-loss.sh: each candidate loses exactly one
# kind of feature and must be refused with that loss named; an approved loss
# and a lossless newer build must pass.
set -u
here=$(cd "$(dirname "$0")" && pwd)
gate=$here/../check-no-feature-loss.sh
root=$(mktemp -d "${TMPDIR:-/tmp}/relay-gate-test.XXXXXX")
trap 'rm -rf "$root"' EXIT
failures=0

# make_app DIR VERSION TOOLS MIKO MODEL SETTINGS HELPERS AMD64SHA
make_app() {
    local app=$1 c=$1/Contents
    mkdir -p "$c/MacOS" "$c/Resources/Relay_Relay.bundle/Rotation"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $2" "$c/Info.plist" >/dev/null
    local tools=""
    for t in $3; do tools="$tools{\"name\":\"$t\"},"; done
    printf '#!/bin/sh\nprintf %%s %q\n' "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[${tools%,}]}}" > "$c/MacOS/relay-mcp"
    chmod 755 "$c/MacOS/relay-mcp"
    local miko=""
    for t in $4; do miko="$miko{\"name\":\"$t\"},"; done
    printf '[%s]' "${miko%,}" > "$c/Resources/Relay_Relay.bundle/Rotation/miko_tool_catalog.json"
    : > "$c/MacOS/relayd"
    for t in $5; do printf 'xx{"name":"%s"}yy\n' "$t" >> "$c/MacOS/relayd"; done
    : > "$c/MacOS/Relay"
    for k in $6; do printf 'key "%s" used\n' "$k" >> "$c/MacOS/Relay"; done
    for h in $7; do : > "$c/MacOS/$h"; done
    printf '{"sha256":{"Resources/relayd-linux-amd64":"%s"}}' "$8" > "$c/Resources/relay-release.json"
}

TOOLS="relay_list_panes relay_ask_miko relay_read_viewport"
MIKO="relay_list_panes relay_read_viewport"
MODEL="read_viewport read_handoff"
SETTINGS="relay.settings.miko-host relay.settings.haiku-pane-health"
HELPERS="relay-bridge relay-workspace"
make_app "$root/installed.app" 100 "$TOOLS" "$MIKO" "$MODEL" "$SETTINGS" "$HELPERS" aaaa

expect() { # NAME WANT(PASS|ABORT) LOSS-LINE ALLOWLIST CANDIDATE...
    local name=$1 want=$2 loss=$3 allow=$4; shift 4
    make_app "$root/$name.app" "$@"
    local output status
    output=$("$gate" "$root/installed.app" "$root/$name.app" "$root/out-$name" "$allow" 2>&1); status=$?
    if [ "$want" = PASS ] && [ $status -eq 0 ] && [[ $output == PASS* ]]; then echo "ok   $name"; return; fi
    if [ "$want" = ABORT ] && [ $status -eq 1 ] && [[ $output == ABORT* ]] && grep -qxF "$loss" "$root/out-$name/unapproved.txt"; then
        echo "ok   $name"; return
    fi
    echo "FAIL $name (status $status): $output"; failures=$((failures + 1))
}

none=$root/none.allow; : > "$none"
expect lossless PASS - "$none" 101 "$TOOLS relay_broadcast_message" "$MIKO" "$MODEL" "$SETTINGS relay.settings.extra" "$HELPERS" aaaa
expect mcp-tool ABORT "mcp-tool relay_ask_miko" "$none" 101 "relay_list_panes relay_read_viewport" "$MIKO" "$MODEL" "$SETTINGS" "$HELPERS" aaaa
expect miko-tool ABORT "miko-tool relay_read_viewport" "$none" 101 "$TOOLS" "relay_list_panes" "$MODEL" "$SETTINGS" "$HELPERS" aaaa
expect model-tool ABORT "model-tool read_handoff" "$none" 101 "$TOOLS" "$MIKO" "read_viewport" "$SETTINGS" "$HELPERS" aaaa
expect setting ABORT "setting relay.settings.miko-host" "$none" 101 "$TOOLS" "$MIKO" "$MODEL" "relay.settings.haiku-pane-health" "$HELPERS" aaaa
expect helper ABORT "helper relay-workspace" "$none" 101 "$TOOLS" "$MIKO" "$MODEL" "$SETTINGS" "relay-bridge" aaaa
expect payload ABORT "payload Resources/relayd-linux-amd64" "$none" 101 "$TOOLS" "$MIKO" "$MODEL" "$SETTINGS" "$HELPERS" bbbb
expect version ABORT "version older" "$none" 100 "$TOOLS" "$MIKO" "$MODEL" "$SETTINGS" "$HELPERS" aaaa
approved=$root/approved.allow; printf '# user approved 2026-10-29\nmcp-tool relay_ask_miko\n' > "$approved"
expect approved PASS - "$approved" 101 "relay_list_panes relay_read_viewport" "$MIKO" "$MODEL" "$SETTINGS" "$HELPERS" aaaa
expect partly-approved ABORT "helper relay-workspace" "$approved" 101 "relay_list_panes relay_read_viewport" "$MIKO" "$MODEL" "$SETTINGS" "relay-bridge" aaaa
if [ $failures -ne 0 ]; then echo "$failures gate case(s) failed"; exit 1; fi
echo "all gate cases passed"
