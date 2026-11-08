#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
app_version="${RELAY_APP_VERSION:-${RELAY_VERSION:-0.5.3}}"
relayd_version="${RELAYD_VERSION:-$app_version}"
relayd_protocol_version="${RELAYD_PROTOCOL_VERSION:-2}"
build_number="${RELAY_BUILD_NUMBER:-1}"
signing_identity="${RELAY_CODESIGN_IDENTITY:--}"
bundle_name="${RELAY_BUNDLE_NAME:-Relay}"
bundle_identifier="${RELAY_BUNDLE_IDENTIFIER:-dev.relay.terminal}"
build_jobs="${RELAY_BUILD_JOBS:-2}"
cd "$project_root"
source "$project_root/scripts/build-app-steps.sh"
check_rotation_resources "$project_root"
check_native_library "$project_root/Vendor/libghostty-spm"
swift_build_args=(-c "$configuration" --jobs "$build_jobs" --force-resolved-versions)
# Keep compiler caches outside File Provider and use SwiftPM's supported default.
# Canonicalize /tmp to /private/tmp so Clang never sees two module-cache paths.
build_scratch="${RELAY_BUILD_SCRATCH_PATH:-/private/tmp/relay-swiftpm-build}"
mkdir -p "$build_scratch"
build_scratch="$(cd "$build_scratch" && pwd -P)"
swift_build_args+=(--scratch-path "$build_scratch")
swift build "${swift_build_args[@]}"
binary_path="$(swift build "${swift_build_args[@]}" --show-bin-path)"

# Resource loaders must resolve Contents/Resources in an installed app. Do not
# rewrite generated SwiftPM accessors: subsequent builds regenerate them.
workspace_link="$project_root/Relay.app"
# A bundle inside Documents may be managed by File Provider, which immediately
# reapplies extended attributes and invalidates strict code-sign verification.
# Rebuild an existing system installation in place so Launch Services never
# sees two physical Relay bundles with the same identifier. Before the first
# system install, keep the development app in the user's Applications folder;
# callers can always choose explicitly with RELAY_APP_OUTPUT.
default_output="$HOME/Applications/Relay.app"
if [[ -d "/Applications/Relay.app" ]]; then
    default_output="/Applications/Relay.app"
fi
output_path="${RELAY_APP_OUTPUT:-$default_output}"

is_executable_running() {
    /bin/ps -axo comm= | relay_build_helper running "$1" 2>/dev/null
}
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/relay-app.XXXXXX")"
trap '/bin/rm -rf "$stage_root"' EXIT
app_path="$stage_root/Relay.app"

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/Relay" "$app_path/Contents/MacOS/Relay"
cp "$binary_path/relay-bridge" "$app_path/Contents/MacOS/relay-bridge"
# One signed Keychain client. Secrets use stdin/stdout pipes, never argv or files.
# Reuse the reviewed client while its source is unchanged: recompilation and
# signing can change an ad-hoc requirement that an existing Keychain item trusts.
credential_source_hash="$(/usr/bin/shasum -a 256 "$project_root/native/credentials/relay-credentials.swift" | /usr/bin/awk '{print $1}')"
credential_previous_source="$(/usr/libexec/PlistBuddy -c 'Print :RelayCredentialHelperSourceSHA256' "$output_path/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "$credential_previous_source" ]]; then
    if [[ "$credential_previous_source" != "$credential_source_hash" ]]; then
        echo "Credential helper source changed; prepare a Keychain migration before replacing the installed client." >&2
        exit 1
    fi
    credential_previous_hash="$(/usr/libexec/PlistBuddy -c 'Print :RelayCredentialHelperSHA256' "$output_path/Contents/Info.plist")"
    credential_actual_hash="$(/usr/bin/shasum -a 256 "$output_path/Contents/MacOS/relay-credentials" | /usr/bin/awk '{print $1}')"
    if [[ "$credential_actual_hash" != "$credential_previous_hash" ]]; then
        echo "Installed credential helper differs from its reviewed hash." >&2
        exit 1
    fi
    /usr/bin/codesign --verify --strict "$output_path/Contents/MacOS/relay-credentials"
    cp -p "$output_path/Contents/MacOS/relay-credentials" "$app_path/Contents/MacOS/relay-credentials"
else
    /usr/bin/swiftc -O "$project_root/native/credentials/relay-credentials.swift" \
        -o "$app_path/Contents/MacOS/relay-credentials"
fi
credential_helper_hash="$(/usr/bin/shasum -a 256 "$app_path/Contents/MacOS/relay-credentials" | /usr/bin/awk '{print $1}')"

# This bridge runs as the user, never as root. The privileged tunnel service is
# separate; Homebrew libraries must not be loaded by a privileged service.
if command -v pkg-config >/dev/null && pkg-config --exists openconnect; then
    read -r -a vpn_cflags <<< "$(pkg-config --cflags openconnect)"
    read -r -a vpn_libs <<< "$(pkg-config --libs openconnect)"
    /usr/bin/clang -fobjc-arc -framework Foundation -framework Security "${vpn_cflags[@]}" \
        "$project_root/native/vpn/relay-vpn-auth.m" "${vpn_libs[@]}" \
        -o "$app_path/Contents/MacOS/relay-vpn-auth"
    if [[ "$signing_identity" == "-" ]]; then
        /usr/bin/codesign --force --sign - "$app_path/Contents/MacOS/relay-vpn-auth"
    else
        /usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_path/Contents/MacOS/relay-vpn-auth"
    fi
    vpn_auth_hash="$(/usr/bin/codesign -d --verbose=4 "$app_path/Contents/MacOS/relay-vpn-auth" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')"
    if [[ ! "$vpn_auth_hash" =~ ^[0-9a-fA-F]{40}$ ]]; then echo "VPN bridge signature hash missing" >&2; exit 1; fi
    printf '#define RELAY_VPN_AUTH_REQUIREMENT "cdhash H\\"%s\\""\n' "$vpn_auth_hash" > "$stage_root/vpn-requirement.h"
    /usr/bin/clang -fobjc-arc -framework Foundation -framework SystemConfiguration \
        -include "$stage_root/vpn-requirement.h" "$project_root/native/vpn/relay-vpn-network.m" \
        -o "$app_path/Contents/MacOS/relay-vpn-network"
    mkdir -p "$app_path/Contents/Library/LaunchDaemons"
    cp "$project_root/native/vpn/dev.relay.terminal.vpn-network.plist" "$app_path/Contents/Library/LaunchDaemons/"
fi
# SwiftPM emits one resource bundle for Relay and another for Ghostty's
# terminfo/shell-integration assets. Copy all of them so a packaged app never
# falls back to absolute development paths in .build (which may be offline or
# File Provider-managed).
for resource_bundle in "$binary_path"/*.bundle; do
    if [[ -d "$resource_bundle" ]]; then
        copy_resource_bundle "$resource_bundle" "$app_path/Contents/Resources/$(basename "$resource_bundle")"
    fi
done

resource_root() {
    local bundle="$1"
    if [[ -d "$bundle/Contents/Resources" ]]; then
        printf '%s\n' "$bundle/Contents/Resources"
    else
        printf '%s\n' "$bundle"
    fi
}
ghostty_bundle="$(resource_root "$app_path/Contents/Resources/GhosttyKit_GhosttyTerminal.bundle")"
# Xcode's SwiftPM cache can emit an empty resource bundle with directory stubs.
# Copy the pinned dependency's canonical resources as part of packaging.
copy_ghostty_resources "$project_root/Vendor/libghostty-spm/Sources/GhosttyTerminal/Resources" "$ghostty_bundle"
if [[ ! -d "$ghostty_bundle/Ghostty" || ! -d "$ghostty_bundle/terminfo" ]]; then
    echo "packaged Ghostty resources are incomplete" >&2
    exit 1
fi

relay_bundle="$(resource_root "$app_path/Contents/Resources/Relay_Relay.bundle")"
relay_terminfo="$relay_bundle/Terminfo/78/xterm-relay"
if [[ ! -s "$relay_terminfo" ]]; then
    echo "packaged xterm-relay entry is missing" >&2
    exit 1
fi
if ! /opt/homebrew/opt/ncurses/bin/infocmp -A "$relay_bundle/Terminfo" xterm-relay >/dev/null 2>&1 &&
   ! /usr/bin/infocmp -A "$relay_bundle/Terminfo" xterm-relay >/dev/null 2>&1; then
    echo "packaged xterm-relay entry is not resolvable" >&2
    exit 1
fi

# Remote installation is explicit in the UI, but it must remain offline and
# reproducible once authorized. Bundle the exact static Linux helpers inside
# the signed app rather than downloading an executable at connection time.
check_daemon_communication_assets "$project_root"
native_helper_names="$(relay_build_helper helper-names)"
for relay_architecture in amd64 arm64; do
    (
        cd "$project_root/remote/relayd"
        CGO_ENABLED=0 GOOS=linux GOARCH="$relay_architecture" \
            go build -trimpath -ldflags="-s -w -X main.relaydVersion=$relayd_version" \
            -o "$app_path/Contents/Resources/relayd-linux-$relay_architecture" ./cmd/relayd
    )
    chmod 0555 "$app_path/Contents/Resources/relayd-linux-$relay_architecture"
    (
        cd "$project_root/remote/relayd"
        CGO_ENABLED=0 GOOS=linux GOARCH="$relay_architecture" \
            go build -trimpath -ldflags="-s -w" \
            -o "$app_path/Contents/Resources/relay-peer-link-linux-$relay_architecture" ./cmd/relay-peer-link
    )
    chmod 0555 "$app_path/Contents/Resources/relay-peer-link-linux-$relay_architecture"
    (
        cd "$project_root/remote/relayd"
        CGO_ENABLED=0 GOOS=linux GOARCH="$relay_architecture" \
            go build -trimpath -ldflags="-s -w" \
            -o "$app_path/Contents/Resources/relay-mcp-linux-$relay_architecture" ./cmd/relay-mcp
    )
    chmod 0555 "$app_path/Contents/Resources/relay-mcp-linux-$relay_architecture"
    while IFS= read -r relay_helper; do
        [[ -n "$relay_helper" ]] || continue
        (
            cd "$project_root/remote/relayd"
            CGO_ENABLED=0 GOOS=linux GOARCH="$relay_architecture" \
                go build -trimpath -ldflags="-s -w" \
                -o "$app_path/Contents/Resources/$relay_helper-linux-$relay_architecture" "./cmd/$relay_helper"
        )
        chmod 0555 "$app_path/Contents/Resources/$relay_helper-linux-$relay_architecture"
    done <<< "$native_helper_names"
done

# The Linux payloads cannot run on the build Mac. Build the same source for the
# host once and verify the embedded helper version before signing the bundle.
relayd_version_check="$stage_root/relayd-version-check"
# cgo is required on macOS: the supervisor is spawned with a responsibility
# disclaim so pane programs get relayd's privacy grants, not the launching app's.
# Pin Apple clang so an activated conda or Homebrew toolchain is never used.
(
    cd "$project_root/remote/relayd"
    CGO_ENABLED=1 CC=/usr/bin/clang go build -trimpath -ldflags="-X main.relaydVersion=$relayd_version" \
        -o "$relayd_version_check" ./cmd/relayd
)
if ! go version -m "$relayd_version_check" | grep -q 'CGO_ENABLED=1'; then
    echo "relayd was built without cgo; supervisor privacy attribution would regress" >&2
    exit 1
fi
if [[ "$($relayd_version_check --version)" != "relayd $relayd_version" ]]; then
    echo "relayd version stamping failed" >&2
    exit 1
fi
cp "$relayd_version_check" "$app_path/Contents/MacOS/relayd"
(
    cd "$project_root/remote/relayd"
    go build -trimpath -ldflags="-s -w" -o "$app_path/Contents/MacOS/relay-mcp" ./cmd/relay-mcp
    # Work threads start this frontend from the installed bundle, and relayd's
    # Work origin proof names its path, so the bundle must always carry it.
    go build -trimpath -ldflags="-s -w" -o "$app_path/Contents/MacOS/relay-work-mcp" ./cmd/relay-work-mcp
    go build -trimpath -ldflags="-s -w" -o "$app_path/Contents/MacOS/relay-peer-link" ./cmd/relay-peer-link
    go build -trimpath -ldflags="-s -w" -o "$app_path/Contents/MacOS/relay-connection" ./cmd/relay-connection
    go build -trimpath -ldflags="-s -w" -o "$app_path/Contents/MacOS/relay-workspace" ./cmd/relay-workspace
)
if [[ ! -f "$app_path/Contents/MacOS/relay-work-mcp" || ! -x "$app_path/Contents/MacOS/relay-work-mcp" ]]; then
    echo "relay-work-mcp was not built into the bundle" >&2
    exit 1
fi
while IFS= read -r relay_helper; do
    [[ -n "$relay_helper" ]] || continue
    (cd "$project_root/remote/relayd" && go build -trimpath -ldflags="-s -w" \
        -o "$app_path/Contents/MacOS/$relay_helper" "./cmd/$relay_helper")
done <<< "$native_helper_names
relay-restart
relay-preserving-update"
# Reject stale SwiftPM resources in the completed bundle before signing.
relay_build_helper assets-check "$app_path/Contents/Resources"
write_release_manifest "$app_path" "$app_version" "$relayd_version" "$build_number"
mkdir -p "$app_path/Contents/Resources/R"
cp "$project_root/remote/r/relay-r.R" "$app_path/Contents/Resources/R/relay-r.R"
cp "$project_root/remote/r/editor-tools.R" "$app_path/Contents/Resources/R/editor-tools.R"

icon_source="$project_root/Resources/RelayIcon.png"
if [[ -f "$icon_source" ]]; then
    iconset="$stage_root/RelayIcon.iconset"
    mkdir -p "$iconset"
    /usr/bin/sips -z 16 16 "$icon_source" --out "$iconset/icon_16x16.png" >/dev/null
    /usr/bin/sips -z 32 32 "$icon_source" --out "$iconset/icon_16x16@2x.png" >/dev/null
    /usr/bin/sips -z 32 32 "$icon_source" --out "$iconset/icon_32x32.png" >/dev/null
    /usr/bin/sips -z 64 64 "$icon_source" --out "$iconset/icon_32x32@2x.png" >/dev/null
    /usr/bin/sips -z 128 128 "$icon_source" --out "$iconset/icon_128x128.png" >/dev/null
    /usr/bin/sips -z 256 256 "$icon_source" --out "$iconset/icon_128x128@2x.png" >/dev/null
    /usr/bin/sips -z 256 256 "$icon_source" --out "$iconset/icon_256x256.png" >/dev/null
    /usr/bin/sips -z 512 512 "$icon_source" --out "$iconset/icon_256x256@2x.png" >/dev/null
    /usr/bin/sips -z 512 512 "$icon_source" --out "$iconset/icon_512x512.png" >/dev/null
    /usr/bin/sips -z 1024 1024 "$icon_source" --out "$iconset/icon_512x512@2x.png" >/dev/null
    /usr/bin/iconutil -c icns "$iconset" -o "$app_path/Contents/Resources/RelayIcon.icns"
fi
/usr/libexec/PlistBuddy -c "Clear dict" "$app_path/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $bundle_name" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $bundle_name" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_identifier" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Relay" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string RelayIcon" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $app_version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$app_path/Contents/Info.plist"
# Update builds preserve installation-scoped consent. A fresh installation/reset
# explicitly rotates this identity; it never imports the old granted capabilities.
installation_id="${RELAY_INSTALLATION_ID:-}"
if [[ -z "$installation_id" && "${RELAY_FRESH_INSTALL:-0}" != "1" ]]; then
    installation_source="$output_path"
    if [[ "$bundle_identifier" == "dev.relay.terminal" && ! -f "$installation_source/Contents/Info.plist" ]]; then
        installation_source="/Applications/Relay.app"
    fi
    installation_id="$(/usr/libexec/PlistBuddy -c 'Print :RelayInstallationID' "$installation_source/Contents/Info.plist" 2>/dev/null || true)"
fi
if [[ ! "$installation_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    installation_id="$(/usr/bin/uuidgen)"
fi
/usr/libexec/PlistBuddy -c "Add :RelayInstallationID string $installation_id" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RelaydVersion string $relayd_version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RelaydProtocolVersion integer $relayd_protocol_version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$app_path/Contents/Info.plist"
if [[ -n "${RELAY_BUNDLE_STATE_ROOT:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :RelayStateRoot string $RELAY_BUNDLE_STATE_ROOT" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :RelayDefaultsSuite string ${RELAY_BUNDLE_DEFAULTS_SUITE:-$bundle_identifier}" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :RelaySidePanelPort string ${RELAY_BUNDLE_SIDE_PANEL_PORT:-47471}" "$app_path/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations array" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0 dict" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeIdentifier string dev.relay.workspace-tab" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeDescription string Relay Workspace Tab" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo array" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :UTExportedTypeDeclarations:0:UTTypeConformsTo:0 string public.data" "$app_path/Contents/Info.plist"

# Some dependency bundles intentionally ship read-only terminfo and shader
# files. The staged copy must be owner-writable while xattrs and signatures are
# normalized; installed runtime permissions remain non-executable for data.
/usr/libexec/PlistBuddy -c "Add :RelayCredentialHelperSourceSHA256 string $credential_source_hash" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RelayCredentialHelperSHA256 string $credential_helper_hash" "$app_path/Contents/Info.plist"
chmod -R u+w "$app_path"
/usr/bin/xattr -cr "$app_path"
# Keychain grants are bound to this helper's own signing requirement. Keep the
# compiler's signed helper intact when normalizing the surrounding bundle; a
# deep re-sign with the app's identity otherwise strands existing saved keys.
cp -p "$app_path/Contents/MacOS/relay-credentials" "$stage_root/relay-credentials.signed"
if [[ "$signing_identity" == "-" ]]; then
    /usr/bin/codesign --force --deep --sign - "$app_path"
else
    /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$signing_identity" "$app_path"
fi
cp -p "$stage_root/relay-credentials.signed" "$app_path/Contents/MacOS/relay-credentials"
# Seal the restored nested signature without recursively replacing it again.
if [[ "$signing_identity" == "-" ]]; then
    /usr/bin/codesign --force --sign - "$app_path"
else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_path"
fi
/usr/bin/xattr -cr "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
if [[ -n "${vpn_auth_hash:-}" ]]; then
    vpn_final_hash="$(/usr/bin/codesign -d --verbose=4 "$app_path/Contents/MacOS/relay-vpn-auth" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')"
    if [[ "$vpn_final_hash" != "$vpn_auth_hash" ]]; then echo "VPN client signature changed after helper pinning" >&2; exit 1; fi
fi

mkdir -p "$(dirname "$output_path")"
# Replacing a live bundle leaves the process executing the old image while
# loading resources from the new installation (or the removed staging path).
# Require a clean quit before replacing it so an install cannot look successful
# while the user's windows still run the previous build.
if is_executable_running "$output_path/Contents/MacOS/Relay"; then
    echo "Relay is still running from $output_path. Quit Relay and rerun this script to install the build." >&2
    exit 1
fi
previous_path="$stage_root/Relay.previous.app"
if [[ -e "$output_path" || -L "$output_path" ]]; then
    /bin/mv "$output_path" "$previous_path"
fi
if ! /bin/mv "$app_path" "$output_path"; then
    if [[ -e "$previous_path" || -L "$previous_path" ]]; then
        /bin/mv "$previous_path" "$output_path"
    fi
    exit 1
fi

if [[ "${RELAY_SKIP_WORKSPACE_LINK:-0}" != "1" && "$workspace_link" != "$output_path" ]]; then
    if [[ -e "$workspace_link" || -L "$workspace_link" ]]; then
        /bin/mv "$workspace_link" "$stage_root/Relay.workspace.previous.app"
    fi
    /bin/ln -s "$output_path" "$workspace_link"
    echo "$workspace_link -> $output_path"
else
    echo "Built $output_path (workspace link unchanged)"
fi
