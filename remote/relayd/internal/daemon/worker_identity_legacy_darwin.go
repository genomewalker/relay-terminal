//go:build darwin

package daemon

import (
	"errors"
	"github.com/relay-terminal/relayd/internal/protocol"
	"net"
	"os"
	"strings"
	"syscall"
	"time"
)

// Old Darwin workers recorded PID as start time. Authenticate their existing
// private socket and token, then use the kernel incarnation for this check.
// Do not rewrite a manifest that its live legacy worker continues publishing.
func validateLegacyWorkerIdentity(manifest workerManifest) (bool, error) {
	if manifest.WorkerStartTime != uint64(manifest.WorkerPID) || !strings.HasPrefix(manifest.NodeBootID, "non-linux:") {
		return false, nil
	}
	refuse := func() (bool, error) { return true, errors.New("legacy worker identity cannot be established") }
	host, err := os.Hostname()
	if err != nil || manifest.NodeBootID != "non-linux:"+host || manifest.CreatedAt.IsZero() || len(manifest.Token) != 48 {
		return refuse()
	}
	start, err := processStartTime(manifest.WorkerPID)
	if err != nil {
		return refuse()
	}
	started := time.Unix(int64(start/1000000), int64(start%1000000)*1000)
	// Creation metadata plus possession of the worker token prevents accepting
	// a recycled PID merely because it is alive. Creation is recorded on launch.
	if started.After(manifest.CreatedAt.Add(time.Second)) || manifest.CreatedAt.Sub(started) > time.Minute {
		return refuse()
	}
	info, err := os.Lstat(manifest.SocketPath)
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm()&0077 != 0 {
		return refuse()
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != os.Getuid() {
		return refuse()
	}
	shellStart, err := processStartTime(manifest.ShellPID)
	if err != nil {
		return refuse()
	}
	expected, err := processStartIdentity(manifest.ShellPID)
	if err != nil {
		return refuse()
	}
	chain, err := networkAncestors(manifest.ShellPID, expected)
	if err != nil {
		return refuse()
	}
	belongs := false
	for _, pid := range chain {
		if pid == manifest.WorkerPID {
			belongs = true
			break
		}
	}
	if !belongs {
		return refuse()
	}
	connection, err := net.DialTimeout("unix", manifest.SocketPath, 300*time.Millisecond)
	if err != nil {
		return refuse()
	}
	defer connection.Close()
	uid, peer, err := PeerCredentials(connection)
	if err != nil || uid != os.Getuid() || peer != manifest.WorkerPID {
		return refuse()
	}
	_ = connection.SetDeadline(time.Now().Add(500 * time.Millisecond))
	hello, _ := protocol.JSONFrame(protocol.Hello, protocol.HelloPayload{Version: workerProtocolVersion, SessionID: manifest.SessionID, WorkerToken: manifest.Token, Probe: true})
	if protocol.NewWriter(connection).Write(hello) != nil {
		return refuse()
	}
	frame, err := protocol.ReadFrame(connection)
	var status protocol.StatusPayload
	if err != nil || frame.Type != protocol.Status || protocol.DecodeJSON(frame, &status) != nil || status.WorkerPID != manifest.WorkerPID || (status.State != "ready" && status.State != "exited") {
		return refuse()
	}
	after, e := processStartTime(manifest.WorkerPID)
	shellAfter, se := processStartTime(manifest.ShellPID)
	if e != nil || after != start || se != nil || shellAfter != shellStart {
		return refuse()
	}
	return true, nil
}
