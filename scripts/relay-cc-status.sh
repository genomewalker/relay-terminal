#!/bin/bash
# Shared local/remote cc-status launcher. Credentials remain with the provider.
set -u
root="$HOME/.claude/plugins/cache/genomewalker-cc-status/cc-status"
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
exec "$node" "$entry"
