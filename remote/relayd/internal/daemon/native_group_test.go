package daemon

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const nativeGroupTestID = "ef2f214b-7540-4504-a183-d17a3b7bfe74"
const nativeGroupMessageID = "33ea5e89-e5c0-4b37-a996-206c9f2cb545"
const nativeGroupUpdateID = "1e1250c5-77d7-4e70-8edc-927692e82277"

func TestNativeGroupCLIRejectsMissingAndSymlinkPlanWithoutPanic(t *testing.T) {
	root := t.TempDir()
	missing := filepath.Join(root, "missing.json")
	link := filepath.Join(root, "link.json")
	if err := os.Symlink(missing, link); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{missing, link} {
		var out strings.Builder
		if err := RunNativeGroup(context.Background(), []string{path}, strings.NewReader("{}"), &out); err == nil || out.Len() != 0 {
			t.Fatalf("unsafe path %q: %v output=%s", path, err, out.String())
		}
	}
}

type nativeGroupFixture struct {
	t         *testing.T
	home      string
	service   *nativeGroupService
	plan      *pyObject
	listeners []*net.UnixListener
	members   []*pyObject
}

func newNativeGroupFixture(t *testing.T, count int) *nativeGroupFixture {
	t.Helper()
	home, err := os.MkdirTemp("/tmp", "rng-go-")
	if err != nil {
		t.Fatal(err)
	}
	f := &nativeGroupFixture{t: t, home: home}
	t.Cleanup(func() {
		for _, listener := range f.listeners {
			listener.Close()
		}
		os.RemoveAll(home)
	})
	f.service = newNativeGroupService(context.Background(), home)
	f.service.processStart = func(int64) string { return "123" }
	f.service.permission = func(int, string) string { return "prompting" }
	for i := 0; i < count; i++ {
		f.addMember(i)
	}
	participants := pyListOf()
	for _, member := range f.members {
		participants.items = append(participants.items, member)
	}
	f.plan = pyObj("id", nativeGroupTestID, "participants", participants, "topology", "everyone", "purpose", "Test")
	return f
}
func (f *nativeGroupFixture) addMember(i int) {
	f.t.Helper()
	pid := int64(100 + i)
	address := filepath.Join(f.home, fmt.Sprint(i, ".sock"))
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: address, Net: "unix"})
	if err != nil {
		f.t.Fatal(err)
	}
	// Python's socket.close leaves the filesystem entry in place. Preserve
	// that behavior so a closed listener fails at the actual send, after the
	// same preflight and durable unknown receipt as the original regression.
	listener.SetUnlinkOnClose(false)
	f.listeners = append(f.listeners, listener)
	member := pyObj("kind", "native", "host", "dandy-07", "name", fmt.Sprint("peer-", i), "session", fmt.Sprint("session-", i), "pid", pid, "processStart", "123")
	f.members = append(f.members, member)
	registry := filepath.Join(f.home, ".claude/sessions")
	if err := os.MkdirAll(registry, 0700); err != nil {
		f.t.Fatal(err)
	}
	record := pyObj("pid", pid, "name", member.Get("name"), "sessionId", member.Get("session"), "procStart", "123", "messagingSocketPath", address)
	for path, value := range map[string]*pyObject{filepath.Join(registry, fmt.Sprint(pid, ".json")): record, func() string {
		h := sha256.Sum256([]byte(address))
		return filepath.Join(registry, fmt.Sprint(pid, ".")+hex.EncodeToString(h[:])+".key")
	}(): pyObj("peerToken", "secret-token-12345678")} {
		if err := os.WriteFile(path, pyEncode(value, pyDumpsDefault), 0600); err != nil {
			f.t.Fatal(err)
		}
	}
}
func (f *nativeGroupFixture) read(i int) map[string]any {
	f.t.Helper()
	listener := f.listeners[i]
	listener.SetDeadline(time.Now().Add(200 * time.Millisecond))
	conn, err := listener.Accept()
	if err != nil {
		f.t.Fatal(err)
	}
	defer conn.Close()
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reader := bufio.NewReader(conn)
	auth, err := reader.ReadBytes('\n')
	if err != nil {
		f.t.Fatal(err)
	}
	frame, err := reader.ReadBytes('\n')
	if err != nil {
		f.t.Fatal(err)
	}
	var token map[string]any
	if json.Unmarshal(auth, &token) != nil || token["token"] != "secret-token-12345678" {
		f.t.Fatal("native group credential", string(auth))
	}
	var message map[string]any
	if err := json.Unmarshal(frame, &message); err != nil {
		f.t.Fatal(err)
	}
	return message
}
func (f *nativeGroupFixture) noMessage(i int) {
	f.t.Helper()
	f.listeners[i].SetDeadline(time.Now().Add(200 * time.Millisecond))
	conn, err := f.listeners[i].Accept()
	if err == nil {
		conn.Close()
		f.t.Fatal("native group replayed a message")
	}
	if failure, ok := err.(net.Error); !ok || !failure.Timeout() {
		f.t.Fatal("unexpected listener failure", err)
	}
}
func nativeGroupContent(frame map[string]any) string {
	return frame["message"].(map[string]any)["content"].(string)
}
func TestNativeGroupBidirectionalAddressesAndDurableReceipts(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	result := f.service.apply(f.plan)
	if result.Get("state") != "introductions_attempted" {
		t.Fatal("group state", result)
	}
	for i := 0; i < 2; i++ {
		frame := f.read(i)
		if frame["from"] != "uds:"+filepath.Join(f.home, fmt.Sprint(1-i, ".sock")) || !strings.Contains(nativeGroupContent(frame), fmt.Sprint("session-", 1-i)) || !strings.Contains(nativeGroupContent(frame), `from-mode="prompting"`) {
			t.Fatal("bidirectional source/provenance", frame)
		}
	}
	if len(result.Get("introductions").(*pyList).items) != 2 {
		t.Fatal("exact original introduction receipt count")
	}
	for _, receipt := range result.Get("introductions").(*pyList).items {
		if receipt.(*pyObject).Get("receipt") != "written_to_socket" {
			t.Fatal("receipt downgraded")
		}
	}
	path := filepath.Join(f.service.directory(), nativeGroupTestID+".json")
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("private durable group", err)
	}
	if !pyEqual(f.service.private(path), result) {
		t.Fatal("returned group differs from durable receipt")
	}
}
func TestNativeGroupReplayCannotSendAgain(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	f.service.apply(f.plan)
	f.read(0)
	f.read(1)
	if err := nativeGroupAttempt(func() { f.service.apply(f.plan) }); !nativeGroupExpectedException(err, phOSError, true) {
		t.Fatal("group creation replayed")
	}
	f.noMessage(0)
}
func TestNativeGroupPairTaskUpdateAndIdempotentNotices(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	f.service.apply(f.plan)
	f.read(0)
	f.read(1)
	purpose := "Profile derep memory and test fixes"
	result := f.service.updatePairTask(nativeGroupTestID, nativeGroupUpdateID, purpose)
	if result.Get("state") != "sent" {
		t.Fatal(result)
	}
	for i := 0; i < 2; i++ {
		content := nativeGroupContent(f.read(i))
		for _, part := range []string{"Profile derep memory", "not authored by the peer", "existing permissions"} {
			if !strings.Contains(content, part) {
				t.Fatal("amendment provenance", part, content)
			}
		}
	}
	saved := f.service.private(filepath.Join(f.service.directory(), nativeGroupTestID+".json"))
	if saved.Get("autonomous") != true || saved.Get("taskAmendments").(*pyList).items[0].(*pyObject).Get("previousPurpose") != "Test" {
		t.Fatal("amendment state", saved)
	}
	f.service.updatePairTask(nativeGroupTestID, nativeGroupUpdateID, purpose)
	f.noMessage(0)
	if err := nativeGroupAttempt(func() { f.service.updatePairTask(nativeGroupTestID, nativeGroupUpdateID, "Different task") }); !nativeGroupExpectedException(err, phValueError, false) {
		t.Fatal("amendment ID conflict accepted")
	}
}
func TestNativeGroupAutonomousAgreementReachesEveryMember(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	f.plan.Set("autonomous", true)
	if f.service.apply(f.plan).Get("autonomous") != true {
		t.Fatal("autonomy missing")
	}
	for i := 0; i < 2; i++ {
		content := nativeGroupContent(f.read(i))
		if !strings.Contains(content, "Collaborate autonomously") || !strings.Contains(content, "Existing permissions remain unchanged") {
			t.Fatal(content)
		}
	}
}
func TestNativeGroupInvalidAgreementHasNoSideEffects(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	for _, c := range []struct {
		mode    any
		purpose any
	}{{true, "  "}, {"true", "Task"}, {int64(1), "Task"}, {false, nil}} {
		f.plan.Set("autonomous", c.mode)
		f.plan.Set("purpose", c.purpose)
		if err := nativeGroupAttempt(func() { f.service.apply(f.plan) }); !nativeGroupExpectedException(err, phValueError, false) {
			t.Fatal("invalid agreement admitted", c)
		}
	}
	if _, err := os.Stat(filepath.Join(f.home, ".local")); !os.IsNotExist(err) {
		t.Fatal("invalid agreement wrote state", err)
	}
}
func TestNativeGroupOldPlanIsCommunicationOnly(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	if !strings.Contains(nativeGroupAgreement(f.plan), "Communication only") {
		t.Fatal("old plan gained work authority")
	}
}
func TestNativeGroupNamedRepliesAndExplicitSend(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	f.service.apply(f.plan)
	for i := 0; i < 2; i++ {
		content := nativeGroupContent(f.read(i))
		if !strings.Contains(content, fmt.Sprint("native peer name: peer-", 1-i)) || !strings.Contains(content, "--send "+nativeGroupTestID) || strings.Contains(content, "python") {
			t.Fatal("native group instructions", content)
		}
	}
	result := f.service.sendGroup(nativeGroupTestID, "session-0", nativeGroupMessageID, "Test broadcast")
	if result.Get("state") != "sent" || !strings.Contains(nativeGroupContent(f.read(1)), "Test broadcast") {
		t.Fatal("group send", result)
	}
	replay := f.service.sendGroup(nativeGroupTestID, "session-0", nativeGroupMessageID, "Test broadcast")
	if !pyEqual(replay, result) {
		t.Fatal("replayed durable receipt changed")
	}
	f.noMessage(1)
	if err := nativeGroupAttempt(func() { f.service.sendGroup(nativeGroupTestID, "session-0", nativeGroupMessageID, "Changed") }); !nativeGroupExpectedException(err, phValueError, false) {
		t.Fatal("message ID conflict accepted")
	}
}
func TestNativeGroupRejectsNonmemberAndReplacedSession(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	f.service.apply(f.plan)
	f.read(0)
	f.read(1)
	if err := nativeGroupAttempt(func() { f.service.sendGroup(nativeGroupTestID, "outsider", nativeGroupMessageID, "Test") }); !nativeGroupExpectedException(err, phValueError, false) {
		t.Fatal("nonmember sent")
	}
	f.service.processStart = func(int64) string { return "changed" }
	if err := nativeGroupAttempt(func() { f.service.sendGroup(nativeGroupTestID, "session-0", nativeGroupMessageID, "Test") }); !nativeGroupExpectedException(err, phValueError, false) {
		t.Fatal("replaced session sent")
	}
}
func TestNativeGroupThreeMemberFanoutContinuesAfterFailure(t *testing.T) {
	f := newNativeGroupFixture(t, 3)
	f.service.apply(f.plan)
	for i := 0; i < 3; i++ {
		f.read(i)
	}
	result := f.service.sendGroup(nativeGroupTestID, "session-0", nativeGroupMessageID, "All members")
	if len(result.Get("recipients").(*pyList).items) != 2 {
		t.Fatal("fanout recipient count")
	}
	for _, i := range []int{1, 2} {
		if !strings.Contains(nativeGroupContent(f.read(i)), "All members") {
			t.Fatal("fanout content")
		}
	}
	f.noMessage(0)
	f.listeners[1].Close()
	next := "9857b63c-1ac6-456e-952c-2544f672664b"
	result = f.service.sendGroup(nativeGroupTestID, "session-0", next, "Partial failure")
	receipts := result.Get("recipients").(*pyList).items
	if result.Get("state") != "needs_attention" || receipts[0].(*pyObject).Get("receipt") != "unknown" || receipts[1].(*pyObject).Get("receipt") != "written_to_socket" {
		t.Fatal("partial fanout receipts", string(pyCompact(result)))
	}
	if !strings.Contains(nativeGroupContent(f.read(2)), "Partial failure") {
		t.Fatal("fanout stopped at first refusal")
	}
}
func TestNativeGroupReplacedProcessRejectsBeforeAnySend(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	f.members[1].Set("processStart", "changed")
	if err := nativeGroupAttempt(func() { f.service.apply(f.plan) }); !nativeGroupExpectedException(err, phValueError, false) {
		t.Fatal("replaced process linked")
	}
	f.noMessage(0)
}
func TestNativeGroupCrossHostIsNotSilentlyLocal(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	f.members[1].Set("host", "dandy-08")
	if err := nativeGroupAttempt(func() { f.service.apply(f.plan) }); !nativeGroupExpectedException(err, phValueError, false) {
		t.Fatal("cross-host plan treated as local")
	}
}
func TestNativeGroupFailedSendRemainsUnknown(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	f.listeners[0].Close()
	result := f.service.apply(f.plan)
	if result.Get("state") != "needs_attention" || result.Get("introductions").(*pyList).items[0].(*pyObject).Get("receipt") != "unknown" {
		t.Fatal("failed send was reported delivered", string(pyCompact(result)))
	}
	if err := nativeGroupAttempt(func() { f.service.apply(f.plan) }); !nativeGroupExpectedException(err, phOSError, true) {
		t.Fatal("failed group send replayed")
	}
}
func TestNativeGroupUUIDAndReceiptFingerprintMatchLegacy(t *testing.T) {
	got := nativeGroupNoticeID(nativeGroupUpdateID, "session-0")
	if got != "d785f825-59fe-5b19-b515-c34271bc0029" {
		t.Fatal("UUIDv5 notice identity", got)
	}
	canonical, err := nativeGroupUUID("{EF2F214B75404504A183D17A3B7BFE74}")
	if err != nil || canonical != nativeGroupTestID {
		t.Fatal(canonical, err)
	}
}
func TestNativeGroupConcurrentIdenticalMessageWritesAtMostOnce(t *testing.T) {
	f := newNativeGroupFixture(t, 2)
	f.service.apply(f.plan)
	f.read(0)
	f.read(1)
	var wg sync.WaitGroup
	results := make(chan string, 2)
	var count int
	var mu sync.Mutex
	f.service.send = func(string, []byte) error { mu.Lock(); count++; mu.Unlock(); return nil }
	for actor := 0; actor < 2; actor++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var value *pyObject
			err := nativeGroupAttempt(func() { value = f.service.sendGroup(nativeGroupTestID, "session-0", nativeGroupMessageID, "same") })
			if err != nil {
				results <- err.Error()
			} else {
				results <- string(pyCompact(value))
			}
		}()
	}
	wg.Wait()
	close(results)
	var first string
	for result := range results {
		if first == "" {
			first = result
		} else if result != first {
			t.Fatal("same identity returned different receipts")
		}
	}
	if count != 1 {
		t.Fatal("concurrent message replay", count)
	}
}

// Enumerate every length-three history over sends by two different members,
// a conflicting same-UUID request, and an outsider. The real persisted receipt
// code executes each step. Fake sockets only count writes; they grant nothing.
func TestNativeGroupBoundedOwnershipAndReplayCheck(t *testing.T) {
	sequences, transitions := 0, 0
	for a := 0; a < 4; a++ {
		for b := 0; b < 4; b++ {
			for c := 0; c < 4; c++ {
				f := newNativeGroupFixture(t, 2)
				writes := map[string]int{}
				f.service.send = func(address string, data []byte) error { writes[address+":"+string(data)]++; return nil }
				f.service.apply(f.plan)
				writes = map[string]int{}
				acceptedSender := ""
				acceptedText := ""
				for _, op := range []int{a, b, c} {
					sender, text := "session-0", "same"
					if op == 1 {
						sender = "session-1"
					}
					if op == 2 {
						text = "conflict"
					}
					if op == 3 {
						sender = "outsider"
					}
					err := nativeGroupAttempt(func() { f.service.sendGroup(nativeGroupTestID, sender, nativeGroupMessageID, text) })
					expectedOK := sender != "outsider" && (acceptedSender == "" || sender == acceptedSender && text == acceptedText)
					if (err == nil) != expectedOK {
						t.Fatalf("ownership/replay history %v op%d error%v", []int{a, b, c}, op, err)
					}
					if err == nil && acceptedSender == "" {
						acceptedSender, acceptedText = sender, text
					}
					total := 0
					for _, count := range writes {
						if count > 1 {
							t.Fatal("bounded no-replay property")
						}
						total += count
					}
					if total > 1 || acceptedSender == "" && total != 0 {
						t.Fatal("bounded nonmember/conflict dispatch", total)
					}
					transitions++
				}
				sequences++
			}
		}
	}
	if sequences != 64 || transitions != 192 {
		t.Fatal("bounded check coverage", sequences, transitions)
	}
	t.Log("native-group real-code histories=64 depth=3 transitions=192 alphabet=4 plus concurrent two-actor same-UUID test")
}
func FuzzNativeGroupPlan(f *testing.F) {
	for _, seed := range []string{`{"id":"ef2f214b-7540-4504-a183-d17a3b7bfe74","participants":[{"kind":"native","host":"node","name":"a","session":"a","pid":1,"processStart":"1"},{"kind":"native","host":"node","name":"b","session":"b","pid":2,"processStart":"2"}],"topology":"everyone"}`, `{"id":"../../escape"}`, `{`, `null`, `[]`} {
		f.Add([]byte(seed))
	}

	valid := `{"id":"ef2f214b-7540-4504-a183-d17a3b7bfe74","participants":[{"kind":"native","host":"node","name":"a","session":"a","pid":1,"processStart":"1"},{"kind":"native","host":"node","name":"b","session":"b","pid":2,"processStart":"2"}],"topology":"everyone"}`
	f.Add([]byte(valid + strings.Repeat(" ", 65537-len(valid))))
	f.Fuzz(func(t *testing.T, data []byte) {
		plan, err := decodeNativeGroupPlan(data)
		if err != nil {
			return
		}
		members, _, id := nativeGroupValidate(plan)
		if len(data) > nativeGroupLimit || len(members) < 2 || len(members) > 8 {
			t.Fatal("group parser bounds")
		}
		root := "/private/group-root"
		path := filepath.Join(root, id+".json")
		rel, err := filepath.Rel(root, path)
		if err != nil || strings.HasPrefix(rel, "..") || strings.ContainsAny(id, "/\\") {
			t.Fatal("group id escaped receipt root")
		}
		round, err := decodeNativeGroupPlan(pyEncode(plan, pyDumpsDefault))
		if err != nil || !pyEqual(plan, round) {
			t.Fatal("group plan round trip")
		}
		seen := map[string]bool{}
		host := members[0].Get("host")
		for _, member := range members {
			session := member.Get("session").(string)
			if seen[session] || !pyEqual(member.Get("host"), host) || member.Get("kind") != "native" {
				t.Fatal("group ownership/membership")
			}
			seen[session] = true
		}
	})
}

// Enumerate all six order-preserving interleavings of two sends by each of
// two actors. Calls use the real locked persistent store. The separate racing
// test exercises simultaneous lock acquisition; this scheduler checks every
// public-operation ordering and its durable ownership/no-replay properties.
func TestNativeGroupEveryTwoActorOperationInterleaving(t *testing.T) {
	var schedules [][]int
	var enumerate func([]int, int, int)
	enumerate = func(prefix []int, a, b int) {
		if a == 2 && b == 2 {
			schedules = append(schedules, append([]int{}, prefix...))
			return
		}
		if a < 2 {
			enumerate(append(append([]int{}, prefix...), 0), a+1, b)
		}
		if b < 2 {
			enumerate(append(append([]int{}, prefix...), 1), a, b+1)
		}
	}
	enumerate(nil, 0, 0)
	transitions := 0
	for _, schedule := range schedules {
		f := newNativeGroupFixture(t, 2)
		f.service.send = func(string, []byte) error { return nil }
		f.service.apply(f.plan)
		writes := 0
		f.service.send = func(string, []byte) error { writes++; return nil }
		winner := -1
		for _, actor := range schedule {
			err := nativeGroupAttempt(func() {
				f.service.sendGroup(nativeGroupTestID, fmt.Sprint("session-", actor), nativeGroupMessageID, fmt.Sprint("body-", actor))
			})
			if winner == -1 {
				winner = actor
			}
			if (err == nil) != (actor == winner) {
				t.Fatalf("schedule%v actor%d winner%d error%v", schedule, actor, winner, err)
			}
			if writes != 1 {
				t.Fatal("two-actor durable receipt dispatched again", schedule, writes)
			}
			transitions++
		}
	}
	if len(schedules) != 6 || transitions != 24 {
		t.Fatal("incomplete two-actor interleavings", len(schedules), transitions)
	}
	t.Log("real-code two actors x two sends: 6 interleavings, 24 checked transitions; separate simultaneous-lock witness")
}

// Preserve the original assertRaises class: an arbitrary panic is not a
// successful ValueError/FileExistsError refusal.
func nativeGroupExpectedException(err error, kind phKind, exists bool) bool {
	e, ok := err.(*phException)
	return ok && e.kind == kind && (!exists || strings.HasPrefix(e.msg, "[Errno 17]"))
}

func TestNativeGroupOriginalPlanSizeBound(t *testing.T) {
	valid := `{"id":"ef2f214b-7540-4504-a183-d17a3b7bfe74","participants":[{"kind":"native","host":"node","name":"a","session":"a","pid":1,"processStart":"1"},{"kind":"native","host":"node","name":"b","session":"b","pid":2,"processStart":"2"}],"topology":"everyone"}`
	at := []byte(valid + strings.Repeat(" ", 65536-len(valid)))
	if _, e := decodeNativeGroupPlan(at); e != nil {
		t.Fatal("original at-limit plan rejected", e)
	}
	if _, e := decodeNativeGroupPlan(append(at, ' ')); e == nil {
		t.Fatal("original 65536-byte plan limit exceeded")
	}
}
