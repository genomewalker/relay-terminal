#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
candidate_root="${RELAY_CANDIDATE_ROOT:-${TMPDIR:-/tmp}/relay-candidate-$(id -u)}"
mkdir -p "$candidate_root/state" "$candidate_root/build"

# Ad-hoc signing is sufficient for static inspection, but macOS refuses to
# execute nested helpers from a hardened app signed that way. Prefer the local
# development identity when it is installed; callers can still override it.
candidate_signing_identity="${RELAY_CODESIGN_IDENTITY:-}"
if [[ -z "$candidate_signing_identity" ]] && \
   /usr/bin/security find-identity -v -p codesigning 2>/dev/null | \
       /usr/bin/grep -Fq '"WinSwitch Local Signing"'; then
    candidate_signing_identity="WinSwitch Local Signing"
fi
candidate_signing_identity="${candidate_signing_identity:--}"

RELAY_APP_OUTPUT="$candidate_root/Relay Candidate.app" \
RELAY_BUNDLE_NAME="Relay Candidate" \
RELAY_BUNDLE_IDENTIFIER="dev.relay.terminal.candidate" \
RELAY_BUNDLE_STATE_ROOT="$candidate_root/state" \
RELAY_BUNDLE_DEFAULTS_SUITE="dev.relay.terminal.candidate.defaults" \
RELAY_BUNDLE_SIDE_PANEL_PORT="47472" \
RELAY_BUILD_SCRATCH_PATH="$candidate_root/build" \
RELAY_SKIP_WORKSPACE_LINK=1 \
RELAY_CODESIGN_IDENTITY="$candidate_signing_identity" \
    "$project_root/scripts/build-app.sh" "${1:-release}"

echo "Candidate: $candidate_root/Relay Candidate.app"
echo "State:     $candidate_root/state"
