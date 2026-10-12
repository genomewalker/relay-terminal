#!/usr/bin/env bash
set -euo pipefail

candidate_root="${RELAY_CANDIDATE_ROOT:-${TMPDIR:-/tmp}/relay-candidate-$(id -u)}"
app="$candidate_root/Relay Candidate.app"
executable="$app/Contents/MacOS/Relay"
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
if [[ ! -x "$executable" ]]; then
    echo "Candidate is not built: $app" >&2
    exit 1
fi
if is_executable_running "$executable"; then
    echo "Candidate is already running: $app" >&2
    exit 1
fi

mkdir -p "$candidate_root/state"
RELAY_STATE_ROOT="$candidate_root/state" \
RELAY_DEFAULTS_SUITE="dev.relay.terminal.candidate.defaults" \
RELAY_SIDE_PANEL_PORT="47472" \
    "$executable" >"$candidate_root/Relay.log" 2>&1 &

echo "Started Relay Candidate (pid $!, side panel 127.0.0.1:47472)"
