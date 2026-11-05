package appupdate

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
)

func CLI(kind string, args []string, out, errout io.Writer) int {
	fs := flag.NewFlagSet(kind, flag.ContinueOnError)
	fs.SetOutput(errout)
	for _, a := range args {
		if a == "-h" || a == "--help" {
			fmt.Fprintln(out, "relay-restart [--candidate APP | --preservation-root ROOT] [--app APP] [--timeout 1..60] [--replay-trace FILE]; relay-preserving-update stage|apply|verify [--root ROOT] [--candidate APP] [--ui-closed] [--workspace-tools]")
			return 0
		}
	}
	var result map[string]any
	var err error
	engine, err := New()
	if err != nil {
		fmt.Fprintln(errout, err)
		return 1
	}
	if kind == "restart" {
		var o RestartOptions
		fs.StringVar(&o.App, "app", engine.Config.Installed, "installed app")
		fs.StringVar(&o.Candidate, "candidate", "", "signed candidate")
		fs.StringVar(&o.Preservation, "preservation-root", "", "native preservation receipt")
		fs.StringVar(&o.Trace, "replay-trace", "", "new private replay trace")
		fs.IntVar(&o.Timeout, "timeout", 30, "graceful quit timeout")
		if fs.Parse(args) != nil || fs.NArg() != 0 {
			return 2
		}
		if o.Timeout < 1 || o.Timeout > 60 || o.Candidate != "" && o.Preservation != "" {
			fmt.Fprintln(errout, "invalid timeout or mutually exclusive update modes")
			return 2
		}
		result, err = engine.Restart(o)
	} else if kind == "preserve" {
		if len(args) == 0 {
			return 2
		}
		phase := args[0]
		var root string
		var o StageOptions
		fs.StringVar(&root, "root", "", "native receipt directory")
		fs.StringVar(&o.Candidate, "candidate", "/private/tmp/relay-close-eight/Relay.app", "candidate bundle")
		fs.BoolVar(&o.UIClosed, "ui-closed", false, "UI is already closed")
		fs.BoolVar(&o.WorkspaceTools, "workspace-tools", false, "retain compatibility; whole bundle contains workspace tools")
		if fs.Parse(args[1:]) != nil || fs.NArg() != 0 {
			return 2
		}
		switch phase {
		case "stage":
			if root != "" {
				return 2
			}
			result, err = engine.Stage(o)
		case "apply":
			if root == "" {
				return 2
			}
			result, err = engine.Apply(root)
		case "verify":
			if root == "" {
				return 2
			}
			result, err = engine.Verify(root)
		default:
			return 2
		}
	} else {
		return 2
	}
	if err != nil {
		fmt.Fprintln(errout, err)
		return 1
	}
	if err = json.NewEncoder(out).Encode(result); err != nil {
		fmt.Fprintln(errout, err)
		return 1
	}
	return 0
}
