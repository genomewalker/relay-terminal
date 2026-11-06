package nativemsg

import (
	"context"
	"fmt"
	"os"
	"strings"
)

// ClaudeSessionTarget names a Claude Code session that runs outside any Relay
// pane, such as the Claude desktop app's background session, by its account
// registry and session ID. The session ID survives the app restarting the
// process; the process, its start and its inbox are resolved from the registry
// on every use and checked again while delivering.
type ClaudeSessionTarget struct {
	AccountRoot string `json:"account_root"`
	SessionID   string `json:"session_id"`
}

// ClaudeDesktopEntrypoint is the registry entrypoint the Claude desktop app's
// sessions publish. Records of terminal sessions ("cli") are pane members and
// are never resolved as a session target.
const ClaudeDesktopEntrypoint = "claude-desktop"

func (t ClaudeSessionTarget) Valid() bool {
	return len(t.AccountRoot) <= 4096 && !strings.ContainsRune(t.AccountRoot, 0) && pathIsAbs(t.AccountRoot) &&
		pathNorm(t.AccountRoot) == t.AccountRoot && t.AccountRoot != "/" && sessionPattern.MatchString(t.SessionID) &&
		len(t.SessionID) == 36
}

// RunClaudeSession performs one discover or send operation for a Claude
// session target. The packet and result have the same shape as Run's.
func RunClaudeSession(ctx context.Context, host Host, target ClaudeSessionTarget, request []byte) (result map[string]any) {
	r := &runner{ctx: ctx, host: host, proc: host.proc, random: host.random, uid: int64(os.Getuid())}
	if r.proc == nil {
		r.proc = defaultSource()
	}
	if r.random == nil {
		r.random = urandom
	}
	r.home = host.home(r.uid)
	r.cwd, _ = os.Getwd()
	packet, err := loadsBytes(request)
	if err != nil {
		return map[string]any{"status": "unavailable", "error": err.Error(), "replay_permitted": false}
	}
	defer func() {
		if failure := recover(); failure != nil {
			result = r.failure(packet, &pyErr{class: classInternal, msg: fmt.Sprint("internal error: ", failure)})
		}
	}()
	result, err = r.runClaudeSession(target, packet)
	if err != nil {
		return r.failure(packet, err)
	}
	return result
}

func (r *runner) runClaudeSession(target ClaudeSessionTarget, packet any) (map[string]any, error) {
	if !target.Valid() {
		return nil, valueError("Invalid Claude session target")
	}
	endpoint, err := r.discoverClaudeSession(target)
	if err != nil {
		return nil, err
	}
	operation, err := pyIndex(packet, "operation")
	if err != nil {
		return nil, err
	}
	switch {
	case pyEqual(operation, "discover"):
		return map[string]any{"endpoint": endpoint}, nil
	case pyEqual(operation, "send"):
		expected, err := pyIndex(packet, "expected")
		if err != nil {
			return nil, err
		}
		if !pyEqual(endpoint, expected) {
			return nil, valueError("Recipient session or socket changed before delivery (no write; changed: " +
				pySlice(strings.Join(changedFields(endpoint, expected), ", "), 200) + ")")
		}
		delivered, err := r.deliver(endpoint, packet)
		if err != nil {
			return nil, err
		}
		delivered["transport"] = endpoint["transport"]
		return delivered, nil
	}
	return nil, valueError("Unknown messaging operation")
}

// discoverClaudeSession finds the one live desktop session publishing target
// in its account registry. A stale record (dead or reused PID), a record of
// another kind or entrypoint, a Relay proxy, a process whose own account
// directory differs, or two live records for one session all fail.
func (r *runner) discoverClaudeSession(target ClaudeSessionTarget) (map[string]any, error) {
	processes, err := r.inventory()
	if err != nil {
		return nil, err
	}
	registry := pathJoin(target.AccountRoot, "sessions")
	var found []map[string]any
	denied, err := forEachRegistryBatch(registry, func(names []string) error {
		for _, name := range liveRegistryCandidates(names, processes) {
			endpoint, err := r.claudeSessionRecord(pathJoin(registry, name), registry, target, processes)
			if err != nil {
				if caught(err, classOS, classValue, classKey, classUnbound) {
					continue
				}
				return err
			}
			if endpoint != nil {
				found = append(found, endpoint)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if denied || len(found) != 1 {
		return nil, valueError("No unique live Claude desktop session publishes this session")
	}
	endpoint := found[0]
	if after, err := r.identity(endpoint["pid"]); err != nil {
		return nil, err
	} else if after != endpoint["start"] {
		return nil, valueError("Claude session process changed while discovering its endpoint")
	}
	return endpoint, nil
}

func (r *runner) claudeSessionRecord(path, registry string, target ClaudeSessionTarget, processes map[int64]processRow) (map[string]any, error) {
	row, err := r.privateJSON(path)
	if err != nil {
		return nil, err
	}
	get := func(key string) any { value, _ := pyGet(row, key, nil); return value }
	worker, ok := pidOf(get("pid"))
	if !ok || worker <= 1 {
		return nil, nil
	}
	if _, live := processes[worker]; !live {
		return nil, nil
	}
	if !pyEqual(get("sessionId"), target.SessionID) || !pyEqual(get("kind"), "interactive") ||
		!pyEqual(get("entrypoint"), ClaudeDesktopEntrypoint) || pyTruthy(get("relayProxy")) {
		return nil, nil
	}
	if protocol, ok := pidOf(get("peerProtocol")); !ok || protocol != 1 {
		return nil, nil
	}
	start, err := r.identity(worker)
	if err != nil {
		return nil, err
	}
	if _, after, _ := strings.Cut(start, ":"); after != pyStr(get("procStart")) {
		return nil, nil
	}
	// The process's own account directory must be the target's: a record
	// copied into another registry does not move the session.
	root, err := r.accountRoot(worker, "claude")
	if err != nil {
		return nil, err
	}
	if root != target.AccountRoot {
		return nil, nil
	}
	address, ok := get("messagingSocketPath").(string)
	if !ok || !pathIsAbs(address) || len(address) > 4096 || strings.ContainsRune(address, 0) {
		return nil, nil
	}
	incarnation, err := r.socketIdentity(address)
	if err != nil {
		return nil, err
	}
	keyName, err := socketKeyName(worker, address)
	if err != nil {
		return nil, err
	}
	key, err := r.privateJSON(pathJoin(registry, keyName))
	if err != nil {
		return nil, err
	}
	if token, _ := pyGet(key, "peerToken", nil); !validPeerToken(token) {
		return nil, nil
	}
	return map[string]any{"pid": worker, "start": start, "provider": "claude", "sessionID": target.SessionID,
		"socketPath": address, "socketIdentity": incarnation, "socketPID": worker, "socketStart": start,
		"transport": "native_peer_socket"}, nil
}

func validPeerToken(token any) bool {
	t, ok := token.(string)
	return ok && pyLen(t) >= 16 && pyLen(t) <= 256
}
