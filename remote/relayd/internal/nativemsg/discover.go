package nativemsg

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// This file ports pane_messaging.py's endpoint discovery and its fences.

const recordLimit = 65536

var parkedSources = []string{"native_parked_job_kernel_owner", "native_pane_job_kernel_owner"}

// privateJSON is a private, owner-only native session record.
func (r *runner) privateJSON(path string) (any, error) {
	f, st, err := openNoFollow(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if !isRegular(st) || int64(st.Uid) != r.uid || st.Mode&0o022 != 0 {
		return nil, valueError("Unsafe native session record")
	}
	raw, err := readUpTo(f, recordLimit+1)
	if err != nil {
		return nil, err
	}
	if len(raw) > recordLimit {
		return nil, valueError("Native session record exceeds limit")
	}
	return loadsBytes(raw)
}

// socketIdentity is "dev:ino" of a private socket in a private directory.
func (r *runner) socketIdentity(value any) (string, error) {
	path, err := pathFrom(value)
	if err != nil {
		return "", err
	}
	if r.host.beforeSocketCheck != nil {
		r.host.beforeSocketCheck(path)
	}
	parent, err := pyLstat(pathParent(path))
	if err != nil {
		return "", err
	}
	info, err := pyLstat(path)
	if err != nil {
		return "", err
	}
	if !pathIsAbs(path) || !isDir(parent) || int64(parent.Uid) != r.uid || parent.Mode&0o022 != 0 ||
		!isSocket(info) || int64(info.Uid) != r.uid || info.Mode&0o022 != 0 {
		return "", valueError("Native socket is not privately owned")
	}
	return devIno(info), nil
}

func (r *runner) claudeSessions(pid any) (string, error) {
	root, err := r.accountRoot(pid, "claude")
	if err != nil {
		return "", err
	}
	return pathJoin(root, "sessions"), nil
}

// peerRecord is a live Claude worker's published inbox.
type peerRecord struct {
	row         any
	start       string
	incarnation string
}

func socketKeyName(worker any, address string) (string, error) {
	encoded, err := pyEncode(address)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(encoded)
	return pyStr(worker) + "." + hex.EncodeToString(sum[:]) + ".key", nil
}

// The Claude session registry keeps records of exited workers (one that was
// SIGKILLed never removes its <pid>.json), so the directory can hold any
// number of stale names. It is read in batches of registryBatchSize entries
// and each batch is filtered and parsed before the next is read: no limit
// applies to the total or live population, and only accepted records outlive
// their batch. Tests lower the batch size.
var registryBatchSize = 256

// registryJSONName is whether globNames(dir, "*.json", false) lists name.
func registryJSONName(name string) bool {
	ok, _ := filepath.Match("*.json", name)
	return ok
}

// forEachRegistryBatch reads dir in batches of registryBatchSize entries and
// passes each batch's *.json names to visit, in directory order. It ends
// silently, with visit possibly never called, where globNames(dir, "*.json",
// false) would return no names: dir missing, not a directory or not readable.
// permissionDenied reports a permission error after the first batch, which
// globNames also turns into no names.
func forEachRegistryBatch(dir string, visit func(names []string) error) (permissionDenied bool, err error) {
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return false, nil
	}
	f, err := os.Open(dir)
	if err != nil {
		if os.IsPermission(err) {
			return true, nil
		}
		return false, fromOS(err, dir)
	}
	defer f.Close()
	names := make([]string, 0, registryBatchSize)
	for {
		batch, err := f.Readdirnames(registryBatchSize)
		if err != nil && err != io.EOF {
			if os.IsPermission(err) {
				return true, nil
			}
			return false, fromOS(err, dir)
		}
		names = names[:0]
		for _, name := range batch {
			if registryJSONName(name) {
				names = append(names, name)
			}
		}
		if len(names) > 0 {
			if err := visit(names); err != nil {
				return false, err
			}
		}
		if err == io.EOF || len(batch) == 0 {
			return false, nil
		}
	}
}

// registryRecordPID is the worker pid a registry file name gives when the
// name is exactly a canonical decimal <pid>.json, as Claude names records.
func registryRecordPID(name string) (int64, bool) {
	stem, found := strings.CutSuffix(name, ".json")
	if !found {
		return 0, false
	}
	worker, err := strconv.ParseInt(stem, 10, 64)
	if err != nil || strconv.FormatInt(worker, 10) != stem {
		return 0, false
	}
	return worker, true
}

// liveRegistryCandidates keeps, in order, the registry names that may be a
// live worker's record. A <pid>.json whose worker is not in the process
// inventory is dead: it is skipped unparsed and does not count (peerRecord
// would refuse it at the ancestor check anyway). Other names stay
// candidates.
func liveRegistryCandidates(names []string, processes map[int64]processRow) []string {
	var candidates []string
	for _, name := range names {
		if worker, ok := registryRecordPID(name); ok {
			if _, alive := processes[worker]; !alive {
				continue
			}
		}
		candidates = append(candidates, name)
	}
	return candidates
}

// peerRecords lists the live Claude workers under pid publishing an inbox.
// A Codex recipient has no Claude registry and reads none. The registry is
// streamed: a batch's dead records are dropped unparsed and its candidates
// parsed before the next batch is read.
func (r *runner) peerRecords(pid int64, provider, session string) ([]peerRecord, error) {
	if provider != "claude" {
		return nil, nil
	}
	processes, err := r.inventory()
	if err != nil {
		return nil, err
	}
	registry, err := r.claudeSessions(pid)
	if err != nil {
		return nil, err
	}
	var records []peerRecord
	seenWorkers := make(map[int64]bool)
	denied, err := forEachRegistryBatch(registry, func(names []string) error {
		for _, name := range liveRegistryCandidates(names, processes) {
			record, err := r.peerRecord(pathJoin(registry, name), registry, pid, session, processes)
			if err != nil {
				if caught(err, classOS, classValue, classKey, classUnbound) {
					continue
				}
				return err
			}
			if record != nil {
				// A filename is not a worker identity. Aliases must not grow the
				// retained set beyond the live inventory or select one of two
				// conflicting publications. Reject duplicates, even identical ones.
				worker, _ := pyGet(record.row, "pid", nil)
				workerPID, ok := pidOf(worker)
				if _, live := processes[workerPID]; !ok || !live {
					return valueError("Native peer is absent from process inventory")
				}
				if seenWorkers[workerPID] {
					return valueError("Native session registry has duplicate live worker records")
				}
				seenWorkers[workerPID] = true
				records = append(records, *record)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if denied {
		// globNames reads an unreadable registry as empty.
		return nil, nil
	}
	return records, nil
}

func (r *runner) peerRecord(path, registry string, pid int64, session string, processes map[int64]processRow) (*peerRecord, error) {
	row, err := r.privateJSON(path)
	if err != nil {
		return nil, err
	}
	worker, err := pyGet(row, "pid", nil)
	if err != nil {
		return nil, err
	}
	if _, ok := pyInt(worker); !ok {
		return nil, nil
	}
	if proxy, _ := pyGet(row, "relayProxy", nil); pyTruthy(proxy) {
		return nil, nil
	}
	chain, err := ancestorsOf(worker, processes)
	if err != nil {
		return nil, err
	}
	if !containsPID(chain, pid) {
		return nil, nil
	}
	start, err := r.identity(worker)
	if err != nil {
		return nil, err
	}
	procStart, _ := pyGet(row, "procStart", "")
	if _, after, _ := strings.Cut(start, ":"); after != pyStr(procStart) {
		return nil, nil
	}
	sid, _ := pyGet(row, "sessionId", nil)
	s, ok := sid.(string)
	if !ok || !sessionPattern.MatchString(s) || (session != "" && s != session) {
		return nil, nil
	}
	address, err := pyIndex(row, "messagingSocketPath")
	if err != nil {
		return nil, err
	}
	incarnation, err := r.socketIdentity(address)
	if err != nil {
		return nil, err
	}
	keyName, err := socketKeyName(worker, address.(string))
	if err != nil {
		return nil, err
	}
	key, err := r.privateJSON(pathJoin(registry, keyName))
	if err != nil {
		return nil, err
	}
	token, err := pyGet(key, "peerToken", nil)
	if err != nil {
		return nil, err
	}
	if t, ok := token.(string); !ok || pyLen(t) < 16 || pyLen(t) > 256 {
		return nil, nil
	}
	return &peerRecord{row: row, start: start, incarnation: incarnation}, nil
}

func (r *runner) authenticated(pane string, pid int64, provider, target string) (map[string]any, error) {
	return r.authenticatedBinding(pane, pid, provider, target)
}

// parkedClaudePeer proves a parked background Claude job's own inbox.
func (r *runner) parkedClaudePeer(verified map[string]any) (*peerRecord, error) {
	peer, err := pyGet(verified, "native_peer", map[string]any{})
	if err != nil {
		return nil, err
	}
	worker, err := pyGet(peer, "pid", nil)
	if err != nil {
		return nil, err
	}
	invalid := valueError("Invalid native parked conversation proof")
	if source, _ := pyGet(verified, "source", nil); !pyIn(source, parkedSources...) {
		return nil, invalid
	}
	if n, ok := intNotBool(worker); !ok || n.Sign() <= 0 || n.IsInt64() && n.Int64() <= 1 {
		return nil, invalid
	}
	job, _ := pyGet(peer, "job_id", nil)
	if s, ok := job.(string); !ok || !jobPattern.MatchString(s) {
		return nil, invalid
	}
	frontend, _ := pyGet(peer, "frontend_session", "")
	matched, err := fullmatch(sessionPattern, frontend)
	if err != nil {
		return nil, err
	}
	if !matched {
		return nil, invalid
	}
	sessions, err := r.claudeSessions(worker)
	if err != nil {
		return nil, err
	}
	row, err := r.privateJSON(pathJoin(sessions, pyStr(worker)+".json"))
	if err != nil {
		return nil, err
	}
	start, err := r.identity(worker)
	if err != nil {
		return nil, err
	}
	changed := valueError("Native parked conversation publication changed")
	get := func(key string) (any, error) { return pyGet(row, key, nil) }
	for _, check := range []struct {
		key  string
		want any
	}{{"pid", worker}, {"kind", "bg"}, {"entrypoint", "cli"}} {
		value, err := get(check.key)
		if err != nil {
			return nil, err
		}
		if !pyEqual(value, check.want) {
			return nil, changed
		}
	}
	if proxy, _ := get("relayProxy"); pyTruthy(proxy) {
		return nil, changed
	}
	if protocol, _ := get("peerProtocol"); !pyEqual(protocol, int64(1)) {
		return nil, changed
	}
	if jobID, _ := get("jobId"); !pyEqual(jobID, job) {
		return nil, changed
	}
	sessionID, err := pyIndex(verified, "session_id")
	if err != nil {
		return nil, err
	}
	if current, _ := get("sessionId"); !pyEqual(current, sessionID) {
		return nil, changed
	}
	processStart, _ := pyGet(peer, "process_start", nil)
	procStart, _ := get("procStart")
	if !pyEqual(pyStr(procStart), processStart) {
		return nil, changed
	}
	if _, after, _ := strings.Cut(start, ":"); !pyEqual(after, processStart) {
		return nil, changed
	}
	socket, _ := pyGet(peer, "socket", nil)
	if published, _ := get("messagingSocketPath"); !pyEqual(published, socket) {
		return nil, changed
	}
	socketValue, err := pyIndex(peer, "socket")
	if err != nil {
		return nil, err
	}
	incarnation, err := r.socketIdentity(socketValue)
	if err != nil {
		return nil, err
	}
	if identity, _ := pyGet(peer, "socket_identity", nil); !pyEqual(incarnation, identity) {
		return nil, valueError("Native parked inbox changed")
	}
	socketPath, _ := pathFrom(socketValue)
	if err := r.checkInboxOwner(socketValue.(string), socketPath, worker, 3*time.Second,
		"Native parked inbox kernel owner mismatch"); err != nil {
		return nil, err
	}
	after, err := r.identity(worker)
	if err != nil {
		return nil, err
	}
	if after != start {
		return nil, valueError("Native parked inbox changed during observation")
	}
	current, err := r.socketIdentity(socketValue)
	if err != nil {
		return nil, err
	}
	if current != incarnation {
		return nil, valueError("Native parked inbox changed during observation")
	}
	return &peerRecord{row: row, start: start, incarnation: incarnation}, nil
}

// checkInboxOwner connects to an inbox and compares its kernel owner. The
// connection carries no data.
func (r *runner) checkInboxOwner(address, _ string, owner any, timeout time.Duration, mismatch string) error {
	client, err := dialUnix(r.ctx, address, timeout)
	if err != nil {
		return err
	}
	defer client.close()
	pid, uid, err := nativePeerOwner(client)
	if err != nil {
		return err
	}
	if !pyEqual(pid, owner) || uid != r.uid {
		return valueError(mismatch)
	}
	return nil
}

func (r *runner) discover(pane, target string) (map[string]any, error) {
	var root any = r.host.RootPID
	var err error
	if r.host.RootPID == 0 {
		root, err = r.rootForPane(pane)
	}
	if err != nil {
		return nil, err
	}
	rootStart, err := r.identity(root)
	if err != nil {
		return nil, err
	}
	pid, provider, err := r.agent(root, pane)
	if err != nil {
		return nil, err
	}
	start, err := r.identity(pid)
	if err != nil {
		return nil, err
	}
	if target != "" && provider != "claude" {
		return nil, valueError("Target sessions address background Claude jobs only")
	}
	verified, err := r.authenticated(pane, pid, provider, target)
	if err != nil {
		return nil, err
	}
	if target != "" {
		source, _ := pyGet(verified, "source", nil)
		session, _ := pyGet(verified, "session_id", nil)
		if !pyTruthy(verified) || !pyEqual(source, "native_pane_job_kernel_owner") || !pyEqual(session, target) {
			return nil, valueError("Target session is not a verified live background job of this pane")
		}
	}
	if provider == "claude" {
		sessions, err := r.claudeSessions(pid)
		if err != nil {
			return nil, err
		}
		front, err := r.privateJSON(pathJoin(sessions, pyStr(pid)+".json"))
		if err != nil {
			if !isA(err, "FileNotFoundError") {
				return nil, err
			}
			front = map[string]any{}
		}
		parked, err := pyGet(front, "parkedJobId", nil)
		if err != nil {
			return nil, err
		}
		if pyTruthy(parked) {
			source, _ := pyGet(verified, "source", nil)
			if !pyTruthy(verified) || !pyIn(source, parkedSources...) {
				return nil, valueError("Parked Claude conversation has no verified background attachment")
			}
		}
	}
	var path string
	var session any
	if pyTruthy(verified) {
		session, err = pyIndex(verified, "session_id")
		if err != nil {
			return nil, err
		}
		bound, _ := pyGet(verified, "transcript_path", nil)
		if pyTruthy(bound) {
			if path, err = pathFrom(bound); err != nil {
				return nil, err
			}
		}
	} else {
		var found string
		path, found, err = r.transcript(pid, provider)
		session = found
		if err != nil {
			if !isA(err, classUnbound) {
				return nil, err
			}
			path = ""
			candidates, err := r.peerRecords(pid, provider, "")
			if err != nil {
				return nil, err
			}
			sessions := map[string]bool{}
			for _, candidate := range candidates {
				sid, _ := pyIndex(candidate.row, "sessionId")
				sessions[sid.(string)] = true
			}
			if len(sessions) != 1 {
				return nil, valueError("No exact session is bound to this live agent")
			}
			for sid := range sessions {
				session = sid
			}
		}
	}
	transcriptIdentity := ""
	if path != "" {
		info, err := pyStat(path)
		if err != nil {
			return nil, err
		}
		if !isRegular(info) || int64(info.Uid) != r.uid || info.Mode&0o022 != 0 {
			return nil, valueError("Bound transcript does not identify this native session")
		}
		current, err := r.metadata(path, provider)
		if err != nil {
			return nil, err
		}
		if !pyEqual(nullable(current), session) {
			return nil, valueError("Bound transcript does not identify this native session")
		}
		transcriptIdentity = devIno(info)
	}
	endpoint := map[string]any{"pid": pid, "start": start, "provider": provider, "sessionID": session,
		"transcriptIdentity": transcriptIdentity, "rootPID": root, "rootStart": rootStart,
		"socketPath": "", "socketIdentity": "", "socketPID": int64(0), "socketStart": "", "transport": "unavailable"}
	var peers []peerRecord
	nativePeer, _ := pyGet(verified, "native_peer", nil)
	if provider == "claude" && pyTruthy(verified) && pyTruthy(nativePeer) {
		record, err := r.parkedClaudePeer(verified)
		if err != nil {
			return nil, err
		}
		peers = []peerRecord{*record}
		endpoint["nativePeer"] = nativePeer
		endpoint["bindingSource"], err = pyIndex(verified, "source")
		if err != nil {
			return nil, err
		}
	} else {
		sid, _ := session.(string)
		if peers, err = r.peerRecords(pid, provider, sid); err != nil {
			return nil, err
		}
	}
	if len(peers) == 1 {
		address, err := pyIndex(peers[0].row, "messagingSocketPath")
		if err != nil {
			return nil, err
		}
		worker, err := pyIndex(peers[0].row, "pid")
		if err != nil {
			return nil, err
		}
		endpoint["socketPath"], endpoint["socketIdentity"] = address, peers[0].incarnation
		endpoint["socketPID"], endpoint["socketStart"], endpoint["transport"] = worker, peers[0].start, "native_peer_socket"
	} else if provider == "codex" {
		if err := r.discoverCodex(endpoint, verified, pid, path, session); err != nil {
			return nil, err
		}
	}
	if after, err := r.identity(pid); err != nil {
		return nil, err
	} else if after != start {
		return nil, valueError("Agent process changed while discovering its endpoint")
	}
	if after, err := r.identity(root); err != nil {
		return nil, err
	} else if after != rootStart {
		return nil, valueError("Agent process changed while discovering its endpoint")
	}
	if path != "" {
		after, err := pyStat(path)
		if err != nil {
			return nil, err
		}
		if devIno(after) != transcriptIdentity {
			return nil, valueError("Bound transcript incarnation changed while discovering its endpoint")
		}
		if err := r.recheckTranscript(pid, provider, path, session.(string), verified); err != nil {
			return nil, err
		}
	}
	if pyTruthy(verified) {
		again, err := r.authenticated(pane, pid, provider, target)
		if err != nil {
			return nil, err
		}
		if !pyEqual(nullable(again), verified) {
			return nil, valueError("Authenticated frontend binding changed while discovering its endpoint")
		}
	}
	return endpoint, nil
}

// nullable maps Go's "no value" results to Python's None.
func nullable(value any) any {
	switch v := value.(type) {
	case string:
		if v == "" {
			return nil
		}
	case map[string]any:
		if v == nil {
			return nil
		}
	}
	return value
}

// discoverCodex asks the official app-server whether it has the exact thread
// loaded. Any socket or protocol failure leaves the endpoint unavailable.
func (r *runner) discoverCodex(endpoint map[string]any, verified map[string]any, pid int64, path string, session any) error {
	var native any = map[string]any{}
	if pyTruthy(verified) {
		native, _ = pyGet(verified, "native_endpoint", map[string]any{})
	}
	if pyTruthy(native) {
		if source, _ := pyGet(verified, "source", nil); !pyEqual(source, "native_runtime_mcp_origin") {
			proof, err := stockProxyIdentity(verified)
			if err != nil {
				return err
			}
			if proof == "" {
				return valueError("Native endpoint has no live runtime binding proof")
			}
		}
	}
	var address string
	if pyTruthy(native) {
		socket, err := pyIndex(native, "socket")
		if err != nil {
			return err
		}
		if address, err = pathFrom(socket); err != nil {
			return err
		}
	} else {
		root, err := r.accountRoot(pid, "codex")
		if err != nil {
			return err
		}
		address = pathJoin(root, "app-server-control/app-server-control.sock")
	}
	err := r.codexThreadLoaded(address, path, session, endpoint, native)
	if err != nil && !caught(err, classOS, classValue, classKey, classConnection) {
		return err
	}
	return nil
}

func (r *runner) codexThreadLoaded(address, path string, session any, endpoint map[string]any, native any) error {
	incarnation, err := r.socketIdentity(address)
	if err != nil {
		return err
	}
	daemonPID, err := pyGet(native, "daemon_pid", int64(0))
	if err != nil {
		return err
	}
	client, err := r.openWebSocket(address, incarnation, daemonPID)
	if err != nil {
		return err
	}
	defer client.close()
	var cursor any
	loaded := false
	for i := 0; i < 32; i++ {
		args := obj{{"limit", int64(128)}}
		if pyTruthy(cursor) {
			args = append(args, kv{"cursor", cursor})
		}
		result, err := client.rpc("thread/loaded/list", args)
		if err != nil {
			return err
		}
		data, err := pyGet(result, "data", []any{})
		if err != nil {
			return err
		}
		found, err := pyContains(data, session)
		if err != nil {
			return err
		}
		if found {
			loaded = true
			break
		}
		cursor, _ = pyGet(result, "nextCursor", nil)
		if !pyTruthy(cursor) {
			break
		}
	}
	if !loaded {
		return valueError("Exact Codex thread is not loaded on this server")
	}
	reply, err := client.rpc("thread/read", obj{{"threadId", session}, {"includeTurns", false}})
	if err != nil {
		return err
	}
	thread, err := pyIndex(reply, "thread")
	if err != nil {
		return err
	}
	id, err := pyGet(thread, "id", nil)
	if err != nil {
		return err
	}
	if !pyEqual(id, session) {
		return valueError("Codex thread changed")
	}
	if path != "" {
		threadPath, _ := pyGet(thread, "path", "")
		owned, err := pathFrom(threadPath)
		if err != nil {
			return err
		}
		left, err := resolvePath(owned, r.cwd, false)
		if err != nil {
			return err
		}
		right, err := resolvePath(path, r.cwd, false)
		if err != nil {
			return err
		}
		if left != right {
			return valueError("Codex server does not own the bound transcript")
		}
	}
	client.close()
	daemonStart, _ := pyGet(native, "daemon_start", "")
	endpoint["socketPath"], endpoint["socketIdentity"] = address, incarnation
	endpoint["socketPID"], endpoint["socketStart"] = daemonPID, pyStr(daemonStart)
	endpoint["transport"] = "codex_app_server_message"
	return nil
}

// authenticateNativePeer proves an inbox-only endpoint (a new session owns
// its inbox before its first transcript is written).
func (r *runner) authenticateNativePeer(endpoint map[string]any) (bool, error) {
	if !pyEqual(endpoint["transport"], "native_peer_socket") {
		return false, nil
	}
	pid := endpoint["socketPID"]
	current, err := r.identity(pid)
	if err != nil {
		return false, err
	}
	if !pyEqual(current, endpoint["socketStart"]) {
		return false, valueError("Native inbox process incarnation changed")
	}
	processes, err := r.inventory()
	if err != nil {
		return false, err
	}
	chain, err := ancestorsOf(pid, processes)
	if err != nil {
		return false, err
	}
	if !containsPID(chain, endpoint["pid"]) {
		if err := r.parkedForeground(endpoint, pid); err != nil {
			return false, err
		}
	}
	address := endpoint["socketPath"].(string)
	identity, err := r.socketIdentity(address)
	if err != nil {
		return false, err
	}
	if identity != endpoint["socketIdentity"] {
		return false, valueError("Native inbox socket changed")
	}
	if err := r.checkInboxOwner(address, address, pid, 3*time.Second, "Native inbox kernel owner mismatch"); err != nil {
		return false, err
	}
	if current, err := r.identity(pid); err != nil {
		return false, err
	} else if !pyEqual(current, endpoint["socketStart"]) {
		return false, valueError("Native inbox changed during authentication")
	}
	if identity, err := r.socketIdentity(address); err != nil {
		return false, err
	} else if identity != endpoint["socketIdentity"] {
		return false, valueError("Native inbox changed during authentication")
	}
	return true, nil
}

// parkedForeground accepts an inbox outside the frontend's process tree only
// when the frontend publishes exactly that parked background job.
func (r *runner) parkedForeground(endpoint map[string]any, pid any) error {
	if !pyEqual(endpoint["bindingSource"], "native_parked_job_kernel_owner") || !pyEqual(endpoint["provider"], "claude") {
		return valueError("Native inbox left the original agent")
	}
	sessions, err := r.claudeSessions(endpoint["pid"])
	if err != nil {
		return err
	}
	front, err := r.privateJSON(pathJoin(sessions, pyStr(endpoint["pid"])+".json"))
	if err != nil {
		return err
	}
	peer, ok := endpoint["nativePeer"]
	if !ok {
		peer = map[string]any{}
	}
	changed := valueError("Native parked foreground publication changed")
	get := func(value any, key string) (any, error) { return pyGet(value, key, nil) }
	checks := []struct {
		key  string
		want func() (any, error)
	}{
		{"pid", func() (any, error) { return endpoint["pid"], nil }},
		{"kind", func() (any, error) { return "interactive", nil }},
		{"entrypoint", func() (any, error) { return "cli", nil }},
	}
	for _, check := range checks {
		value, err := get(front, check.key)
		if err != nil {
			return err
		}
		want, _ := check.want()
		if !pyEqual(value, want) {
			return changed
		}
	}
	if proxy, _ := get(front, "relayProxy"); pyTruthy(proxy) {
		return changed
	}
	parked, _ := get(front, "parkedJobId")
	job, err := get(peer, "job_id")
	if err != nil {
		return err
	}
	if !pyEqual(parked, job) {
		return changed
	}
	frontSession, _ := get(front, "sessionId")
	frontend, _ := get(peer, "frontend_session")
	if !pyEqual(frontSession, frontend) {
		return changed
	}
	procStart, _ := get(front, "procStart")
	start, _ := endpoint["start"].(string)
	_, after, _ := strings.Cut(start, ":")
	if pyStr(procStart) != after {
		return changed
	}
	record, err := r.parkedClaudePeer(map[string]any{"source": endpoint["bindingSource"], "native_peer": peer,
		"session_id": endpoint["sessionID"]})
	if err != nil {
		return err
	}
	worker, err := pyIndex(record.row, "pid")
	if err != nil {
		return err
	}
	if !pyEqual(worker, pid) || record.start != endpoint["socketStart"] || record.incarnation != endpoint["socketIdentity"] {
		return valueError("Native parked inbox no longer matches the foreground attachment")
	}
	return nil
}
