#!/bin/bash
# Shared local/remote cc-status launcher. Credentials remain with the provider.
set -u
root="$HOME/.claude/plugins/cache/genomewalker-cc-status/cc-status"
# Claude runs this on every status refresh in every pane. Resolving the entry
# point and probing Node with --version doubled the Node starts per refresh,
# so the resolution is cached until the plugin directory or Node changes.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/relay/cc-status.resolved"
# Each refresh also started Node itself: on a busy host (dandy-07, load 131,
# 2026-11-23) about eight ran at once. Each session's line is kept for
# CC_STATUS_TTL seconds (60; 0 turns it off) and Node runs at lower priority.
out_dir="${XDG_CACHE_HOME:-$HOME/.cache}/relay/cc-status-out"
ttl=${CC_STATUS_TTL:-60}
[[ $ttl =~ ^[0-9]{1,6}$ ]] || ttl=60
session='' input=''
if [ "${1:-}" != --check ]; then
    input=$(cat; printf x); input=${input%x}
    if [[ $input =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]{1,128})\" ]]; then
        session=${BASH_REMATCH[1]}
    fi
fi
if [ -n "$session" ] && (( ttl > 0 )) && [ -f "$out_dir/$session" ]; then
    mtime=$(stat -c %Y "$out_dir/$session" 2>/dev/null || stat -f %m "$out_dir/$session" 2>/dev/null)
    now=${EPOCHSECONDS:-$(date +%s)}
    if [[ $mtime =~ ^[0-9]+$ ]] && (( now >= mtime && now - mtime < ttl )); then
        cat "$out_dir/$session" && exit 0
    fi
fi
run_status() {
    if [ -z "$session" ] || (( ttl == 0 )) || ! (umask 077; mkdir -p "$out_dir") 2>/dev/null; then
        printf '%s' "$input" | nice -n 10 "$1" "$2"
        exit
    fi
    # Lines of sessions that ended are removed after an hour.
    find "$out_dir" -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null
    local tmp="$out_dir/.$session.$$" status
    printf '%s' "$input" | nice -n 10 "$1" "$2" > "$tmp"
    status=$?
    cat "$tmp" 2>/dev/null
    # A failed run is shown once but not kept, so the next refresh retries.
    if (( status == 0 )) && [ -s "$tmp" ]; then
        mv -f "$tmp" "$out_dir/$session" 2>/dev/null || rm -f "$tmp"
        exit 0
    fi
    rm -f "$tmp"
    exit "$status"
}
if [ "${1:-}" != --check ] && [ -f "$cache" ] && [ "$cache" -nt "$root" ] &&
    IFS= read -r node < "$cache" && entry=$(sed -n 2p "$cache") &&
    [ -n "$node" ] && [ -x "$node" ] && [ "$cache" -nt "$node" ] &&
    [ -n "$entry" ] && [ -f "$entry" ]; then
    run_status "$node" "$entry"
fi
entry='' max_major=-1 max_minor=-1 max_patch=-1
for candidate in "$root"/*/dist/index.js; do
    [ -f "$candidate" ] || continue
    version=${candidate%/dist/index.js}; version=${version##*/}
    [[ $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
    major=$((10#${BASH_REMATCH[1]})); minor=$((10#${BASH_REMATCH[2]})); patch=$((10#${BASH_REMATCH[3]}))
    if (( major > max_major || (major == max_major && minor > max_minor) || (major == max_major && minor == max_minor && patch > max_patch) )); then
        entry=$candidate; max_major=$major; max_minor=$minor; max_patch=$patch
    fi
done
if [ -z "$entry" ]; then printf '[cc-status] No installed plugin entry point\n' >&2; exit 1; fi
node=''
path_node=$(command -v node 2>/dev/null || true)
for candidate in "$HOME/.claude/nodejs/bin/node" /opt/homebrew/bin/node /usr/local/bin/node "$path_node" "$HOME/.local/bin/node" /usr/bin/node; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" --version >/dev/null 2>&1; then node=$candidate; break; fi
done
if [ -z "$node" ]; then printf '[cc-status] No working Node runtime found\n' >&2; exit 1; fi
if [ "${1:-}" = --check ]; then printf 'Node: %s\nPlugin: %s.%s.%s\n' "$node" "$max_major" "$max_minor" "$max_patch"; exit 0; fi
# A cache that cannot be written only costs the next refresh a full lookup.
if mkdir -p "${cache%/*}" 2>/dev/null; then
    tmp="$cache.$$"
    printf '%s\n%s\n' "$node" "$entry" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp" 2>/dev/null
fi
run_status "$node" "$entry"
