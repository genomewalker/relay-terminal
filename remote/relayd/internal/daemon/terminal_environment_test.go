package daemon

import (
	"reflect"
	"testing"
)

func TestTerminalEnvironmentRemovesLauncherColorPolicy(t *testing.T) {
	input := []string{"NO_COLOR=1", "PATH=/relay:/usr/bin:/relay:$PATH:${PATH}::/bin:", "HOME=/home/user", "LANG=en_US.UTF-8", "CUSTOM=preserved", "COLORTERM=truecolor"}
	want := []string{"PATH=/relay:/usr/bin::/bin", "HOME=/home/user", "LANG=en_US.UTF-8", "CUSTOM=preserved", "COLORTERM=truecolor"}
	got := TerminalEnvironment(input)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
	if !reflect.DeepEqual(TerminalEnvironment(got), got) {
		t.Fatal("normalization must be idempotent")
	}
	if input[0] != "NO_COLOR=1" {
		t.Fatal("input was mutated")
	}
}
