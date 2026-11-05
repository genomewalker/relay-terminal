//go:build linux

package daemon

import (
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

// All eight complete outputs were captured from the original implementation
// on real disposable Linux process trees while the original comparisons passed.
// Only kernel/file identities and their digests vary between fixture runs.
//
//go:embed testdata/host_pane_health_probe/linux-live-reference.json
var phLiveReferenceData []byte

type phLiveReferenceInput struct {
	Name, Pane, Daemon, Boot, Session, ClaudePath, CodexPath string
	Live                                                     phLivePane
}

func phLiveReferenceSHA(t *testing.T, path string) string {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	h := sha256.New()
	if _, err := io.Copy(h, file); err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%x", h.Sum(nil))
}

func phLiveReference(t *testing.T, input phLiveReferenceInput) phOracleResult {
	t.Helper()
	if fmt.Sprintf("%x", sha256.Sum256(phLiveReferenceData)) != "b8df78daddd5464d14ee09803bee204bc8d01f5c95c2b9e5685c1a4171f56dc7" {
		t.Fatal("Linux live probe primary reference drift")
	}
	var references map[string]string
	if err := json.Unmarshal(phLiveReferenceData, &references); err != nil {
		t.Fatal(err)
	}
	if len(references) != 8 {
		t.Fatal("Linux live primary scenario coverage")
	}
	text, ok := references[input.Name]
	if !ok {
		t.Fatal("uncaptured Linux live probe scenario", input.Name)
	}
	live := input.Live
	numbers := map[string]int64{"WORKER_PID": int64(live.worker.Pid), "WORKER_START": live.workerStart, "SHELL_PID": int64(live.shell.Pid), "SHELL_START": live.shellStart, "AGENT_PID": live.agentPID, "AGENT_START": live.agentStart}
	for key, value := range numbers {
		text = strings.ReplaceAll(text, strconv.Quote("$"+key), strconv.FormatInt(value, 10))
	}
	values := map[string]string{"BOOT": input.Boot, "PANE": input.Pane}
	if strings.Contains(text, "$INSTALLED_SHA256") {
		values["INSTALLED_SHA256"] = phLiveReferenceSHA(t, input.Daemon)
	}
	if strings.Contains(text, "$RUNNING_SHA256") {
		values["RUNNING_SHA256"] = phLiveReferenceSHA(t, fmt.Sprintf("/proc/%d/exe", live.worker.Pid))
	}
	if strings.Contains(text, "$REVISION") {
		path := input.ClaudePath
		if input.Name == "codex-bound" {
			path = input.CodexPath
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			t.Fatal("Linux fixture has no native stat")
		}
		preimage := fmt.Sprintf("%d:%d:%d:%d", st.Dev, st.Ino, info.Size(), info.ModTime().UnixNano())
		values["REVISION"] = fmt.Sprintf("%x", sha256.Sum256([]byte(preimage)))
	}
	if strings.Contains(text, "$RECOVERY_OWNER") {
		// Independent stdlib encoding of the captured sorted-key hash preimage.
		proof := map[string]any{"version": 1, "pane_id": input.Pane, "node_boot_id": input.Boot, "worker_pid": live.worker.Pid, "worker_start": live.workerStart, "shell_pid": live.shell.Pid, "shell_start": live.shellStart, "provider": "claude", "process_id": live.agentPID, "process_start": live.agentStart, "session_id": input.Session}
		keys := make([]string, 0, len(proof))
		for key := range proof {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		parts := make([]string, 0, len(keys))
		for _, key := range keys {
			value, err := json.Marshal(proof[key])
			if err != nil {
				t.Fatal(err)
			}
			parts = append(parts, strconv.Quote(key)+": "+string(value))
		}
		digest := sha256.Sum256([]byte("{" + strings.Join(parts, ", ") + "}"))
		values["RECOVERY_OWNER"] = "input:" + fmt.Sprintf("%x", digest)[:48]
	}
	for key, value := range values {
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		text = strings.ReplaceAll(text, strconv.Quote("$"+key), string(encoded))
	}
	if strings.Contains(text, "$") {
		t.Fatal("unexpanded Linux live reference identity")
	}
	if !json.Valid([]byte(text)) {
		t.Fatal("invalid expanded Linux reference")
	}
	return phOracleResult{Value: &text}
}
