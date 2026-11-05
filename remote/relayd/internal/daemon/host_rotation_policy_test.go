package daemon

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type hostRotationPolicyGolden struct {
	Cases []struct {
		Name     string  `json:"name"`
		NowMS    int64   `json:"now_ms"`
		Input    string  `json:"input"`
		ExitCode int     `json:"exit_code"`
		Stdout   *string `json:"stdout"`
	} `json:"cases"`
}

func loadHostRotationPolicyGolden(t *testing.T) hostRotationPolicyGolden {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "host_rotation_policy", "golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var golden hostRotationPolicyGolden
	if err := json.Unmarshal(data, &golden); err != nil || len(golden.Cases) < 100 {
		t.Fatalf("invalid policy golden: %v", err)
	}
	return golden
}

// The frozen goldens are stdout of the former Python policy for the same stdin and
// --now-ms; the Go port must reproduce every byte and every failed exit.
func TestHostRotationPolicyMatchesPythonGoldens(t *testing.T) {
	for _, c := range loadHostRotationPolicyGolden(t).Cases {
		got, err := evaluateHostRotationPolicy([]byte(c.Input), c.NowMS)
		if c.ExitCode != 0 {
			if err == nil {
				t.Errorf("%s: Python exited %d but Go returned %s", c.Name, c.ExitCode, got)
			}
			continue
		}
		if err != nil || c.Stdout == nil {
			t.Errorf("%s: Go failed where Python succeeded: %v", c.Name, err)
			continue
		}
		if string(got) != *c.Stdout {
			t.Errorf("%s: output differs\n go: %s\npy: %s", c.Name, got, *c.Stdout)
		}
	}
}

func TestHostRotationStatusEvaluationUsesGoPolicyAndCancellation(t *testing.T) {
	t.Setenv("PATH", "")
	golden := loadHostRotationPolicyGolden(t)
	for _, c := range golden.Cases {
		if c.Name != "rotate_pressure" {
			continue
		}
		got, err := evaluateHostRotationStatus(context.Background(), json.RawMessage(c.Input), time.UnixMilli(c.NowMS))
		if err != nil || string(got) != *c.Stdout {
			t.Fatalf("status evaluation needs no interpreter: %v %s", err, got)
		}
		var decision hostRotationDecision
		if json.Unmarshal(got, &decision) != nil || decision.Decision != "rotate" || decision.Schedule == nil ||
			len(decision.Schedule.Fingerprint) != 64 {
			t.Fatalf("decision does not satisfy the supervisor contract: %s", got)
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if _, err := evaluateHostRotationStatus(ctx, json.RawMessage(c.Input), time.UnixMilli(c.NowMS)); err == nil {
			t.Fatal("cancelled evaluation returned a decision")
		}
		return
	}
	t.Fatal("rotate_pressure golden missing")
}
