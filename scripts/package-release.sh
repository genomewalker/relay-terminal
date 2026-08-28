#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${RELAY_VERSION:-0.5.2}"
output_directory="${RELAY_RELEASE_OUTPUT:-$project_root/dist}"
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/relay-release.XXXXXX")"
trap '/bin/rm -rf "$stage_root"' EXIT

if [[ "${RELAY_ALLOW_UNSIGNED_RELEASE:-0}" != "1" ]]; then
    if [[ -z "${RELAY_CODESIGN_IDENTITY:-}" || "${RELAY_CODESIGN_IDENTITY:-}" == "-" ]]; then
        echo "RELAY_CODESIGN_IDENTITY is required for a public release" >&2
        exit 1
    fi
    if [[ -z "${RELAY_NOTARY_PROFILE:-}" ]]; then
        echo "RELAY_NOTARY_PROFILE is required for a public release" >&2
        exit 1
    fi
fi

mkdir -p "$output_directory"
RELAY_APP_OUTPUT="$stage_root/Relay.app" \
RELAY_SKIP_WORKSPACE_LINK=1 \
RELAY_VERSION="$version" \
    "$project_root/scripts/build-app.sh" release

archive="$output_directory/Relay-$version-macOS.zip"
/bin/rm -f "$archive"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$stage_root/Relay.app" "$archive"

if [[ -n "${RELAY_NOTARY_PROFILE:-}" ]]; then
    /usr/bin/xcrun notarytool submit "$archive" --keychain-profile "$RELAY_NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$stage_root/Relay.app"
    /bin/rm -f "$archive"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$stage_root/Relay.app" "$archive"
fi

dmg="$output_directory/Relay-$version-macOS.dmg"
RELAY_DMG_SIGNING_IDENTITY="${RELAY_CODESIGN_IDENTITY:-}" \
    "$project_root/scripts/create-dmg.sh" "$stage_root/Relay.app" "$dmg"

if [[ -n "${RELAY_NOTARY_PROFILE:-}" ]]; then
    /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$RELAY_NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$dmg"
    /usr/bin/xcrun stapler validate "$dmg"
fi

for architecture in amd64 arm64; do
    binary="$output_directory/relayd-$version-linux-$architecture"
    /bin/cp "$stage_root/Relay.app/Contents/Resources/relayd-linux-$architecture" "$binary"
    chmod 0755 "$binary"
done

(
    cd "$output_directory"
    /usr/bin/shasum -a 256 \
        "Relay-$version-macOS.dmg" \
        "Relay-$version-macOS.zip" \
        "relayd-$version-linux-amd64" \
        "relayd-$version-linux-arm64" \
        > "SHA256SUMS-$version.txt"
)

echo "$output_directory"
