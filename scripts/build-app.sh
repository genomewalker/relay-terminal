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
python3 "$project_root/scripts/check-rotation-resources.py"
swift_build_args=(-c "$configuration" --jobs "$build_jobs")
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
    /bin/ps -axo comm= | /usr/bin/perl -MCwd=realpath -e '
        my $target = realpath(shift) // "";
        while (my $path = <STDIN>) {
            chomp $path;
            my $resolved = realpath($path) // $path;
            exit 0 if length($target) && $resolved eq $target;
        }
        exit 1;
    ' -- "$1"
}
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/relay-app.XXXXXX")"
trap '/bin/rm -rf "$stage_root"' EXIT
app_path="$stage_root/Relay.app"

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/Relay" "$app_path/Contents/MacOS/Relay"
cp "$binary_path/relay-bridge" "$app_path/Contents/MacOS/relay-bridge"
# One signed Keychain client. Secrets use stdin/stdout pipes, never argv or files.
/usr/bin/swiftc -O "$project_root/native/credentials/relay-credentials.swift" \
    -o "$app_path/Contents/MacOS/relay-credentials"

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
        # SwiftPM resource caches can contain symlinks to source assets. Materialize
        # them so the installed bundle never depends on that build cache or checkout.
        python3 - "$resource_bundle" "$app_path/Contents/Resources/$(basename "$resource_bundle")" <<'PY'
import shutil
import sys
shutil.copytree(sys.argv[1], sys.argv[2], symlinks=False)
PY
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
python3 - "$project_root/Vendor/libghostty-spm/Sources/GhosttyTerminal/Resources" "$ghostty_bundle" <<'PY'
from pathlib import Path
import shutil
import sys
source, destination = map(Path, sys.argv[1:])
for name in ("Ghostty", "terminfo"):
    if not (source / name).is_dir():
        raise SystemExit("canonical Ghostty resources are missing")
    shutil.copytree(source / name, destination / name, symlinks=False, dirs_exist_ok=True)
required = (
    "Ghostty/shell-integration/bash/bash-preexec.sh",
    "Ghostty/shell-integration/bash/ghostty.bash",
    "Ghostty/shell-integration/elvish/lib/ghostty-integration.elv",
    "Ghostty/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish",
    "Ghostty/shell-integration/nushell/vendor/autoload/ghostty.nu",
    "Ghostty/shell-integration/zsh/ghostty-integration",
    "terminfo/67/ghostty", "terminfo/78/xterm-ghostty",
)
for relative in required:
    path = destination / relative
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit("packaged Ghostty resource is missing: " + relative)
PY
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
python3 "$project_root/scripts/sync-daemon-communication-assets.py"
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
done

# The Linux payloads cannot run on the build Mac. Build the same source for the
# host once and verify the embedded helper version before signing the bundle.
relayd_version_check="$stage_root/relayd-version-check"
(
    cd "$project_root/remote/relayd"
    go build -trimpath -ldflags="-X main.relaydVersion=$relayd_version" \
        -o "$relayd_version_check" ./cmd/relayd
)
if [[ "$($relayd_version_check --version)" != "relayd $relayd_version" ]]; then
    echo "relayd version stamping failed" >&2
    exit 1
fi
cp "$relayd_version_check" "$app_path/Contents/MacOS/relayd"
(
    cd "$project_root/remote/relayd"
    go build -trimpath -ldflags="-s -w" -o "$app_path/Contents/MacOS/relay-mcp" ./cmd/relay-mcp
    go build -trimpath -ldflags="-s -w" -o "$app_path/Contents/MacOS/relay-peer-link" ./cmd/relay-peer-link
    go build -trimpath -ldflags="-s -w" -o "$app_path/Contents/MacOS/relay-connection" ./cmd/relay-connection
    go build -trimpath -ldflags="-s -w" -o "$app_path/Contents/MacOS/relay-workspace" ./cmd/relay-workspace
)
mkdir -p "$app_path/Contents/Resources/R"
cp "$project_root/scripts/relay-workspace.py" "$app_path/Contents/Resources/relay-workspace.py"
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
chmod -R u+w "$app_path"
/usr/bin/xattr -cr "$app_path"
if [[ "$signing_identity" == "-" ]]; then
    /usr/bin/codesign --force --deep --sign - "$app_path"
else
    /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$signing_identity" "$app_path"
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
