#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_entry="$project_root/Sources/Relay/Resources/Terminfo/xterm-relay.terminfo"
swift_target="$project_root/Sources/Relay/Resources/Terminfo/78/xterm-relay"
go_target="$project_root/remote/relayd/internal/terminfo/assets/78/xterm-relay"

ghostty_database="${GHOSTTY_TERMINFO_DATABASE:-}"
if [[ -z "$ghostty_database" ]]; then
    for candidate in \
        "$project_root/.build/arm64-apple-macosx/release/GhosttyKit_GhosttyTerminal.bundle/terminfo" \
        "$project_root/.build/arm64-apple-macosx/debug/GhosttyKit_GhosttyTerminal.bundle/terminfo"
    do
        if [[ -d "$candidate" ]]; then
            ghostty_database="$candidate"
            break
        fi
    done
fi

if [[ ! -d "$ghostty_database" ]]; then
    echo "Ghostty terminfo database is unavailable; build Relay first or set GHOSTTY_TERMINFO_DATABASE" >&2
    exit 1
fi

tic_binary=""
for candidate in \
    /opt/homebrew/opt/ncurses/bin/tic \
    /usr/local/opt/ncurses/bin/tic \
    /usr/bin/tic
do
    if [[ -x "$candidate" ]]; then
        tic_binary="$candidate"
        break
    fi
done
if [[ -z "$tic_binary" ]]; then
    echo "ncurses tic is required to generate xterm-relay" >&2
    exit 1
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/relay-terminfo.XXXXXX")"
trap '/bin/rm -rf "$stage"' EXIT
TERMINFO="$ghostty_database" "$tic_binary" -x -o "$stage" "$source_entry"
compiled="$stage/78/xterm-relay"
if [[ ! -s "$compiled" ]]; then
    echo "tic did not produce xterm-relay" >&2
    exit 1
fi

infocmp_binary="${tic_binary%/tic}/infocmp"
if [[ ! -x "$infocmp_binary" ]]; then
    infocmp_binary=/usr/bin/infocmp
fi
"$infocmp_binary" -A "$stage" xterm-relay >/dev/null

mkdir -p "$(dirname "$swift_target")" "$(dirname "$go_target")"
install -m 0644 "$compiled" "$swift_target"
install -m 0644 "$compiled" "$go_target"
hash="$(shasum -a 256 "$compiled" | awk '{print $1}')"
echo "generated xterm-relay $hash"
