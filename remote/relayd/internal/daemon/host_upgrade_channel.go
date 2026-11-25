package daemon

import (
	"fmt"
	"path/filepath"
	"regexp"
	"time"
)

// Relay's own short host-channel jobs (communication requests, agent
// maintenance and conversation runs, the Claude stream-json helper) start
// continuously, so counting them as blockers defers every upgrade. They are
// marked at start from their exact launch shape and, at upgrade time, waited
// for under the handoff barrier instead of counted. They are never signalled:
// a maintenance or conversation run cut short could leave an account move or
// a turn half done. One still running after the bounded wait defers the
// upgrade, exactly as before, and the barrier is lifted.
const hostJobOriginRelayChannel = "relay_channel_v1"

// Bounded so channel wait, listener drain and the ledger scan stay well inside
// upgrade-supervisor's preparation timeout.
var hostUpgradeChannelDrain = 15 * time.Second

var hostUpgradeChannelPoll = 100 * time.Millisecond

// The Mac's communicationCommand / workCarrierCommand, which a remote host
// runs through /bin/sh -lc. The helper tested and the helper run must be the
// same file.
var relayChannelShell = regexp.MustCompile(`^if \[ -x "\$HOME/\.local/share/relay/bin/(relayd-communication|relayd-work-communication)" \]; then "\$HOME/\.local/share/relay/bin/(relayd-communication|relayd-work-communication)" (communication|communication-shepherd); else [^\n]*; fi$`)

var relayChannelBinaries = map[string]bool{
	"relayd": true, "relayd-linux-amd64": true, "relayd-linux-arm64": true,
	"relayd-communication": true, "relayd-work-communication": true,
}

var relayChannelVerbs = map[string]bool{
	"agent-maintenance": true, "agent-conversation": true,
	"communication": true, "communication-shepherd": true,
}

// relayChannelOrigin classifies an ordinary (kind "") job request. Anything
// that does not match exactly stays a normal job and keeps blocking.
func relayChannelOrigin(r hostRequest) string {
	if r.Kind != "" || r.Listener != nil {
		return ""
	}
	if r.Command != "" {
		if m := relayChannelShell.FindStringSubmatch(r.Command); m != nil && m[1] == m[2] {
			return hostJobOriginRelayChannel
		}
		return ""
	}
	argv := r.Argv
	if len(argv) < 2 {
		return ""
	}
	exe := argv[0]
	if exe != ".local/bin/relayd" && !filepath.IsAbs(exe) {
		return ""
	}
	base := filepath.Base(exe)
	if relayChannelBinaries[base] && relayChannelVerbs[argv[1]] {
		return hostJobOriginRelayChannel
	}
	if base == "claude" && (argv[1] == "-p" || argv[1] == "--print") {
		for i := 2; i+1 < len(argv); i++ {
			if argv[i] == "--output-format" && argv[i+1] == "stream-json" {
				return hostJobOriginRelayChannel
			}
		}
	}
	return ""
}

// One in-flight channel job: reports whether it is still running.
type hostUpgradeChannel func() bool

func memoryChannel(job *hostJob) hostUpgradeChannel {
	return func() bool {
		job.mu.Lock()
		defer job.mu.Unlock()
		return job.record.State == "starting" || job.record.State == "running"
	}
}

// A record owned by an earlier supervisor generation: alive or unprovable
// counts as running.
func ledgerChannel(record hostJobRecord) hostUpgradeChannel {
	return func() bool {
		switch hostJobProcessState(record) {
		case "absent", "replaced":
			return false
		}
		return true
	}
}

// waitRelayChannelsLocked raises the barrier so no job can start, releases
// hostJobsMu while the channel jobs finish on their own, and reacquires it.
// It returns the previous barrier so a deferral can restore it.
func (s *Server) waitRelayChannelsLocked(channels []hostUpgradeChannel) (time.Time, error) {
	previous := s.hostUpgradeUntil
	deadline := time.Now().Add(hostUpgradeChannelDrain)
	s.hostUpgradeUntil = deadline.Add(hostUpgradeHandoff)
	s.hostJobsMu.Unlock()
	remaining := len(channels)
	for {
		remaining = 0
		for _, running := range channels {
			if running() {
				remaining++
			}
		}
		if remaining == 0 || !time.Now().Before(deadline) {
			break
		}
		time.Sleep(hostUpgradeChannelPoll)
	}
	s.hostJobsMu.Lock()
	if remaining > 0 {
		s.hostUpgradeUntil = previous
		return previous, fmt.Errorf("upgrade deferred: %d Relay channel jobs still running after %s; none were signalled", remaining, hostUpgradeChannelDrain)
	}
	return previous, nil
}
