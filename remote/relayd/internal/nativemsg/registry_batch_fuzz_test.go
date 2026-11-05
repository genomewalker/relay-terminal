package nativemsg

import (
	"bytes"
	"strconv"
	"strings"
	"testing"
)

// FuzzRegistryBatchFilter drives the production per-name filters exactly as
// peerRecords composes them per streamed batch — registryJSONName in
// forEachRegistryBatch, then liveRegistryCandidates — over a fuzzed list of
// directory names cut into batches of a fuzzed size. Properties:
//
//	B1 registryJSONName(name) holds exactly when name ends in ".json" and
//	   holds no '/' (what "*.json" matches in one directory entry).
//	B2 batching invariance: the names kept batch by batch, concatenated,
//	   equal the names an unbatched oracle keeps from the whole list, in
//	   order. Batch size is 1..256; the list is up to 1024 names.
//	B3 no kept name is a canonical <pid>.json whose pid is dead; every
//	   kept name is a *.json name of the input; and the filter retains
//	   nothing across batches (each batch's output only holds that batch's
//	   names).
//
// The name list is data split at NUL bytes; live marks, per name index,
// whether that name's pid (if any) is in the process inventory, cycling
// through its 64 bits.
func FuzzRegistryBatchFilter(f *testing.F) {
	f.Add([]byte("201.json\x00202.json\x00x.json\x00201.0123456789abcdef.key"), uint8(0), uint64(1))
	f.Add([]byte("0201.json\x00+5.json\x00-0.json\x00a/b.json\x00.json\x00json"), uint8(1), uint64(0))
	f.Add([]byte("9223372036854775807.json\x009223372036854775808.json\x00\xff.json\x00٣.json"), uint8(255), ^uint64(0))
	f.Add(bytes.Repeat([]byte("7.json\x00"), 600), uint8(2), uint64(0xaaaaaaaaaaaaaaaa))
	f.Fuzz(func(t *testing.T, data []byte, batchByte uint8, live uint64) {
		raw := strings.Split(string(data), "\x00")
		if len(raw) > 1024 {
			raw = raw[:1024]
		}
		batch := int(batchByte) + 1
		processes := map[int64]processRow{}
		for i, name := range raw {
			if pid, ok := canonicalRecordPID(name); ok && live>>(uint(i)%64)&1 == 1 {
				processes[pid] = processRow{}
			}
		}
		// B1 and the unbatched oracle.
		var want []string
		for _, name := range raw {
			isJSON := strings.HasSuffix(name, ".json") && !strings.Contains(name, "/")
			if registryJSONName(name) != isJSON {
				t.Fatalf("B1 registryJSONName(%q) = %v, want %v", name, !isJSON, isJSON)
			}
			if !isJSON {
				continue
			}
			if pid, ok := canonicalRecordPID(name); ok {
				if _, alive := processes[pid]; !alive {
					continue
				}
			}
			want = append(want, name)
		}
		// The production composition, batch by batch.
		var got []string
		for start := 0; start < len(raw); start += batch {
			end := min(start+batch, len(raw))
			var names []string
			for _, name := range raw[start:end] {
				if registryJSONName(name) {
					names = append(names, name)
				}
			}
			kept := liveRegistryCandidates(names, processes)
			if len(kept) > end-start {
				t.Fatalf("B3 batch [%d,%d) kept %d names", start, end, len(kept))
			}
			in := map[string]bool{}
			for _, name := range raw[start:end] {
				in[name] = true
			}
			for _, name := range kept {
				if !in[name] {
					t.Fatalf("B3 batch [%d,%d) kept %q from outside it", start, end, name)
				}
				if pid, ok := canonicalRecordPID(name); ok {
					if _, alive := processes[pid]; !alive {
						t.Fatalf("B3 dead record %q kept", name)
					}
				}
			}
			got = append(got, kept...)
		}
		if strings.Join(got, "\x00") != strings.Join(want, "\x00") || len(got) != len(want) {
			t.Fatalf("B2 batch=%d: kept %d names %s, unbatched oracle %d", batch, len(got), strconv.Quote(strings.Join(got, ",")), len(want))
		}
	})
}
