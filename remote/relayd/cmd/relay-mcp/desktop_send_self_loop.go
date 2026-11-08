package main

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// relay_send_desktop_message carries a Codex Work thread's message to the
// route's Claude owner. Called by that owner itself (the 0.5.25 XL test: bc08
// on route c69609) it delivered the message back to the sender. A caller whose
// own process ancestry contains the route's exact owner incarnation is refused
// and told how to reach the Codex thread instead. Codex senders, in the
// desktop app or a terminal pane, are not affected.
const desktopSendSelfLoop = "This route's Claude owner is the caller, so relay_send_desktop_message would deliver the message back to you. " +
	"To message the Codex thread on the other end, use Claude Code's SendMessage to the route's uds:/tmp/relay-desktop-<uid>/<id>/peer.sock address. Nothing was sent."

type processIdentity struct {
	pid   int
	start string
}

// desktopSendAncestors lists the calling helper's ancestors with their start
// times, nearest first. It returns nil when the chain cannot be read, which
// does not refuse: the previous behaviour is kept for that case.
var desktopSendAncestors = func() []processIdentity {
	var chain []processIdentity
	for pid := os.Getppid(); pid > 1 && len(chain) < 64; {
		out, e := exec.Command("ps", "-o", "ppid=", "-o", "lstart=", "-p", strconv.Itoa(pid)).Output()
		if e != nil {
			return nil
		}
		fields := strings.Fields(string(out))
		if len(fields) < 2 {
			return nil
		}
		parent, e := strconv.Atoi(fields[0])
		if e != nil {
			return nil
		}
		chain = append(chain, processIdentity{pid, strings.Join(fields[1:], " ")})
		pid = parent
	}
	return chain
}

// desktopSendFromOwner reports whether the route's owner, which runs on this
// Mac (host laptop), is the caller. Start times compare with whitespace
// normalised, since lstart pads the day of the month.
func desktopSendFromOwner(host string, pid int, start string) bool {
	if host != "laptop" {
		return false
	}
	want := strings.Join(strings.Fields(start), " ")
	for _, p := range desktopSendAncestors() {
		if p.pid == pid && p.start == want {
			return true
		}
	}
	return false
}
