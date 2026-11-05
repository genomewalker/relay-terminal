package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const knownLegacyListenerDigest = "a9cd94eeb34dad40a5b9a65feb1e1e4d59a765e079afd26e5cdd22573bb24918"

func nativeListenerFixture() *peerListenerSpec {
	return &peerListenerSpec{Executable: ".local/bin/relayd", Route: "route-a", OwnerPID: 44, OwnerStart: "123", OwnerSession: "conversation-a"}
}
func TestNativeListenerExecutableUsesAuthenticatedHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	spec := nativeListenerFixture()
	if err := spec.validate(); err != nil {
		t.Fatal(err)
	}
	argv, err := resolveNativeHostArgv(spec.argv())
	if err != nil {
		t.Fatal(err)
	}
	want := []string{filepath.Join(home, ".local/bin/relayd"), "desktop-remote", "listen", "44", "conversation-a", "123", "route-a"}
	if !reflect.DeepEqual(argv, want) {
		t.Fatal("native listener cwd-dependent argv", argv)
	}
	input := []string{".local/bin/relayd", "native-group", "-"}
	resolved, err := resolveNativeHostArgv(input)
	if err != nil || resolved[0] != want[0] || input[0] != ".local/bin/relayd" {
		t.Fatal("remote native send executable redirected or argv mutated", resolved, err)
	}
	t.Setenv("HOME", "")
	if _, err := resolveNativeHostArgv(input); err == nil {
		t.Fatal("missing home fell back to project cwd")
	}
}
func TestNativeListenerRejectsMixedOrRelativeLaunches(t *testing.T) {
	for _, mutate := range []func(*peerListenerSpec){func(s *peerListenerSpec) { s.Executable = "project/relayd" }, func(s *peerListenerSpec) { s.Executable = "/tmp/../relayd" }, func(s *peerListenerSpec) { s.Script = "code" }, func(s *peerListenerSpec) { s.Interpreter = "python3" }, func(s *peerListenerSpec) { s.Executable = "/tmp/relayd\nother" }} {
		spec := nativeListenerFixture()
		mutate(spec)
		if err := spec.validate(); err == nil {
			t.Fatal("mixed/relative listener accepted", spec)
		}
	}
}
func TestNativeListenerLegacyMigrationPinsHashAndOwner(t *testing.T) {
	old := nativeListenerFixture()
	old.Executable = ""
	old.Interpreter = "python3"
	old.Script = "legacy source is archived outside active source"
	unchanged := *old
	successor, err := nativePeerListenerSuccessorDigest(old, knownLegacyListenerDigest)
	if err != nil {
		t.Fatal(err)
	}
	executable, _ := os.Executable()
	if successor.Executable != executable || successor.Script != "" || successor.Interpreter != "" || !reflect.DeepEqual(successor.binding(), old.binding()) || *old != unchanged {
		t.Fatal("migration changed route/owner or retained interpreter", successor)
	}
	if _, err := nativePeerListenerSuccessor(old); err == nil {
		t.Fatal("unrecognized actual source migrated")
	}
	for index := range knownLegacyListenerDigest {
		bad := []byte(knownLegacyListenerDigest)
		if bad[index] == '0' {
			bad[index] = '1'
		} else {
			bad[index] = '0'
		}
		if _, err := nativePeerListenerSuccessorDigest(old, string(bad)); err == nil {
			t.Fatal("non-exact source digest migrated", index)
		}
	}
	server := &Server{stateDir: t.TempDir()}
	if _, err := server.startHostJob(hostRequest{JobID: "job-legacy", Kind: hostJobKindPeerListener, KeepStdin: true, Listener: old}); err == nil {
		t.Fatal("legacy interpreter was launched")
	}
	if _, err := os.Stat(filepath.Join(server.stateDir, "host-jobs")); !os.IsNotExist(err) {
		t.Fatal("legacy launch rejection created a job", err)
	}
}
func TestNativeListenerBoundedMigrationPolicy(t *testing.T) {
	states := 0
	for mask := 0; mask < 256; mask++ {
		spec := nativeListenerFixture()
		if mask&1 != 0 {
			spec.Executable = ""
			spec.Interpreter = "python3"
			spec.Script = "archived-source"
		}
		if mask&2 != 0 {
			spec.OwnerPID = 1
		}
		if mask&4 != 0 {
			spec.OwnerStart = ""
		}
		if mask&8 != 0 {
			spec.OwnerSession = "../escape"
		}
		if mask&16 != 0 {
			spec.Route = "../escape"
		}
		if mask&32 != 0 {
			spec.Script += "\x00"
		}
		if mask&64 != 0 {
			spec.Interpreter = "python3\nother"
		}
		digest := knownLegacyListenerDigest
		if mask&128 != 0 {
			digest = strings.Repeat("0", 64)
		}
		before := *spec
		successor, err := nativePeerListenerSuccessorDigest(spec, digest)
		expected := mask&126 == 0 && (mask&1 == 0 || mask&128 == 0)
		if (err == nil) != expected {
			t.Fatalf("native migration policy mask%d accepted%v expected%v error%v", mask, err == nil, expected, err)
		}
		if *spec != before {
			t.Fatal("policy changed submitted identity")
		}
		if err == nil && (!reflect.DeepEqual(successor.binding(), spec.binding()) || successor.Executable == "" || successor.Script != "" || successor.Interpreter != "") {
			t.Fatal("migration failed native-only/exact-owner property")
		}
		states++
	}
	t.Logf("native listener conversion policy: all %d field states; trusts SHA256 computation and os.Executable", states)
}
func FuzzNativeListenerSpecification(f *testing.F) {
	seed, _ := json.Marshal(nativeListenerFixture())
	f.Add(seed)
	f.Add([]byte(`{"executable":"../../relayd"}`))
	f.Add([]byte(`{`))
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 65536 {
			return
		}
		var spec peerListenerSpec
		if json.Unmarshal(data, &spec) != nil || spec.validate() != nil {
			return
		}
		encoded, err := json.Marshal(spec)
		if err != nil {
			t.Fatal(err)
		}
		var again peerListenerSpec
		if json.Unmarshal(encoded, &again) != nil || again.validate() != nil || spec != again {
			t.Fatal("listener spec identity round trip")
		}
		argv := spec.argv()
		if len(argv) == 0 {
			t.Fatal("accepted listener lacks executable")
		}
		if spec.Executable != "" {
			if len(argv) != 7 || argv[0] != spec.Executable || argv[1] != "desktop-remote" || argv[2] != "listen" || argv[4] != spec.OwnerSession || argv[5] != spec.OwnerStart || argv[6] != spec.Route || spec.Interpreter != "" || spec.Script != "" {
				t.Fatal("native argv changed route/owner or admitted interpreter")
			}
		}
		if spec.legacyPython() {
			if _, err := nativePeerListenerSuccessor(&spec); err == nil && spec.Script != "" {
				t.Fatal("unknown fuzz source migrated")
			}
		}
	})
}
