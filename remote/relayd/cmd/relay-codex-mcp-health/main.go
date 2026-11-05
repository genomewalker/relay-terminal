package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"github.com/relay-terminal/relayd/internal/codexmcphealth"
	"os"
)

func main() {
	args := os.Args[1:]
	var e error
	if len(args) > 0 && args[0] == "--fixture-helper" {
		e = codexmcphealth.FixtureHelper(args[1:], os.Stdin, os.Stdout)
	} else if len(args) > 0 && args[0] == "--recovery-fixture" {
		e = codexmcphealth.RecoveryFixture(context.Background(), args[1:], os.Stdout, os.Stderr)
	} else {
		e = codexmcphealth.Run(context.Background(), args, os.Stdout, os.Stderr)
	}
	if errors.Is(e, flag.ErrHelp) {
		return
	}
	if e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
