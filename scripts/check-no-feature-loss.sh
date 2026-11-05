#!/bin/bash
# Refuses an app replacement that would lose a feature the running app has.
# Usage: check-no-feature-loss.sh INSTALLED.app CANDIDATE.app OUT_DIR [ALLOWLIST]
# Each ALLOWLIST line is "<kind> <name>" for one loss the user approved, for
# example "mcp-tool relay_read_viewport" or "payload Resources/relayd-linux-amd64".
# Kinds: helper, mcp-tool, miko-tool, model-tool, setting, payload, version.
# Exit 0 prints PASS; exit 1 prints ABORT and every unapproved loss.
set -u
[ $# -ge 3 ] || { echo "usage: $0 INSTALLED.app CANDIDATE.app OUT_DIR [ALLOWLIST]" >&2; exit 2; }
installed=$1 candidate=$2 out=$3 allow=${4:-/dev/null}
mkdir -p "$out" || exit 2

inventory() { # app side
    local app=$1 side=$2 c=$1/Contents
    { ls "$c/MacOS"; ls "$c/Resources" | grep -- '-linux-'; } | sort -u | sed 's/^/helper /' > "$out/$side.helper"
    printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' |
        env -i HOME=/nonexistent PATH=/usr/bin:/bin "$c/MacOS/relay-mcp" 2>/dev/null |
        /usr/bin/python3 -I -c 'import json,sys
for t in json.load(sys.stdin)["result"]["tools"]: print("mcp-tool", t["name"])' | sort -u > "$out/$side.mcp-tool"
    # Builds before the Miko catalog have none; an empty list is then correct.
    find "$c/Resources" -name miko_tool_catalog.json -print0 | xargs -0 cat 2>/dev/null |
        /usr/bin/python3 -I -c 'import json,sys
text = sys.stdin.read()
for t in (json.loads(text) if text.strip() else []): print("miko-tool", t["name"])' | sort -u > "$out/$side.miko-tool"
    LC_ALL=C grep -aoE '"name":"[a-z_]{3,64}","type":"object"|"name":"[a-z_]{3,64}"\}' "$c/MacOS/relayd" |
        sed -E 's/"name":"([a-z_]+)".*/model-tool \1/' | sort -u > "$out/$side.model-tool"
    LC_ALL=C strings -n 12 "$c/MacOS/Relay" | grep -oE 'relay\.settings\.[a-z0-9.-]+[a-z0-9]' |
        sed 's/^/setting /' | sort -u > "$out/$side.setting"
    /usr/bin/python3 -I -c 'import json,sys
for k,v in sorted(json.load(open(sys.argv[1]))["sha256"].items()): print("payload", k, v)' "$c/Resources/relay-release.json" > "$out/$side.payload"
    /usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$c/Info.plist" > "$out/$side.version"
}

inventory "$installed" installed
inventory "$candidate" candidate
for side in installed candidate; do
    [ -s "$out/$side.mcp-tool" ] && [ -s "$out/$side.helper" ] && [ -s "$out/$side.payload" ] ||
        { echo "ABORT could not read the $side app's inventory"; exit 1; }
done

losses=$out/losses.txt
: > "$losses"
for kind in helper mcp-tool miko-tool model-tool setting; do
    comm -23 "$out/installed.$kind" "$out/candidate.$kind" >> "$losses"
done
# A payload is lost when it disappears or its bytes change (for example the
# qualified ENOLCK amd64 relayd being replaced by an older build).
/usr/bin/python3 -I - "$out/installed.payload" "$out/candidate.payload" >> "$losses" <<'EOF'
import sys
def read(p):
    return dict(line.split()[1:3] for line in open(p) if line.strip())
old, new = read(sys.argv[1]), read(sys.argv[2])
for name, digest in sorted(old.items()):
    if new.get(name) != digest:
        print("payload", name)
EOF
[ "$(cat "$out/candidate.version")" -gt "$(cat "$out/installed.version")" ] 2>/dev/null || echo "version older" >> "$losses"

unapproved=$out/unapproved.txt
grep -vxF -f <(grep -vE '^[[:space:]]*(#|$)' "$allow" | awk '{print $1" "$2}'; echo "#none") <(awk '{print $1" "$2}' "$losses") > "$unapproved" || true
advisory=$(comm -23 <(LC_ALL=C strings -n 8 "$installed/Contents/MacOS/Relay" | sort -u) <(LC_ALL=C strings -n 8 "$candidate/Contents/MacOS/Relay" | sort -u) | wc -l | tr -d ' ')
echo "advisory: $advisory strings of the installed Relay binary are absent from the candidate (not a gate)" > "$out/advisory.txt"
if [ -s "$unapproved" ]; then
    echo "ABORT $(wc -l < "$unapproved" | tr -d ' ') feature(s) would be lost; full list in $unapproved:"
    head -20 "$unapproved" | sed 's/^/  /'
    exit 1
fi
echo "PASS no unapproved feature loss ($(wc -l < "$losses" | tr -d ' ') approved); inventories in $out"
