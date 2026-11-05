package rotationtext

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func safetySecuritySettings(updates obj) obj {
	return mergeSafety(obj{"enabled": true, "providers": []any{"anthropic_api"}, "daily_limit_microusd": int64(5_000_000), "monthly_limit_microusd": int64(10_000_000), "max_requests_per_day": int64(10)}, updates)
}
func safetySubmit(n int, evidence string) obj {
	return obj{"v": int64(1), "operation_id": safetyID(n), "binding": obj{"session_id": "session-1", "client": "claude", "turn_seq": int64(n)}, "evidence": evidence}
}
func safetySuccess(req obj) obj {
	return obj{"v": int64(1), "operation_id": req["operation_id"], "status": "draft", "provider": "anthropic_api", "model": apiModel, "binding": req["binding"], "draft": validDraft(), "source_sha256": sha256Hex(req["evidence"].(string)), "usage": obj{"input_tokens": int64(1000), "output_tokens": int64(200)}}
}
func safetySecurityJournal(t *testing.T) (*Journal, string, *int) {
	t.Helper()
	root := newLedgerRoot(t)
	j, err := OpenLedgerJournal(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { j.Close() })
	calls := new(int)
	j.backend = func(_ context.Context, req obj) any {
		*calls++
		other, err := OpenLedgerJournal(context.Background(), root)
		if err != nil {
			t.Fatal(err)
		}
		defer other.Close()
		safetyEq(t, other.Status(req["operation_id"])["status"], "pending")
		safetyEq(t, other.Status(nil)["charged_today_microusd"], apiReservationMicroUSD)
		return safetySuccess(req)
	}
	return j, root, calls
}
func safetyConfigure(j *Journal, updates obj) obj {
	return j.Configure(strings.Repeat("a", 32), safetySecuritySettings(updates), nil)
}

func TestLegacyTextSecurity(t *testing.T) {
	ctx := context.Background()
	t.Run("test_disabled_and_no_secret_settings", func(t *testing.T) {
		j, _, calls := safetySecurityJournal(t)
		safetyCode(t, "text_backend_disabled", func() { j.Submit(ctx, safetySubmit(1, "User asked for a factual capsule.")) })
		safetyCode(t, "invalid_settings", func() { safetyConfigure(j, obj{"api_key": "do-not-store"}) })
		safetyEq(t, *calls, 0)
	})
	t.Run("test_durable_reservation_settlement_and_replay", func(t *testing.T) {
		j, _, calls := safetySecurityJournal(t)
		safetyConfigure(j, nil)
		req := safetySubmit(1, "User asked for a factual capsule.")
		r := j.Submit(ctx, req)
		safetyEq(t, r["status"], "complete")
		safetyEq(t, r["charged_microusd"], 200)
		safetyEq(t, j.Submit(ctx, req), r)
		safetyEq(t, *calls, 1)
		safetyCode(t, "operation_identity_conflict", func() { j.Submit(ctx, safetySubmit(1, "Changed evidence")) })
		duplicate := clone(req).(obj)
		duplicate["operation_id"] = strings.Repeat("b", 32)
		safetyCode(t, "operation_identity_conflict", func() { j.Submit(ctx, duplicate) })
	})
	t.Run("test_config_replay_never_reverts_later_setting", func(t *testing.T) {
		j, _, _ := safetySecurityJournal(t)
		safetyConfigure(j, nil)
		j.Configure(strings.Repeat("b", 32), safetySecuritySettings(obj{"enabled": false}), nil)
		safetyConfigure(j, nil)
		safetyEq(t, j.Status(nil)["settings"].(obj)["enabled"], false)
		safetyCode(t, "operation_identity_conflict", func() { safetyConfigure(j, obj{"max_requests_per_day": int64(1)}) })
	})
	t.Run("test_configuration_receipt_tracks_current_saved_settings", func(t *testing.T) {
		j, root, calls := safetySecurityJournal(t)
		safetyEq(t, j.Status(nil)["configuration_id"], "")
		safetyEq(t, safetyConfigure(j, nil)["configuration_id"], strings.Repeat("a", 32))
		other, err := OpenLedgerJournal(ctx, root)
		if err != nil {
			t.Fatal(err)
		}
		defer other.Close()
		safetyEq(t, other.Status(nil)["configuration_id"], strings.Repeat("a", 32))
		settings := safetySecuritySettings(obj{"enabled": false, "providers": []any{"codex_account", "claude_account"}, "codex_model": "fixture-model", "claude_path": "/owned/claude"})
		current := other.Configure(strings.Repeat("b", 32), settings, nil)
		safetyEq(t, current["configuration_id"], strings.Repeat("b", 32))
		replay := safetyConfigure(j, nil)
		safetyEq(t, replay["configuration_id"], strings.Repeat("b", 32))
		safetyEq(t, replay["settings"], settings)
		safetyEq(t, *calls, 0)
	})
	t.Run("test_uncertain_blocks_then_abandon_keeps_charge", func(t *testing.T) {
		j, _, _ := safetySecurityJournal(t)
		safetyConfigure(j, nil)
		j.backend = func(_ context.Context, r obj) any {
			return obj{"v": int64(1), "operation_id": r["operation_id"], "status": "failed", "code": "request_outcome_unknown"}
		}
		req := safetySubmit(1, "User asked for a factual capsule.")
		safetyEq(t, j.Submit(ctx, req)["status"], "uncertain")
		safetyCode(t, "reconciliation_required", func() { j.Submit(ctx, safetySubmit(2, "User asked for a factual capsule.")) })
		j.Abandon(req["operation_id"])
		safetyEq(t, j.Submit(ctx, req)["status"], "abandoned")
		safetyEq(t, j.Status(nil)["charged_today_microusd"], apiReservationMicroUSD)
	})
	t.Run("test_limits_persist_across_connections", func(t *testing.T) {
		j, root, _ := safetySecurityJournal(t)
		safetyConfigure(j, obj{"max_requests_per_day": int64(1)})
		j.Submit(ctx, safetySubmit(1, "User asked for a factual capsule."))
		other, err := OpenLedgerJournal(ctx, root)
		if err != nil {
			t.Fatal(err)
		}
		defer other.Close()
		other.backend = func(context.Context, obj) any { t.Fatal("limit bypass"); return nil }
		safetyCode(t, "spending_limit", func() { other.Submit(ctx, safetySubmit(2, "User asked for a factual capsule.")) })
	})
	t.Run("test_spending_reservation_not_just_settled_amount", func(t *testing.T) {
		j, _, calls := safetySecurityJournal(t)
		safetyConfigure(j, obj{"daily_limit_microusd": int64(1_000_000)})
		j.Submit(ctx, safetySubmit(1, "User asked for a factual capsule."))
		safetyCode(t, "spending_limit", func() { j.Submit(ctx, safetySubmit(2, "User asked for a factual capsule.")) })
		safetyEq(t, *calls, 1)
	})
	t.Run("test_cross_connection_single_flight", func(t *testing.T) {
		j, root, _ := safetySecurityJournal(t)
		safetyConfigure(j, nil)
		entered, release := make(chan struct{}), make(chan struct{})
		var once sync.Once
		defer once.Do(func() { close(release) })
		done := make(chan any, 1)
		go func() {
			defer func() {
				if p := recover(); p != nil {
					done <- p
				}
			}()
			other, err := OpenLedgerJournal(ctx, root)
			if err != nil {
				done <- err
				return
			}
			defer other.Close()
			other.backend = func(_ context.Context, req obj) any {
				close(entered)
				select {
				case <-release:
				case <-time.After(3 * time.Second):
					return obj{"status": "failed", "code": "request_outcome_unknown"}
				}
				return safetySuccess(req)
			}
			done <- other.Submit(ctx, safetySubmit(1, "User asked for a factual capsule."))
		}()
		select {
		case <-entered:
		case <-time.After(3 * time.Second):
			t.Fatal("single-flight worker did not enter")
		}
		safetyCode(t, "reconciliation_required", func() { j.Submit(ctx, safetySubmit(2, "User asked for a factual capsule.")) })
		once.Do(func() { close(release) })
		select {
		case r := <-done:
			value, ok := r.(obj)
			if !ok {
				t.Fatalf("worker failed: %v", r)
			}
			safetyEq(t, value["status"], "complete")
		case <-time.After(3 * time.Second):
			t.Fatal("single-flight worker did not finish")
		}
	})
	t.Run("test_private_files_and_no_evidence_persistence", func(t *testing.T) {
		j, root, _ := safetySecurityJournal(t)
		safetyConfigure(j, nil)
		marker := "original transcript marker 987654321"
		j.Submit(ctx, safetySubmit(1, marker))
		info, err := os.Stat(root)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0700 {
			t.Fatal("journal root not private")
		}
		info, err = os.Stat(filepath.Join(root, ledgerLogName))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0600 {
			t.Fatal("journal log not private")
		}
		entries, err := os.ReadDir(root)
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			raw, err := os.ReadFile(filepath.Join(root, entry.Name()))
			if err != nil {
				t.Fatal(err)
			}
			if bytes.Contains(raw, []byte(marker)) {
				t.Fatal("source evidence persisted")
			}
		}
		shared := filepath.Join(t.TempDir(), "shared")
		if err := os.Mkdir(shared, 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(shared, 0755); err != nil {
			t.Fatal(err)
		}
		safetyJournalOpenCode(t, shared, "journal_permissions")
		linked := filepath.Join(t.TempDir(), "linked")
		if err := os.Mkdir(linked, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(root, ledgerLogName), filepath.Join(linked, ledgerLogName)); err != nil {
			t.Fatal(err)
		}
		safetyJournalOpenCode(t, linked, "journal_permissions")
	})
	t.Run("test_config_injection_and_invalid_input", func(t *testing.T) {
		j, _, calls := safetySecurityJournal(t)
		safetyConfigure(j, nil)
		bad := safetySubmit(1, "User asked for a factual capsule.")
		bad["config"] = obj{"claude_path": "/untrusted/executable"}
		safetyCode(t, "invalid_request", func() { j.Submit(ctx, bad) })
		safetyCode(t, "invalid_evidence", func() { j.Submit(ctx, safetySubmit(1, strings.Repeat("x", maxSource+1))) })
		safetyEq(t, *calls, 0)
	})
	t.Run("test_redaction_and_no_fallback_after_submission", func(t *testing.T) {
		secret := "sk-ant-test-abcdefghijklmnopqrstuvwxyz"
		t.Setenv("ANTHROPIC_API_KEY", secret)
		source := "api_key=" + secret + " password=verysecretvalue Keep the goal."
		clean, count := redactEvidence(source)
		if strings.Contains(clean, secret) || strings.Contains(clean, "verysecretvalue") || !strings.Contains(clean, "Keep the goal.") || count < 2 {
			t.Fatal("evidence redaction changed")
		}
		old := apiPostHook
		defer func() { apiPostHook = old }()
		calls := 0
		apiPostHook = func([]byte, string, time.Duration) []byte { calls++; fail("api_http_429"); return nil }
		marker := filepath.Join(t.TempDir(), "fallback")
		cli := filepath.Join(t.TempDir(), "claude")
		writeScript(t, cli, "#!/bin/sh\nprintf started > '"+marker+"'\nexit 1\n")
		req := safetySubmit(1, source)
		req["config"] = obj{"providers": []any{"anthropic_api", "claude_account"}, "claude_path": cli}
		result := Draft(ctx, req).(obj)
		safetyEq(t, result["code"], "api_http_429")
		safetyEq(t, calls, 1)
		if strings.Contains(compact(result), secret) {
			t.Fatal("error echoed credential")
		}
		if _, err := os.Stat(marker); !os.IsNotExist(err) {
			t.Fatal("fallback after started API submission")
		}
	})
	t.Run("test_account_environment_and_flags", func(t *testing.T) {
		record := filepath.Join(t.TempDir(), "record")
		cli := safetyHelperScript(t, "account", record)
		t.Setenv("HOME", t.TempDir())
		t.Setenv("ANTHROPIC_API_KEY", "secret-api-value")
		t.Setenv("OPENAI_API_KEY", "other-api-value")
		accountDraft(ctx, "claude_account", "public evidence", obj{"claude_path": cli})
		raw, err := os.ReadFile(record)
		if err != nil {
			t.Fatal(err)
		}
		captured := parseJSON(raw).(obj)
		argv := captured["argv"].([]any)
		if !listContains(argv, "--safe-mode") || !listContains(argv, "--no-session-persistence") {
			t.Fatal("account isolation flags missing")
		}
		tools := -1
		for n, v := range argv {
			if v == "--tools" {
				tools = n
			}
		}
		if tools < 0 || tools+1 >= len(argv) || argv[tools+1] != "" {
			t.Fatal("account tools not disabled")
		}
		env := captured["env"].(obj)
		if _, ok := env["ANTHROPIC_API_KEY"]; ok {
			t.Fatal("provider key leaked to CLI")
		}
		if _, ok := env["OPENAI_API_KEY"]; ok {
			t.Fatal("provider key leaked to CLI")
		}
	})
	t.Run("test_redirect_and_bad_response_are_not_followed_or_echoed", func(t *testing.T) {
		old := apiPostHook
		apiPostHook = nil
		defer func() { apiPostHook = old }()
		var calls atomic.Int32
		withAPIServer(t, func(w http.ResponseWriter, r *http.Request) {
			calls.Add(1)
			if r.URL.Path != "/v1/messages" {
				t.Error("redirect followed")
			}
			w.Header().Set("Location", "https://example.invalid/never")
			w.Header().Set("Content-Length", "32")
			w.WriteHeader(302)
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		}, nil)
		requestContext, cancel := context.WithCancel(ctx)
		defer cancel()
		done := make(chan string, 1)
		go func() {
			_, e := catchDraft(func() []byte { return apiPost(requestContext, []byte("{}"), "never-log-this-key", 60*time.Second) })
			code := ""
			if e != nil {
				code = e.code
			}
			done <- code
		}()
		select {
		case code := <-done:
			safetyEq(t, code, "api_http_302")
		case <-time.After(3 * time.Second):
			cancel()
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("redirect request failed to cancel")
			}
			t.Fatal("redirect body consumed before refusal")
		}
		safetyEq(t, int(calls.Load()), 1)
	})
	t.Run("test_source_and_embedded_security_policy_match", func(t *testing.T) { // Native health and standalone service use the same package, with no generated backend copy.
		root := newLedgerRoot(t)
		h, err := OpenHealthText(ctx, root)
		if err != nil {
			t.Fatal(err)
		}
		defer h.Close()
		h.journal.Configure(strings.Repeat("a", 32), safetySecuritySettings(nil), nil)
		a, err := h.Call(ctx, "status", []byte(`{"operation_id":null}`))
		if err != nil {
			t.Fatal(err)
		}
		b, err := RunOperation(ctx, func() (*Journal, error) { return OpenLedgerJournal(ctx, root) }, "status", []byte(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		safetyEq(t, parseJSON(a), parseJSON(b))
	})
}

func TestLegacyCredentialEnvironment(t *testing.T) {
	t.Run("test_private_bus_discovery_and_no_provider_environment", func(t *testing.T) {
		runtimeDir := safetyShortTemp(t)
		if err := os.Chmod(runtimeDir, 0700); err != nil {
			t.Fatal(err)
		}
		server, err := net.Listen("unix", filepath.Join(runtimeDir, "bus"))
		if err != nil {
			t.Fatal(err)
		}
		defer server.Close()
		t.Setenv("DBUS_SESSION_BUS_ADDRESS", "")
		t.Setenv("XDG_RUNTIME_DIR", runtimeDir)
		t.Setenv("ANTHROPIC_API_KEY", "FIXTURE_ONLY_MUST_NOT_BE_PASSED")
		safetyEq(t, verifiedUserBus(runtimeDir), "unix:path="+runtimeDir+"/bus")
		env := safetyEnvMap(credentialEnvironment())
		if runtime.GOOS == "linux" {
			safetyEq(t, env["DBUS_SESSION_BUS_ADDRESS"], "unix:path="+runtimeDir+"/bus")
		}
		if _, ok := env["ANTHROPIC_API_KEY"]; ok {
			t.Fatal("vault inherited provider environment")
		}
	})
	t.Run("test_public_or_symlink_runtime_cannot_supply_a_password_bus", func(t *testing.T) {
		runtimeDir := safetyShortTemp(t)
		server, err := net.Listen("unix", filepath.Join(runtimeDir, "bus"))
		if err != nil {
			t.Fatal(err)
		}
		defer server.Close()
		link := filepath.Join(t.TempDir(), "link")
		if err := os.Symlink(runtimeDir, link); err != nil {
			t.Fatal(err)
		}
		safetyEq(t, verifiedUserBus(link), "")
		if err := os.Chmod(runtimeDir, 0755); err != nil {
			t.Fatal(err)
		}
		safetyEq(t, verifiedUserBus(runtimeDir), "")
	})
	t.Run("test_explicit_bus_is_preserved_without_discovery", func(t *testing.T) {
		runtimeDir := safetyShortTemp(t)
		server, err := net.Listen("unix", filepath.Join(runtimeDir, "bus"))
		if err != nil {
			t.Fatal(err)
		}
		defer server.Close()
		t.Setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/explicit/owned/bus")
		t.Setenv("XDG_RUNTIME_DIR", runtimeDir)
		safetyEq(t, safetyEnvMap(credentialEnvironment())["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/explicit/owned/bus")
	})
}
func safetyEnvMap(env []string) obj {
	out := obj{}
	for _, v := range env {
		if k, value, ok := strings.Cut(v, "="); ok {
			out[k] = value
		}
	}
	return out
}

func safetyShortTemp(t *testing.T) string {
	t.Helper()
	d, e := os.MkdirTemp("/tmp", "rotation-vault-")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return d
}

func safetyJournalOpenCode(t *testing.T, root, want string) {
	t.Helper()
	l, err := OpenLedger(root)
	if err == nil {
		l.Close()
		t.Fatal("unsafe journal admitted")
	}
	coded, ok := err.(interface{ Code() string })
	if !ok || coded.Code() != want {
		t.Fatalf("journal refusal code changed: %v want %s", err, want)
	}
}
