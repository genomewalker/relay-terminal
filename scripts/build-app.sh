#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
app_version="${RELAY_APP_VERSION:-${RELAY_VERSION:-0.5.2}}"
relayd_version="${RELAYD_VERSION:-$app_version}"
relayd_protocol_version="${RELAYD_PROTOCOL_VERSION:-2}"
build_number="${RELAY_BUILD_NUMBER:-1}"
signing_identity="${RELAY_CODESIGN_IDENTITY:--}"
cd "$project_root"
swift build -c "$configuration"
binary_path="$(cd "$project_root" && swift build -c "$configuration" --show-bin-path)"

# SwiftPM generates command-line executable accessors that resolve resource
# bundles beside Bundle.main.bundleURL. Once wrapped as a signed .app, bundles
# must live in Contents/Resources. Rewrite only generated accessors and rebuild
# when needed so the executable uses the standard macOS resource location.
accessor_changed=0
while IFS= read -r -d '' accessor; do
    if /usr/bin/grep -q 'Bundle.main.bundleURL.appendingPathComponent' "$accessor"; then
        /usr/bin/perl -pi -e 's/Bundle\.main\.bundleURL\.appendingPathComponent/Bundle.main.resourceURL!.appendingPathComponent/g' "$accessor"
        accessor_changed=1
    fi
done < <(/usr/bin/find "$(dirname "$binary_path")/$configuration" -path '*/DerivedSources/resource_bundle_accessor.swift' -print0)
if [[ "$accessor_changed" == "1" ]]; then
    swift build -c "$configuration"
    binary_path="$(cd "$project_root" && swift build -c "$configuration" --show-bin-path)"
fi
workspace_link="$project_root/Relay.app"
# A bundle inside Documents may be managed by File Provider, which immediately
# reapplies extended attributes and invalidates strict code-sign verification.
# Keep the runnable development app in the user's local Applications folder;
# the repository path remains a convenient symlink for `open Relay.app`.
output_path="${RELAY_APP_OUTPUT:-$HOME/Applications/Relay.app}"
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/relay-app.XXXXXX")"
trap '/bin/rm -rf "$stage_root"' EXIT
app_path="$stage_root/Relay.app"

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/Relay" "$app_path/Contents/MacOS/Relay"
cp "$binary_path/relay-bridge" "$app_path/Contents/MacOS/relay-bridge"
# SwiftPM emits one resource bundle for Relay and another for Ghostty's
# terminfo/shell-integration assets. Copy all of them so a packaged app never
# falls back to absolute development paths in .build (which may be offline or
# File Provider-managed).
for resource_bundle in "$binary_path"/*.bundle; do
    if [[ -d "$resource_bundle" ]]; then
        ditto "$resource_bundle" "$app_path/Contents/Resources/$(basename "$resource_bundle")"
    fi
done

# Remote installation is explicit in the UI, but it must remain offline and
# reproducible once authorized. Bundle the exact static Linux helpers inside
# the signed app rather than downloading an executable at connection time.
for relay_architecture in amd64 arm64; do
    (
        cd "$project_root/remote/relayd"
        CGO_ENABLED=0 GOOS=linux GOARCH="$relay_architecture" \
            go build -trimpath -ldflags="-s -w -X main.relaydVersion=$relayd_version" \
            -o "$app_path/Contents/Resources/relayd-linux-$relay_architecture" ./cmd/relayd
    )
    chmod 0555 "$app_path/Contents/Resources/relayd-linux-$relay_architecture"
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
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Relay" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Relay" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string dev.relay.terminal" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Relay" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string RelayIcon" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $app_version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RelaydVersion string $relayd_version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RelaydProtocolVersion integer $relayd_protocol_version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$app_path/Contents/Info.plist"

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

mkdir -p "$(dirname "$output_path")"
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
fi
echo "$workspace_link -> $output_path"
