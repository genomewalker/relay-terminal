package main

import "testing"

// A mismatched folder must still accept login/logout, or the wrong login
// could never be replaced from a pane; everything else is gated.
func TestCodexManagesAuth(t *testing.T) {
	for _, c := range []struct {
		arguments []string
		want      bool
	}{
		{[]string{"login"}, true},
		{[]string{"logout"}, true},
		{[]string{"--version"}, true},
		{[]string{"-m", "gpt", "--help"}, true},
		{nil, false},
		{[]string{"resume", "0198c1d2-0000-7000-8000-000000000000"}, false},
		{[]string{"exec", "login"}, false},
		{[]string{"--", "--help"}, false},
	} {
		if got := codexManagesAuth(c.arguments); got != c.want {
			t.Errorf("codexManagesAuth(%q) = %v, want %v", c.arguments, got, c.want)
		}
	}
}
