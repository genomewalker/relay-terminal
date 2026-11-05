package main

import (
	"context"
	"errors"
	"fmt"
	"github.com/relay-terminal/relayd/internal/helpercli"
	"os"
)

func main() {
	if e := helpercli.RunSettings(context.Background(), os.Args[1:], os.Stdout, os.Stderr, helpercli.DefaultSettingsDependencies()); e != nil {
		fmt.Fprintln(os.Stderr, e)
		var usage *helpercli.UsageError
		if errors.As(e, &usage) {
			os.Exit(2)
		}
		os.Exit(1)
	}
}
