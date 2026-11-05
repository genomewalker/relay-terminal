package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/relay-terminal/relayd/internal/rotationtext"
)

// runRotationTextReconcile is the operator recovery for journal_diverged:
//
//	relayd rotation-text-reconcile [--root DIR] [--apply [--retire [--helper-dir DIR]...]]
//
// --retire also retires operations.sqlite3 under the same locks, fenced
// against legacy writers (rotationtext/retire.go). It needs the SHA-256 of
// every reviewed image that may hold the legacy file or sit in a helper
// directory (--allow-image-sha256, repeatable, or --allow-image-file with one
// hash per line), and refuses unless every rotation-text executable in the
// helper directories (default: ~/.local/share/relay/bin) is on that list.
// Without --apply it only reports. It needs no relayd to stop; see
// rotationtext.ReconcileLegacy. Exit 0: reconciled or nothing to do (or a
// clean dry run); 3: conflicts, nothing written; 1: any other failure.
func runRotationTextReconcile(arguments []string) {
	flags := flag.NewFlagSet("rotation-text-reconcile", flag.ExitOnError)
	root := flags.String("root", "", "rotation-text directory (default: the worker state directory's)")
	apply := flags.Bool("apply", false, "write the merged ledger (default: report only)")
	retire := flags.Bool("retire", false, "after the fold, retire operations.sqlite3 (requires --apply)")
	var helperDirs helperDirFlag
	flags.Var(&helperDirs, "helper-dir", "helper directory whose rotation-text executables must be ledger-aware (repeatable)")
	var allowed helperDirFlag
	flags.Var(&allowed, "allow-image-sha256", "SHA-256 of a reviewed image that never writes the legacy journal (repeatable)")
	allowFile := flags.String("allow-image-file", "", "file with one reviewed image SHA-256 per line (# comments allowed)")
	flags.Parse(arguments)
	if *allowFile != "" {
		data, err := os.ReadFile(*allowFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		for _, line := range strings.Split(string(data), "\n") {
			if line = strings.TrimSpace(line); line != "" && !strings.HasPrefix(line, "#") {
				allowed = append(allowed, strings.Fields(line)[0])
			}
		}
	}
	if len(helperDirs) == 0 {
		home, err := os.UserHomeDir()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		helperDirs = helperDirFlag{filepath.Join(home, ".local", "share", "relay", "bin")}
	}
	if *root == "" {
		state := os.Getenv("XDG_STATE_HOME")
		if state == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			state = filepath.Join(home, ".local", "state")
		}
		*root = filepath.Join(state, "relay", "workers", "rotation-text")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	report, err := rotationtext.ReconcileLegacyWith(ctx, *root, rotationtext.ReconcileOptions{Apply: *apply, Retire: *retire, HelperDirs: helperDirs, AllowedImages: allowed})
	output := map[string]any{"root": *root, "apply": *apply, "retire": *retire, "report": report}
	if err != nil {
		output["error"] = err.Error()
	}
	encoded, _ := json.MarshalIndent(output, "", "  ")
	fmt.Println(string(encoded))
	switch {
	case err == nil:
	case report != nil && len(report.Conflicts) > 0:
		os.Exit(3)
	default:
		os.Exit(1)
	}
}

type helperDirFlag []string

func (f *helperDirFlag) String() string     { return fmt.Sprint([]string(*f)) }
func (f *helperDirFlag) Set(v string) error { *f = append(*f, v); return nil }
