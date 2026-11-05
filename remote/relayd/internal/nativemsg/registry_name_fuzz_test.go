package nativemsg

import (
	"math/big"
	"strconv"
	"strings"
	"testing"
)

// canonicalRecordPID is the fuzz oracle for registryRecordPID, written
// without strconv: a name is a record name exactly when it is <stem>.json and
// math/big reads stem as an int64 whose canonical decimal form is stem.
func canonicalRecordPID(name string) (int64, bool) {
	if !strings.HasSuffix(name, ".json") {
		return 0, false
	}
	stem := name[:len(name)-len(".json")]
	value, ok := new(big.Int).SetString(stem, 10)
	if !ok || !value.IsInt64() || value.String() != stem {
		return 0, false
	}
	return value.Int64(), true
}

// FuzzRegistryCandidates drives the production filename filter that decides
// which registry records are skipped unparsed and uncounted. Properties:
//
//	N1 registryRecordPID(name) equals the math/big oracle: it accepts
//	   exactly the canonical decimal int64 <pid>.json names (no sign "+",
//	   leading zero, "-0", space, overflow or other suffix) and returns that
//	   pid.
//	N2 round trip: the canonical name of any int64 pid gives back that pid.
//	N3 liveRegistryCandidates keeps names in input order and drops a name
//	   exactly when it is a canonical record name whose pid is not in the
//	   process inventory; every other name (malformed, noncanonical, live)
//	   is kept.
func FuzzRegistryCandidates(f *testing.F) {
	for _, seed := range []struct {
		name string
		pid  int64
		live bool
	}{
		{"201.json", 201, true},
		{"201.json", 201, false},
		{"0.json", 0, false},
		{"-5.json", -5, false},
		{"-0.json", 0, false},
		{"+201.json", 201, false},
		{"0201.json", 201, false},
		{"00.json", 0, false},
		{" 201.json", 201, false},
		{"201 .json", 201, false},
		{"201.JSON", 201, false},
		{"201", 201, false},
		{"201.json.json", 201, false},
		{"201.0123456789abcdef.key", 201, false},
		{".json", 0, false},
		{"9223372036854775807.json", 9223372036854775807, false},
		{"9223372036854775808.json", 9223372036854775807, false},
		{"-9223372036854775808.json", -9223372036854775808, false},
		{"-9223372036854775809.json", -9223372036854775808, false},
		{"99999999999999999999999.json", 1, false},
		{"0x10.json", 16, false},
		{"1_000.json", 1000, false},
		{"٣.json", 3, false},
	} {
		f.Add(seed.name, seed.pid, seed.live)
	}
	f.Fuzz(func(t *testing.T, name string, pid int64, live bool) {
		got, ok := registryRecordPID(name)
		want, wantOK := canonicalRecordPID(name)
		if ok != wantOK || got != want {
			t.Fatalf("N1 registryRecordPID(%q) = (%d, %v), want (%d, %v)", name, got, ok, want, wantOK)
		}
		canonical := strconv.FormatInt(pid, 10) + ".json"
		if back, ok := registryRecordPID(canonical); !ok || back != pid {
			t.Fatalf("N2 registryRecordPID(%q) = (%d, %v), want (%d, true)", canonical, back, ok, pid)
		}
		processes := map[int64]processRow{}
		if live {
			processes[pid] = processRow{}
		}
		names := []string{name, canonical, "x.json", name}
		kept := liveRegistryCandidates(names, processes)
		var expected []string
		for _, n := range names {
			if p, ok := canonicalRecordPID(n); ok {
				if _, alive := processes[p]; !alive {
					continue
				}
			}
			expected = append(expected, n)
		}
		if len(kept) != len(expected) {
			t.Fatalf("N3 liveRegistryCandidates(%q, live=%v pid=%d) = %q, want %q", names, live, pid, kept, expected)
		}
		for i := range kept {
			if kept[i] != expected[i] {
				t.Fatalf("N3 liveRegistryCandidates(%q, live=%v pid=%d) = %q, want %q", names, live, pid, kept, expected)
			}
		}
	})
}
