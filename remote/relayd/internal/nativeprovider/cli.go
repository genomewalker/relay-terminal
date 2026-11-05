package nativeprovider

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
)

func CLI(kind string, args []string, out, errout io.Writer) int {
	for _, a := range args {
		if a == "--help" || a == "-h" {
			fmt.Fprintln(out, "Native provider lifecycle tool:", kind, "(build ROOT TARGET [--native-bundle]; install --codex PATH --worker PATH [--code-mode-host PATH] [--expected-manifest PATH] [--stage-only]; repair ROOT SOURCE)")
			return 0
		}
	}
	var result map[string]any
	var err error
	fs := flag.NewFlagSet(kind, flag.ContinueOnError)
	fs.SetOutput(errout)
	switch kind {
	case "build":
		bundle := false
		pos := []string{}
		for _, a := range args {
			if a == "--native-bundle" {
				bundle = true
			} else {
				pos = append(pos, a)
			}
		}
		if len(pos) != 2 {
			fmt.Fprintln(errout, "usage: relay-build-codehost ROOT TARGET [--native-bundle]")
			return 2
		}
		err = Build(pos[0], pos[1], bundle, Execute)
	case "install":
		var o InstallOptions
		fs.StringVar(&o.Codex, "codex", "", "Codex executable")
		fs.StringVar(&o.Worker, "worker", "", "peer worker")
		fs.StringVar(&o.Host, "code-mode-host", "", "tool host")
		fs.StringVar(&o.Expected, "expected-manifest", "", "acceptance manifest")
		fs.BoolVar(&o.StageOnly, "stage-only", false, "prepare without activating")
		if fs.Parse(args) != nil || fs.NArg() != 0 || o.Codex == "" || o.Worker == "" {
			return 2
		}
		o.Home, err = os.UserHomeDir()
		if err == nil {
			result, err = Install(o, Execute)
		}
	case "repair":
		if len(args) != 2 {
			fmt.Fprintln(errout, "usage: relay-repair-codehost ROOT SOURCE")
			return 2
		}
		result, err = Repair(args[0], args[1], Execute)
	default:
		return 2
	}
	if err != nil {
		fmt.Fprintln(errout, err)
		return 1
	}
	if result != nil {
		if e := json.NewEncoder(out).Encode(result); e != nil {
			fmt.Fprintln(errout, e)
			return 1
		}
	}
	return 0
}
