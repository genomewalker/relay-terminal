package daemon

import "testing"

// A parked or addressed background job runs the sending conversation in its
// own process: its class is read there, never from the frontend or a request.
func TestCommunicationSenderClassReadsTheConversationProcess(t *testing.T) {
	for _, tc := range []struct {
		name     string
		endpoint map[string]any
		want     int
	}{
		{"frontend", map[string]any{"transport": "native_peer_socket", "socketPID": float64(5150)}, 4242},
		{"parked job", map[string]any{"bindingSource": "native_parked_job_kernel_owner", "socketPID": float64(5150)}, 5150},
		{"addressed job", map[string]any{"bindingSource": "native_pane_job_kernel_owner", "socketPID": float64(5150)}, 5150},
		{"parked job without a process", map[string]any{"bindingSource": "native_parked_job_kernel_owner"}, 4242},
		{"parked job with a bogus process", map[string]any{"bindingSource": "native_parked_job_kernel_owner", "socketPID": 1.5}, 4242},
	} {
		calls := withSenderPermissionClass(t, "bypass")
		member := sourceFixture("native_peer_socket")
		member.Endpoint = tc.endpoint
		if got := communicationSenderClass(member); got != "bypass" || len(*calls) != 1 || (*calls)[0] != tc.want {
			t.Errorf("%s: class %q from %v, want pid %d", tc.name, got, *calls, tc.want)
		}
	}
	withSenderPermissionClass(t, "everything")
	if got := communicationSenderClass(sourceFixture("native_peer_socket")); got != "" {
		t.Fatalf("an unrecognised class was asserted: %q", got)
	}
}

// The attestation and the kernel-verified packet both use that class.
func TestCommunicationAttestationCarriesTheJobProcessClass(t *testing.T) {
	calls := withSenderPermissionClass(t, "bypass")
	f := newAttestFixture(t)
	f.member.Endpoint = map[string]any{"bindingSource": "native_parked_job_kernel_owner", "socketPID": float64(5150),
		"transport": "native_peer_socket"}
	result, err := communicationAttestConsume(f.root, consumeRequest(f.mint(t)), f.deps)
	if err != nil {
		t.Fatal(err)
	}
	if result["source"].(map[string]any)["permissionClass"] != "bypass" {
		t.Fatalf("class not carried: %v", result)
	}
	for _, pid := range *calls {
		if pid != 5150 {
			t.Fatalf("class read from pid %d, not the job process", pid)
		}
	}
	packet := communicationSourcePacket(verifiedSendFixture(), "node-1", f.member)
	if packet["permissionClass"] != "bypass" {
		t.Fatalf("verified packet lacks the job class: %v", packet)
	}
}

func TestCommunicationNativeOutcomeKeepsTheExpectedHold(t *testing.T) {
	result := communicationNativeOutcome(map[string]any{"status": "not_sent", "reason": "held_expected",
		"held_expected": "no_mode_asserted", "recipient_mode": "bypass", "sender_mode": "unasserted"}, nil)
	if result["status"] != "not_sent" || result["held_expected"] != "no_mode_asserted" ||
		result["recipient_mode"] != "bypass" || result["sender_mode"] != "unasserted" {
		t.Fatalf("receipt lost the expected hold: %v", result)
	}
}
