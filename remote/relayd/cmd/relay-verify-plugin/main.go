package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/relay-terminal/relayd/internal/pluginverify"
	"os"
)

func main() {
	if len(os.Args) == 2 && (os.Args[1] == "--help" || os.Args[1] == "-h") {
		fmt.Println("usage: relay-verify-plugin HELPER FIXTURE [--ssh HOST]\nUse a staged helper and disposable /tmp fixture only.")
		return
	}
	o, e := pluginverify.ParseArgs(os.Args[1:])
	if e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(2)
	}
	r, e := pluginverify.Run(context.Background(), o)
	if e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
	json.NewEncoder(os.Stdout).Encode(r)
}
