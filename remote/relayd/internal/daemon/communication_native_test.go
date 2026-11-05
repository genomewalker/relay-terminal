package daemon

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/relay-terminal/relayd/internal/nativemsg"
)

const adapterTestPane = "7d85fd72-64ec-46a4-8591-567bf64f7c93"

func useNativeRun(t *testing.T, run func(context.Context, nativemsg.Host, string, []byte) map[string]any) {
	t.Helper()
	saved := communicationNativeRun
	communicationNativeRun = run
	t.Cleanup(func() { communicationNativeRun = saved })
}

func TestCommunicationAdapterRunsInProcessWithAnAuthenticatedBinding(t *testing.T) {
	var pane string
	var request map[string]any
	useNativeRun(t, func(_ context.Context, host nativemsg.Host, p string, data []byte) map[string]any {
		pane = p
		if err := json.Unmarshal(data, &request); err != nil {
			t.Errorf("request is not JSON: %v", err)
		}
		if host.Binding == nil || host.InboundClass == nil {
			t.Errorf("adapter host lacks relayd's readers")
		}
		return map[string]any{"endpoint": map[string]any{"pid": int64(4242), "transport": "native_peer_socket"}}
	})
	result, err := communicationNative(adapterTestPane, map[string]any{"operation": "discover", "targetSessionID": "s"})
	if err != nil {
		t.Fatalf("adapter failed: %v", err)
	}
	if pane != adapterTestPane || request["requireAuthenticatedBinding"] != true || request["operation"] != "discover" || request["targetSessionID"] != "s" {
		t.Fatalf("adapter got pane %q request %v", pane, request)
	}
	// Callers read numbers as JSON numbers, as they read the adapter's output.
	endpoint, _ := result["endpoint"].(map[string]any)
	if endpoint["pid"] != float64(4242) || endpoint["transport"] != "native_peer_socket" {
		t.Fatalf("adapter result = %#v", result)
	}
}

func TestCommunicationAdapterRefusesAnInvalidPane(t *testing.T) {
	useNativeRun(t, func(context.Context, nativemsg.Host, string, []byte) map[string]any {
		t.Error("adapter ran for an invalid pane")
		return nil
	})
	if _, err := communicationNative("../pane", map[string]any{"operation": "discover"}); err == nil || err.Error() != "invalid native pane" {
		t.Fatalf("invalid pane error = %v", err)
	}
}

func TestCommunicationAdapterCapsItsResponse(t *testing.T) {
	useNativeRun(t, func(context.Context, nativemsg.Host, string, []byte) map[string]any {
		return map[string]any{"status": "unavailable", "error": strings.Repeat("x", 128<<10)}
	})
	if _, err := communicationNative(adapterTestPane, map[string]any{"operation": "discover"}); err == nil || err.Error() != "native communication response exceeds limit" {
		t.Fatalf("oversized response error = %v", err)
	}
}

func TestASlowAdapterNamesThePaneAndTheRealReason(t *testing.T) {
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	useNativeRun(t, func(ctx context.Context, _ nativemsg.Host, _ string, _ []byte) map[string]any {
		<-release
		return map[string]any{"endpoint": map[string]any{"transport": "late"}}
	})
	saved := communicationAdapterTimeout
	communicationAdapterTimeout = 200 * time.Millisecond
	t.Cleanup(func() { communicationAdapterTimeout = saved })

	recipient := communicationObserve(adapterTestPane)
	if recipient.Endpoint != nil || !strings.Contains(recipient.Unavailable, "native communication adapter failed") {
		t.Fatalf("slow adapter observed as %+v", recipient)
	}
	source := communicationMember{PaneID: "b93f5a99-ca0d-4c6d-9cf0-8e08a1cd23fc", Endpoint: map[string]any{}}
	err := communicationUnverifiedEndpoint("a pane has no verified native communication endpoint", source, recipient)
	want := "a pane has no verified native communication endpoint: pane " + adapterTestPane + ": native communication adapter failed: signal: killed"
	if err.Error() != want {
		t.Fatalf("refusal = %q, want %q", err, want)
	}
}

func TestTheAdapterReadsATargetSessionsOwnBinding(t *testing.T) {
	// A named target never falls back to the pane's default binding.
	_, err := communicationNativeHost().Binding(adapterTestPane, "not-a-session")
	if err == nil || err.Error() != "invalid target session" {
		t.Fatalf("target binding error = %v", err)
	}
}

func TestTheUnverifiedEndpointErrorBlamesTheFailingPane(t *testing.T) {
	const prefix = "a pane has no verified native communication endpoint"
	source := communicationMember{PaneID: "source-pane", Unavailable: "exited"}
	recipient := communicationMember{PaneID: "recipient-pane", Endpoint: map[string]any{}, Unavailable: "provider has no verified messaging endpoint"}
	cases := []struct {
		source, recipient communicationMember
		want              string
	}{
		{source, recipient, prefix + ": pane source-pane: exited"},
		{communicationMember{PaneID: "source-pane", Endpoint: map[string]any{}}, recipient, prefix + ": pane recipient-pane: provider has no verified messaging endpoint"},
		{communicationMember{}, communicationMember{PaneID: "silent-pane"}, prefix + ": pane silent-pane: no endpoint was reported"},
	}
	for _, c := range cases {
		if got := communicationUnverifiedEndpoint(prefix, c.source, c.recipient).Error(); got != c.want {
			t.Fatalf("got %q, want %q", got, c.want)
		}
	}
	long := communicationMember{PaneID: "long-pane", Unavailable: strings.Repeat("x", 4096)}
	if got := communicationUnverifiedEndpoint(prefix, communicationMember{}, long).Error(); len(got) != len(prefix+": pane long-pane: ")+512 {
		t.Fatalf("reason not capped: %d bytes", len(got))
	}
}
