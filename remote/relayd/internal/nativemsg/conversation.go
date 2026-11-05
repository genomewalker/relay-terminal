package nativemsg

import (
	"bytes"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// This file ports the read-only process, session and transcript discovery of
// communication_runtime/agent_conversation.py that pane_messaging.py uses.

const maxLine = 16 << 20

var (
	agentIDPattern  = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
	sessionPattern  = regexp.MustCompile(`^[0-9a-fA-F-]{32,36}$`)
	versionPattern  = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	revisionPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
	jobPattern      = regexp.MustCompile(`^[a-fA-F0-9]{8}$`)
)

// fullmatch is re.fullmatch(pattern, value): a non-string raises TypeError.
func fullmatch(pattern *regexp.Regexp, value any) (bool, error) {
	s, ok := value.(string)
	if !ok {
		return false, typeError("expected string or bytes-like object")
	}
	return pattern.MatchString(s), nil
}

type processRow struct {
	parent int64
	name   string
}

// pid converts a Python int to a PID; ok is false for one no process has.
func pidOf(value any) (int64, bool) {
	n, ok := pyInt(value)
	if !ok || !n.IsInt64() {
		return 0, false
	}
	return n.Int64(), true
}

// identity is agent_conversation.identity for any Python int.
func (r *runner) identity(value any) (string, error) {
	if pid, ok := pidOf(value); ok {
		return r.proc.identity(pid)
	}
	if r.proc.linux() {
		path := "/proc/" + pyStr(value)
		return "", osError(2, &path)
	}
	return "", unbound("Process owner changed.")
}

func (r *runner) inventory() (map[int64]processRow, error) {
	rows, err := r.proc.processes()
	if err != nil {
		return nil, err
	}
	result := map[int64]processRow{}
	for _, row := range rows {
		// ps prints "PID PPID UID COMM"; split(None, 3) drops a command
		// name that is empty or all whitespace, and its leading blanks.
		name := strings.TrimLeftFunc(row.comm, pyIsSpace)
		if name == "" || row.uid != r.uid || row.pid <= 1 {
			continue
		}
		if r.proc.linux() && versionPattern.MatchString(name) {
			// A pinned native Claude exec is named after its version in Linux
			// comm; resolve that process's actual image.
			if executable, err := r.proc.executable(row.pid); err == nil {
				if kind, err := r.provider(executable); err == nil && kind == "claude" {
					name = executable
				}
			}
		}
		result[row.pid] = processRow{parent: row.ppid, name: name}
	}
	if len(result) > 16384 {
		return nil, unbound("Process inventory exceeded its limit.")
	}
	return result, nil
}

// privateFile is agent_conversation.private_file.
func (r *runner) privateFile(path string, limit int) ([]byte, float64, error) {
	f, st, err := openNoFollow(path)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	if int64(st.Uid) != r.uid || st.Mode&0o022 != 0 || !isRegular(st) || st.Size > int64(limit) {
		return nil, 0, unbound("The source file is not an owner-controlled regular file.")
	}
	data, err := readUpTo(f, limit+1)
	if err != nil {
		return nil, 0, err
	}
	info, err := f.Stat()
	if err != nil {
		return nil, 0, fromOS(err)
	}
	modified := info.ModTime()
	// os.stat_result.st_mtime is sec + 1e-9 * nsec.
	return data, float64(modified.Unix()) + 1e-9*float64(modified.Nanosecond()), nil
}

func (r *runner) rootForPane(pane string) (any, error) {
	stateHome := pathJoin(r.home, ".local/state")
	if value, ok := r.host.getenv("XDG_STATE_HOME"); ok {
		stateHome = pathNorm(value)
	}
	state := pathJoin(stateHome, "relay/workers")
	var paths []string
	dirs, err := globNames(state, "recovered-*", true)
	if err != nil {
		return nil, err
	}
	for _, dir := range dirs {
		candidate := pathJoin(state, dir+"/"+pane+".json")
		if _, err := pyStat(candidate); err == nil {
			paths = append(paths, candidate)
		}
	}
	if len(paths) > 3 {
		paths = paths[:3]
	}
	if len(paths) == 0 {
		paths = []string{pathJoin(state, pane+".json")}
	}
	if len(paths) != 1 {
		return nil, unbound("Multiple recovered workers claim this pane.")
	}
	data, _, err := r.privateFile(paths[0], 65536)
	if err != nil {
		return nil, err
	}
	record, err := loadsBytes(data)
	if err != nil {
		return nil, err
	}
	session, err := pyGet(record, "session_id", nil)
	if err != nil {
		return nil, err
	}
	state2, _ := pyGet(record, "state", nil)
	if !pyEqual(session, pane) || !pyEqual(state2, "running") {
		return nil, unbound("No live durable worker owns this pane.")
	}
	workerValue, err := pyIndex(record, "worker_pid")
	if err != nil {
		return nil, err
	}
	worker, err := pyIntConvert(workerValue)
	if err != nil {
		return nil, err
	}
	shellValue, err := pyIndex(record, "shell_pid")
	if err != nil {
		return nil, err
	}
	shell, err := pyIntConvert(shellValue)
	if err != nil {
		return nil, err
	}
	if r.proc.linux() {
		start, err := r.identity(worker)
		if err != nil {
			return nil, err
		}
		recorded, err := pyIndex(record, "worker_start_time")
		if err != nil {
			return nil, err
		}
		if start != "linux:"+pyStr(recorded) {
			return nil, unbound("The worker process incarnation changed.")
		}
	}
	processes, err := r.inventory()
	if err != nil {
		return nil, err
	}
	shellPID, shellOK := pidOf(shell)
	if _, live := processes[shellPID]; !shellOK || !live {
		return nil, unbound("The pane shell is not owned by its worker.")
	}
	chain, err := ancestors(shellPID, processes)
	if err != nil {
		return nil, err
	}
	if !containsPID(chain, worker) {
		return nil, unbound("The pane shell is not owned by its worker.")
	}
	return normalInt(shell), nil
}

// normalInt keeps a PID-sized Python int as int64.
func normalInt(n *big.Int) any {
	if n.IsInt64() {
		return n.Int64()
	}
	return n
}

func containsPID(chain []int64, value any) bool {
	for _, pid := range chain {
		if pyEqual(pid, value) {
			return true
		}
	}
	return false
}

// ancestors is the process's own PID and its parents, at most 64.
func ancestors(pid int64, processes map[int64]processRow) ([]int64, error) {
	var result []int64
	for pid > 1 && len(result) < 64 {
		row, ok := processes[pid]
		if !ok {
			break
		}
		for _, seen := range result {
			if seen == pid {
				return nil, unbound("Invalid process ancestry.")
			}
		}
		result = append(result, pid)
		pid = row.parent
	}
	return result, nil
}

// ancestorsOf is ancestors() for any Python value used as a PID.
func ancestorsOf(value any, processes map[int64]processRow) ([]int64, error) {
	pid, ok := pidOf(value)
	if !ok {
		return nil, nil
	}
	return ancestors(pid, processes)
}

// provider classifies a ps command name or an executable path.
func (r *runner) provider(name string) (string, error) {
	base := pyLower(pathName(name))
	switch base {
	case "codex", "codex.exe":
		return "codex", nil
	case "claude", "claude.exe":
		return "claude", nil
	}
	path := pathNorm(name)
	if pathIsAbs(path) {
		versions, err := resolvePath(pathJoin(r.home, ".local/share/claude/versions"), r.cwd, true)
		if err != nil {
			return "", nil
		}
		resolved, err := resolvePath(path, r.cwd, true)
		if err != nil {
			return "", nil
		}
		if pathParent(resolved) == versions && pathName(resolved) == pathName(path) {
			if st, err := pyStat(resolved); err == nil && isRegular(st) {
				return "claude", nil
			}
		}
	}
	return "", nil
}

func (r *runner) agent(root any, pane string) (int64, string, error) {
	processes, err := r.inventory()
	if err != nil {
		return 0, "", err
	}
	rootPID, ok := pidOf(root)
	if _, live := processes[rootPID]; !ok || !live {
		return 0, "", unbound("The pane foreground process is no longer running.")
	}
	candidates := map[int64]string{}
	chains := map[int64][]int64{}
	for pid, row := range processes {
		chain, err := ancestors(pid, processes)
		if err != nil {
			return 0, "", err
		}
		chains[pid] = chain
		if !containsPID(chain, rootPID) {
			continue
		}
		if kind, _ := r.provider(row.name); kind != "" {
			candidates[pid] = kind
		}
	}
	var top []int64
	for pid := range candidates {
		nested := false
		for _, parent := range chains[pid][1:] {
			if _, ok := candidates[parent]; ok {
				nested = true
				break
			}
		}
		if !nested {
			top = append(top, pid)
		}
	}
	if len(top) != 1 {
		// Official Node launchers can place the frontend and its private
		// server in sibling subtrees. Only the exact live proxy and native
		// process proof may select one of those Codex candidates.
		if selected, ok := r.stockProxyCandidate(pane, candidates); ok {
			return selected, "codex", nil
		}
		return 0, "", unbound("An exact, unique foreground agent is required.")
	}
	return top[0], candidates[top[0]], nil
}

func (r *runner) stockProxyCandidate(pane string, candidates map[int64]string) (int64, bool) {
	if r.host.NativeProcessStart == nil {
		return 0, false
	}
	data, err := r.host.binding(r.ctx, pane, "")
	if err != nil {
		return 0, false
	}
	initial, err := loadsBytes(data)
	if err != nil {
		return 0, false
	}
	producer, err := pyGet(initial, "producer", map[string]any{})
	if err != nil {
		return 0, false
	}
	value, err := pyGet(producer, "process_id", nil)
	pid, strict := intNotBool(value)
	if err != nil || !strict || !pid.IsInt64() || candidates[pid.Int64()] != "codex" {
		return 0, false
	}
	object, ok := initial.(map[string]any)
	if !ok {
		return 0, false
	}
	delete(object, "observed_at")
	verified, err := r.authenticatedBinding(pane, pid.Int64(), "codex", "")
	if err != nil || !pyEqual(object, verified) {
		return 0, false
	}
	proof, err := stockProxyIdentity(verified)
	if err != nil || proof == "" {
		return 0, false
	}
	start, err := pyGet(producer, "process_start", nil)
	want, strict := intNotBool(start)
	if err != nil || !strict || !want.IsUint64() || want.Sign() <= 0 {
		return 0, false
	}
	type incarnation struct {
		start uint64
		err   error
	}
	got, crashed, finished := call(r.ctx, 5*time.Second, func() incarnation {
		start, err := r.host.NativeProcessStart(pane, pid.Int64(), "codex")
		return incarnation{start, err}
	})
	return pid.Int64(), !crashed && finished && got.err == nil && got.start == want.Uint64()
}

// metadata is the session a transcript's first rows name, or "".
func (r *runner) metadata(path, kind string) (string, error) {
	f, st, err := openNoFollow(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if int64(st.Uid) != r.uid || st.Mode&0o022 != 0 || !isRegular(st) {
		return "", nil
	}
	reader := newLineReader(f)
	for i := 0; i < 16; i++ {
		line, err := reader.readline(maxLine + 1)
		if err != nil {
			return "", err
		}
		if len(line) == 0 || len(line) > maxLine {
			return "", nil
		}
		row, err := loadsBytes(line)
		if err != nil {
			if isA(err, classValue) {
				return "", nil
			}
			return "", err
		}
		if !isDict(row) {
			return "", nil
		}
		rowType, _ := pyGet(row, "type", nil)
		if kind == "codex" && pyEqual(rowType, "session_meta") {
			payload, _ := pyGet(row, "payload", map[string]any{})
			source, err := pyGet(payload, "source", nil)
			if err != nil {
				return "", err
			}
			if isDict(source) {
				return "", nil
			}
			sid, _ := pyGet(payload, "id", "")
			if ok, _ := fullmatch(sessionPattern, sid); ok {
				return sid.(string), nil
			}
			return "", nil
		}
		if kind == "claude" {
			sidechain, _ := pyGet(row, "isSidechain", nil)
			if !pyTruthy(sidechain) {
				sid, _ := pyGet(row, "sessionId", "")
				if ok, _ := fullmatch(sessionPattern, sid); ok {
					return sid.(string), nil
				}
			}
		}
	}
	return "", nil
}

// processVariable is one variable of the process's initial environment.
func (r *runner) processVariable(pid int64, name string) (string, error) {
	entries, err := r.proc.environment(pid)
	if err != nil {
		return "", err
	}
	prefix := []byte(name + "=")
	var values [][]byte
	for _, entry := range entries {
		if bytes.HasPrefix(entry, prefix) {
			values = append(values, entry[len(prefix):])
		}
	}
	if len(values) > 1 {
		return "", unbound("Ambiguous process environment.")
	}
	value := ""
	if len(values) == 1 {
		runes, err := decodeUTF8(values[0], false)
		if err != nil {
			return "", err
		}
		value = pyString(runes)
	}
	if value != "" && (!strings.HasPrefix(value, "/") || normpath(value) != value) {
		return "", unbound("Invalid account directory.")
	}
	return value, nil
}

var accountVariable = map[string]string{"claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"}

// accountRoot is the process's own CLAUDE_CONFIG_DIR or CODEX_HOME.
func (r *runner) accountRoot(pid any, kind string) (string, error) {
	var override string
	var err error
	if n, ok := pidOf(pid); ok {
		override, err = r.processVariable(n, accountVariable[kind])
	} else {
		path := "/proc/" + pyStr(pid) + "/environ"
		err = osError(2, &path)
	}
	if err != nil {
		if !caught(err, classOS, classValue, classIndex, classUnbound) {
			return "", err
		}
		override = ""
		if kind == "codex" {
			override, _ = r.host.getenv("CODEX_HOME")
		}
	}
	if override != "" {
		return pathNorm(override), nil
	}
	return pathJoin(r.home, "."+kind), nil
}

func (r *runner) transcript(pid int64, kind string) (string, string, error) {
	root, err := r.accountRoot(pid, kind)
	if err != nil {
		return "", "", err
	}
	base := pathJoin(root, map[string]string{"codex": "sessions", "claude": "projects"}[kind])
	resolved, err := resolvePath(base, r.cwd, false)
	if err != nil {
		return "", "", err
	}
	candidates := map[string]string{}
	paths, err := r.proc.openPaths(pid)
	if err != nil {
		return "", "", err
	}
	for _, raw := range paths {
		path := pathNorm(raw)
		full, err := resolvePath(path, r.cwd, false)
		if err != nil {
			if caught(err, classOS, classValue) {
				continue
			}
			return "", "", err
		}
		if !pathRelativeTo(full, resolved) || pathSuffix(path) != ".jsonl" {
			continue
		}
		sid, err := r.metadata(path, kind)
		if err != nil {
			if caught(err, classOS, classValue) {
				continue
			}
			return "", "", err
		}
		if sid != "" {
			candidates[full] = sid
		}
	}
	if kind == "claude" && len(candidates) == 0 {
		if err := r.registryTranscript(root, base, pid, kind, candidates); err != nil {
			return "", "", err
		}
	}
	if len(candidates) != 1 {
		return "", "", unbound("No unique transcript is bound to the running process. No directory fallback was used.")
	}
	for path, session := range candidates {
		return path, session, nil
	}
	return "", "", nil
}

// registryTranscript is transcript()'s Claude session registry fallback.
func (r *runner) registryTranscript(root, base string, pid int64, kind string, candidates map[string]string) error {
	registry := pathJoin(root, "sessions/"+strconv.FormatInt(pid, 10)+".json")
	err := func() error {
		data, mtime, err := r.privateFile(registry, 65536)
		if err != nil {
			return err
		}
		record, err := loadsBytes(data)
		if err != nil {
			return err
		}
		fallback, err := pyGet(record, "session_id", "")
		if err != nil {
			return err
		}
		sid, _ := pyGet(record, "sessionId", fallback)
		matched, err := fullmatch(sessionPattern, sid)
		if err != nil {
			if _, ok := sid.(string); !ok {
				return unbound("Stale session registry.")
			}
			return err
		}
		if !matched {
			return unbound("Stale session registry.")
		}
		started, err := r.proc.epoch(pid)
		if err != nil {
			return err
		}
		if mtime+1 < started {
			return unbound("Stale session registry.")
		}
		names, err := globNames(base, "*", true)
		if err != nil {
			return err
		}
		var matches []string
		for _, dir := range names {
			path := pathJoin(base, dir+"/"+sid.(string)+".jsonl")
			if _, err := pyStat(path); err == nil {
				matches = append(matches, path)
			}
		}
		if len(matches) > 3 {
			matches = matches[:3]
		}
		for _, path := range matches {
			found, err := r.metadata(path, kind)
			if err != nil {
				return err
			}
			if found == sid {
				full, err := resolvePath(path, r.cwd, false)
				if err != nil {
					return err
				}
				candidates[full] = found
			}
		}
		return nil
	}()
	if err != nil && !caught(err, classOS, classValue, classUnbound) {
		return err
	}
	return nil
}

// recheckTranscript proves the frontend still shows the same transcript.
func (r *runner) recheckTranscript(pid int64, kind, path, session string, verified map[string]any) error {
	if pyTruthy(verified) {
		if bound, _ := pyGet(verified, "transcript_path", nil); pyTruthy(bound) {
			boundPath, err := pathFrom(bound)
			if err != nil {
				return err
			}
			left, err := resolvePath(boundPath, r.cwd, false)
			if err != nil {
				return err
			}
			right, err := resolvePath(path, r.cwd, false)
			if err != nil {
				return err
			}
			if left != right {
				return unbound("Authenticated transcript session changed during the read; refresh.")
			}
			current, err := r.metadata(path, kind)
			if err != nil {
				return err
			}
			if current != session {
				return unbound("Authenticated transcript session changed during the read; refresh.")
			}
			return nil
		}
	}
	currentPath, currentSession, err := r.transcript(pid, kind)
	if err != nil {
		return err
	}
	left, err := resolvePath(currentPath, r.cwd, false)
	if err != nil {
		return err
	}
	right, err := resolvePath(path, r.cwd, false)
	if err != nil {
		return err
	}
	if left != right || currentSession != session {
		return unbound("The frontend changed its bound transcript during the read; refresh.")
	}
	return nil
}

// authenticatedBinding is relayd's verified binding of the pane's agent, or
// nil where `relayd agent-binding` produced none.
func (r *runner) authenticatedBinding(pane string, pid int64, kind, session string) (map[string]any, error) {
	output, err := r.host.binding(r.ctx, pane, session)
	if err != nil {
		if isA(err, classUnbound) {
			return nil, err
		}
		return nil, nil
	}
	decoded, err := loadsText([]byte(strings.ToValidUTF8(string(output), "�")))
	if err != nil {
		if isA(err, classValue) {
			return nil, nil
		}
		return nil, err
	}
	if session != "" {
		bound, err := pyGet(decoded, "session_id", nil)
		if err != nil {
			return nil, err
		}
		if !pyEqual(bound, session) {
			return nil, unbound("Authenticated target session does not match.")
		}
	}
	producer, err := pyGet(decoded, "producer", map[string]any{})
	if err != nil {
		return nil, err
	}
	version, _ := pyGet(decoded, "version", nil)
	if !pyEqual(version, int64(1)) {
		return nil, unbound("Authenticated producer does not match this conversation.")
	}
	for _, check := range []struct {
		key  string
		want any
	}{{"pane_id", pane}, {"process_id", pid}, {"provider", kind}} {
		value, err := pyGet(producer, check.key, nil)
		if err != nil {
			return nil, err
		}
		if !pyEqual(value, check.want) {
			return nil, unbound("Authenticated producer does not match this conversation.")
		}
	}
	start, _ := pyGet(producer, "process_start", nil)
	n, ok := pyInt(start)
	if !ok || n.Sign() <= 0 {
		return nil, unbound("Invalid authenticated session binding.")
	}
	sid, _ := pyGet(decoded, "session_id", "")
	matched, err := fullmatch(agentIDPattern, sid)
	if err != nil {
		return nil, err
	}
	if !matched {
		return nil, unbound("Invalid authenticated session binding.")
	}
	value := decoded.(map[string]any)
	delete(value, "observed_at")
	return value, nil
}

// stockProxyIdentity is "" unless the binding is relayd's live stock App
// Server proxy, whose proof must be complete.
func stockProxyIdentity(verified map[string]any) (string, error) {
	if !pyTruthy(verified) {
		return "", nil
	}
	if source, _ := pyGet(verified, "source", nil); !pyEqual(source, "stock_app_server_proxy") {
		return "", nil
	}
	invalid := unbound("The stock App Server proxy has no live identity proof.")
	proof, _ := pyGet(verified, "stock_proxy", map[string]any{})
	endpoint, _ := pyGet(verified, "native_endpoint", map[string]any{})
	if !isDict(proof) || !isDict(endpoint) {
		return "", invalid
	}
	for _, key := range []string{"proxy_pid", "proxy_start", "control_device", "control_inode", "connection", "selection"} {
		value, _ := pyGet(proof, key, nil)
		n, ok := intNotBool(value)
		if !ok || n.Sign() <= 0 {
			return "", invalid
		}
	}
	control, _ := pyGet(proof, "control_socket", nil)
	if s, ok := control.(string); !ok || !strings.HasPrefix(s, "/") {
		return "", invalid
	}
	socket, _ := pyGet(endpoint, "socket", nil)
	if s, ok := socket.(string); !ok || !strings.HasPrefix(s, "/") {
		return "", invalid
	}
	daemonPID, _ := pyGet(endpoint, "daemon_pid", nil)
	if n, ok := pyInt(daemonPID); !ok || n.Cmp(big.NewInt(1)) <= 0 {
		return "", invalid
	}
	daemonStart, _ := pyGet(endpoint, "daemon_start", nil)
	if n, ok := pyInt(daemonStart); !ok || n.Sign() <= 0 {
		return "", invalid
	}
	revision, _ := pyGet(verified, "revision", "")
	matched, err := fullmatch(revisionPattern, revision)
	if err != nil {
		return "", err
	}
	if !matched {
		return "", invalid
	}
	return "stock-proxy:" + revision.(string), nil
}
