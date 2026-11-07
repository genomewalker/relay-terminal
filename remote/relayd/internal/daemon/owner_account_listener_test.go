package daemon

import "testing"

// The recorded owner account reaches the listener's argv and survives a
// durable registration, so a restarted listener searches the same account.
func TestPeerListenerSpecCarriesRecordedOwnerAccount(t *testing.T) {
	f := newListenerFixture(t)
	s := f.server()
	spec := f.spec("route-a", drainingListener)
	spec.Executable = "/usr/local/bin/relayd"
	spec.Interpreter, spec.Script = "", ""
	spec.OwnerAccount = "/Users/example/.claude-max"
	if err := spec.validate(); err != nil {
		t.Fatalf("valid account refused: %v", err)
	}
	argv := spec.argv()
	if len(argv) != 8 || argv[7] != spec.OwnerAccount {
		t.Fatalf("argv = %q", argv)
	}
	if err := s.recordPeerListener(spec, "", "job-account"); err != nil {
		t.Fatal(err)
	}
	entry, err := f.entry(s, "route-a")
	if err != nil || entry.spec().OwnerAccount != spec.OwnerAccount {
		t.Fatalf("registry lost the account: %+v %v", entry, err)
	}
	for _, bad := range []string{"relative/acct", "/Users/example/../acct", "/Users/example/acct/"} {
		spec.OwnerAccount = bad
		if spec.validate() == nil {
			t.Fatalf("invalid account %q accepted", bad)
		}
	}
}
