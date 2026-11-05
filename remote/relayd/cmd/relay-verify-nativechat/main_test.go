package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCampaignRequiresIntendedFailureAndRestores(t *testing.T) {
	cases, err := parsePlan(canonicalPlan)
	if err != nil {
		t.Fatal(err)
	}
	var allMessages []string
	for _, c := range cases {
		allMessages = append(allMessages, strings.Split(c.Expected, "|")[0])
	}
	for _, scenario := range []struct {
		name     string
		exit     int
		messages string
		allow    bool
	}{
		{"intended", 1, "--- FAIL: TestFixture\n" + strings.Join(allMessages, "\n"), true},
		{"compiler", 1, "compiler: syntax error", false},
		{"wrong-assertion", 1, "--- FAIL: TestFixture\nwrong assertion", false},
		{"success-with-text", 0, "--- FAIL: TestFixture\n" + strings.Join(allMessages, "\n"), false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			root := t.TempDir()
			module := filepath.Join(root, "module")
			pkg := filepath.Join(module, "internal", "nativechat")
			if err := os.MkdirAll(pkg, 0700); err != nil {
				t.Fatal(err)
			}
			for _, name := range []string{"go.mod", "go.sum"} {
				if err := os.WriteFile(filepath.Join(module, name), nil, 0600); err != nil {
					t.Fatal(err)
				}
			}
			sources := map[string]string{}
			for _, c := range cases {
				for _, p := range c.Patches {
					sources[p.File] += p.Old + "\n"
				}
			}
			for path, text := range sources {
				if err := os.WriteFile(filepath.Join(pkg, path), []byte(text), 0600); err != nil {
					t.Fatal(err)
				}
			}
			bin := filepath.Join(root, "bin")
			if err := os.Mkdir(bin, 0700); err != nil {
				t.Fatal(err)
			}
			script := "#!/bin/sh\ncat <<'MUTANT_FIXTURE_END'\n" + scenario.messages + "\nMUTANT_FIXTURE_END\nexit " + fmt.Sprint(scenario.exit) + "\n"
			if err := os.WriteFile(filepath.Join(bin, "go"), []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			result, err := campaign(module, filepath.Join(root, "work"), filepath.Join(root, "evidence"))
			if (err == nil) != scenario.allow || result.Complete != scenario.allow {
				t.Fatal("campaign credited unintended result", scenario.name, err)
			}
			if !result.Restored || !result.Unchanged {
				t.Fatal("source restoration failed", scenario.name)
			}
			if scenario.allow && (result.Mutants != 38 || result.Runs != 58) {
				t.Fatal("campaign coverage lost", result.Mutants, result.Runs)
			}
			if !scenario.allow && (result.Mutants != 1 || result.Runs != 1) {
				t.Fatal("campaign did not stop on first invalid kill", result.Mutants, result.Runs)
			}
		})
	}
}

func TestCampaignPreservesAllOriginalMutants(t *testing.T) {
	cases, err := parsePlan(canonicalPlan)
	if err != nil {
		t.Fatal(err)
	}
	runs := 0
	for _, c := range cases {
		runs += c.Repetitions
	}
	if len(cases) != 38 || runs != 58 || fmt.Sprintf("%x", sha256.Sum256(canonicalPlan)) != "62dbb79a9e916fd06ad2bd0afa982e29501f12919be35eb0e6550b3d06264db5" {
		t.Fatal("original mutation campaign changed", len(cases), runs)
	}
	c := cases[0]
	c.Patches[0].File = "../worker.go"
	data, _ := json.Marshal([]scenario{c})
	if _, err := parsePlan(data); err == nil {
		t.Fatal("mutation path escaped private package")
	}
}

func FuzzMutationPlan(f *testing.F) {
	f.Add(canonicalPlan)
	f.Add([]byte(`[]`))
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 1<<20 {
			return
		}
		cases, err := parsePlan(data)
		if err != nil {
			return
		}
		for _, c := range cases {
			for _, p := range c.Patches {
				root := "/private/mutations/internal/nativechat"
				relative, err := filepath.Rel(root, filepath.Join(root, p.File))
				if err != nil || strings.HasPrefix(relative, "..") || filepath.IsAbs(relative) {
					t.Fatal("mutation path escaped root")
				}
			}
		}
		round, err := json.Marshal(cases)
		if err != nil {
			t.Fatal(err)
		}
		again, err := parsePlan(round)
		if err != nil || len(again) != len(cases) {
			t.Fatal("plan roundtrip lost scenarios", err)
		}
		if _, err := parsePlan(append(append([]byte{}, data...), 'x')); err == nil {
			t.Fatal("accepted trailing mutation data")
		}
	})
}
