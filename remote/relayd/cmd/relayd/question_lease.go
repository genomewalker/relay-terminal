package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/relay-terminal/relayd/internal/daemon"
)

// relayd question-lease list
// relayd question-lease reconcile <op-id> [--apply]
//
// Reports, and with --apply resolves, one unresolved question-thread lease_claim
// whose reply never arrived. Without --apply nothing is written. A release is
// never reconciled.
func runQuestionLease(arguments []string) {
	usage := func() {
		fmt.Fprintln(os.Stderr, "Usage: relayd question-lease list | reconcile <op-id> [--apply]")
		os.Exit(2)
	}
	if len(arguments) == 0 {
		usage()
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	switch arguments[0] {
	case "list":
		journal, err := daemon.ListQuestionLeaseJournal()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		_ = encoder.Encode(journal)
	case "reconcile":
		if len(arguments) < 2 {
			usage()
		}
		flags := flag.NewFlagSet("question-lease reconcile", flag.ExitOnError)
		apply := flags.Bool("apply", false, "resolve the claim when the proof holds (default: report only)")
		flags.Parse(arguments[2:])
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		receipt, err := daemon.ReconcileQuestionLeaseClaim(ctx, arguments[1], *apply)
		_ = encoder.Encode(receipt)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	default:
		usage()
	}
}
