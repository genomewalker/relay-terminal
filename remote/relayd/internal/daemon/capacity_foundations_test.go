package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/capacity"
)

func capacityEnvelope(r any) []byte {
	raw, _ := json.Marshal(map[string]any{"request_id": "native-capacity-test", "operation": "host_accounts", "host_accounts": map[string]any{"request": r}})
	return raw
}
func capacitySourceFixture() capacity.Source {
	return capacity.Source{Model: "observed-model", Host: "host", Boot: "boot", Pane: "pane", WorkerPID: 20, WorkerStart: 30, Provider: "claude", Session: "session", PID: 40, Start: 50, Account: "team", Config: "/team", Binding: strings.Repeat("a", 64), Root: "/project"}
}
func TestCapacityNativeSettingsActionRoute(t *testing.T) {
	root := t.TempDir()
	observeCalls, accountCalls := 0, 0
	observe := func(context.Context, string) (capacity.Source, capacity.Counters, error) {
		observeCalls++
		return capacitySourceFixture(), capacity.Counters{Session: "session", Turn: 1, Tokens: 56000, Window: 200000, ObservedMS: time.Now().UnixMilli(), CompletedIdle: true}, nil
	}
	accounts := func(context.Context, capacity.Settings, capacity.Source, int64) ([]capacity.Account, []string, error) {
		accountCalls++
		return []capacity.Account{}, []string{"claude:team", "claude:personal"}, nil
	}
	call := func(r capacityRequest) capacityReply {
		t.Helper()
		raw, err := handleNodeCapacityRequest(context.Background(), capacityEnvelope(r), root, observe, accounts)
		if err != nil {
			t.Fatal(err)
		}
		var reply struct {
			Result capacityReply `json:"result"`
			Error  string        `json:"error"`
		}
		if json.Unmarshal(raw, &reply) != nil || reply.Error != "" {
			t.Fatal("NATIVE_ROUTE_FAILED", string(raw))
		}
		return reply.Result
	}
	status := call(capacityRequest{V: 1, Operation: "capacity_status", Pane: "pane"})
	if status.Enabled || status.Ready || status.Entry != nil {
		t.Fatal("READ_DEFAULT_MIGRATED_EXISTING", status)
	}
	expected := status.Revision
	settings := capacity.Defaults()
	settings.Approved = []string{"claude:team", "claude:personal"}
	settings.RebalanceEnabled = true
	status = call(capacityRequest{V: 1, Operation: "capacity_configure", ID: strings.Repeat("a", 32), Expected: &expected, Settings: &settings})
	if status.Settings.QuotaEnabled || !status.Settings.RebalanceEnabled {
		t.Fatal("INDEPENDENT_USER_POLICY_SWITCH", status)
	}
	expected = status.Revision
	status = call(capacityRequest{V: 1, Operation: "capacity_enroll", ID: strings.Repeat("b", 32), Expected: &expected, Pane: "pane"})
	if !status.Enabled || status.Ready {
		t.Fatal("ENABLED_CONFUSED_WITH_READY", status)
	}
	expected = status.Revision
	r := capacityRequest{V: 1, Operation: "capacity_manual_refresh", ID: strings.Repeat("c", 32), Expected: &expected, Pane: "pane"}
	status = call(r)
	if status.Operation == nil || status.Operation.State != "held" || status.Operation.Reason != capacity.RetirementHold {
		t.Fatal("ACTUAL_PROVIDER_RETIREMENT_NOT_HELD", status)
	}
	revision := status.Revision
	status = call(r)
	if status.Revision != revision || status.Operation == nil {
		t.Fatal("NATIVE_ACTION_REPLAY", status)
	}
	conflict := r
	conflict.Operation = "capacity_manual_move"
	conflict.Target = "personal"
	raw, err := handleNodeCapacityRequest(context.Background(), capacityEnvelope(conflict), root, observe, accounts)
	if err != nil || !strings.Contains(string(raw), "capacity action ID conflicts") {
		t.Fatal("NATIVE_REQUEST_ID_PAYLOAD_CONFLICT", string(raw), err)
	}
	unavailable := func(context.Context, string) (capacity.Source, capacity.Counters, error) {
		return capacity.Source{}, capacity.Counters{}, errors.New("source temporarily unavailable")
	}
	raw, err = handleNodeCapacityRequest(context.Background(), capacityEnvelope(capacityRequest{V: 1, Operation: "capacity_status", Pane: "pane"}), root, unavailable, accounts)
	var held struct {
		Result capacityReply `json:"result"`
	}
	if err != nil || json.Unmarshal(raw, &held) != nil || !held.Result.Managed || held.Result.Supported || held.Result.Entry == nil {
		t.Fatal("MISSING_NATIVE_EVIDENCE_RELEASED_COMBINED_LANE", string(raw), err)
	}
	expected = status.Revision
	raw, err = handleNodeCapacityRequest(context.Background(), capacityEnvelope(capacityRequest{V: 1, Operation: "capacity_pause", ID: strings.Repeat("e", 32), Expected: &expected, Pane: "pane"}), root, unavailable, accounts)
	if err != nil || json.Unmarshal(raw, &held) != nil || held.Result.Enabled || !held.Result.Managed || held.Result.Entry == nil {
		t.Fatal("UNAVAILABLE_NATIVE_PAUSE_STATE_NOT_REPORTED", string(raw), err)
	}
	status = held.Result
	expected = status.Revision
	status = call(capacityRequest{V: 1, Operation: "capacity_pause", ID: strings.Repeat("d", 32), Expected: &expected, Pane: "pane"})
	if status.Enabled {
		t.Fatal("NATIVE_PAUSE_IGNORED")
	}
	loaded, err := (capacity.Journal{Root: filepath.Join(root, "capacity")}).Load()
	if err != nil || !loaded.Entries["pane"].OptOut {
		t.Fatal("NATIVE_OPTOUT_NOT_DURABLE")
	}
	if observeCalls < 4 || accountCalls < 2 {
		t.Fatal("REAL_NATIVE_SEAMS_NOT_CALLED", observeCalls, accountCalls)
	}
}
func TestCapacityNativeRejectsAuthorityAndAmbiguity(t *testing.T) {
	good := string(capacityEnvelope(capacityRequest{V: 1, Operation: "capacity_status", Pane: "pane"}))
	for _, raw := range []string{strings.Replace(good, `"v":1`, `"v":1,"v":1`, 1), strings.Replace(good, `"pane_id":"pane"`, `"pane_id":"pane","source":{"pid":1}`, 1), strings.Replace(good, `"pane_id":"pane"`, `"pane_id":"pane","capabilities":{"admission":true}`, 1), strings.Replace(good, `"capacity_status"`, `"capacity_stop_tasks"`, 1), good + "{}"} {
		if _, _, err := decodeCapacityEnvelope([]byte(raw)); err == nil {
			t.Fatal("UNTRUSTED_NATIVE_AUTHORITY_ACCEPTED", raw)
		}
	}
	for i := 0; i < len(good); i++ {
		if _, _, err := decodeCapacityEnvelope([]byte(good[:i])); err == nil {
			t.Fatalf("NATIVE_ENVELOPE_TRUNCATION %d", i)
		}
	}
}
func TestCapacityActualGoPolicyOptIn(t *testing.T) {
	t.Setenv("XDG_STATE_HOME", t.TempDir())
	golden := loadHostRotationPolicyGolden(t)
	var input []byte
	var now int64
	for _, c := range golden.Cases {
		if c.Name == "rotate_pressure" {
			input = []byte(c.Input)
			now = c.NowMS
			break
		}
	}
	if len(input) == 0 {
		t.Fatal("missing retained golden")
	}
	doc, err := pyDecode(input)
	if err != nil {
		t.Fatal(err)
	}
	status := hostRotationPolicyUnwrap(doc)
	session, _ := status.Get("session_id").(string)
	e := capacity.Entry{Managed: true, Source: capacitySourceFixture(), Enabled: true, Baseline: 56000, BaselineTurn: 1}
	e.Source.Session = session
	j := capacity.Journal{Root: filepath.Join(defaultWorkerStateDir(), "capacity")}
	_, err = j.Update("setup", capacity.Hash([]byte("setup")), 0, func(d *capacity.Disk) error { d.Entries[e.Source.Pane] = e; return nil })
	if err != nil {
		t.Fatal(err)
	}
	raw, err := evaluateHostRotationPolicy(input, now)
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Decision   string `json:"decision"`
		Retirement string `json:"retirement"`
		Threshold  int64  `json:"threshold_tokens"`
	}
	if json.Unmarshal(raw, &result) != nil || result.Decision != "hold" || result.Retirement != capacity.RetirementHold || result.Threshold != 100000 {
		t.Fatal("PRODUCTION_GO_THRESHOLD_BYPASSED", string(raw))
	}
}
func TestCapacityNativeCWDAndMetadata(t *testing.T) {
	rows := rotationClaudeFixtureRow("user", "u", "", "text", map[string]any{"cwd": "/project"}) + rotationClaudeFixtureRow("assistant", "a", "u", "text", map[string]any{"cwd": "/project/hooks"})
	root, dirs, err := parseHostRotationNativeDirectoryEvidence(context.Background(), strings.NewReader(rows), "claude", "fixture-session")
	if err != nil || root != "/project" || len(dirs) != 2 {
		t.Fatal("LEGITIMATE_CWD_CHANGE_REFUSED", root, dirs, err)
	}
	escaped := strings.Replace(rows, "/project/hooks", "/project/../escape", 1)
	if _, _, err := parseHostRotationNativeDirectoryEvidence(context.Background(), strings.NewReader(escaped), "claude", "fixture-session"); err == nil {
		t.Fatal("TRANSCRIPT_ROOT_ESCAPE")
	}
	actual := t.TempDir()
	inside := filepath.Join(actual, "inside")
	_ = os.Mkdir(inside, 0700)
	outside := t.TempDir()
	link := filepath.Join(actual, "link")
	_ = os.Symlink(outside, link)
	if verifyNativeDirectoryEvidence(actual, []string{inside}, inside) != nil {
		t.Fatal("VERIFIED_LIVE_CWD_REFUSED")
	}
	if verifyNativeDirectoryEvidence(actual, []string{link}, inside) == nil {
		t.Fatal("CWD_SYMLINK_ESCAPE")
	}
	if verifyNativeDirectoryEvidence(actual, []string{inside}, outside) == nil {
		t.Fatal("LIVE_PROCESS_CWD_ESCAPE")
	}
	path := filepath.Join(t.TempDir(), "missing.json")
	_, _, _, err = readNativeClaudeRegistration(path, 123, "expected")
	if err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatal("MISSING_METADATA_MISCLASSIFIED", err)
	}
	_ = os.WriteFile(path, []byte(`{}`), 0666)
	_ = os.Chmod(path, 0666)
	_, _, _, err = readNativeClaudeRegistration(path, 123, "expected")
	if err == nil || !strings.Contains(err.Error(), "owner or integrity") {
		t.Fatal("UNSAFE_METADATA_WEAKENED", err)
	}
}
func FuzzCapacityNativeEnvelope(f *testing.F) {
	f.Add(capacityEnvelope(capacityRequest{V: 1, Operation: "capacity_status", Pane: "pane"}))
	f.Add([]byte(`{"operation":"host_accounts","request_id":"x","host_accounts":{"request":{"v":1,"v":1}}}`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		id, r, err := decodeCapacityEnvelope(raw)
		if err != nil {
			return
		}
		again := capacityEnvelope(r)
		id2, back, err := decodeCapacityEnvelope(again)
		if err != nil || id == "" || id2 == "" || r.Operation != back.Operation || r.Pane != back.Pane {
			t.Fatal("NATIVE_REQUEST_ROUNDTRIP")
		}
		if r.Operation == "capacity_status" && (r.ID != "" || r.Settings != nil || r.Target != "") {
			t.Fatal("NATIVE_READ_ESCALATED")
		}
	})
}
func FuzzCapacityNativeDirectory(f *testing.F) {
	f.Add([]byte(rotationClaudeFixtureRow("user", "u", "", "text", map[string]any{"cwd": "/project"})))
	f.Fuzz(func(t *testing.T, raw []byte) {
		root, dirs, err := parseHostRotationNativeDirectoryEvidence(context.Background(), strings.NewReader(string(raw)), "claude", "fixture-session")
		if err != nil {
			return
		}
		if !filepath.IsAbs(root) || filepath.Clean(root) != root || len(dirs) > 256 {
			t.Fatal("NATIVE_ROOT_BOUND")
		}
		for _, d := range dirs {
			if !nativeDirectoryWithin(root, d) {
				t.Fatal("NATIVE_ROOT_ESCAPE")
			}
		}
	})
}
func FuzzCapacityLedgerSample(f *testing.F) {
	f.Add([]byte(`null`))
	f.Add([]byte(`{"session_id":"s","turn_seq":2,"usage":{}}`))
	f.Fuzz(func(t *testing.T, raw []byte) {
		c := capacityCountersFromLedger(raw)
		if c.CompletedIdle && (c.Session == "" || c.ObservedMS <= 0) {
			t.Fatal("UNBOUND_LEDGER_SAMPLE")
		}
	})
}

func TestCapacityNativeHumanInputRevokesIndependentEnrollment(t *testing.T) {
	root := t.TempDir()
	j := capacity.Journal{Root: filepath.Join(root, "capacity")}
	_, err := j.Update("setup", capacity.Hash([]byte("setup")), 0, func(d *capacity.Disk) error {
		d.Entries["pane"] = capacity.Entry{Managed: true, Source: capacitySourceFixture(), Enabled: true, Baseline: 56000, BaselineTurn: 1}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	s := &hostRotationSupervisor{path: filepath.Join(root, "rotation-supervision", "pane.json"), record: hostRotationRecord{Enabled: false}}
	s.humanInput()
	d, err := j.Load()
	if err != nil || d.Entries["pane"].Enabled || !d.Entries["pane"].Takeover || d.Entries["pane"].UserGeneration != 1 {
		t.Fatal("NATIVE_HUMAN_INPUT_DID_NOT_REVOKE", d, err)
	}
	before := d.Revision
	s.humanInput()
	d, err = j.Load()
	if err != nil || d.Revision != before {
		t.Fatal("REPEATED_INPUT_TOMBSTONE_CHURN", err)
	}
	e := d.Entries["pane"]
	if _, err = e.ApplyUserState("resume"); err == nil {
		t.Fatal("MCP_RESUME_LIFTED_TAKEOVER")
	}
}

func TestCapacityNativeTargetModelPermissionStaysUnknown(t *testing.T) {
	source := capacitySourceFixture()
	cases := []struct {
		provider, label, config string
		usageOK, want           bool
	}{
		{"claude", "team", "/team", true, true},
		{"claude", "personal", "/personal", true, false},
		{"claude", "team", "/other", true, false},
		{"codex", "team", "/team", true, false},
		{"claude", "team", "/team", false, false},
	}
	for _, tc := range cases {
		got, reason := capacityUsageModelScope(source, tc.provider, tc.label, tc.config, tc.usageOK)
		if got != tc.want || reason == "" {
			t.Fatal("TARGET_MODEL_ADMISSION_FABRICATED", tc, got, reason)
		}
	}
	source.Model = ""
	if got, _ := capacityUsageModelScope(source, "claude", "team", "/team", true); got {
		t.Fatal("MISSING_NATIVE_MODEL_ADMISSION_ACCEPTED")
	}
}
