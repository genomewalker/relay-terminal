#!/bin/bash
# Shared local/remote cc-status launcher. Credentials remain with the provider.
set -u
root="$HOME/.claude/plugins/cache/genomewalker-cc-status/cc-status"
# Claude runs this on every status refresh in every pane. Resolving the entry
# point and probing Node with --version doubled the Node starts per refresh,
# so the resolution is cached until the plugin directory or Node changes.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/relay/cc-status.resolved"
if [ "${1:-}" != --check ] && [ -f "$cache" ] && [ "$cache" -nt "$root" ] &&
    IFS= read -r node < "$cache" && entry=$(sed -n 2p "$cache") &&
    [ -n "$node" ] && [ -x "$node" ] && [ "$cache" -nt "$node" ] &&
    [ -n "$entry" ] && [ -f "$entry" ]; then
    exec "$node" "$entry"
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
exec "$node" "$entry"
