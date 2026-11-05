#!/bin/bash
# Fixture tests for scripts/build-app-steps.sh. Usage: test-build-app-steps.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../build-app-steps.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/build-app-steps.XXXXXX")"
trap '/bin/chmod -R u+w "$work"; /bin/rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

# check_rotation_resources: pin the native ports' primary references and reject
# any stale interpreter asset, replacing obsolete duplicate-script equality.
root="$work/rotation"
for relative in Sources/Relay/Resources/Rotation/miko_tool_catalog.json \
    remote/relayd/internal/daemon/testdata/host_rotation_policy/golden.json \
    remote/relayd/internal/daemon/testdata/host_pane_health_controller/golden.json; do
    mkdir -p "$root/$(dirname "$relative")"
    cp "$here/../../$relative" "$root/$relative"
done
check_rotation_resources "$root" >/dev/null && pass "matching native references" || fail "matching native references refused"
printf 'drift\n' >> "$root/Sources/Relay/Resources/Rotation/miko_tool_catalog.json"
message="$(check_rotation_resources "$root" 2>&1)" && fail "drifted native reference accepted" ||
    { [[ "$message" == *"native reference drift:"* ]] && pass "drifted native reference refused" || fail "unexpected drift message: $message"; }
/bin/rm "$root/Sources/Relay/Resources/Rotation/miko_tool_catalog.json"
check_rotation_resources "$root" >/dev/null 2>&1 && fail "missing native reference accepted" || pass "missing native reference refused"
cp "$here/../../Sources/Relay/Resources/Rotation/miko_tool_catalog.json" "$root/Sources/Relay/Resources/Rotation/"
printf 'stale' > "$root/Sources/Relay/Resources/Rotation/text_backend.py"
check_rotation_resources "$root" >/dev/null 2>&1 && fail "stale interpreter resource accepted" || pass "stale interpreter resource refused"

# check_native_library
library_case() {
    local root="$work/native-$1"
    mkdir -p "$root/NativePatches" "$root/BinaryTarget/GhosttyKit.xcframework/macos-arm64_x86_64"
    printf '%s' "$2" > "$root/BinaryTarget/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a"
    printf '{"other": 1, "library_sha256": "%s"}' "$(printf '%s' "$3" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" \
        > "$root/NativePatches/build-provenance.json"
    check_native_library "$root"
}
library_case match fixed fixed >/dev/null && pass "matching library" || fail "matching library refused"
message="$(library_case older older fixed 2>&1)" && fail "other library accepted" ||
    { [[ "$message" == *"install the matching library first."* ]] && pass "other library refused" || fail "message: $message"; }
mkdir -p "$work/native-none/NativePatches"
printf '{"library_sha256": "%s"}' "$(printf '' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" > "$work/native-none/NativePatches/build-provenance.json"
check_native_library "$work/native-none" >/dev/null 2>&1 && fail "missing library accepted" || pass "missing library refused"
check_native_library "$here/../../Vendor/libghostty-spm" >/dev/null && pass "this source tree is consistent" || fail "this source tree's library differs"

# copy_resource_bundle
source_bundle="$work/source.bundle"
mkdir -p "$source_bundle/Rotation/__pycache__" "$source_bundle/deep/__pycache__/inner" "$work/outside"
printf 'kept' > "$source_bundle/Rotation/policy.py"
printf 'bytecode' > "$source_bundle/Rotation/__pycache__/policy.cpython-314.pyc"
printf 'bytecode' > "$source_bundle/Rotation/stray.pyc"
printf 'deep' > "$source_bundle/deep/__pycache__/inner/file"
printf 'linked file' > "$work/outside/target.txt"
printf 'linked dir' > "$work/outside/in-dir.txt"
ln -s "$work/outside/target.txt" "$source_bundle/link-to-file"
ln -s "$work/outside" "$source_bundle/link-to-dir"
printf 'x' > "$source_bundle/executable"; chmod 755 "$source_bundle/executable"
printf 'r' > "$source_bundle/readonly"; chmod 444 "$source_bundle/readonly"
copy_resource_bundle "$source_bundle" "$work/copied.bundle"
[[ -f "$work/copied.bundle/Rotation/policy.py" ]] && pass "resource copied" || fail "resource missing"
[[ ! -e "$work/copied.bundle/Rotation/__pycache__" && ! -e "$work/copied.bundle/Rotation/stray.pyc" &&
   ! -e "$work/copied.bundle/deep/__pycache__" && -d "$work/copied.bundle/deep" ]] &&
    pass "bytecode caches excluded" || fail "bytecode cache copied"
[[ -f "$work/copied.bundle/link-to-file" && ! -L "$work/copied.bundle/link-to-file" &&
   "$(cat "$work/copied.bundle/link-to-file")" == "linked file" ]] && pass "file symlink materialized" || fail "file symlink kept"
[[ -d "$work/copied.bundle/link-to-dir" && ! -L "$work/copied.bundle/link-to-dir" &&
   -f "$work/copied.bundle/link-to-dir/in-dir.txt" ]] && pass "directory symlink materialized" || fail "directory symlink kept"
[[ "$(stat -f %Lp "$work/copied.bundle/executable")" == 755 && "$(stat -f %Lp "$work/copied.bundle/readonly")" == 444 ]] &&
    pass "modes preserved" || fail "modes changed"
copy_resource_bundle "$source_bundle" "$work/copied.bundle" 2>/dev/null && fail "existing destination merged" || pass "existing destination refused"

# copy_ghostty_resources
ghostty_source="$work/ghostty-source"
for relative in Ghostty/shell-integration/bash/bash-preexec.sh Ghostty/shell-integration/bash/ghostty.bash \
    Ghostty/shell-integration/elvish/lib/ghostty-integration.elv \
    Ghostty/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish \
    Ghostty/shell-integration/nushell/vendor/autoload/ghostty.nu Ghostty/shell-integration/zsh/ghostty-integration \
    terminfo/67/ghostty terminfo/78/xterm-ghostty; do
    mkdir -p "$ghostty_source/$(dirname "$relative")"
    printf 'content of %s' "$relative" > "$ghostty_source/$relative"
done
destination="$work/ghostty-destination"
mkdir -p "$destination/Ghostty/shell-integration/bash" "$destination/terminfo/67"
copy_ghostty_resources "$ghostty_source" "$destination" && pass "Ghostty resources merged into stubs" || fail "Ghostty merge failed"
[[ ! -e "$destination/Ghostty/Ghostty" && ! -e "$destination/terminfo/terminfo" &&
   "$(cat "$destination/terminfo/78/xterm-ghostty")" == "content of terminfo/78/xterm-ghostty" ]] &&
    pass "Ghostty merge did not nest" || fail "Ghostty merge nested"
copy_ghostty_resources "$ghostty_source" "$destination" && pass "Ghostty merge is repeatable" || fail "second Ghostty merge failed"
: > "$ghostty_source/terminfo/67/ghostty"
copy_ghostty_resources "$ghostty_source" "$work/ghostty-empty" 2>/dev/null && fail "empty Ghostty resource accepted" ||
    pass "empty Ghostty resource refused"
copy_ghostty_resources "$work/outside" "$work/ghostty-none" 2>/dev/null && fail "missing Ghostty source accepted" ||
    pass "missing Ghostty source refused"

# check_daemon_communication_assets
root="$work/communication"
mkdir -p "$root/remote/relayd/internal/daemon/communication_runtime"
check_daemon_communication_assets "$root" && pass "native communication needs no copied assets" || fail "empty native assets refused"
printf 'stale' > "$root/remote/relayd/internal/daemon/communication_runtime/pane_messaging.py"
check_daemon_communication_assets "$root" >/dev/null 2>&1 && fail "stale communication script accepted" || pass "stale communication script refused"
[[ "$(cat "$root/remote/relayd/internal/daemon/communication_runtime/pane_messaging.py")" == stale ]] && pass "check did not mutate source" || fail "check overwrote source"

# write_release_manifest
app="$work/Relay.app"
mkdir -p "$app/Contents/Resources/dir-linux-x"
printf 'amd' > "$app/Contents/Resources/relayd-linux-amd64"
printf 'arm' > "$app/Contents/Resources/relay-mcp-linux-arm64"
printf 'other' > "$app/Contents/Resources/RelayIcon.icns"
sha() { printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }
expected="$(printf '{\n  "app_version": "1.2",\n  "daemon_version": "q\\"\\\\\\u00e9\\ud83d\\ude00",\n  "build_number": "7",\n  "source_digest": null,\n  "sha256": {\n    "Resources/relay-mcp-linux-arm64": "%s",\n    "Resources/relayd-linux-amd64": "%s"\n  }\n}\nX' "$(sha arm)" "$(sha amd)")"
(unset RELAY_SOURCE_DIGEST; write_release_manifest "$app" 1.2 "q\"\\é😀" 7)
[[ "$(cat "$app/Contents/Resources/relay-release.json"; printf X)" == "$expected" ]] && pass "release manifest format" ||
    fail "release manifest: $(cat "$app/Contents/Resources/relay-release.json")"
RELAY_SOURCE_DIGEST="" write_release_manifest "$app" 1 1 1
grep -q '"source_digest": "",' "$app/Contents/Resources/relay-release.json" && pass "empty digest is a string" || fail "empty digest"
RELAY_SOURCE_DIGEST="abc" write_release_manifest "$app" 1 1 1
grep -q '"source_digest": "abc",' "$app/Contents/Resources/relay-release.json" && pass "digest recorded" || fail "digest"
empty="$work/Empty.app"; mkdir -p "$empty/Contents/Resources"
(unset RELAY_SOURCE_DIGEST; write_release_manifest "$empty" 1 1 1)
[[ "$(tail -2 "$empty/Contents/Resources/relay-release.json")" == $'  "sha256": {}\n}' ]] && pass "no payloads" || fail "no payloads"

echo "failures: $failures"
[[ $failures -eq 0 ]]
