//go:build darwin

package daemon

import "testing"

func TestForceAccountCommandDigestPreservesArgumentBoundaries(t *testing.T) {
	a := forceAccountCommandDigest([]string{"sh", "-c", "one two"})
	b := forceAccountCommandDigest([]string{"sh", "-c", "one", "two"})
	if len(a) != 64 || a == b || a != forceAccountCommandDigest([]string{"sh", "-c", "one two"}) {
		t.Fatal("command digest does not preserve exact arguments")
	}
}
