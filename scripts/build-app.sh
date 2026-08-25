#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
cd "$project_root"
swift build -c "$configuration"
binary_path="$(cd "$project_root" && swift build -c "$configuration" --show-bin-path)"
output_path="$project_root/Relay.app"
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/relay-app.XXXXXX")"
trap '/bin/rm -rf "$stage_root"' EXIT
app_path="$stage_root/Relay.app"

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/Relay" "$app_path/Contents/MacOS/Relay"
cp "$binary_path/relay-bridge" "$app_path/Contents/MacOS/relay-bridge"
resource_bundle="$binary_path/Relay_Relay.bundle"
if [[ -d "$resource_bundle" ]]; then
    ditto "$resource_bundle" "$app_path/Contents/Resources/Relay_Relay.bundle"
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
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.4.0" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$app_path/Contents/Info.plist"

/usr/bin/xattr -cr "$app_path"
/usr/bin/codesign --force --deep --sign - "$app_path"
if [[ -e "$output_path" ]]; then
    /bin/mv "$output_path" "$stage_root/Relay.previous.app"
fi
/bin/mv "$app_path" "$output_path"
/usr/bin/xattr -cr "$output_path"
# Documents may be backed by File Provider, which immediately reapplies these
# attributes after a move. codesign rejects them as resource-fork detritus.
/usr/bin/xattr -dr com.apple.FinderInfo "$output_path" 2>/dev/null || true
/usr/bin/xattr -dr 'com.apple.fileprovider.fpfs#P' "$output_path" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.provenance "$output_path" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$output_path"
echo "$output_path"
