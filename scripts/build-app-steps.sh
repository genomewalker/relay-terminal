# The Go module supplies all structured-data and executable-identity helpers.
relay_build_source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
relay_build_helper() {
    (cd "$relay_build_source_root/remote/relayd" && go run ./cmd/relay-build "$@")
}

# Packaging steps sourced by build-app.sh. Each one is a plain shell function so
# scripts/tests/test-build-app-steps.sh can exercise it on a fixture tree.

# Native ports use pinned reference vectors; no interpreter asset may be shipped.
check_rotation_resources() {
    relay_build_helper rotation-check "$1" || return 1
    echo "Native rotation references match; resources contain no Python."
}

# The prebuilt libghostty.a is not in git. Refuse to build with any library
# other than the one NativePatches/build-provenance.json names, so a source copy
# holding an older library (one without a native fix) cannot ship silently.
check_native_library() {
    local root="$1" expected actual
    expected="$(relay_build_helper provenance "$root/NativePatches/build-provenance.json")" || return 1
    actual="$(/usr/bin/shasum -a 256 "$root/BinaryTarget/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a" | /usr/bin/awk '{print $1}')"
    [[ -n "$actual" ]] || return 1
    if [[ "$actual" != "$expected" ]]; then
        echo "libghostty.a is $actual, but build-provenance.json names $expected; install the matching library first." >&2
        return 1
    fi
    echo "libghostty.a matches build-provenance.json."
}

# SwiftPM resource caches can contain symlinks to source assets. Materialize
# them (-L) so the installed bundle never depends on that build cache or
# checkout, and leave out Python bytecode caches.
copy_resource_bundle() {
    local source="$1" destination="$2"
    if [[ -e "$destination" || -L "$destination" ]]; then
        echo "resource bundle destination already exists: $destination" >&2
        return 1
    fi
    /bin/cp -RLp "$source" "$destination" || return 1
    /usr/bin/find "$destination" -mindepth 1 \( -name __pycache__ -o -name '*.pyc' \) -prune \
        -exec /bin/rm -rf {} + || return 1
}

# Xcode's SwiftPM cache can emit an empty resource bundle with directory stubs.
# Merge the pinned dependency's canonical resources into it.
copy_ghostty_resources() {
    local source="$1" destination="$2" name relative path
    for name in Ghostty terminfo; do
        if [[ ! -d "$source/$name" ]]; then
            echo "canonical Ghostty resources are missing" >&2
            return 1
        fi
        /bin/mkdir -p "$destination/$name" || return 1
        /bin/cp -RLp "$source/$name/." "$destination/$name/" || return 1
    done
    for relative in \
        Ghostty/shell-integration/bash/bash-preexec.sh \
        Ghostty/shell-integration/bash/ghostty.bash \
        Ghostty/shell-integration/elvish/lib/ghostty-integration.elv \
        Ghostty/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish \
        Ghostty/shell-integration/nushell/vendor/autoload/ghostty.nu \
        Ghostty/shell-integration/zsh/ghostty-integration \
        terminfo/67/ghostty terminfo/78/xterm-ghostty; do
        path="$destination/$relative"
        if [[ ! -f "$path" || ! -s "$path" ]]; then
            echo "packaged Ghostty resource is missing: $relative" >&2
            return 1
        fi
    done
}

# The native communication adapter is compiled into relayd. Refuse a stale
# interpreter payload rather than copying one into the source or app bundle.
check_daemon_communication_assets() {
    local root="$1" target
    target="$root/remote/relayd/internal/daemon/communication_runtime"
    if [[ -d "$target" ]]; then
        relay_build_helper assets-check "$target" || return 1
    fi
}

# relay-release.json: the release identity and the sha256 of every bundled
# Linux payload, preserving the established ASCII JSON byte format.
# source_digest is null only when RELAY_SOURCE_DIGEST is unset.
write_release_manifest() {
    relay_build_helper manifest "$@"
}
