package daemon

// Go port of the durable host pane-health controller formerly run as
// pane_health_controller.py. The relayd supervisor owns scheduling. This
// controller never attaches a terminal, claims an input lease, sends keys,
// restarts a provider, or executes model text. Its model tools can inspect
// native facts and report a hold. Native identity probes, health-message
// validation and the budgeted Haiku journal remain in Python behind
// paneHealthBackend (host_pane_health_backend.go).
//
// State files keep the Python format byte for byte: compact JSON with sorted
// keys and raw UTF-8, Python float repr for time.time() stamps, and the same
// SHA-256 digests over that encoding, so existing state stays valid. Python
// exceptions are panics recovered by run(), producing the same failure codes.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	paneHealthNativeInterval = 120
	paneHealthModelInterval  = 6 * 3600
	paneHealthStateLimit     = 2 << 20
	paneHealthToolResults    = 384
	paneHealthCompletedKept  = 128
	paneHealthReceiptsKept   = 256
	paneHealthModelBatch     = 64
	paneHealthModelSteps     = 12
)

var (
	paneHealthPaneID       = regexp.MustCompile(`^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$`)
	paneHealthOperationID  = regexp.MustCompile(`^[a-f0-9]{32}$`)
	paneHealthHostID       = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
	paneHealthSessionID    = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
	paneHealthRevision     = regexp.MustCompile(`^[a-f0-9]{64}$`)
	paneHealthReceiptState = regexp.MustCompile(`^[a-z_]{1,48}$`)
)

// paneHealthControllerError is the Python ControllerError: its code is
// reported verbatim.
type paneHealthControllerError string

func (e paneHealthControllerError) Error() string { return string(e) }

// paneHealthBackendError is an exception raised by the Python backend. code
// is its `code` attribute (DraftError), empty when it had none.
type paneHealthBackendError struct{ code string }

func (e *paneHealthBackendError) Error() string {
	if e.code == "" {
		return "pane health backend failed"
	}
	return e.code
}

// paneHealthOSError stands for Python OSError and other uncoded failures.
type paneHealthOSError struct{ err error }

func (e paneHealthOSError) Error() string { return e.err.Error() }

// paneHealthBackend is everything the controller still needs from Python:
// native pane probes (agent_maintenance) and text_backend's health
// validation and Haiku journal. Errors are *paneHealthBackendError.
type paneHealthBackend interface {
	Probe(pane string) (any, error)
	ValidatePanes(hostID, snapshotID, panes any) (any, error)
	ValidateMessages(messages, hostID, panes any) (any, error)
	ValidateCalls(content, latest any) (any, error)
	Assess(request *pyObject) (any, error)
	Status(operationID any) (any, error)
}

type paneHealthController struct {
	root        string
	backend     paneHealthBackend
	now         func() any // Python time.time(): a float in production
	parentAlive func() bool
}

func paneHealthTimeNow() any { return float64(time.Now().UnixNano()) / 1e9 }

func paneHealthDigest(value any) string {
	sum := sha256.Sum256(pyCompact(value))
	return hex.EncodeToString(sum[:])
}

func newPaneHealthController(root string, backend paneHealthBackend, now func() any, parentAlive func() bool) *paneHealthController {
	if err := os.MkdirAll(root, 0o700); err != nil {
		panic(paneHealthOSError{err})
	}
	c := &paneHealthController{root: root, backend: backend, now: now, parentAlive: parentAlive}
	c.private(root, true)
	return c
}

// runPaneHealthController is the former Python main(): one operation, and
// every failure becomes {"v":1,"status":"failed","code":...}.
func runPaneHealthController(root string, backend paneHealthBackend, now func() any, parentAlive func() bool,
	operation string, request any) (result *pyObject) {
	defer func() {
		if recovered := recover(); recovered != nil {
			result = pyObj("v", int64(1), "status", "failed", "code", paneHealthFailureCode(recovered))
		}
	}()
	c := newPaneHealthController(root, backend, now, parentAlive)
	if request == nil {
		request = newPyObject()
	}
	switch operation {
	case "configure":
		return c.configure(request)
	case "check":
		return c.check(pyGet(request, "operation_id", nil))
	case "desktop_facts":
		return c.desktopFacts(pyGet(request, "owner_id", nil), pyGet(request, "generation", nil), pyGet(request, "facts", nil))
	case "complete_action":
		return c.completeAction(pyGet(request, "owner_id", nil), pyGet(request, "operation_id", nil),
			pyGet(request, "action_id", nil), pyGet(request, "result", nil))
	case "tick":
		return c.tick()
	case "status":
		return c.status()
	}
	panic(paneHealthControllerError("invalid_controller_operation"))
}

func paneHealthFailureCode(recovered any) string {
	switch e := recovered.(type) {
	case paneHealthControllerError:
		return string(e)
	case *paneHealthBackendError:
		if e.code != "" {
			return e.code
		}
	}
	return "controller_state_or_backend_unavailable"
}

func paneHealthRaise(err error) {
	if err == nil {
		return
	}
	var backend *paneHealthBackendError
	if errors.As(err, &backend) {
		panic(backend)
	}
	panic(paneHealthOSError{err})
}

func (c *paneHealthController) private(path string, directory bool) {
	info, err := os.Lstat(path)
	if err != nil {
		panic(paneHealthOSError{err})
	}
	valid := info.Mode().IsRegular()
	if directory {
		valid = info.IsDir()
	}
	if !valid || !paneHealthOwnedPrivate(info) {
		panic(paneHealthControllerError("controller_state_not_private"))
	}
}

func paneHealthOwnedPrivate(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Getuid() && uint32(stat.Mode)&0o077 == 0
}

func (c *paneHealthController) load(name string, fallback any) any {
	file, err := os.OpenFile(filepath.Join(c.root, name), os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if errors.Is(err, os.ErrNotExist) {
		return fallback
	}
	if err != nil {
		panic(paneHealthOSError{err})
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		panic(paneHealthOSError{err})
	}
	if !info.Mode().IsRegular() || !paneHealthOwnedPrivate(info) {
		panic(paneHealthControllerError("controller_state_not_private"))
	}
	data, err := io.ReadAll(io.LimitReader(file, paneHealthStateLimit+1))
	if err != nil {
		panic(paneHealthOSError{err})
	}
	if len(data) > paneHealthStateLimit {
		panic(paneHealthControllerError("controller_state_too_large"))
	}
	value, err := pyDecode(data)
	if err != nil {
		panic(paneHealthOSError{err})
	}
	return value
}

func (c *paneHealthController) save(name string, value *pyObject) {
	if name == "state.json" {
		if value.Has("tool_results") {
			// dict(list(items)[-384:]) is a new dict; local aliases keep the old one.
			results := pyMustObject(value.Get("tool_results"))
			trimmed := newPyObject()
			keys := results.Keys()
			for _, key := range keys[max(0, len(keys)-paneHealthToolResults):] {
				trimmed.Set(key, results.Get(key))
			}
			value.Set("tool_results", trimmed)
		}
		if value.Has("action_requests") {
			actions := pyMustObject(value.Get("action_requests"))
			completed := []string{}
			for _, key := range actions.Keys() {
				if !pyEqual(pyIndex(actions.Get(key), "state"), "pending_native") {
					completed = append(completed, key)
				}
			}
			for _, key := range completed[:max(0, len(completed)-paneHealthCompletedKept)] {
				actions.Delete(key)
			}
		}
	}
	data := pyCompact(value)
	if len(data) > paneHealthStateLimit {
		panic(paneHealthControllerError("controller_state_too_large"))
	}
	temporary, err := os.CreateTemp(c.root, ".controller-")
	if err != nil {
		panic(paneHealthOSError{err})
	}
	path := temporary.Name()
	defer os.Remove(path)
	_, err = temporary.Write(data)
	if err == nil {
		err = temporary.Sync()
	}
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(path, filepath.Join(c.root, name))
	}
	if err == nil {
		var directory *os.File
		if directory, err = os.Open(c.root); err == nil {
			err = directory.Sync()
			directory.Close()
		}
	}
	if err != nil {
		panic(paneHealthOSError{err})
	}
}

// lock returns an exclusive flock. With blocking false, busy reports a lock
// held elsewhere (BlockingIOError in Python).
func (c *paneHealthController) lock(name string, blocking bool) (file *os.File, busy bool) {
	file, err := os.OpenFile(filepath.Join(c.root, name), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		panic(paneHealthOSError{err})
	}
	ok := false
	defer func() {
		if !ok {
			file.Close()
		}
	}()
	info, err := file.Stat()
	if err != nil {
		panic(paneHealthOSError{err})
	}
	if !info.Mode().IsRegular() || !paneHealthOwnedPrivate(info) {
		panic(paneHealthControllerError("controller_lock_not_private"))
	}
	// A blocking wait polls a non-blocking flock so that an operation whose
	// deadline or supervisor lifetime ended stops waiting. The former
	// subprocess had a kill boundary here; an in-process wait needs its own.
	delay := 2 * time.Millisecond
	for {
		err = syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == syscall.EINTR {
			continue
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			break
		}
		if !blocking {
			return nil, true
		}
		c.ensureLive()
		time.Sleep(delay)
		delay = min(2*delay, 50*time.Millisecond)
	}
	if err != nil {
		panic(paneHealthOSError{err})
	}
	ok = true
	return file, false
}

// ensureLive stops an operation whose context or supervisor ended. It guards
// lock waits and configuration mutations only: tick's settlement writes after
// a model call (pending IDs, unknown outcomes) never depend on it.
func (c *paneHealthController) ensureLive() {
	if !c.parentAlive() {
		panic(paneHealthControllerError("controller_operation_cancelled"))
	}
}

func (c *paneHealthController) configure(request any) *pyObject {
	required := []string{"v", "operation", "operation_id", "host_id", "owner_id", "enabled", "haiku_enabled", "panes"}
	invalid := func() bool {
		r, ok := request.(*pyObject)
		if !ok || r.Len() != len(required) {
			return true
		}
		for _, key := range required {
			if !r.Has(key) {
				return true
			}
		}
		if !pyEqual(r.Get("v"), int64(1)) || !pyEqual(r.Get("operation"), "configure") ||
			!pyFullMatch(paneHealthOperationID, r.Get("operation_id")) ||
			!pyFullMatch(paneHealthHostID, r.Get("host_id")) || !pyFullMatch(paneHealthPaneID, r.Get("owner_id")) {
			return true
		}
		for _, key := range []string{"enabled", "haiku_enabled"} {
			if _, ok := r.Get(key).(bool); !ok {
				return true
			}
		}
		panes, ok := r.Get("panes").(*pyList)
		if !ok || len(panes.items) < 1 || len(panes.items) > 128 {
			return true
		}
		seen := map[string]bool{}
		for _, pane := range panes.items {
			text, ok := pane.(string)
			if !ok || !paneHealthPaneID.MatchString(text) {
				return true
			}
			seen[text] = true
		}
		return len(seen) != len(panes.items)
	}
	if invalid() {
		panic(paneHealthControllerError("invalid_controller_configuration"))
	}
	r := request.(*pyObject)
	lock, _ := c.lock("configuration.lock", true)
	unchanged := func() bool {
		defer lock.Close()
		c.ensureLive()
		old := c.load("configuration.json", newPyObject())
		if pyTruthy(old) && !pyEqual(pyIndex(old, "owner_id"), r.Get("owner_id")) {
			panic(paneHealthControllerError("controller_owned_by_another_installation"))
		}
		fields := newPyObject()
		for _, key := range r.Keys() {
			if key != "operation" && key != "operation_id" {
				fields.Set(key, r.Get(key))
			}
		}
		panes := append([]any(nil), r.Get("panes").(*pyList).items...)
		sort.Slice(panes, func(i, j int) bool { return panes[i].(string) < panes[j].(string) })
		fields.Set("panes", &pyList{items: panes})
		configurationID := paneHealthDigest(fields)
		if pyEqual(pyGet(old, "configuration_id", nil), configurationID) {
			return true
		}
		fields.Set("configuration_id", configurationID)
		fields.Set("configured_at", c.now())
		fields.Set("force_sequence", pyGet(old, "force_sequence", int64(0)))
		fields.Set("generation", pyAdd(pyGet(old, "generation", int64(0)), int64(1)))
		c.ensureLive()
		c.save("configuration.json", fields)
		return false
	}()
	result := c.status()
	if !unchanged {
		result.Set("wake_controller", true)
	}
	return result
}

func (c *paneHealthController) check(operationID any) *pyObject {
	if !pyIsString(operationID) || !pyFullMatch(paneHealthOperationID, operationID) {
		panic(paneHealthControllerError("invalid_controller_operation"))
	}
	lock, _ := c.lock("configuration.lock", true)
	changed := func() bool {
		defer lock.Close()
		c.ensureLive()
		config := c.load("configuration.json", newPyObject())
		if !pyTruthy(config) {
			panic(paneHealthControllerError("controller_not_configured"))
		}
		recent := pyGet(config, "checks", pyListOf())
		if pyContains(recent, operationID) {
			return false
		}
		object := pyMustObject(config)
		object.Set("force_sequence", pyAdd(pyGet(config, "force_sequence", int64(0)), int64(1)))
		items := append(append([]any(nil), pyMustList(recent).items...), operationID)
		object.Set("checks", &pyList{items: items[max(0, len(items)-32):]})
		c.ensureLive()
		c.save("configuration.json", object)
		return true
	}()
	result := c.status()
	result.Set("wake_controller", changed)
	return result
}

func (c *paneHealthController) status() *pyObject {
	config := c.load("configuration.json", newPyObject())
	state := c.load("state.json", newPyObject())
	next := int64(-1)
	if pyTruthy(pyGet(config, "enabled", nil)) {
		next = paneHealthNativeInterval
	}
	return pyObj("v", int64(1), "status", "controller_status", "controller", "relayd",
		"configuration", config, "state", state, "next_check_seconds", next)
}

func (c *paneHealthController) desktopFacts(owner, generation, panes any) *pyObject {
	config := c.load("configuration.json", newPyObject())
	scopeChanged := func() bool {
		if !pyEqual(pyGet(config, "owner_id", nil), owner) || !pyEqual(pyGet(config, "generation", nil), generation) {
			return true
		}
		list, ok := panes.(*pyList)
		if !ok || len(list.items) < 1 || len(list.items) > 64 {
			return true
		}
		for _, pane := range list.items {
			object, ok := pane.(*pyObject)
			if !ok || !pyContains(pyIndex(config, "panes"), object.Get("pane_id")) {
				return true
			}
		}
		return false
	}
	if scopeChanged() {
		panic(paneHealthControllerError("desktop_input_facts_scope_changed"))
	}
	host := pyIndex(config, "host_id")
	_, err := c.backend.ValidatePanes(host, paneHealthDigest(pyObj("host_id", host, "panes", panes)), panes)
	paneHealthRaise(err)
	configurationLock, _ := c.lock("configuration.lock", true)
	defer configurationLock.Close()
	latest := c.load("configuration.json", newPyObject())
	if !pyEqual(pyGet(latest, "owner_id", nil), owner) || !pyEqual(pyGet(latest, "generation", nil), generation) {
		panic(paneHealthControllerError("desktop_input_facts_scope_changed"))
	}
	factsLock, _ := c.lock("desktop-facts.lock", true)
	defer factsLock.Close()
	stored := pyMustObject(c.load("desktop-facts.json", newPyObject()))
	if !pyEqual(stored.Get("generation"), generation) {
		stored = pyObj("generation", generation, "panes", newPyObject())
	}
	for _, pane := range panes.(*pyList).items {
		pyMustObject(pyIndex(stored, "panes")).Set(pyMustString(pyIndex(pane, "pane_id")), pyObj("at", c.now(), "facts", pane))
	}
	c.save("desktop-facts.json", stored)
	return c.status()
}

func (c *paneHealthController) nativeAction(owner, operationID, actionID, result any) (*pyObject, *pyObject) {
	config := c.load("configuration.json", newPyObject())
	state := c.load("state.json", newPyObject())
	action := pyGet(pyGet(state, "action_requests", newPyObject()), actionID, nil)
	invalid := func() bool {
		if !pyEqual(pyGet(config, "owner_id", nil), owner) || !pyIsString(operationID) ||
			!pyFullMatch(paneHealthOperationID, operationID) || !pyIsString(actionID) ||
			!pyFullMatch(paneHealthOperationID, actionID) || !pyTruthy(action) {
			return true
		}
		receipt, ok := result.(*pyObject)
		if !ok {
			return true
		}
		for _, key := range receipt.Keys() {
			if key != "state" && key != "message" && key != "pane" {
				return true
			}
		}
		if !pyEqual(pyGet(state, "generation", nil), pyGet(config, "generation", nil)) ||
			!pyEqual(pyGet(action, "generation", nil), pyGet(config, "generation", nil)) {
			return true
		}
		pane := pyGet(pyGet(pyGet(action, "call", newPyObject()), "input", newPyObject()), "pane_id", nil)
		if !pyContains(pyGet(config, "panes", pyListOf()), pane) {
			return true
		}
		stateText, ok := receipt.Get("state").(string)
		if !ok || !paneHealthReceiptState.MatchString(stateText) {
			return true
		}
		if receipt.Has("message") {
			message, ok := receipt.Get("message").(string)
			if !ok || len(message) > 2048 {
				return true
			}
		}
		return len(pyCompact(receipt)) > 16384
	}
	if invalid() {
		panic(paneHealthControllerError("invalid_native_action_receipt"))
	}
	return pyMustObject(config), pyMustObject(action)
}

func (c *paneHealthController) completeAction(owner, operationID, actionID, result any) *pyObject {
	config, action := c.nativeAction(owner, operationID, actionID, result)
	receipt := result.(*pyObject)
	if receipt.Has("pane") {
		pane, ok := receipt.Get("pane").(*pyObject)
		if !ok || !pyEqual(pane.Get("pane_id"), pyIndex(pyIndex(pyIndex(action, "call"), "input"), "pane_id")) {
			panic(paneHealthControllerError("native_action_receipt_pane_changed"))
		}
		host := pyIndex(config, "host_id")
		panes := pyListOf(pane)
		_, err := c.backend.ValidatePanes(host, paneHealthDigest(pyObj("host_id", host, "panes", panes)), panes)
		paneHealthRaise(err)
	}
	func() {
		configurationLock, _ := c.lock("configuration.lock", true)
		defer configurationLock.Close()
		// Validation may cross a configuration change while reading native
		// pane facts. Pin the generation again before recording its receipt.
		config, action = c.nativeAction(owner, operationID, actionID, result)
		receiptsLock, _ := c.lock("action-results.lock", true)
		defer receiptsLock.Close()
		receipts := pyMustObject(c.load("action-results.json", newPyObject()))
		row := pyObj("operation_id", operationID, "action_operation_id", pyIndex(action, "operation_id"),
			"generation", pyIndex(config, "generation"), "owner_id", owner, "result", result)
		key := pyMustString(actionID)
		if receipts.Has(key) {
			for _, field := range row.Keys() {
				if !pyEqual(pyGet(receipts.Get(key), field, nil), row.Get(field)) {
					panic(paneHealthControllerError("native_action_receipt_conflict"))
				}
			}
		}
		stored := row.Copy()
		stored.Set("at", c.now())
		receipts.Set(key, stored)
		kept := newPyObject()
		keys := receipts.Keys()
		for _, k := range keys[max(0, len(keys)-paneHealthReceiptsKept):] {
			kept.Set(k, receipts.Get(k))
		}
		c.save("action-results.json", kept)
	}()
	response := c.status()
	response.Set("wake_controller", true)
	response.Set("acknowledged_action_id", actionID)
	return response
}

func (c *paneHealthController) current(config *pyObject) bool {
	if !c.parentAlive() {
		return false
	}
	latest := c.load("configuration.json", newPyObject())
	return pyEqual(pyGet(latest, "generation", nil), pyIndex(config, "generation")) && pyGet(latest, "enabled", nil) == true
}

func paneHealthIsInt(v any) bool { return pyIsInt(v) }

func (c *paneHealthController) probe(pane string) *pyObject {
	unavailable := func() *pyObject {
		return pyObj("version", int64(1), "unavailable", "Native identity could not be verified on this host.")
	}
	value, err := c.backend.Probe(pane)
	if errors.Is(err, errPaneHealthBackendLost) {
		// The former adapter process failed as a whole; never publish
		// unverified observations because the backend itself went away.
		panic(paneHealthOSError{err})
	}
	proof, ok := value.(*pyObject)
	if err != nil || !ok || len(pyCompact(proof)) > 32768 {
		return unavailable()
	}
	filtered := newPyObject()
	for _, key := range proof.Keys() {
		if key != "resume_command" && key != "resume_error" {
			filtered.Set(key, proof.Get(key))
		}
	}
	return filtered
}

func (c *paneHealthController) observe(pane string) *pyObject {
	proof := c.probe(pane)
	ownerValue := proof.Get("owner")
	if !pyTruthy(ownerValue) {
		ownerValue = newPyObject()
	}
	provider := proof.Get("provider")
	owner := func() *pyObject { return pyMustObject(ownerValue) } // AttributeError only where Python evaluates it
	positiveInt := func(object *pyObject, key string, floor int64) bool {
		return paneHealthIsInt(object.Get(key)) && pyLess(floor, object.Get(key))
	}
	valid := func() bool {
		if !pyEqual(proof.Get("version"), int64(1)) || !pyEqual(proof.Get("pane_id"), pane) ||
			!(pyEqual(provider, "claude") || pyEqual(provider, "codex") || pyEqual(provider, "shell")) ||
			!positiveInt(proof, "process_id", 1) || !positiveInt(proof, "process_start", 1) ||
			!pyEqual(owner().Get("version"), int64(1)) {
			return false
		}
		boot, ok := owner().Get("node_boot_id").(string)
		if !ok || pyLen(boot) < 1 || pyLen(boot) > 128 {
			return false
		}
		for _, key := range []string{"worker_pid", "shell_pid"} {
			if !positiveInt(owner(), key, 1) {
				return false
			}
		}
		for _, key := range []string{"worker_start", "shell_start"} {
			if !positiveInt(owner(), key, 0) {
				return false
			}
		}
		return pyEqual(owner().Get("pane_id"), pane) && pyEqual(owner().Get("provider"), provider) &&
			pyEqual(owner().Get("process_id"), proof.Get("process_id")) &&
			pyEqual(owner().Get("process_start"), proof.Get("process_start"))
	}()
	shell := valid && pyEqual(provider, "shell")
	if shell {
		valid = pyEqual(proof.Get("process_id"), owner().Get("shell_pid")) &&
			pyEqual(proof.Get("process_start"), owner().Get("shell_start")) &&
			proof.Get("session_id") == nil && proof.Get("bound") == nil && proof.Get("installed_update") != true &&
			owner().Get("session_id") == nil && owner().Get("transcript_identity") == nil && owner().Get("input_only") != true
		shell = valid
	} else if valid {
		session, sessionOK := proof.Get("session_id").(string)
		revision, revisionOK := proof.Get("revision").(string)
		identity, identityOK := owner().Get("transcript_identity").(string)
		valid = sessionOK && paneHealthSessionID.MatchString(session) && revisionOK &&
			paneHealthRevision.MatchString(revision) && pyEqual(owner().Get("session_id"), session) &&
			identityOK && pyLen(identity) >= 1 && pyLen(identity) <= 80
	}
	kind, connection := any("other"), "unknown"
	if valid {
		kind, connection = provider, "connected"
	}
	binding := "unknown"
	switch {
	case shell:
		binding = "not_applicable"
	case valid && proof.Get("bound") == true:
		binding = "bound"
	case valid && proof.Get("bound") == false:
		binding = "unbound"
	}
	lifecycle := proof.Get("lifecycle")
	activity := "unknown"
	switch {
	case valid && (proof.Get("background_work") == true || pyEqual(lifecycle, "active") || pyEqual(lifecycle, "working")):
		activity = "working"
	case valid && (shell || pyEqual(lifecycle, "quiet")):
		activity = "quiet"
	}
	facts := pyObj("pane_id", pane, "kind", kind, "connection", connection, "binding", binding, "activity", activity,
		"identity_verified", valid, "prompt_empty", nil, "has_draft", nil, "pending_approvals", nil, "input_idle", nil,
		"installed_update", valid && !shell && proof.Get("installed_update") == true,
		"allowed_actions", pyListOf("observe", "attention"), "observed_at", pyTrunc(c.now()))
	if valid {
		facts.Set("process_id", proof.Get("process_id"))
		facts.Set("process_start", proof.Get("process_start"))
		if !shell {
			facts.Set("session_id", proof.Get("session_id"))
		}
	}
	// A desktop can supply native input safety while it owns the terminal.
	// It cannot supply identity, a command, or headless terminal authority.
	// The eventual executor independently rechecks every native fence.
	config := c.load("configuration.json", newPyObject())
	desktop := c.load("desktop-facts.json", newPyObject())
	var inputRow any = newPyObject()
	if pyEqual(pyGet(desktop, "generation", nil), pyGet(config, "generation", nil)) {
		inputRow = pyGet(pyGet(desktop, "panes", newPyObject()), pane, newPyObject())
	}
	offered := pyGet(inputRow, "facts", newPyObject())
	sameIdentity := valid
	if valid {
		for _, key := range []string{"pane_id", "kind", "process_id", "process_start", "session_id", "identity_verified", "binding", "installed_update"} {
			if !pyEqual(pyGet(offered, key, nil), facts.Get(key)) {
				sameIdentity = false
				break
			}
		}
	}
	fresh := func() bool {
		age := pySub(c.now(), pyGet(inputRow, "at", int64(0)))
		return pyLessEq(int64(0), age) && pyLessEq(age, int64(30))
	}
	if sameIdentity && fresh() {
		for _, key := range []string{"prompt_empty", "has_draft", "pending_approvals", "input_idle"} {
			facts.Set(key, pyIndex(offered, key))
		}
		allowed := pyListOf()
		for _, value := range pyIter(pyIndex(offered, "allowed_actions")) {
			for _, permitted := range []string{"observe", "attention", "repair_link", "apply_update"} {
				if pyEqual(value, permitted) {
					allowed.items = append(allowed.items, value)
					break
				}
			}
		}
		facts.Set("allowed_actions", allowed)
	} else if pyEqual(pyGet(offered, "connection", nil), "disconnected") &&
		pyContains(pyGet(offered, "allowed_actions", pyListOf()), "reconnect") && fresh() {
		// Reconnect only reattaches the existing viewer. It cannot create a
		// worker or provider, and has its own fresh native admission.
		facts = pyMustObject(offered).Copy()
		facts.Set("observed_at", pyTrunc(c.now()))
		facts.Delete("evidence_id")
	}
	facts.Set("evidence_id", paneHealthDigest(facts))
	return pyObj("pane_id", pane, "observed_at", c.now(), "proof", proof, "facts", facts,
		"input_contract", "desktop_native_verification_required")
}

func paneHealthSignal(panes any) string {
	rows := pyListOf()
	for _, value := range pyIter(panes) {
		pane := pyMustObject(value)
		row := newPyObject()
		for _, key := range pane.Keys() {
			switch key {
			case "evidence_id", "observed_at", "activity", "prompt_empty", "has_draft", "pending_approvals", "input_idle", "allowed_actions":
			default:
				row.Set(key, pane.Get(key))
			}
		}
		set := map[string]bool{}
		for _, action := range pyIter(pyIndex(pane, "allowed_actions")) {
			if !pyHashable(action) {
				panic(pyTypeError("unhashable action"))
			}
			if name := pyMustString(action); name != "observe" && name != "attention" {
				set[name] = true
			}
		}
		repairable := make([]string, 0, len(set))
		for name := range set {
			repairable = append(repairable, name)
		}
		sort.Strings(repairable)
		list := pyListOf()
		for _, name := range repairable {
			list.items = append(list.items, name)
		}
		row.Set("repairable", list)
		rows.items = append(rows.items, row)
	}
	return paneHealthDigest(rows)
}

func paneHealthPaneIDs(batch any) *pyList {
	ids := pyListOf()
	for _, pane := range pyIter(batch) {
		ids.items = append(ids.items, pyIndex(pane, "pane_id"))
	}
	return ids
}

func (c *paneHealthController) tick() *pyObject {
	lock, busy := c.lock("tick.lock", false)
	if busy {
		return c.status()
	}
	defer lock.Close()
	return c.runTick()
}

var paneHealthHoldCodes = map[string]bool{"spending_limit": true, "text_backend_disabled": true, "api_key_missing": true,
	"health_api_account_required": true, "api_account_unavailable": true, "no_ready_account": true}

func (c *paneHealthController) runTick() *pyObject {
	configValue := c.load("configuration.json", newPyObject())
	if !pyTruthy(pyGet(configValue, "enabled", nil)) || !c.parentAlive() {
		return c.status()
	}
	config := pyMustObject(configValue)
	generation := pyIndex(config, "generation")
	state := pyMustObject(c.load("state.json", newPyObject()))
	if !pyEqual(state.Get("generation"), generation) {
		// Keep uncertain operation IDs for reconciliation, but an earlier
		// configuration's healthy report is not current evidence.
		state.Delete("report")
		state.Set("observations", newPyObject())
		state.Delete("last_observed_at")
		state.Set("checked_batches", newPyObject())
	}
	state.Set("last_tick_at", c.now())
	state.Set("generation", generation)
	state.Set("status", "Reading native pane identities on this host")
	c.save("state.json", state)
	observations := newPyObject()
	for _, paneValue := range pyIter(pyIndex(config, "panes")) {
		if !c.current(config) {
			return c.status()
		}
		pane := pyMustString(paneValue)
		observation := c.observe(pane)
		if !c.current(config) {
			return c.status()
		}
		observations.Set(pane, observation)
		state.Set("observations", observations)
		state.Set("last_observed_at", c.now())
		c.save("state.json", state)
	}
	sortedPanes := observations.Keys()
	sort.Strings(sortedPanes)
	panes := make([]any, 0, len(sortedPanes))
	for _, pane := range sortedPanes {
		panes = append(panes, pyIndex(observations.Get(pane), "facts"))
	}
	state.Set("status", "Native host checks completed")
	c.save("state.json", state)
	if !pyTruthy(pyIndex(config, "haiku_enabled")) || !c.current(config) {
		return c.status()
	}
	// One bounded batch covers up to 64 panes. A second batch is selected on
	// the next host deadline. Healthy activity changes do not spend API calls.
	// New faults/identities do; otherwise a fresh pass is due in 6 h.
	checkedValue, ok := state.Lookup("checked_batches")
	if !ok {
		checkedValue = newPyObject()
		state.Set("checked_batches", checkedValue)
	}
	checked := checkedValue
	batches := []*pyList{}
	for index := 0; index < len(panes); index += paneHealthModelBatch {
		batches = append(batches, &pyList{items: append([]any(nil), panes[index:min(index+paneHealthModelBatch, len(panes))]...)})
	}
	pendingValue := state.Get("pending")
	if pyTruthy(pendingValue) && !pyEqual(pyGet(pendingValue, "generation", nil), generation) {
		receipt, err := c.backend.Status(pyIndex(pendingValue, "operation_id"))
		paneHealthRaise(err)
		switch status := pyGet(receipt, "status", nil); {
		case pyEqual(status, "not_found"), pyEqual(status, "failed"), pyEqual(status, "abandoned"), pyEqual(status, "complete"):
			state.Delete("pending")
			for _, key := range pyMustObject(state.GetOr("action_requests", newPyObject())).Keys() {
				action := pyMustObject(state.GetOr("action_requests", newPyObject())).Get(key)
				if pyEqual(pyIndex(action, "operation_id"), pyIndex(pendingValue, "operation_id")) &&
					pyEqual(pyIndex(action, "state"), "pending_native") {
					pyMustObject(action).Set("state", "held_configuration_changed")
				}
			}
		}
		state.Set("status", "The previous configuration's operation is held for receipt reconciliation; no model tool was replayed")
		c.save("state.json", state)
		return c.status()
	}
	due := []*pyList{}
	for _, batch := range batches {
		old := pyGet(checked, paneHealthDigest(paneHealthPaneIDs(batch)), newPyObject())
		if !pyEqual(pyGet(old, "signal", nil), paneHealthSignal(batch)) ||
			pyLessEq(int64(paneHealthModelInterval), pySub(c.now(), pyGet(old, "at", int64(0)))) ||
			!pyEqual(pyGet(old, "force_sequence", int64(-1)), pyGet(config, "force_sequence", int64(0))) {
			due = append(due, batch)
		}
	}
	pending := pyTruthy(pendingValue)
	if !pending && len(due) == 0 {
		state.Set("status", "Native host checks completed; unchanged panes need no Haiku call")
		c.save("state.json", state)
		return c.status()
	}
	if !pending && pyLess(c.now(), state.GetOr("deferred_until", int64(0))) &&
		pyEqual(state.Get("deferred_force"), pyGet(config, "force_sequence", int64(0))) {
		state.Set("status", "Native checks continue; Haiku is held by its configured account or spending limit")
		c.save("state.json", state)
		return c.status()
	}
	var batch, messages, snapshot, step any
	if pending {
		batch = pyIndex(pendingValue, "panes")
		snapshot = pyIndex(pendingValue, "snapshot_id")
		messages = pyIndex(pendingValue, "messages")
		step = pyIndex(pendingValue, "step")
	} else {
		batch = due[0]
		snapshot = paneHealthDigest(pyObj("host_id", pyIndex(config, "host_id"), "panes", batch))
		messages = pyListOf()
		step = int64(0)
	}
	first, ok := pyInt(step)
	if !ok {
		panic(pyTypeError("step must be an integer"))
	}
	host := pyIndex(config, "host_id")
	for iteration := first; iteration < paneHealthModelSteps; iteration++ {
		if !c.current(config) {
			return c.status()
		}
		var operationID any
		if pending {
			operationID = pyIndex(pendingValue, "operation_id")
		} else {
			operationID = paneHealthDigest(pyObj("host_id", host, "snapshot_id", snapshot, "panes", batch, "messages", messages))[:32]
		}
		request := pyObj("v", int64(1), "operation_id", operationID, "host_id", host, "snapshot_id", snapshot,
			"panes", batch, "messages", messages)
		state.Set("pending", pyObj("operation_id", operationID, "snapshot_id", snapshot, "panes", batch,
			"messages", messages, "step", step, "generation", generation))
		state.Set("status", "Haiku is assessing native host observations")
		c.save("state.json", state) // durable before any API request
		var receipt any
		if pending {
			var err error
			receipt, err = c.backend.Status(operationID)
			paneHealthRaise(err)
			if pyEqual(pyGet(receipt, "status", nil), "not_found") {
				state.Delete("pending")
				state.Set("status", "The prior assessment was not submitted; a later native check can assess fresh evidence")
				c.save("state.json", state)
				return c.status()
			}
		} else {
			var err error
			receipt, err = c.backend.Assess(request)
			if err != nil {
				code := "request_outcome_unknown"
				var backend *paneHealthBackendError
				if errors.As(err, &backend) && backend.code != "" {
					code = backend.code
				}
				if paneHealthHoldCodes[code] {
					state.Delete("pending")
					state.Set("deferred_until", pyAdd(c.now(), int64(3600)))
					state.Set("deferred_force", pyGet(config, "force_sequence", int64(0)))
					state.Set("status", "Native checks continue; Haiku is held: "+code)
				} else {
					state.Set("status", "Haiku outcome is unconfirmed; reading its original receipt is required")
				}
				c.save("state.json", state)
				return c.status()
			}
		}
		receiptStatus := pyGet(receipt, "status", nil)
		if !pyEqual(receiptStatus, "complete") {
			code := pyGet(receipt, "code", pyGet(receipt, "status", "unknown"))
			state.Set("status", "Haiku assessment is held: "+pyTruncateRunes(pyStr(code), 120))
			if pyEqual(receiptStatus, "failed") || pyEqual(receiptStatus, "abandoned") {
				state.Delete("pending")
				state.Set("deferred_until", pyAdd(c.now(), int64(3600)))
				state.Set("deferred_force", pyGet(config, "force_sequence", int64(0)))
			}
			c.save("state.json", state)
			return c.status()
		}
		result := pyGet(receipt, "result", newPyObject())
		evidence := sha256.Sum256(pyCompact(pyObj("panes", batch, "messages", messages)))
		if !pyEqual(pyGet(result, "operation_id", nil), operationID) || !pyEqual(pyGet(result, "purpose", nil), "pane_health") ||
			!pyEqual(pyGet(result, "binding", nil), pyObj("host_id", host, "snapshot_id", snapshot)) ||
			!pyEqual(pyGet(result, "source_sha256", nil), hex.EncodeToString(evidence[:])) {
			state.Set("status", "The exact Haiku operation receipt could not be verified")
			c.save("state.json", state)
			return c.status()
		}
		latest, err := c.backend.ValidateMessages(messages, host, batch)
		paneHealthRaise(err)
		calls, err := c.backend.ValidateCalls(pyGet(result, "assistant_content", nil), latest)
		paneHealthRaise(err)
		if !pyEqual(calls, pyGet(result, "tool_calls", nil)) {
			panic(paneHealthControllerError("controller_tool_receipt_mismatch"))
		}
		operations := state.GetOr("model_operations", pyListOf())
		if !pyContains(operations, operationID) {
			items := append(append([]any(nil), pyMustList(operations).items...), operationID)
			state.Set("model_operations", &pyList{items: items[max(0, len(items)-128):]})
			state.Set("last_model_at", c.now())
		}
		if !c.current(config) {
			state.Set("status", "Host settings changed during the request; its receipt is retained and further tools are held")
			c.save("state.json", state)
			return c.status()
		}
		callList := pyIter(calls)
		if len(callList) == 1 && pyEqual(pyIndex(callList[0], "name"), "report_health") {
			observed := func(panes any) *pyList {
				facts := pyListOf()
				for _, pane := range pyIter(panes) {
					facts.items = append(facts.items, pyIndex(pyIndex(observations, pyMustString(pyIndex(pane, "pane_id"))), "facts"))
				}
				return facts
			}
			if paneHealthSignal(latest) != paneHealthSignal(observed(latest)) {
				state.Delete("pending")
				state.Set("status", "Native identity or health changed during the assessment; a fresh pass is required")
				c.save("state.json", state)
				return c.status()
			}
			reports := newPyObject()
			for _, pane := range pyIter(pyGet(pyGet(state, "report", newPyObject()), "panes", pyListOf())) {
				reports.Set(pyMustString(pyIndex(pane, "pane_id")), pane)
			}
			for _, pane := range pyIter(pyIndex(pyIndex(callList[0], "input"), "panes")) {
				reports.Set(pyMustString(pyIndex(pane, "pane_id")), pane)
			}
			keys := reports.Keys()
			sort.Strings(keys)
			kept := pyListOf()
			for _, pane := range keys {
				if observations.Has(pane) {
					kept.items = append(kept.items, reports.Get(pane))
				}
			}
			state.Set("report", pyObj("panes", kept))
			pyMustObject(checked).Set(paneHealthDigest(paneHealthPaneIDs(batch)), pyObj(
				"signal", paneHealthSignal(observed(batch)), "at", c.now(),
				"force_sequence", pyGet(config, "force_sequence", int64(0))))
			state.Delete("pending")
			state.Set("status", "Haiku completed a host pane batch; native monitoring continues")
			state.Set("last_finished_at", c.now())
			c.save("state.json", state)
			return c.status()
		}
		results := pyListOf()
		waiting := false
		toolResults, ok := state.Lookup("tool_results")
		if !ok {
			toolResults = newPyObject()
			state.Set("tool_results", toolResults)
		}
		actionsValue, ok := state.Lookup("action_requests")
		if !ok {
			actionsValue = newPyObject()
			state.Set("action_requests", actionsValue)
		}
		actions := pyMustObject(actionsValue)
		receipts := c.load("action-results.json", newPyObject())
		currentPanes := newPyObject()
		for _, pane := range pyIter(latest) {
			currentPanes.Set(pyMustString(pyIndex(pane, "pane_id")), pane)
		}
		inspected := map[string]bool{}
		messageList := pyIter(messages)
		for index := 0; index < len(messageList); index += 2 {
			callsBefore := newPyObject()
			for _, call := range pyIter(pyIndex(messageList[index], "content")) {
				if pyEqual(pyGet(call, "type", nil), "tool_use") {
					callsBefore.Set(pyMustString(pyIndex(call, "id")), call)
				}
			}
			if index+1 >= len(messageList) {
				panic(pyTypeError("list index out of range"))
			}
			for _, item := range pyIter(pyIndex(messageList[index+1], "content")) {
				callBefore := pyIndex(callsBefore, pyMustString(pyIndex(item, "tool_use_id")))
				name := pyIndex(callBefore, "name")
				if pyEqual(name, "inspect_pane") || pyEqual(name, "verify_pane") {
					valueBefore, err := pyDecode([]byte(pyMustString(pyIndex(item, "content"))))
					if err != nil {
						panic(paneHealthOSError{err})
					}
					if object, ok := valueBefore.(*pyObject); ok {
						if _, ok := object.Get("pane").(*pyObject); ok {
							inspected[pyMustString(pyIndex(pyIndex(callBefore, "input"), "pane_id"))] = true
						}
					}
				}
			}
		}
		for _, call := range callList {
			pane := pyMustString(pyIndex(pyIndex(call, "input"), "pane_id"))
			actionID := paneHealthDigest(pyObj("operation_id", operationID, "tool_id", pyIndex(call, "id")))[:32]
			name := pyIndex(call, "name")
			var value any
			if existing, ok := pyMustObject(toolResults).Lookup(actionID); ok {
				value = existing
			} else if (pyEqual(name, "inspect_pane") || pyEqual(name, "verify_pane")) && c.current(config) {
				observation := c.observe(pane)
				observations.Set(pane, observation)
				value = pyObj("state", "observed", "pane", observation.Get("facts"))
			} else {
				var required any
				switch {
				case pyEqual(name, "repair_agent_link"):
					required = "repair_link"
				case pyEqual(name, "apply_installed_update"):
					required = "apply_update"
				case pyEqual(name, "reconnect_pane"):
					required = "reconnect"
				}
				before := pyIndex(currentPanes, pane)
				if inspected[pane] && pyContains(pyIndex(before, "allowed_actions"), required) &&
					pyEqual(pyGet(pyIndex(call, "input"), "evidence_id", nil), pyIndex(before, "evidence_id")) {
					if !actions.Has(actionID) {
						actions.Set(actionID, pyObj("id", actionID, "operation_id", operationID, "generation", generation,
							"call", call, "before", before, "created_at", c.now(), "state", "pending_native"))
						c.save("state.json", state) // durable before an executor can receive it
					}
					stored, ok := pyMustObject(receipts).Lookup(actionID)
					if !ok {
						waiting = true
						continue
					}
					if !pyEqual(pyGet(stored, "generation", nil), generation) ||
						!pyEqual(pyGet(stored, "owner_id", nil), pyIndex(config, "owner_id")) ||
						!pyEqual(pyGet(stored, "action_operation_id", nil), operationID) {
						value = pyObj("state", "held", "message", "The native action receipt belongs to another configuration or operation.")
					} else {
						value = pyIndex(stored, "result")
					}
					observation := c.observe(pane)
					observations.Set(pane, observation)
					after := pyGet(value, "pane", nil)
					if pyTruthy(after) {
						facts := observation.Get("facts")
						for _, key := range []string{"kind", "process_id", "process_start", "session_id", "identity_verified", "binding"} {
							if !pyEqual(pyGet(after, key, nil), pyGet(facts, key, nil)) {
								value = pyObj("state", "held", "message", "The host identity changed after the native action receipt.",
									"pane", facts)
								break
							}
						}
					}
					action := pyMustObject(pyIndex(actions, actionID))
					action.Set("state", "completed")
					action.Set("result", value)
				} else {
					value = pyObj("state", "held", "message",
						"A verified native prompt and input-ownership contract is required before this terminal action.")
				}
			}
			pyMustObject(toolResults).Set(actionID, value)
			results.items = append(results.items, pyObj("type", "tool_result", "tool_use_id", pyIndex(call, "id"),
				"content", string(pyCompact(value))))
		}
		if waiting {
			state.Set("status", "Haiku's native repair request is journaled; waiting for the exact pane executor")
			state.Set("observations", observations)
			c.save("state.json", state)
			return c.status()
		}
		list := pyMustList(messages)
		list.items = append(list.items, pyObj("role", "assistant", "content", pyIndex(result, "assistant_content")),
			pyObj("role", "user", "content", results))
		step = pyAdd(step, int64(1))
		pending = false
		state.Set("observations", observations)
		state.Set("pending", pyObj("operation_id",
			paneHealthDigest(pyObj("host_id", host, "snapshot_id", snapshot, "panes", batch, "messages", messages))[:32],
			"snapshot_id", snapshot, "panes", batch, "messages", messages, "step", step, "generation", generation))
		c.save("state.json", state)
	}
	state.Set("status", "The bounded Haiku tool pass reached its step limit")
	c.save("state.json", state)
	return c.status()
}

// pyGet is value.get(key, fallback) on a dict; other receivers raise.
func pyGet(value any, key any, fallback any) any {
	object := pyMustObject(value)
	text, ok := key.(string)
	if !ok {
		if !pyHashable(key) {
			panic(pyTypeError("unhashable key"))
		}
		return fallback // JSON objects only have string keys.
	}
	return object.GetOr(text, fallback)
}

// pyContains is `item in container`.
func pyContains(container, item any) bool {
	switch t := container.(type) {
	case *pyList:
		for _, value := range t.items {
			if pyEqual(value, item) {
				return true
			}
		}
		return false
	case *pyObject:
		if !pyHashable(item) {
			panic(pyTypeError("unhashable key"))
		}
		text, ok := item.(string)
		return ok && t.Has(text)
	case string:
		return strings.Contains(t, pyMustString(item))
	}
	panic(pyTypeError("argument is not iterable"))
}

// pyIter is iter(value): list items, dict keys, string characters.
func pyIter(value any) []any {
	switch t := value.(type) {
	case *pyList:
		return t.items
	case *pyObject:
		keys := make([]any, 0, t.Len())
		for _, key := range t.keys {
			keys = append(keys, key)
		}
		return keys
	case string:
		chars := []any{}
		for _, r := range t {
			chars = append(chars, string(r))
		}
		return chars
	}
	panic(pyTypeError("object is not iterable"))
}

func pyIsString(v any) bool { _, ok := v.(string); return ok }

// pyFullMatch is re.fullmatch(pattern, value) for anchored patterns.
func pyFullMatch(pattern *regexp.Regexp, value any) bool {
	return pattern.MatchString(pyMustString(value))
}

func pyNumberValue(v any) (int64, float64, bool) {
	switch t := v.(type) {
	case bool:
		if t {
			return 1, 0, false
		}
		return 0, 0, false
	case int64:
		return t, 0, false
	case int:
		return int64(t), 0, false
	case float64:
		return 0, t, true
	}
	panic(pyTypeError("unsupported operand type"))
}

func pyAdd(a, b any) any {
	ai, af, aFloat := pyNumberValue(a)
	bi, bf, bFloat := pyNumberValue(b)
	if !aFloat && !bFloat {
		return ai + bi
	}
	if !aFloat {
		af = float64(ai)
	}
	if !bFloat {
		bf = float64(bi)
	}
	return af + bf
}

func pySub(a, b any) any {
	ai, af, aFloat := pyNumberValue(a)
	bi, bf, bFloat := pyNumberValue(b)
	if !aFloat && !bFloat {
		return ai - bi
	}
	if !aFloat {
		af = float64(ai)
	}
	if !bFloat {
		bf = float64(bi)
	}
	return af - bf
}

// pyTrunc is int(number).
func pyTrunc(v any) any {
	i, f, isFloat := pyNumberValue(v)
	if !isFloat {
		return i
	}
	if math.IsNaN(f) || math.IsInf(f, 0) {
		panic(pyTypeError("cannot convert float to integer"))
	}
	return pyRound(math.Trunc(f))
}

// pyStr is str(value).
func pyStr(v any) string {
	if text, ok := v.(string); ok {
		return text
	}
	return pyRepr(v)
}

func pyTruncateRunes(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n])
}
