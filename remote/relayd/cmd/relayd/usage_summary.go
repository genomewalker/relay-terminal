package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/relay-terminal/relayd/internal/daemon"
)

// usage-summary is read-only: it reports per-pane agent states for a window
// from the worker event journals on this node, as JSON with schema_version.
func runUsageSummary(arguments []string) {
	flags := flag.NewFlagSet("usage-summary", flag.ExitOnError)
	sinceText := flags.String("since", "", "window start, RFC 3339 (required)")
	untilText := flags.String("until", "", "window end, RFC 3339 (default now)")
	_ = flags.Bool("json", true, "emit JSON (the only format)")
	_ = flags.Parse(arguments)
	since, err := time.Parse(time.RFC3339Nano, *sinceText)
	if err != nil {
		fatal("usage: relayd usage-summary --since RFC3339 [--until RFC3339] [--json]")
	}
	until := time.Now()
	if *untilText != "" {
		if until, err = time.Parse(time.RFC3339Nano, *untilText); err != nil {
			fatal("usage-summary: invalid --until")
		}
	}
	summary, err := daemon.UsageSummaryHere(since, until)
	if err != nil {
		fatal("usage-summary: " + err.Error())
	}
	data, err := json.Marshal(summary)
	if err != nil {
		fatal("usage-summary: " + err.Error())
	}
	fmt.Fprintln(os.Stdout, string(data))
}
