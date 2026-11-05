#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
fixture_id="recovery-endpoint-$$"
fixture_root="$repo_root/.build/$fixture_id"
mkdir -p "$fixture_root"
export RELAY_STATE_ROOT="$fixture_root/state"
export RELAY_DEFAULTS_SUITE="dev.relay.test.$fixture_id"
export RELAY_SIDE_PANEL_PORT="${RELAY_RECOVERY_TEST_PORT:-47575}"
unset RELAY_RECOVERY_FIXTURE_MCP
cd "$repo_root"
swift test -j 2 --filter recoveryMCPEndpoint
