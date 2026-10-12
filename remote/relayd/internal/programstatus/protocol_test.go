package programstatus

import (
	"encoding/base64"
	"fmt"
	"strings"
	"testing"
)

func seq(s string) string { return "\x1b]7501;" + s + "\x1b\\" }
func enc(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
func TestFields(t *testing.T) {
	r, e := Parse("state=working:state=blocked:kind=permission:app=terraform:progress=40:msg=" + enc("Approve deploy?"))
	if e != nil || r.State != "blocked" || r.Kind != "permission" || r.Progress == nil || *r.Progress != 40 || r.Message != "Approve deploy?" {
		t.Fatalf("%#v %v", r, e)
	}
	r, e = Parse("unknown=anything:malformed:State=error:state = working:progress=101:app=bad/name")
	if e != nil || r.State != "working" || r.Progress != nil || r.App != "" {
		t.Fatalf("%#v %v", r, e)
	}
	r, e = Parse("state=done:kind=question:progress=20:msg=" + strings.TrimRight(enc("hello"), "="))
	if e != nil || r.Kind != "" || r.Progress != nil || r.Message != "hello" {
		t.Fatalf("%#v %v", r, e)
	}
}
func TestInvalidReportsPreservePriorRecord(t *testing.T) {
	bad := []string{"state=future", "app=cargo", "state=done:id=", "state=done:id=bad//child", "state=done:id=" + strings.Repeat("a", 33), "state=done:id=" + strings.Repeat("a/", 8) + "a", "state=done:msg=a", "state=done:msg=" + enc("line\nbreak"), "state=done:msg=" + enc("\x1b[2J"), "state=done:title=" + enc("\u0085"), "state=done:msg=" + enc(string([]byte{255})), "state=done:title=" + enc(strings.Repeat("a", 193)), "state=done:msg=" + enc(strings.Repeat("a", 2049)), "state=done:app=" + strings.Repeat("a", 33), "state=done:" + strings.Repeat("a", 17) + "=1", "state=done:unknown=" + strings.Repeat("a", MaxSequence)}
	for i, b := range bad {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			var tr Tracker
			tr.Feed([]byte(seq("state=working:app=original")))
			tr.Feed([]byte(seq(b)))
			r := tr.Snapshot()
			if len(r) != 1 || r[0].State != "working" || r[0].App != "original" {
				t.Fatalf("invalid input mutated records %#v", r)
			}
		})
	}
}
func TestFragmentationAndStringIsolation(t *testing.T) {
	input := seq("state=blocked:kind=question:msg=" + enc("Need input"))
	for i := 0; i <= len(input); i++ {
		var tr Tracker
		tr.Feed([]byte(input[:i]))
		tr.Feed([]byte(input[i:]))
		r := tr.Snapshot()
		if len(r) != 1 || r[0].Message != "Need input" {
			t.Fatalf("split %d %#v", i, r)
		}
	}
	var tr Tracker
	for _, b := range []byte(input) {
		tr.Feed([]byte{b})
	}
	if len(tr.Snapshot()) != 1 {
		t.Fatal("bytewise split")
	}
	var hidden Tracker
	hidden.Feed([]byte("\x1bP" + seq("state=error") + "\x1b\\"))
	if len(hidden.Snapshot()) != 0 {
		t.Fatal("DCS status interpreted")
	}
	hidden.Feed([]byte("\x1b]0;title " + seq("state=error")))
	if len(hidden.Snapshot()) != 0 {
		t.Fatal("nested OSC interpreted")
	}
	hidden.Feed([]byte("\x1b]7501;state=done\a"))
	if r := hidden.Snapshot(); len(r) != 1 || r[0].State != "done" {
		t.Fatal("BEL terminator")
	}
}
func TestOversizeRecoveryAndDetection(t *testing.T) {
	var tr Tracker
	tr.Feed([]byte("\x1b]7501;state=error:msg=" + strings.Repeat("a", 100000)))
	if len(tr.body) > MaxSequence {
		t.Fatal("unbounded buffer")
	}
	tr.Feed([]byte("\x1b\\" + seq("state=idle")))
	if r := tr.Snapshot(); len(r) != 1 || r[0].State != "idle" {
		t.Fatal("no recovery")
	}
	before := tr.Snapshot()[0].Revision
	e := tr.Feed([]byte(seq("?") + seq("?")))
	if e.DetectionQueries != 2 || e.Changed || tr.Snapshot()[0].Revision != before || DetectionReply != "\x1b]7501;?\x1b\\" {
		t.Fatalf("detection %#v", e)
	}
}
func TestReplacementHierarchyAndLifetime(t *testing.T) {
	var tr Tracker
	for _, b := range []string{"state=working:app=cargo:progress=40", "state=blocked:id=build/test:kind=question", "state=done:id=build/package"} {
		tr.Feed([]byte(seq(b)))
	}
	r := tr.Snapshot()
	if len(r) != 3 || r[1].App != "cargo" || r[2].App != "cargo" {
		t.Fatalf("inheritance %#v", r)
	}
	tr.Feed([]byte(seq("state=idle:app=new")))
	r = tr.Snapshot()
	if r[0].Progress != nil || r[1].App != "new" {
		t.Fatal("old fields retained")
	}
	tr.Feed([]byte("\x1b[?1049h\x1b[?1049l\x1b[!p"))
	if len(tr.Snapshot()) != 3 {
		t.Fatal("alternate screen/soft reset changed records")
	}
	tr.Feed([]byte("\x1b]133;A\a"))
	if len(tr.Snapshot()) != 2 {
		t.Fatal("shell prompt lifetime")
	}
	tr.Feed([]byte(seq("state=clear:id=build")))
	if len(tr.Snapshot()) != 1 {
		t.Fatal("subtree clear")
	}
	tr.Feed([]byte(seq("state=error:id=another")))
	tr.DropRunning()
	if len(tr.Snapshot()) != 2 {
		t.Fatal("error lost on exit")
	}
	tr.Feed([]byte("\x1bc"))
	if len(tr.Snapshot()) != 0 {
		t.Fatal("RIS")
	}
}
func TestBoundsDetachedSnapshotAndPlainText(t *testing.T) {
	var tr Tracker
	for i := 0; i < MaxRecords+5; i++ {
		tr.Feed([]byte(seq(fmt.Sprintf("state=working:id=task%d:progress=40", i))))
	}
	r := tr.Snapshot()
	if len(r) != MaxRecords {
		t.Fatal("record cap")
	}
	for _, v := range r {
		if v.ID == "task0" {
			t.Fatal("oldest not evicted")
		}
	}
	*r[0].Progress = 90
	for _, v := range tr.Snapshot() {
		if *v.Progress != 40 {
			t.Fatal("snapshot aliases progress")
		}
	}
	tr.Feed([]byte(seq("state=done:id=label:title=" + enc("<b>Literal</b>\u202e spoof 🧬"))))
	for _, v := range tr.Snapshot() {
		if v.ID == "label" && v.Title != "<b>Literal</b> spoof 🧬" {
			t.Fatalf("unsafe display %q", v.Title)
		}
	}
}

func TestProgressAndReplacementEdgeCases(t *testing.T) {
	r, err := Parse("state=working:progress=0000001")
	if err != nil || r.Progress == nil || *r.Progress != 1 {
		t.Fatalf("decimal progress %#v %v", r, err)
	}
	for _, value := range []string{"-1", "101", "1.5", "lots", "999999999999999999999999"} {
		r, err = Parse("state=working:progress=" + value)
		if err != nil || r.Progress != nil {
			t.Fatalf("invalid optional progress %q %#v %v", value, r, err)
		}
	}
	r, err = Parse("state=done:msg=%%%")
	if err != nil || r.State != "done" || r.Message != "" {
		t.Fatal("syntactically malformed pairs must be skipped")
	}
	if _, err = Parse("state=done:msg=a:msg=" + enc("replacement")); err == nil {
		t.Fatal("invalid encoded text earlier in report must reject atomically")
	}
	if DisplayText("one\u2028two\u2029three") != "one two three" {
		t.Fatal("display text must remain one line")
	}
}

func FuzzFragmentedReportsRemainBounded(f *testing.F) {
	for _, seed := range []string{seq("state=working"), tmuxWrap(seq("state=done")), tmuxWrap(tmuxWrap("\x1b]7501;?\a")), seq("state=blocked:id=build/test:kind=permission"), "\x1bPopaque\x1b\\", "\x1b]7501;msg=a\a", "plain output"} {
		f.Add([]byte(seed), uint8(3))
	}
	f.Fuzz(func(t *testing.T, data []byte, width uint8) {
		if len(data) > 65536 {
			t.Skip()
		}
		size := int(width) + 1
		var tr Tracker
		for index := 0; index < len(data); index += size {
			tr.Feed(data[index:min(index+size, len(data))])
		}
		if len(tr.body) > MaxSequence || len(tr.passthrough) > MaxPassthrough || len(tr.records) > MaxRecords {
			t.Fatal("unbounded state")
		}
		for _, record := range tr.Snapshot() {
			if record.Progress != nil && (*record.Progress < 0 || *record.Progress > 100) {
				t.Fatal("invalid progress stored")
			}
		}
	})
}

func tmuxWrap(payload string) string {
	return "\x1bPtmux;" + strings.ReplaceAll(payload, "\x1b", "\x1b\x1b") + "\x1b\\"
}
func TestTmuxPassthroughFragmentation(t *testing.T) {
	input := tmuxWrap(seq("state=blocked:progress=42:msg=" + enc("waiting")))
	for split := 0; split <= len(input); split++ {
		var tr Tracker
		tr.Feed([]byte(input[:split]))
		tr.Feed([]byte(input[split:]))
		r := tr.Snapshot()
		if len(r) != 1 || r[0].Message != "waiting" || r[0].Progress == nil || *r[0].Progress != 42 {
			t.Fatalf("split %d %#v", split, r)
		}
	}
	var tr Tracker
	for _, b := range []byte(input) {
		tr.Feed([]byte{b})
	}
	if len(tr.Snapshot()) != 1 {
		t.Fatal("bytewise split")
	}
}
func TestTmuxPassthroughDetectionAndClear(t *testing.T) {
	var tr Tracker
	e := tr.Feed([]byte(tmuxWrap(seq("state=done") + "\x1b]7501;?\a")))
	if !e.Changed || e.DetectionQueries != 1 || len(tr.Snapshot()) != 1 {
		t.Fatalf("%#v", e)
	}
	tr.Feed([]byte(tmuxWrap(seq("state=clear"))))
	if len(tr.Snapshot()) != 0 {
		t.Fatal("wrapped clear")
	}
}
func TestTmuxPassthroughDepth(t *testing.T) {
	for depth := 1; depth <= MaxPassthroughDepth+1; depth++ {
		input := seq("state=done")
		for n := 0; n < depth; n++ {
			input = tmuxWrap(input)
		}
		var tr Tracker
		tr.Feed([]byte(input))
		if (len(tr.Snapshot()) == 1) != (depth <= MaxPassthroughDepth) {
			t.Fatalf("depth %d", depth)
		}
	}
}
func TestTmuxPassthroughInvalidAndOversize(t *testing.T) {
	inputs := []string{
		"\x1bPtmux?" + seq("state=error") + "\x1b\\",
		"\x1bPtmux;" + seq("state=error") + "\x1b\\",
		"\x1bPtmux;" + strings.ReplaceAll(seq("state=error"), "\x1b", "\x1b\x1b") + "\x1bxBAD\x1b\\",
		tmuxWrap(strings.Repeat("x", MaxPassthrough+1) + seq("state=error")),
	}
	for n, input := range inputs {
		var tr Tracker
		tr.Feed([]byte(seq("state=done:app=retained")))
		e := tr.Feed([]byte(input))
		r := tr.Snapshot()
		if e.Changed || e.DetectionQueries != 0 || len(r) != 1 || r[0].App != "retained" ||
			len(tr.passthrough) > MaxPassthrough {
			t.Fatalf("case %d %#v %#v", n, e, r)
		}
		tr.Feed([]byte(seq("state=idle:app=recovered")))
		if tr.Snapshot()[0].App != "recovered" {
			t.Fatalf("case %d recovery", n)
		}
	}
}
