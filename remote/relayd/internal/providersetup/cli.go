package providersetup

import (
	"context"
	"fmt"
	"io"
	"os"
)

// Main operates only on the explicit home provided by its caller. The installed
// commands pass os.UserHomeDir; every test supplies a private temporary home.
func Main(ctx context.Context, args []string, home string, in io.Reader, out, errout io.Writer) int {
	assets := DefaultAssets()
	fail := func(e error) int { fmt.Fprintln(errout, e); return 1 }
	if len(args) > 0 && args[0] == "--assets-base64" {
		if len(args) < 2 {
			return fail(fmt.Errorf("missing bundle assets"))
		}
		var e error
		assets, e = DecodeAssets(args[1])
		if e != nil {
			return fail(e)
		}
		args = args[2:]
	}
	action := "audit"
	if len(args) > 0 {
		action = args[0]
	}
	if action == "migrate-quota-statusline" {
		if len(args) != 3 {
			return fail(fmt.Errorf("migration requires reviewed settings and legacy source sha256 values"))
		}
		store, e := Open(home)
		if e != nil {
			return fail(e)
		}
		defer store.Close()
		if e = store.MigrateQuotaStatusline(home, args[1], args[2]); e != nil {
			return fail(e)
		}
		fmt.Fprintln(out, "Managed quota status line migrated; renderer and other settings preserved.")
		return 0
	}
	if len(args) > 1 {
		return fail(fmt.Errorf("unexpected provider setup arguments"))
	}
	if e := ValidateAction(action); e != nil {
		return fail(e)
	}
	if action == "bundle" {
		raw, e := Bundle(assets)
		if e != nil {
			return fail(e)
		}
		if _, e = out.Write(raw); e != nil {
			return fail(e)
		}
		return 0
	}
	if action == "statusline" {
		code, e := (Runtime{Home: home, Env: os.Environ()}).Statusline(ctx, in, out, errout)
		if e != nil {
			return fail(e)
		}
		return code
	}
	store, e := Open(home)
	if e != nil {
		return fail(e)
	}
	defer store.Close()
	switch action {
	case "install-shell-ui":
		if e = store.Install(assets); e != nil {
			return fail(e)
		}
		fmt.Fprintln(out, "Shared prompt and cc-status launcher installed; other Claude settings preserved.")
		return 0
	case "repair-chitta-failure":
		changed, e := store.Repair()
		if e != nil {
			return fail(e)
		}
		old, e := store.read(adapterPath)
		if e != nil {
			return fail(e)
		}
		if changed {
			fmt.Fprintln(out, "Repaired", adapterPath, hash(old.raw), "private backup retained")
		} else {
			fmt.Fprintln(out, "Already repaired", hash(old.raw))
		}
		return 0
	}
	var report Report
	if action == "apply" {
		report, e = store.Apply(assets)
	} else {
		report, e = store.Audit(assets)
	}
	if e != nil {
		return fail(e)
	}
	if e = FormatReport(report, out); e != nil {
		return fail(e)
	}
	if report.Drift {
		return 1
	}
	return 0
}
