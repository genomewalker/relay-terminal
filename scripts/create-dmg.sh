#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 /path/to/Relay.app /path/to/Relay-version.dmg" >&2
    exit 64
fi

app_path="$1"
output_path="$2"
volume_name="${RELAY_DMG_VOLUME_NAME:-Relay}"
signing_identity="${RELAY_DMG_SIGNING_IDENTITY:-}"

if [[ ! -d "$app_path" || "$(basename "$app_path")" != "Relay.app" ]]; then
    echo "Relay.app not found: $app_path" >&2
    exit 66
fi
if [[ "$output_path" != *.dmg ]]; then
    echo "DMG output must end in .dmg: $output_path" >&2
    exit 64
fi

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/relay-dmg.XXXXXX")"
trap '/bin/rm -rf "$stage_root"' EXIT
image_root="$stage_root/image"
temporary_dmg="$stage_root/Relay.dmg"

/bin/mkdir -p "$image_root" "$(dirname "$output_path")"
/usr/bin/ditto --norsrc --noextattr "$app_path" "$image_root/Relay.app"
/bin/ln -s /Applications "$image_root/Applications"

# Relay requires macOS 14, so APFS is available everywhere the app runs. It
# also preserves the signed bundle without HFS synthesizing FinderInfo xattrs.
# UDZO keeps the downloadable image small. Building in a temporary directory
# makes replacing an existing release artifact atomic.
/usr/bin/hdiutil create \
    -volname "$volume_name" \
    -fs APFS \
    -format UDZO \
    -imagekey zlib-level=9 \
    -srcfolder "$image_root" \
    "$temporary_dmg" >/dev/null

if [[ -n "$signing_identity" && "$signing_identity" != "-" ]]; then
    /usr/bin/codesign --force --timestamp --sign "$signing_identity" "$temporary_dmg"
    /usr/bin/codesign --verify --verbose=2 "$temporary_dmg"
fi

/usr/bin/hdiutil verify "$temporary_dmg" >/dev/null
/bin/mv -f "$temporary_dmg" "$output_path"
echo "$output_path"
