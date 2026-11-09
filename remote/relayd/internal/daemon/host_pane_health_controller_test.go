package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

const (
	phPane  = "11111111-2222-4333-8444-555555555555"
	phOwner = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
)

// phFakeBackend mirrors scripts/tests/test_pane_health_controller.py's
// Backend: receipts are built from the request, validation is the happy path
// of text_backend (the bridge test covers the real validators).
type phFakeBackend struct {
	native             map[string]any
	rows               map[string]any
	err                string
	inspectFirst       bool
	repairAfterInspect bool
	requests           []*pyObject
	statusReads        []any
	probes             []string
	mutate             func()
	validatePanes      func(host, snapshot, panes any) (any, error)
}

func newPHFakeBackend() *phFakeBackend {
	return &phFakeBackend{native: map[string]any{}, rows: map[string]any{}}
}

func (b *phFakeBackend) Probe(pane string) (any, error) {
	b.probes = append(b.probes, pane)
	proof, ok := b.native[pane]
	if !ok {
		return nil, errors.New("probe unavailable")
	}
	return pyDeepCopy(proof), nil
}

func (b *phFakeBackend) ValidatePanes(host, snapshot, panes any) (any, error) {
	if b.validatePanes != nil {
		return b.validatePanes(host, snapshot, panes)
	}
	return phValidPanes(host, snapshot, panes)
}

func phValidPanes(host, snapshot, panes any) (any, error) {
	if snapshot != paneHealthDigest(pyObj("host_id", host, "panes", panes)) {
		return nil, &paneHealthBackendError{code: "invalid_health_snapshot"}
	}
	return panes, nil
}

func (b *phFakeBackend) ValidateMessages(messages, host, panes any) (any, error) {
	latest := newPyObject()
	for _, pane := range pyIter(panes) {
		latest.Set(pyIndex(pane, "pane_id").(string), pane)
	}
	list := pyIter(messages)
	for index := 0; index+1 < len(list); index += 2 {
		for _, item := range pyIter(pyIndex(list[index+1], "content")) {
			value, err := pyDecode([]byte(pyIndex(item, "content").(string)))
			if err != nil {
				return nil, &paneHealthBackendError{code: "invalid_health_tool_results"}
			}
			if object, ok := value.(*pyObject); ok {
				if pane, ok := object.Get("pane").(*pyObject); ok {
					latest.Set(pane.Get("pane_id").(string), pane)
				}
			}
		}
	}
	out := pyListOf()
	for _, key := range latest.Keys() {
		out.items = append(out.items, latest.Get(key))
	}
	return out, nil
}

func (b *phFakeBackend) ValidateCalls(content, latest any) (any, error) {
	calls := pyListOf()
	for _, block := range pyIter(content) {
		if pyEqual(pyGet(block, "type", nil), "text") {
			continue
		}
		call := newPyObject()
		for _, key := range []string{"type", "id", "name", "input"} {
			call.Set(key, pyIndex(block, key))
		}
		calls.items = append(calls.items, call)
	}
	return calls, nil
}

func (b *phFakeBackend) receipt(request *pyObject, calls *pyList) *pyObject {
	sum := sha256.Sum256(pyCompact(pyObj("panes", request.Get("panes"), "messages", request.Get("messages"))))
	return pyObj("v", int64(1), "operation_id", request.Get("operation_id"), "status", "complete", "result", pyObj(
		"v", int64(1), "operation_id", request.Get("operation_id"), "purpose", "pane_health",
		"binding", pyObj("host_id", request.Get("host_id"), "snapshot_id", request.Get("snapshot_id")),
		"source_sha256", hex.EncodeToString(sum[:]), "assistant_content", calls, "tool_calls", calls))
}

func (b *phFakeBackend) Assess(request *pyObject) (any, error) {
	b.requests = append(b.requests, pyDeepCopy(request).(*pyObject))
	operation := request.Get("operation_id").(string)
	if b.err != "" {
		if b.err == "request_outcome_unknown" {
			b.rows[operation] = pyObj("v", int64(1), "status", "uncertain")
		}
		return nil, &paneHealthBackendError{code: b.err}
	}
	latestValue, _ := b.ValidateMessages(request.Get("messages"), request.Get("host_id"), request.Get("panes"))
	latest := latestValue.(*pyList).items
	messages := len(request.Get("messages").(*pyList).items)
	var calls *pyList
	switch {
	case b.inspectFirst && messages == 0:
		calls = pyListOf(pyObj("type", "tool_use", "id", "owned_inspect", "name", "inspect_pane",
			"input", pyObj("pane_id", pyIndex(latest[0], "pane_id"))))
	case b.repairAfterInspect && messages == 2:
		calls = pyListOf(pyObj("type", "tool_use", "id", "owned_update", "name", "apply_installed_update",
			"input", pyObj("pane_id", pyIndex(latest[0], "pane_id"), "evidence_id", pyIndex(latest[0], "evidence_id"))))
	default:
		panes := pyListOf()
		for _, pane := range latest {
			panes.items = append(panes.items, pyObj("pane_id", pyIndex(pane, "pane_id"), "evidence_id", pyIndex(pane, "evidence_id"),
				"health", "healthy", "action", "observe", "reason", "The exact native binding is verified."))
		}
		calls = pyListOf(pyObj("type", "tool_use", "id", "owned_report", "name", "report_health", "input", pyObj("panes", panes)))
	}
	result := b.receipt(request, calls)
	b.rows[operation] = result
	if b.mutate != nil {
		b.mutate()
	}
	return result, nil
}

func (b *phFakeBackend) Status(operationID any) (any, error) {
	b.statusReads = append(b.statusReads, operationID)
	if row, ok := b.rows[operationID.(string)]; ok {
		return row, nil
	}
	return pyObj("v", int64(1), "status", "not_found"), nil
}

func phProof(pane, provider string, pid int64) *pyObject {
	owner := pyObj("version", int64(1), "pane_id", pane, "node_boot_id", "owned-test-boot", "worker_pid", int64(100),
		"worker_start", int64(1000), "shell_pid", int64(200), "shell_start", int64(2000),
		"process_id", pid, "process_start", int64(3000), "provider", provider)
	result := pyObj("version", int64(1), "pane_id", pane, "provider", provider, "process_id", pid, "process_start", int64(3000),
		"owner", owner, "installed_update", false)
	if provider == "shell" {
		result.Set("process_id", int64(200))
		result.Set("process_start", int64(2000))
		owner.Set("process_id", int64(200))
		owner.Set("process_start", int64(2000))
	} else {
		owner.Set("session_id", "owned-session")
		owner.Set("transcript_identity", "1:2")
		result.Set("session_id", "owned-session")
		result.Set("bound", true)
		result.Set("lifecycle", "quiet")
		result.Set("revision", strings.Repeat("f", 64))
	}
	return result
}

// ---- Golden replay: the Go controller reproduces the Python controller's
// results and on-disk bytes for the same steps.

func TestPaneHealthControllerMatchesPythonGoldens(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "host_pane_health_controller", "golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	golden, err := pyDecode(data)
	if err != nil {
		t.Fatal(err)
	}
	scenarios := pyIndex(golden, "scenarios").(*pyObject)
	if scenarios.Len() < 2 {
		t.Fatal("controller goldens missing")
	}
	for _, name := range scenarios.Keys() {
		t.Run(name, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "pane-health-controller")
			backend := newPHFakeBackend()
			var clock any = int64(0)
			alive := true
			now := func() any { return clock }
			parent := func() bool { return alive }
			expected := map[string]string{}
			operations := 0
			for index, stepValue := range pyIter(scenarios.Get(name)) {
				step := stepValue.(*pyObject)
				switch pyIndex(step, "do") {
				case "clock":
					clock = step.Get("value")
				case "native":
					backend.native[step.Get("pane").(string)] = step.Get("proof")
				case "backend":
					backend.err, _ = pyGet(step, "error", "").(string)
					backend.inspectFirst = pyGet(step, "inspect_first", false) == true
					backend.repairAfterInspect = pyGet(step, "repair_after_inspect", false) == true
				case "alive":
					alive = step.Get("value") == true
				case "write":
					path := filepath.Join(root, step.Get("name").(string))
					if err := os.WriteFile(path, []byte(step.Get("content").(string)), 0o600); err != nil {
						t.Fatal(err)
					}
					expected[step.Get("name").(string)] = step.Get("content").(string)
				case "observe":
					c := newPaneHealthController(root, backend, now, parent)
					if got := string(pyCompact(c.observe(step.Get("pane").(string)))); got != step.Get("observation") {
						t.Fatalf("step %d observe differs\n go: %s\npy: %s", index, got, step.Get("observation"))
					}
				case "op":
					operations++
					operation := step.Get("operation").(string)
					result := runPaneHealthController(root, backend, now, parent, operation, pyDeepCopy(step.Get("request")))
					if got := string(pyCompact(result)); got != step.Get("result") {
						t.Fatalf("step %d %s result differs\n go: %.3000s\npy: %.3000s", index, operation, got, step.Get("result"))
					}
					for _, file := range pyIndex(step, "changed_files").(*pyObject).Keys() {
						expected[file] = pyIndex(step, "changed_files").(*pyObject).Get(file).(string)
					}
					entries, err := os.ReadDir(root)
					if err != nil {
						t.Fatal(err)
					}
					names := []string{}
					for _, entry := range entries {
						names = append(names, entry.Name())
						data, err := os.ReadFile(filepath.Join(root, entry.Name()))
						if err != nil {
							t.Fatal(err)
						}
						if string(data) != expected[entry.Name()] {
							t.Fatalf("step %d %s: %s differs\n go: %.3000s\npy: %.3000s", index, operation, entry.Name(), data, expected[entry.Name()])
						}
						info, _ := entry.Info()
						if info.Mode().Perm() != 0o600 {
							t.Fatalf("step %d: %s mode %v", index, entry.Name(), info.Mode())
						}
					}
					sort.Strings(names)
					if want := pyIndex(step, "file_names"); !pyEqual(want, phStrings(names)) {
						t.Fatalf("step %d files %v, Python wrote %s", index, names, pyCompact(want))
					}
				default:
					t.Fatalf("unknown golden step %s", pyCompact(step))
				}
			}
			if operations == 0 {
				t.Fatal("scenario has no operations")
			}
		})
	}
}

func phStrings(values []string) *pyList {
	list := pyListOf()
	for _, value := range values {
		list.items = append(list.items, value)
	}
	return list
}

// ---- Ports of scripts/tests/test_pane_health_controller.py.

type phHarness struct {
	t       *testing.T
	root    string
	backend *phFakeBackend
	clock   any
	alive   bool
	request *pyObject
}

func newPHHarness(t *testing.T) *phHarness {
	h := &phHarness{t: t, root: filepath.Join(t.TempDir(), "pane-health-controller"), backend: newPHFakeBackend(),
		clock: int64(1800000000), alive: true}
	h.backend.native[phPane] = phProof(phPane, "claude", 1234)
	h.request = pyObj("v", int64(1), "operation", "configure", "operation_id", strings.Repeat("1", 32), "host_id", "owned-host",
		"owner_id", phOwner, "enabled", true, "haiku_enabled", true, "panes", pyListOf(phPane))
	h.ok(h.run("configure", h.request))
	return h
}

func (h *phHarness) now() any { return h.clock }

func (h *phHarness) advance(seconds int64) { h.clock = pyAdd(h.clock, seconds) }

func (h *phHarness) controller() *paneHealthController {
	return newPaneHealthController(h.root, h.backend, h.now, func() bool { return h.alive })
}

func (h *phHarness) run(operation string, request any) *pyObject {
	return runPaneHealthController(h.root, h.backend, h.now, func() bool { return h.alive }, operation, request)
}

func (h *phHarness) ok(result *pyObject) *pyObject {
	h.t.Helper()
	if result.Get("status") != "controller_status" {
		h.t.Fatalf("operation failed: %s", pyCompact(result))
	}
	return result
}

func (h *phHarness) failed(result *pyObject, code string) {
	h.t.Helper()
	if result.Get("status") != "failed" || (code != "" && result.Get("code") != code) {
		h.t.Fatalf("expected failure %q, got %s", code, pyCompact(result))
	}
}

func (h *phHarness) configure(changes ...any) *pyObject {
	request := h.request.Copy()
	for i := 0; i+1 < len(changes); i += 2 {
		request.Set(changes[i].(string), changes[i+1])
	}
	return h.run("configure", request)
}

func (h *phHarness) tickState() *pyObject {
	return h.ok(h.run("tick", newPyObject())).Get("state").(*pyObject)
}

func (h *phHarness) observe(pane string) *pyObject {
	return h.controller().observe(pane)
}

func (h *phHarness) load(name string) any { return h.controller().load(name, newPyObject()) }

func (h *phHarness) desktopRow() *pyObject {
	h.backend.native[phPane].(*pyObject).Set("installed_update", true)
	row := pyDeepCopy(h.observe(phPane).Get("facts")).(*pyObject)
	row.Set("prompt_empty", true)
	row.Set("has_draft", false)
	row.Set("pending_approvals", int64(0))
	row.Set("input_idle", true)
	row.Set("allowed_actions", pyListOf("observe", "attention", "apply_update"))
	row.Delete("evidence_id")
	row.Set("evidence_id", paneHealthDigest(row))
	return row
}

func (h *phHarness) desktopFacts(rows ...any) *pyObject {
	return h.run("desktop_facts", pyObj("owner_id", phOwner, "generation", int64(1), "facts", pyListOf(rows...)))
}

func (h *phHarness) completeAction(operation, action string, result any) *pyObject {
	return h.run("complete_action", pyObj("owner_id", phOwner, "operation_id", operation, "action_id", action, "result", result))
}

func phFirstAction(t *testing.T, state *pyObject) *pyObject {
	t.Helper()
	actions, ok := state.Get("action_requests").(*pyObject)
	if !ok || actions.Len() == 0 {
		t.Fatalf("no action request: %s", pyCompact(state))
	}
	return actions.Get(actions.Keys()[0]).(*pyObject)
}

func (h *phHarness) pendingNativeAction() (*pyObject, *pyObject) {
	row := h.desktopRow()
	h.ok(h.desktopFacts(row))
	h.backend.inspectFirst, h.backend.repairAfterInspect = true, true
	return phFirstAction(h.t, h.tickState()), row
}

func phReportHealth(t *testing.T, state *pyObject) any {
	t.Helper()
	report, ok := state.Get("report").(*pyObject)
	if !ok {
		t.Fatalf("no report: %s", pyCompact(state))
	}
	return pyIndex(pyIndex(report, "panes").(*pyList).items[0], "health")
}

func TestPaneHealthNativeInspectionAndBudgetedReportWithoutTerminalAuthority(t *testing.T) {
	h := newPHHarness(t)
	h.backend.inspectFirst = true
	state := h.tickState()
	if len(h.backend.requests) != 2 || len(h.backend.probes) != 2 || state.Has("pending") || phReportHealth(t, state) != "healthy" {
		t.Fatalf("requests=%d probes=%d state=%s", len(h.backend.requests), len(h.backend.probes), pyCompact(state))
	}
	pane := h.backend.requests[0].Get("panes").(*pyList).items[0].(*pyObject)
	if !pyEqual(pane.Get("allowed_actions"), pyListOf("observe", "attention")) || pane.Get("prompt_empty") != nil ||
		pane.Get("has_draft") != nil || pane.Get("input_idle") != nil || pane.Has("resume_command") || pane.Has("transcript") || pane.Has("prompt") {
		t.Fatalf("request granted terminal facts: %s", pyCompact(pane))
	}
}

func TestPaneHealthUnchangedPanesDoNotSpendButSixHourRefreshIsANewRequest(t *testing.T) {
	h := newPHHarness(t)
	h.tickState()
	h.advance(paneHealthNativeInterval)
	h.backend.native[phPane].(*pyObject).Set("lifecycle", "active")
	h.tickState()
	if len(h.backend.requests) != 1 || len(h.backend.probes) != 2 {
		t.Fatalf("unchanged panes spent a request: %d/%d", len(h.backend.requests), len(h.backend.probes))
	}
	h.advance(paneHealthModelInterval)
	h.tickState()
	if len(h.backend.requests) != 2 || pyEqual(h.backend.requests[0].Get("operation_id"), h.backend.requests[1].Get("operation_id")) {
		t.Fatal("six hour refresh did not issue a new request")
	}
}

func TestPaneHealthBudgetHoldKeepsNativeObservationsAndCheckIsIdempotent(t *testing.T) {
	h := newPHHarness(t)
	h.backend.err = "spending_limit"
	h.tickState()
	h.advance(paneHealthNativeInterval)
	h.tickState()
	if len(h.backend.requests) != 1 || len(h.backend.probes) != 2 {
		t.Fatalf("budget hold resubmitted: %d/%d", len(h.backend.requests), len(h.backend.probes))
	}
	first := h.ok(h.run("check", pyObj("operation_id", strings.Repeat("2", 32))))
	again := h.ok(h.run("check", pyObj("operation_id", strings.Repeat("2", 32))))
	if first.Get("wake_controller") != true || again.Get("wake_controller") != false {
		t.Fatal("explicit check is not idempotent")
	}
	h.tickState()
	if len(h.backend.requests) != 2 {
		t.Fatal("explicit check did not override the hold")
	}
}

func TestPaneHealthUnknownRequestIsReconciledByOriginalIDWithoutResubmission(t *testing.T) {
	h := newPHHarness(t)
	h.backend.err = "request_outcome_unknown"
	original := pyIndex(h.tickState().Get("pending"), "operation_id")
	h.advance(paneHealthNativeInterval)
	state := h.tickState()
	if len(h.backend.requests) != 1 || !pyEqual(pyListOf(h.backend.statusReads...), pyListOf(original)) ||
		!pyEqual(pyIndex(state.Get("pending"), "operation_id"), original) || len(h.backend.probes) != 2 {
		t.Fatalf("unknown outcome was not reconciled by its id: %s", pyCompact(state))
	}
}

func TestPaneHealthRecoveredReceiptForReplacedProcessNeverReportsNewProcessHealthy(t *testing.T) {
	h := newPHHarness(t)
	h.backend.err = "request_outcome_unknown"
	state := h.tickState()
	request := h.backend.requests[0]
	pane := request.Get("panes").(*pyList).items[0]
	calls := pyListOf(pyObj("type", "tool_use", "id", "report_old", "name", "report_health", "input", pyObj("panes", pyListOf(
		pyObj("pane_id", phPane, "evidence_id", pyIndex(pane, "evidence_id"), "health", "healthy", "action", "observe", "reason", "Old native process.")))))
	h.backend.rows[pyIndex(state.Get("pending"), "operation_id").(string)] = h.backend.receipt(request, calls)
	h.backend.native[phPane] = phProof(phPane, "claude", 1235)
	h.advance(paneHealthNativeInterval)
	state = h.tickState()
	if state.Has("report") || state.Has("pending") || !strings.Contains(state.Get("status").(string), "changed") {
		t.Fatalf("replaced process reported healthy: %s", pyCompact(state))
	}
}

func TestPaneHealthParentLossAndDisabledMonitorPreventModelRequests(t *testing.T) {
	h := newPHHarness(t)
	h.alive = false
	h.ok(h.run("tick", newPyObject()))
	if len(h.backend.probes) != 0 {
		t.Fatal("probe ran without its parent")
	}
	h.alive = true
	h.ok(h.configure("enabled", false))
	h.ok(h.run("tick", newPyObject()))
	if len(h.backend.probes) != 0 || len(h.backend.requests) != 0 {
		t.Fatal("disabled monitor probed or spent")
	}
}

func TestPaneHealthHaikuDisabledStillRunsNativeChecks(t *testing.T) {
	h := newPHHarness(t)
	h.ok(h.configure("haiku_enabled", false))
	state := h.tickState()
	if len(h.backend.probes) != 1 || len(h.backend.requests) != 0 || !pyIndex(state, "observations").(*pyObject).Has(phPane) {
		t.Fatalf("native checks did not run: %s", pyCompact(state))
	}
}

func TestPaneHealthForeignInstallationAndDuplicatePanesAreRefused(t *testing.T) {
	h := newPHHarness(t)
	h.failed(h.configure("owner_id", "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"), "controller_owned_by_another_installation")
	h.failed(h.configure("panes", pyListOf(phPane, phPane)), "invalid_controller_configuration")
	same := h.ok(h.configure())
	if same.Has("wake_controller") || !pyEqual(pyIndex(same.Get("configuration"), "generation"), int64(1)) {
		t.Fatalf("identical configuration changed generation: %s", pyCompact(same))
	}
}

func TestPaneHealthConfigurationChangeDuringModelCallHoldsRemainingTools(t *testing.T) {
	h := newPHHarness(t)
	h.backend.inspectFirst = true
	h.backend.mutate = func() { h.ok(h.configure("haiku_enabled", false)) }
	state := h.tickState()
	if len(h.backend.probes) != 1 || len(h.backend.requests) != 1 || !strings.Contains(state.Get("status").(string), "held") || !state.Has("pending") {
		t.Fatalf("tools continued after configuration change: %s", pyCompact(state))
	}
}

func TestPaneHealthNativeMissingOwnerDoesNotInventDisconnectionOrSuccess(t *testing.T) {
	h := newPHHarness(t)
	h.backend.native[phPane].(*pyObject).Delete("owner")
	facts := h.observe(phPane).Get("facts").(*pyObject)
	if facts.Get("identity_verified") != false || facts.Get("connection") != "unknown" {
		t.Fatalf("missing owner verified: %s", pyCompact(facts))
	}
}

func TestPaneHealthPrivateJournalRefusesSymlinksAndPublicFiles(t *testing.T) {
	h := newPHHarness(t)
	if err := os.Symlink(filepath.Join(h.root, "configuration.json"), filepath.Join(h.root, "foreign.json")); err != nil {
		t.Fatal(err)
	}
	func() {
		defer func() {
			if _, ok := recover().(paneHealthOSError); !ok {
				t.Fatal("symlinked state was read")
			}
		}()
		h.controller().load("foreign.json", newPyObject())
	}()
	if err := os.WriteFile(filepath.Join(h.root, "public.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	_ = os.Chmod(filepath.Join(h.root, "public.json"), 0o644)
	func() {
		defer func() {
			if recover() != paneHealthControllerError("controller_state_not_private") {
				t.Fatal("public state was read")
			}
		}()
		h.controller().load("public.json", newPyObject())
	}()
	// The controller directory itself must stay private.
	if err := os.Chmod(h.root, 0o755); err != nil {
		t.Fatal(err)
	}
	h.failed(h.run("status", newPyObject()), "controller_state_not_private")
}

func TestPaneHealthNativeObservationTimeAndUnknownInputNeverGrantActions(t *testing.T) {
	h := newPHHarness(t)
	facts := h.observe(phPane).Get("facts").(*pyObject)
	if !pyEqual(facts.Get("allowed_actions"), pyListOf("observe", "attention")) || facts.Get("prompt_empty") != nil ||
		facts.Get("input_idle") != nil || facts.Get("pending_approvals") != nil {
		t.Fatalf("native observation granted input facts: %s", pyCompact(facts))
	}
	evidence := facts.Get("evidence_id")
	facts.Delete("evidence_id")
	if paneHealthDigest(facts) != evidence {
		t.Fatal("evidence id is not the digest of its facts")
	}
}

func TestPaneHealthNativeActionIsDurableWaitsWithoutResubmissionAndRequiresReceipt(t *testing.T) {
	h := newPHHarness(t)
	action, _ := h.pendingNativeAction()
	if len(h.backend.requests) != 2 || action.Get("state") != "pending_native" ||
		!pyEqual(pyIndex(pyIndex(action.Get("call"), "input"), "evidence_id"), pyIndex(action.Get("before"), "evidence_id")) {
		t.Fatalf("native action not journaled: %s", pyCompact(action))
	}
	id := action.Get("id").(string)
	h.advance(paneHealthNativeInterval)
	again := h.tickState()
	if len(h.backend.requests) != 2 || pyIndex(pyIndex(again.Get("action_requests"), id), "state") != "pending_native" {
		t.Fatal("pending native action was resubmitted")
	}
	h.backend.native[phPane] = phProof(phPane, "claude", 1235)
	after := h.observe(phPane).Get("facts")
	receipt := pyObj("state", "verified", "pane", after, "message", "Native original conversation is current.")
	if ack := h.ok(h.completeAction(strings.Repeat("3", 32), id, receipt)); ack.Get("acknowledged_action_id") != id || ack.Get("wake_controller") != true {
		t.Fatal("receipt not acknowledged")
	}
	if ack := h.ok(h.completeAction(strings.Repeat("3", 32), id, receipt)); ack.Get("acknowledged_action_id") != id {
		t.Fatal("identical receipt not idempotent")
	}
	conflict := receipt.Copy()
	conflict.Set("state", "held")
	h.failed(h.completeAction(strings.Repeat("4", 32), id, conflict), "native_action_receipt_conflict")
	final := h.tickState()
	if len(h.backend.requests) != 3 || final.Has("pending") || pyIndex(pyIndex(final.Get("action_requests"), id), "state") != "completed" ||
		phReportHealth(t, final) != "healthy" {
		t.Fatalf("receipt not consumed: %s", pyCompact(final))
	}
}

func TestPaneHealthStaleOrOtherSessionDesktopInputFactsNeverAllowAnUpdate(t *testing.T) {
	h := newPHHarness(t)
	row := h.desktopRow()
	h.ok(h.desktopFacts(row))
	h.advance(31)
	if h.observe(phPane).Get("facts").(*pyObject).Get("prompt_empty") != nil {
		t.Fatal("stale desktop facts were applied")
	}
	h.advance(-31)
	changed := row.Copy()
	changed.Set("session_id", "a-different-session")
	changed.Delete("evidence_id")
	changed.Set("evidence_id", paneHealthDigest(changed))
	h.ok(h.desktopFacts(changed))
	if pyContains(h.observe(phPane).Get("facts").(*pyObject).Get("allowed_actions"), "apply_update") {
		t.Fatal("another session's facts allowed an update")
	}
}

func TestPaneHealthDesktopFactsRecheckGenerationAfterNativeValidation(t *testing.T) {
	h := newPHHarness(t)
	row := h.observe(phPane).Get("facts")
	h.backend.validatePanes = func(host, snapshot, panes any) (any, error) {
		value, err := phValidPanes(host, snapshot, panes)
		h.ok(h.configure("enabled", false))
		return value, err
	}
	h.failed(h.desktopFacts(row), "desktop_input_facts_scope_changed")
	if h.load("desktop-facts.json").(*pyObject).Len() != 0 {
		t.Fatal("facts stored across a configuration change")
	}
}

func TestPaneHealthReplacedConfigurationRejectsLateNativeActionReceipt(t *testing.T) {
	h := newPHHarness(t)
	action, _ := h.pendingNativeAction()
	h.ok(h.configure("haiku_enabled", false))
	h.failed(h.completeAction(strings.Repeat("3", 32), action.Get("id").(string), pyObj("state", "verified")), "invalid_native_action_receipt")
	if h.load("action-results.json").(*pyObject).Len() != 0 {
		t.Fatal("late receipt recorded")
	}
}

func TestPaneHealthNativeActionReceiptRechecksGenerationAfterPaneValidation(t *testing.T) {
	h := newPHHarness(t)
	action, row := h.pendingNativeAction()
	h.backend.validatePanes = func(host, snapshot, panes any) (any, error) {
		value, err := phValidPanes(host, snapshot, panes)
		h.ok(h.configure("enabled", false))
		return value, err
	}
	h.failed(h.completeAction(strings.Repeat("3", 32), action.Get("id").(string), pyObj("state", "held", "pane", row)), "invalid_native_action_receipt")
	if h.load("action-results.json").(*pyObject).Len() != 0 {
		t.Fatal("receipt recorded across a configuration change")
	}
}

func TestPaneHealthActionReceiptForOtherOwnerOrOperationIsNeverReused(t *testing.T) {
	h := newPHHarness(t)
	action, _ := h.pendingNativeAction()
	id := action.Get("id").(string)
	h.controller().save("action-results.json", pyObj(id, pyObj("operation_id", strings.Repeat("3", 32),
		"action_operation_id", strings.Repeat("4", 32), "owner_id", "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee",
		"generation", int64(1), "result", pyObj("state", "verified"))))
	recorded := pyIndex(pyIndex(h.tickState().Get("action_requests"), id), "result").(*pyObject)
	if recorded.Get("state") != "held" || !strings.Contains(recorded.Get("message").(string), "another configuration or operation") {
		t.Fatalf("foreign receipt reused: %s", pyCompact(recorded))
	}
}

func TestPaneHealthNewGenerationClearsOldReportWithoutRepeatingTheAPI(t *testing.T) {
	h := newPHHarness(t)
	if !h.tickState().Has("report") {
		t.Fatal("no initial report")
	}
	calls := len(h.backend.requests)
	h.ok(h.configure("haiku_enabled", false))
	current := h.tickState()
	if !pyEqual(current.Get("generation"), int64(2)) || current.Has("report") || len(h.backend.requests) != calls {
		t.Fatalf("old report kept: %s", pyCompact(current))
	}
}

// phProbeHook lets a test act while a probe is in flight.
type phProbeHook struct {
	*phFakeBackend
	hook func()
}

func (p phProbeHook) Probe(pane string) (any, error) {
	p.hook()
	return phProof(pane, "claude", 1234), nil
}

func TestPaneHealthProbeFinishingAfterParentOrConfigurationChangeNeverPublishesFreshEvidence(t *testing.T) {
	for _, cause := range []string{"parent", "configuration"} {
		t.Run(cause, func(t *testing.T) {
			h := newPHHarness(t)
			backend := phProbeHook{phFakeBackend: h.backend}
			backend.hook = func() {
				if cause == "parent" {
					h.alive = false
				} else {
					h.ok(h.configure("enabled", false))
				}
			}
			result := h.ok(runPaneHealthController(h.root, backend, h.now, func() bool { return h.alive }, "tick", newPyObject()))
			state := result.Get("state").(*pyObject)
			if observations, _ := state.GetOr("observations", newPyObject()).(*pyObject); observations.Len() != 0 ||
				state.Has("last_observed_at") || len(h.backend.requests) != 0 {
				t.Fatalf("late probe published evidence: %s", pyCompact(state))
			}
		})
	}
}

func TestPaneHealthNewGenerationCannotLabelOldObservationsCurrentWhileProbeIsInFlight(t *testing.T) {
	h := newPHHarness(t)
	if !pyIndex(h.tickState(), "observations").(*pyObject).Has(phPane) {
		t.Fatal("no initial observation")
	}
	calls := len(h.backend.requests)
	h.ok(h.configure("haiku_enabled", false))
	backend := phProbeHook{phFakeBackend: h.backend}
	backend.hook = func() {
		state := h.ok(h.run("status", newPyObject())).Get("state").(*pyObject)
		if !pyEqual(state.Get("generation"), int64(2)) || pyIndex(state, "observations").(*pyObject).Len() != 0 ||
			state.Has("last_observed_at") || state.Has("report") {
			t.Errorf("old observations labelled current: %s", pyCompact(state))
		}
		h.alive = false
	}
	state := h.ok(runPaneHealthController(h.root, backend, h.now, func() bool { return h.alive }, "tick", newPyObject())).Get("state").(*pyObject)
	if pyIndex(state, "observations").(*pyObject).Len() != 0 || state.Has("last_observed_at") || len(h.backend.requests) != calls {
		t.Fatalf("in-flight probe published: %s", pyCompact(state))
	}
}

// ---- Go-specific behavior: cadence, locking, trimming and persistence.

func TestPaneHealthCadenceFollowsConfiguration(t *testing.T) {
	h := newPHHarness(t)
	if !pyEqual(h.ok(h.run("status", newPyObject())).Get("next_check_seconds"), int64(paneHealthNativeInterval)) {
		t.Fatal("enabled controller does not run every 120 s")
	}
	h.ok(h.configure("enabled", false))
	if !pyEqual(h.ok(h.run("status", newPyObject())).Get("next_check_seconds"), int64(-1)) {
		t.Fatal("disabled controller still schedules native checks")
	}
}

func TestPaneHealthModelBatchesCoverAtMostSixtyFourPanes(t *testing.T) {
	h := newPHHarness(t)
	panes := pyListOf()
	for index := 0; index < 70; index++ {
		pane := phPaneID(index)
		panes.items = append(panes.items, pane)
		h.backend.native[pane] = phProof(pane, "claude", 1234)
	}
	h.ok(h.configure("panes", panes))
	h.tickState()
	if len(h.backend.requests) != 1 || len(h.backend.requests[0].Get("panes").(*pyList).items) != paneHealthModelBatch {
		t.Fatalf("first batch: %d requests", len(h.backend.requests))
	}
	h.advance(paneHealthNativeInterval)
	h.tickState()
	if len(h.backend.requests) != 2 || len(h.backend.requests[1].Get("panes").(*pyList).items) != 6 {
		t.Fatal("second batch was not selected on the next deadline")
	}
	h.advance(paneHealthNativeInterval)
	h.tickState()
	if len(h.backend.requests) != 2 {
		t.Fatal("unchanged batches spent another request")
	}
}

func phPaneID(index int) string {
	return strings.Replace("00000000-2222-4333-8444-555555555555", "00000000", hex.EncodeToString([]byte{0, 0, byte(index >> 8), byte(index)}), 1)
}

func TestPaneHealthConcurrentTickReturnsStatusWithoutProbing(t *testing.T) {
	h := newPHHarness(t)
	held, busy := h.controller().lock("tick.lock", false)
	if busy {
		t.Fatal("tick lock unavailable")
	}
	defer held.Close()
	h.ok(h.run("tick", newPyObject()))
	if len(h.backend.probes) != 0 {
		t.Fatal("a second tick ran while the first held its lock")
	}
}

func TestPaneHealthStateTrimmingKeepsRecentToolResultsAndPendingActions(t *testing.T) {
	h := newPHHarness(t)
	state := pyObj("generation", int64(1))
	results := newPyObject()
	for index := 0; index < 400; index++ {
		results.Set(phKey("r", index), pyObj("n", int64(index)))
	}
	actions := newPyObject()
	for index := 0; index < 140; index++ {
		status := "completed"
		if index%40 == 0 {
			status = "pending_native"
		}
		actions.Set(phKey("a", index), pyObj("state", status))
	}
	state.Set("tool_results", results)
	state.Set("action_requests", actions)
	h.controller().save("state.json", state)
	loaded := h.load("state.json").(*pyObject)
	keptResults := loaded.Get("tool_results").(*pyObject)
	keptActions := loaded.Get("action_requests").(*pyObject)
	if keptResults.Len() != paneHealthToolResults || keptResults.Has(phKey("r", 15)) || !keptResults.Has(phKey("r", 16)) {
		t.Fatalf("tool results not trimmed to the last 384 (%d)", keptResults.Len())
	}
	pending := 0
	for _, key := range keptActions.Keys() {
		if pyIndex(keptActions.Get(key), "state") == "pending_native" {
			pending++
		}
	}
	if pending != 4 || keptActions.Len() != 4+paneHealthCompletedKept || keptActions.Has(phKey("a", 1)) || !keptActions.Has(phKey("a", 139)) {
		t.Fatalf("actions not trimmed to pending + last 128 completed: %d pending, %d kept", pending, keptActions.Len())
	}
	info, err := os.Stat(filepath.Join(h.root, "state.json"))
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatal("state is not private", err)
	}
	if info, err := os.Stat(h.root); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatal("controller directory is not private", err)
	}
}

// Insertion order: keys sort the same as their numeric suffix.
func phKey(prefix string, index int) string {
	return prefix + strings.Repeat("0", 4-len(itoa(index))) + itoa(index)
}

func itoa(value int) string { return string(pyEncode(int64(value), pyDumpsCompact)) }

func TestPaneHealthOversizedOrCorruptStateFailsClosed(t *testing.T) {
	h := newPHHarness(t)
	if err := os.WriteFile(filepath.Join(h.root, "state.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	h.failed(h.run("status", newPyObject()), "controller_state_or_backend_unavailable")
	large := make([]byte, paneHealthStateLimit+2)
	for i := range large {
		large[i] = ' '
	}
	if err := os.WriteFile(filepath.Join(h.root, "state.json"), large, 0o600); err != nil {
		t.Fatal(err)
	}
	h.failed(h.run("status", newPyObject()), "controller_state_too_large")
}

// The real backend: Go-computed facts, evidence IDs and snapshot digests must
// satisfy text_backend's own validators, so existing ledgers stay compatible.
// No probe runs (it would read native pane state), no API is reachable and no
// interpreter is on PATH: the text calls run in relayd over the Go ledger.
func TestPaneHealthTextBackendAcceptsGoDigestsAndKeepsDraftErrorCodes(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	worker := filepath.Join(t.TempDir(), "worker")
	if err := os.Mkdir(worker, 0o700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	backend, err := startPaneHealthTextBackend(ctx, worker)
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	h := newPHHarness(t)
	facts := h.observe(phPane).Get("facts").(*pyObject)
	panes := pyListOf(facts)
	snapshot := paneHealthDigest(pyObj("host_id", "owned-host", "panes", panes))
	if _, err := backend.ValidatePanes("owned-host", snapshot, panes); err != nil {
		t.Fatalf("text_backend rejected a Go observation: %v", err)
	}
	tampered := facts.Copy()
	tampered.Set("installed_update", true)
	tampered.Set("allowed_actions", pyListOf("observe", "attention", "apply_update"))
	tampered.Delete("evidence_id")
	tampered.Set("evidence_id", paneHealthDigest(tampered))
	bad := pyListOf(tampered)
	_, err = backend.ValidatePanes("owned-host", paneHealthDigest(pyObj("host_id", "owned-host", "panes", bad)), bad)
	var coded *paneHealthBackendError
	if !errors.As(err, &coded) || coded.code == "" {
		t.Fatalf("unverified update action accepted or lost its DraftError code: %v", err)
	}
	latest, err := backend.ValidateMessages(pyListOf(), "owned-host", panes)
	if err != nil || !pyEqual(latest, panes) {
		t.Fatalf("validate_health_messages: %v %s", err, pyCompact(latest))
	}
	report := pyListOf(pyObj("type", "tool_use", "id", "owned_report", "name", "report_health", "input", pyObj("panes", pyListOf(
		pyObj("pane_id", phPane, "evidence_id", facts.Get("evidence_id"), "health", "healthy", "action", "observe",
			"reason", "The exact native binding is verified.")))))
	calls, err := backend.ValidateCalls(report, latest)
	if err != nil || !pyEqual(calls, report) {
		t.Fatalf("validate_health_calls: %v %s", err, pyCompact(calls))
	}
	status, err := backend.Status(strings.Repeat("a", 32))
	if err != nil || pyGet(status, "status", nil) == nil {
		t.Fatalf("journal status: %v %s", err, pyCompact(status))
	}
	if _, err := backend.ValidateCalls(pyListOf(), latest); !errors.As(err, &coded) || coded.code != "invalid_health_tool_response" {
		t.Fatalf("empty tool response accepted: %v", err)
	}
	forged := pyListOf(pyObj("type", "tool_use", "id", "owned_report", "name", "report_health", "input", pyObj("panes", pyListOf(
		pyObj("pane_id", phPane, "evidence_id", strings.Repeat("0", 64), "health", "healthy", "action", "observe",
			"reason", "The exact native binding is verified.")))))
	if _, err := backend.ValidateCalls(forged, latest); !errors.As(err, &coded) || coded.code == "" {
		t.Fatalf("a report on unobserved evidence was accepted: %v", err)
	}
	if _, err := backend.call("probe", pyObj()); !errors.As(err, &coded) || coded.code != "" {
		t.Fatalf("unknown operation = %v, want an uncoded backend error", err)
	}
	if _, err := os.Stat(filepath.Join(worker, "rotation-text", "ledger.log")); err != nil {
		t.Fatal("journal is not the Go ledger", err)
	}
	if _, err := os.Lstat(filepath.Join(worker, "rotation-text", "operations.sqlite3")); !os.IsNotExist(err) {
		t.Fatal("a fresh journal created SQLite state", err)
	}
	// A cancellation between calls loses the backend for good.
	cancel()
	for range 2 {
		if _, err := backend.Status(strings.Repeat("a", 32)); !errors.Is(err, errPaneHealthBackendLost) {
			t.Fatalf("status after cancellation = %v", err)
		}
	}
}

// Review P2: a check/configure whose context expires while another holder
// owns configuration.lock must stop waiting and never mutate configuration
// after the lock is released.
func TestPaneHealthCancelledOperationWaitingForLockNeverMutatesConfiguration(t *testing.T) {
	for _, operation := range []string{"check", "configure"} {
		t.Run(operation, func(t *testing.T) {
			h := newPHHarness(t)
			before, err := os.ReadFile(filepath.Join(h.root, "configuration.json"))
			if err != nil {
				t.Fatal(err)
			}
			held, _ := h.controller().lock("configuration.lock", true)
			ctx, cancel := context.WithTimeout(context.Background(), 75*time.Millisecond)
			defer cancel()
			request := any(pyObj("operation_id", strings.Repeat("2", 32)))
			if operation == "configure" {
				changed := h.request.Copy()
				changed.Set("haiku_enabled", false)
				request = changed
			}
			done := make(chan *pyObject, 1)
			go func() {
				done <- runPaneHealthController(h.root, h.backend, h.now, func() bool { return ctx.Err() == nil }, operation, request)
			}()
			var result *pyObject
			select {
			case result = <-done:
			case <-time.After(3 * time.Second):
				held.Close()
				t.Fatal("cancelled operation kept waiting for the configuration lock")
			}
			held.Close()
			time.Sleep(50 * time.Millisecond)
			h.failed(result, "controller_operation_cancelled")
			after, err := os.ReadFile(filepath.Join(h.root, "configuration.json"))
			if err != nil || string(after) != string(before) {
				t.Fatalf("cancelled %s mutated configuration: %s", operation, after)
			}
		})
	}
}

func TestPaneHealthLockWaitStillSucceedsWhenTheHolderReleasesInTime(t *testing.T) {
	h := newPHHarness(t)
	held, _ := h.controller().lock("configuration.lock", true)
	go func() { time.Sleep(60 * time.Millisecond); held.Close() }()
	result := h.ok(h.run("check", pyObj("operation_id", strings.Repeat("2", 32))))
	if result.Get("wake_controller") != true || !pyEqual(pyIndex(result.Get("configuration"), "force_sequence"), int64(1)) {
		t.Fatalf("live check did not apply after waiting: %s", pyCompact(result))
	}
}

// A long launch command (an initial prompt) lives only in resume_command,
// which health never keeps, so it must not count against the proof cap; a
// kept proof over the cap, and a failed probe, each say why they were refused.
func TestPaneHealthProbeCapCountsOnlyTheKeptProof(t *testing.T) {
	backend := newPHFakeBackend()
	c := &paneHealthController{root: t.TempDir(), backend: backend, now: func() any { return int64(1) }, parentAlive: func() bool { return true }}

	long := phProof(phPane, "claude", 1234)
	long.Set("resume_command", strings.Repeat("p", 40000))
	long.Set("resume_error", nil)
	backend.native[phPane] = long
	proof := c.probe(phPane)
	if proof.Has("unavailable") || proof.Has("resume_command") || !pyEqual(proof.Get("session_id"), "owned-session") {
		t.Fatalf("bound proof with a long resume command was refused or leaked it: %s", pyCompact(proof))
	}
	if facts := c.observe(phPane); pyIndex(facts.Get("facts"), "identity_verified") != true {
		t.Fatalf("identity not verified: %s", pyCompact(facts))
	}

	oversized := phProof(phPane, "claude", 1234)
	oversized.Set("subagent_work", strings.Repeat("s", 40000))
	backend.native[phPane] = oversized
	if got := c.probe(phPane).Get("unavailable"); got != "Native identity could not be verified on this host: the native proof exceeded its size limit." {
		t.Fatalf("oversized kept proof: %v", got)
	}

	delete(backend.native, phPane)
	if got := c.probe(phPane).Get("unavailable"); got != "Native identity could not be verified on this host: the native probe failed." {
		t.Fatalf("failed probe: %v", got)
	}

	backend.native[phPane] = pyListOf()
	if got := c.probe(phPane).Get("unavailable"); got != "Native identity could not be verified on this host: the native probe returned no proof." {
		t.Fatalf("non-object probe: %v", got)
	}
}
