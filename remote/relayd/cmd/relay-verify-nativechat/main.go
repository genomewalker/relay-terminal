// Run the preserved nativechat mutation campaign on a private source copy.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

//go:embed mutations.json
var canonicalPlan []byte

type patch struct {
	File string `json:"file"`
	Old  string `json:"old"`
	New  string `json:"new"`
}
type scenario struct {
	Label       string  `json:"label"`
	Repetitions int     `json:"repetitions"`
	Test        string  `json:"test"`
	Expected    string  `json:"expected"`
	Patches     []patch `json:"patches"`
}
type runResult struct {
	Run    int  `json:"run"`
	Exit   int  `json:"exit"`
	Killed bool `json:"intended_assertion_killed"`
}
type mutationResult struct {
	Mutant         string      `json:"mutant"`
	Classification string      `json:"classification"`
	Runs           []runResult `json:"runs"`
}
type report struct {
	Complete  bool              `json:"complete"`
	Weakening string            `json:"weakening"`
	Mutants   int               `json:"mutants"`
	Runs      int               `json:"runs"`
	Restored  bool              `json:"restored"`
	Unchanged bool              `json:"candidate_unchanged"`
	Hashes    map[string]string `json:"source_sha256"`
	Results   []mutationResult  `json:"results"`
}

func parsePlan(data []byte) ([]scenario, error) {
	if len(data) > 1<<20 {
		return nil, errors.New("mutation plan exceeds limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var cases []scenario
	if err := decoder.Decode(&cases); err != nil {
		return nil, err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, errors.New("trailing plan data")
	}
	if len(cases) == 0 || len(cases) > 128 {
		return nil, errors.New("invalid scenario count")
	}
	seen := map[string]bool{}
	label := regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,79}$`)
	for _, c := range cases {
		if !label.MatchString(c.Label) || seen[c.Label] || c.Repetitions != 1 && c.Repetitions != 3 || len(c.Patches) == 0 || len(c.Patches) > 8 {
			return nil, errors.New("invalid mutation scenario")
		}
		seen[c.Label] = true
		if _, err := regexp.Compile(c.Expected); err != nil {
			return nil, err
		}
		if c.Expected == "" || c.Test == "" {
			return nil, errors.New("missing assertion")
		}
		if _, err := regexp.Compile("^(" + c.Test + ")$"); err != nil {
			return nil, err
		}
		for _, p := range c.Patches {
			if filepath.Base(p.File) != p.File || strings.ContainsAny(p.File, "/\\\x00") || !strings.HasSuffix(p.File, ".go") || p.Old == "" || p.Old == p.New || len(p.Old)+len(p.New) > 256<<10 {
				return nil, errors.New("unsafe mutation patch")
			}
		}
	}
	return cases, nil
}

func save(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0600)
}

func campaign(module, work, output string) (result report, retErr error) {
	result = report{Weakening: "none", Hashes: map[string]string{}}
	cases, err := parsePlan(canonicalPlan)
	if err != nil {
		return result, err
	}
	if err := os.Mkdir(work, 0700); err != nil {
		return result, fmt.Errorf("mutation work directory must be new: %w", err)
	}
	if err := os.MkdirAll(output, 0700); err != nil {
		return result, err
	}
	type original struct {
		data []byte
		mode os.FileMode
	}
	originals := map[string]original{}
	for _, name := range []string{"go.mod", "go.sum"} {
		data, err := os.ReadFile(filepath.Join(module, name))
		if err != nil {
			return result, err
		}
		if err := os.WriteFile(filepath.Join(work, name), data, 0600); err != nil {
			return result, err
		}
	}
	packageDir := filepath.Join("internal", "nativechat")
	err = filepath.WalkDir(filepath.Join(module, packageDir), func(path string, entry os.DirEntry, e error) error {
		if e != nil {
			return e
		}
		relative, e := filepath.Rel(module, path)
		if e != nil {
			return e
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return errors.New("source symlink refused")
		}
		target := filepath.Join(work, relative)
		if entry.IsDir() {
			return os.MkdirAll(target, 0700)
		}
		info, e := entry.Info()
		if e != nil {
			return e
		}
		if !info.Mode().IsRegular() {
			return errors.New("nonregular source refused")
		}
		data, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		originals[relative] = original{data, info.Mode().Perm()}
		result.Hashes[relative] = fmt.Sprintf("%x", sha256.Sum256(data))
		return os.WriteFile(target, data, info.Mode().Perm())
	})
	if err != nil {
		return result, err
	}
	restore := func() error {
		for path, o := range originals {
			if e := os.WriteFile(filepath.Join(work, path), o.data, o.mode); e != nil {
				return e
			}
		}
		return nil
	}
	defer func() {
		if err := restore(); err != nil {
			retErr = errors.Join(retErr, err)
		}
		result.Restored = true
		result.Unchanged = true
		for path, o := range originals {
			private, e := os.ReadFile(filepath.Join(work, path))
			if e != nil || !bytes.Equal(private, o.data) {
				result.Restored = false
			}
			candidate, e := os.ReadFile(filepath.Join(module, path))
			if e != nil || !bytes.Equal(candidate, o.data) {
				result.Unchanged = false
			}
		}
		if !result.Restored || !result.Unchanged {
			retErr = errors.Join(retErr, errors.New("source changed during mutation evidence"))
			result.Complete = false
		}
		if err := save(filepath.Join(output, "report.json"), result); err != nil {
			retErr = errors.Join(retErr, err)
		}
	}()
	for _, c := range cases {
		if err := restore(); err != nil {
			return result, err
		}
		for _, p := range c.Patches {
			path := filepath.Join(work, packageDir, p.File)
			data, err := os.ReadFile(path)
			if err != nil {
				return result, err
			}
			if !bytes.Contains(data, []byte(p.Old)) {
				return result, fmt.Errorf("%s: mutation anchor missing in %s", c.Label, p.File)
			}
			if err := os.WriteFile(path, bytes.Replace(data, []byte(p.Old), []byte(p.New), 1), 0600); err != nil {
				return result, err
			}
		}
		r := mutationResult{Mutant: c.Label, Classification: "deterministic"}
		if c.Repetitions == 3 {
			r.Classification = "I/O/concurrency/process"
		}
		for n := 1; n <= c.Repetitions; n++ {
			ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
			command := exec.CommandContext(ctx, "go", "test", "-p", "1", "-count=1", "-timeout", "90s", "-run", "^("+c.Test+")$", "./internal/nativechat")
			command.Dir = work
			command.Env = append(os.Environ(), "GOMAXPROCS=2")
			data, err := command.CombinedOutput()
			cancel()
			exit := 0
			if err != nil {
				exit = 1
				if e, ok := err.(*exec.ExitError); ok {
					exit = e.ExitCode()
				}
			}
			if err := os.WriteFile(filepath.Join(output, fmt.Sprintf("%s-%d.log", c.Label, n)), data, 0600); err != nil {
				return result, err
			}
			killed := exit != 0 && bytes.Contains(data, []byte("--- FAIL:")) && regexp.MustCompile(c.Expected).Match(data)
			r.Runs = append(r.Runs, runResult{n, exit, killed})
			result.Runs++
			if !killed {
				result.Results = append(result.Results, r)
				result.Mutants = len(result.Results)
				return result, fmt.Errorf("%s run%d did not die at intended assertion", c.Label, n)
			}
		}
		result.Results = append(result.Results, r)
		result.Mutants = len(result.Results)
		fmt.Printf("%s: %d intended kills\n", c.Label, c.Repetitions)
	}
	result.Complete = true
	return result, nil
}

func main() {
	module := flag.String("module", "", "Go module")
	work := flag.String("work", "", "new private mutation directory")
	output := flag.String("output", "", "evidence directory")
	flag.Parse()
	if *module == "" || *work == "" || *output == "" {
		fmt.Fprintln(os.Stderr, "--module, --work and --output required")
		os.Exit(2)
	}
	result, err := campaign(*module, *work, *output)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	_ = json.NewEncoder(os.Stdout).Encode(result)
}
