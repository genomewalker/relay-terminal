//go:build linux || darwin

package nativemsg

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestNativeKernelOwnerExactPIDUIDAndClosedSocket(t *testing.T) {
	path := filepath.Join(shortTempDir(t), "peer.sock")
	listener, e := net.ListenUnix("unix", &net.UnixAddr{Net: "unix", Name: path})
	if e != nil {
		t.Fatal(e)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	c, e := dialUnix(ctx, path, time.Second)
	if e != nil {
		t.Fatal(e)
	}
	pid, uid, e := nativePeerOwner(c)
	if e != nil || pid != int64(os.Getpid()) || uid != int64(os.Getuid()) {
		t.Fatal("kernel peer PID/UID lost", pid, uid, e)
	}
	c.close()
	if _, _, e := nativePeerOwner(c); e == nil {
		t.Fatal("closed socket fabricated credentials")
	}
}

func TestOriginalEndpointTranscriptFinalGuards(t *testing.T) {
	for _, kind := range []string{"stable", "wrong-session", "replaced-transcript", "final-metadata", "binding-revision"} {
		t.Run(kind, func(t *testing.T) {
			f := claudePane(t)
			binding := f.claudeBinding(nil)
			path := binding["transcript_path"].(string)
			host := f.host()
			before := host.Binding
			calls := 0
			host.Binding = func(pane, session string) ([]byte, error) {
				calls++
				if kind == "binding-revision" && calls == 2 {
					changed := map[string]any{}
					for k, v := range binding {
						changed[k] = v
					}
					changed["revision"] = strings.Repeat("e", 64)
					return json.Marshal(changed)
				}
				return before(pane, session)
			}
			changed := false
			host.beforeSocketCheck = func(string) {
				if changed {
					return
				}
				changed = true
				switch kind {
				case "replaced-transcript":
					data, e := os.ReadFile(path)
					if e != nil {
						t.Error(e)
					}
					if e := os.WriteFile(path+".new", data, 0600); e != nil {
						t.Error(e)
					}
					if e := os.Rename(path+".new", path); e != nil {
						t.Error(e)
					}
				case "final-metadata":
					if e := os.WriteFile(path, []byte(`{"type":"user","sessionId":"`+sessionB+`","message":{"content":"changed"}}`+"\n"), 0600); e != nil {
						t.Error(e)
					}
				}
			}
			if kind == "wrong-session" {
				binding["session_id"] = sessionB
				f.write("fix/binding.json", binding)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			r := &runner{ctx: ctx, host: host, proc: defaultSource(), uid: int64(os.Getuid()), random: urandom}
			r.home = host.home(r.uid)
			r.cwd, _ = os.Getwd()
			endpoint, e := r.discover(f.pane, "")
			if kind == "stable" {
				st, se := pyStat(path)
				if e != nil || se != nil || endpoint["transcriptIdentity"] != devIno(st) || calls != 2 {
					t.Fatal("stable exact transcript/binding fence changed", endpoint, e, se, calls)
				}
				return
			}
			want := map[string]string{"wrong-session": "does not identify", "replaced-transcript": "incarnation changed", "final-metadata": "session changed", "binding-revision": "binding changed"}[kind]
			if e == nil || !strings.Contains(e.Error(), want) {
				t.Fatal("transcript fence lost", kind, endpoint, e)
			}
			if kind == "wrong-session" && changed {
				t.Fatal("wrong initial session reached socket discovery")
			}
		})
	}
}

// The complete expected result and send frames were captured while running the
// original Python assertions unchanged. Only the receiver fixture's thread ID
// and authentication token are instantiated; source claims and content stay exact.
func TestOriginalProvenanceModeAndQuestionAssertions(t *testing.T) {
	data, e := os.ReadFile("testdata/provenance-original.json")
	if e != nil {
		t.Fatal(e)
	}
	var rows []struct {
		Test      string
		Endpoint  map[string]any
		Packet    json.RawMessage
		Result    map[string]any
		Recipient string
		Frames    []map[string]any
		Method    string
		Args      map[string]any
	}
	if e = json.Unmarshal(data, &rows); e != nil || len(rows) != 47 {
		t.Fatal("original 47-call corpus changed", len(rows), e)
	}
	for index, row := range rows {
		t.Run(fmt.Sprintf("%s/%02d", row.Test, index), func(t *testing.T) {
			claude := row.Endpoint["transport"] == "native_peer_socket"
			var f *fixture
			if claude {
				f = claudePane(t)
			} else {
				f = codexPane(t, codexConfig{Loaded: [][]any{{threadA}}, Turn: map[string]any{"id": row.Result["provider_turn_id"]}})
				f.codexBinding(nil)
			}
			host := f.host()
			host.InboundClass = func(int, string) (string, string) { return row.Recipient, "" }
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			r := &runner{ctx: ctx, host: host, proc: defaultSource(), uid: int64(os.Getuid()), random: urandom}
			r.home = host.home(r.uid)
			r.cwd, _ = os.Getwd()
			discoveryPacket, err := loadsBytes(request(discover()))
			if err != nil {
				t.Fatal(err)
			}
			endpointResult, err := r.run(f.pane, discoveryPacket)
			if err != nil {
				t.Fatal(err)
			}
			endpoint, ok := endpointResult["endpoint"].(map[string]any)
			if !ok {
				t.Fatal("fixture endpoint unavailable", endpointResult)
			}
			f.clearRecords()
			packet, e := loadsBytes(row.Packet)
			if e != nil {
				t.Fatal(e)
			}
			result, e := r.deliver(endpoint, packet)
			if e != nil {
				t.Fatal(e)
			}
			if !reflect.DeepEqual(result, row.Result) {
				t.Fatalf("original result changed: got %#v want %#v", result, row.Result)
			}
			records := writes(f.settledRecords())
			if claude {
				if len(row.Frames) == 0 {
					if len(records) != 0 {
						t.Fatal("held sender wrote to provider", records)
					}
					return
				}
				if len(records) != 1 {
					t.Fatal("native delivery count changed", len(records))
				}
				var frames []map[string]any
				for _, line := range strings.Split(strings.TrimSpace(records[0]), "\n") {
					var v map[string]any
					if e := json.Unmarshal([]byte(line), &v); e != nil {
						t.Fatal(e)
					}
					frames = append(frames, v)
				}
				row.Frames[0]["token"] = "token-0123456789abcdef"
				if !reflect.DeepEqual(frames, row.Frames) {
					t.Fatalf("original complete Claude frames changed\ngot %#v\nwant %#v", frames, row.Frames)
				}
			} else {
				if len(records) != 1 {
					t.Fatal("Codex delivery count changed", len(records))
				}
				turns := 0
				for _, line := range strings.Split(records[0], "\n") {
					var v map[string]any
					if json.Unmarshal([]byte(strings.TrimPrefix(line, "FRAME fin=1 opcode=1 ")), &v) != nil || v["method"] != "turn/start" {
						continue
					}
					turns++
					row.Args["threadId"] = threadA
					if v["method"] != row.Method || !reflect.DeepEqual(v["params"], row.Args) {
						t.Fatalf("original complete Codex arguments changed\ngot %#v\nwant %#v", v, row.Args)
					}
				}
				if turns != 1 {
					t.Fatal("Codex turn replayed or missing", turns)
				}
			}
		})
	}
}

func TestOriginalSenderHoldParityTable(t *testing.T) {
	for _, c := range []struct{ recipient, sender, want string }{{"bypass", "", "no_mode_asserted"}, {"prompting", "", ""}, {"bypass", "prompting", "mode_mismatch"}, {"prompting", "bypass", "mode_mismatch"}, {"bypass", "bypass", ""}, {"prompting", "prompting", ""}, {"", "", ""}, {"", "bypass", ""}} {
		if got := expectedHold(c.recipient, c.sender); got != c.want {
			t.Fatalf("hold parity for %q/%q: %q want %q", c.recipient, c.sender, got, c.want)
		}
	}
}

func TestOriginalRecipientClassUsesExactHostAndRechecksIncarnation(t *testing.T) {
	f := claudePane(t)
	host := f.host()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	r := &runner{ctx: ctx, host: host, proc: defaultSource(), uid: int64(os.Getuid()), random: urandom}
	r.home = host.home(r.uid)
	r.cwd, _ = os.Getwd()
	packet, e := loadsBytes(request(discover()))
	if e != nil {
		t.Fatal(e)
	}
	result, e := r.run(f.pane, packet)
	if e != nil {
		t.Fatal(e)
	}
	endpoint := result["endpoint"].(map[string]any)
	for _, mode := range []string{"bypass", "prompting", "", "not json"} {
		calls := 0
		r.host.InboundClass = func(pid int, session string) (string, string) {
			calls++
			if int64(pid) != endpoint["socketPID"] || session != endpoint["sessionID"] {
				t.Error("recipient callback lost exact process/session", pid, session)
			}
			return mode, ""
		}
		got, e := r.recipientInboundClass(endpoint)
		want := mode
		if mode == "not json" {
			want = ""
		}
		if e != nil || got != want || calls != 1 {
			t.Fatal("recipient class changed", got, e, calls)
		}
	}
	r.host.InboundClass = func(int, string) (string, string) { return "bypass", "" }
	original := endpoint["socketStart"]
	endpoint["socketStart"] = "changed"
	if _, e := r.recipientInboundClass(endpoint); e == nil || !strings.Contains(e.Error(), "process changed") {
		t.Fatal("recipient incarnation was not rechecked", e)
	}
	endpoint["socketStart"] = original
	r.host.InboundClass = func(int, string) (string, string) { panic("fixture callback failure") }
	if got, e := r.recipientInboundClass(endpoint); e != nil || got != "" {
		t.Fatal("failed callback fabricated a mode", got, e)
	}
	r.host.InboundClass = nil
	if got, e := r.recipientInboundClass(endpoint); e != nil || got != "" {
		t.Fatal("absent callback fabricated a mode", got, e)
	}
}

func TestOriginalAssistantAppRunAndPaneClaimsAreRefused(t *testing.T) {
	source := map[string]any{"authentication": "relay_assistant_owner_submitted", "principal": "relay-assistant", "assistantRequestID": "req123", "replyPaneID": "a5515700-0000-4000-8000-00000000b0c5", "hostID": "node-1"}
	for _, label := range []string{"relay_app_signed", "relay_app_assistant_attested"} {
		source["authentication"] = label
		if got, e := relayAssistant(source); got != nil || e != nil {
			t.Fatal("app authentication was overstated", got, e)
		}
	}
	source["authentication"] = "relay_assistant_owner_submitted"
	if got, e := relayAssistant(source); got == nil || e != nil {
		t.Fatal("valid owner principal refused", got, e)
	}
	for claim, value := range map[string]string{"approval": "user_run_card", "keyFingerprint": strings.Repeat("ab", 32), "paneID": "claimed", "sessionID": "s"} {
		claimed := map[string]any{}
		for k, v := range source {
			claimed[k] = v
		}
		claimed[claim] = value
		if got, e := relayAssistant(claimed); got != nil || e != nil {
			t.Fatal("unverified extra claim admitted", claim, got, e)
		}
	}
	source["paneID"] = "claimed"
	source["sessionID"] = "s"
	if got, e := verifiedSender(source); got != nil || e != nil {
		t.Fatal("assistant became verified pane", got, e)
	}
}

func retirementRunner(t *testing.T, f *fixture) *runner {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	host := f.host()
	r := &runner{ctx: ctx, host: host, proc: defaultSource(), uid: int64(os.Getuid()), random: urandom}
	r.home = host.home(r.uid)
	r.cwd, _ = os.Getwd()
	return r
}
func TestOriginalParkedPublicationFieldGuards(t *testing.T) {
	for key, value := range map[string]any{"jobId": "aaaaaaaa", "sessionId": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "kind": "interactive", "procStart": "stale"} {
		t.Run(key, func(t *testing.T) {
			f, binding := parkedPane(t)
			r := retirementRunner(t, f)
			overrides := map[string]any{"kind": "bg", "jobId": "abcdef12"}
			overrides[key] = value
			f.claudeSession("job", sessionB, f.path("s/j.sock"), overrides)
			if _, e := r.parkedClaudePeer(binding); e == nil || !strings.Contains(e.Error(), "publication changed") {
				t.Fatal("invalid parked publication admitted", key, e)
			}
		})
	}
}
func TestOriginalNativeInboxRequiresExactPIDAndUID(t *testing.T) {
	f, _ := parkedPane(t)
	r := retirementRunner(t, f)
	address := f.path("s/j.sock")
	pid := int64(f.pids["job"])
	if e := r.checkInboxOwner(address, address, pid, time.Second, "kernel owner mismatch"); e != nil {
		t.Fatal(e)
	}
	if e := r.checkInboxOwner(address, address, pid+1, time.Second, "kernel owner mismatch"); e == nil || !strings.Contains(e.Error(), "kernel owner mismatch") {
		t.Fatal("foreign kernel PID admitted", e)
	}
	r.uid++
	if e := r.checkInboxOwner(address, address, pid, time.Second, "kernel owner mismatch"); e == nil || !strings.Contains(e.Error(), "kernel owner mismatch") {
		t.Fatal("foreign kernel UID admitted", e)
	}
}
func TestOriginalParkedAuthenticationRechecksForegroundJob(t *testing.T) {
	f, _ := parkedPane(t)
	r := retirementRunner(t, f)
	endpoint, e := r.discover(f.pane, "")
	if e != nil {
		t.Fatal(e)
	}
	if yes, e := r.authenticateNativePeer(endpoint); !yes || e != nil {
		t.Fatal("detached parked job rejected", yes, e)
	}
	f.claudeSession("claude", sessionA, f.path("s/c.sock"), map[string]any{"parkedJobId": "aaaaaaaa"})
	if yes, e := r.authenticateNativePeer(endpoint); yes || e == nil || !strings.Contains(e.Error(), "foreground publication changed") {
		t.Fatal("changed foreground job admitted", yes, e)
	}
}
func TestOriginalTargetAndDefaultBindingScopes(t *testing.T) {
	for _, kind := range []string{"target", "default", "missing", "wrong-source", "wrong-session"} {
		t.Run(kind, func(t *testing.T) {
			f, binding := parkedPane(t)
			r := retirementRunner(t, f)
			target := sessionB
			if kind == "default" {
				target = ""
			} else {
				binding["source"] = "native_pane_job_kernel_owner"
			}
			if kind == "wrong-source" {
				binding["source"] = "native_parked_job_kernel_owner"
			}
			if kind == "wrong-session" {
				binding["session_id"] = sessionA
			}
			calls := 0
			r.host.Binding = func(pane, session string) ([]byte, error) {
				calls++
				if pane != f.pane || session != target {
					t.Error("binding lost exact pane/session", pane, session, target)
				}
				if kind == "missing" {
					return nil, os.ErrNotExist
				}
				return json.Marshal(binding)
			}
			endpoint, e := r.discover(f.pane, target)
			if kind == "target" || kind == "default" {
				if e != nil || endpoint["sessionID"] != sessionB || endpoint["socketPID"] != int64(f.pids["job"]) || endpoint["transport"] != "native_peer_socket" || endpoint["bindingSource"] != binding["source"] {
					t.Fatal("exact scoped endpoint lost", endpoint, e)
				}
			} else {
				if e == nil || endpoint != nil || !strings.Contains(strings.ToLower(e.Error()), "target session") {
					t.Fatal("invalid target proof admitted", endpoint, e)
				}
				if calls != 1 {
					t.Fatal("invalid target repeated binding", calls)
				}
			}
			if calls == 0 {
				t.Fatal("scoped binding not checked")
			}
		})
	}
}
func TestOriginalCodexMissingStockProofIsRefused(t *testing.T) {
	f := codexPane(t, codexConfig{})
	binding := f.stockProxy(nil)
	delete(binding, "stock_proxy")
	f.write("fix/binding.json", binding)
	r := retirementRunner(t, f)
	if endpoint, e := r.discover(f.pane, ""); e == nil || endpoint != nil || !strings.Contains(e.Error(), "live identity proof") {
		t.Fatal("missing stock proof admitted", endpoint, e)
	}
}

func TestOriginalUnwrittenStockDiscoveryUsesOnlyConfirmedBackend(t *testing.T) {
	f := codexPane(t, codexConfig{Loaded: [][]any{{threadA}}, Thread: map[string]any{"id": threadA, "path": "/not-written"}})
	f.stockProxy(map[string]any{"transcript_path": ""})
	r := retirementRunner(t, f)
	f.clearRecords()
	endpoint, e := r.discover(f.pane, "")
	if e != nil || endpoint["transport"] != "codex_app_server_message" || endpoint["socketPID"] != int64(f.pids["codex"]) || endpoint["transcriptIdentity"] != "" {
		t.Fatal("unwritten stock endpoint fabricated history or changed daemon", endpoint, e)
	}
	var methods []string
	for _, raw := range f.settledRecords() {
		for _, line := range strings.Split(raw, "\n") {
			var value map[string]any
			if json.Unmarshal([]byte(strings.TrimPrefix(line, "FRAME fin=1 opcode=1 ")), &value) == nil {
				if method, ok := value["method"].(string); ok {
					methods = append(methods, method)
				}
			}
		}
	}
	if !reflect.DeepEqual(methods, []string{"initialize", "initialized", "thread/loaded/list", "thread/read"}) {
		t.Fatal("stock discovery changed read-only RPCs", methods)
	}
}
