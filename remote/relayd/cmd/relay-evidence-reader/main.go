// relay-evidence-reader is the only MCP server given to a dedicated research
// worker. It serves an allowlist of evidence files bound to the research
// contract hash; see internal/evidencereader.
//
// Usage: relay-evidence-reader --allowlist PATH --allowlist-sha256 HEX --contract-sha256 HEX
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/relay-terminal/relayd/internal/evidencereader"
)

func main() {
	flags := flag.NewFlagSet("relay-evidence-reader", flag.ContinueOnError)
	allowlist := flags.String("allowlist", "", "absolute path of the evidence allowlist JSON")
	allowlistSHA := flags.String("allowlist-sha256", "", "sha256 of the allowlist file bytes")
	contractSHA := flags.String("contract-sha256", "", "research contract sha256 the allowlist must name")
	if err := flags.Parse(os.Args[1:]); err != nil || flags.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: relay-evidence-reader --allowlist PATH --allowlist-sha256 HEX --contract-sha256 HEX")
		os.Exit(2)
	}
	reader, err := evidencereader.Open(*allowlist, *allowlistSHA, *contractSHA)
	if err != nil {
		// Refuse to start: a worker with a required reader then cannot begin.
		fmt.Fprintln(os.Stderr, "relay-evidence-reader refused:", err)
		os.Exit(1)
	}
	if err := reader.Serve(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "relay-evidence-reader:", err)
		os.Exit(1)
	}
}
