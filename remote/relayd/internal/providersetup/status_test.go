package providersetup

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestStatuslinePreservesProcessContract(t *testing.T) {
	home, _ := fixture(t)
	raw := []byte("{\"hook\":\"payload\"}\n")
	write(t, home, ".local/bin/relayd", []byte(`#!/bin/sh
set -eu
fixture_root=${0%/.local/bin/relayd}
[ -n "$fixture_root" ] || exit 91
printf '%s\n' "$@" >> "$fixture_root/argv"
case "$1" in
 claude-status-capture) cat > "$fixture_root/capture"; printf capture-noise; printf capture-error >&2; exit 9;;
 subscription-quota-statusline) cat > "$fixture_root/quota-input"; printf quota-noise; printf quota-error >&2; exit 9;;
 *) exit 88;;
esac
`))
	if e := os.Chmod(filepath.Join(home, ".local/bin/relayd"), 0700); e != nil {
		t.Fatal(e)
	}
	write(t, home, ".config/relay/cc-status.sh", []byte(`set -eu
fixture_root=${0%/.config/relay/cc-status.sh}
[ -n "$fixture_root" ] || exit 91
cat > "$fixture_root/render-input"
cat "$fixture_root/render-input"
printf '|%s|%s|%s' "${RELAY_SESSION-}" "${USER_FOOTER-}" "${HOME-}"
printf user-stderr >&2
exit 7`))
	var out, errout bytes.Buffer
	r := Runtime{Home: home, Env: []string{"HOME=" + home, "PATH=/usr/bin:/bin", "RELAY_SESSION=private-pane", "USER_FOOTER=å preserved"}}
	code, e := r.Statusline(context.Background(), bytes.NewReader(raw), &out, &errout)
	if e != nil || code != 7 {
		t.Fatalf("renderer exit=%d error=%v", code, e)
	}
	if !bytes.Equal(read(t, home, "capture"), raw) || !bytes.Equal(read(t, home, "quota-input"), raw) || !bytes.Equal(read(t, home, "render-input"), raw) {
		t.Fatal("statusline hook payload changed")
	}
	if out.String() != string(raw)+"|private-pane|å preserved|"+home || errout.String() != "user-stderr" {
		t.Fatalf("forwarding/noise stdout=%q stderr=%q", out.String(), errout.String())
	}
	expected := "claude-status-capture\n--pane\nprivate-pane\nsubscription-quota-statusline\n" + base64.StdEncoding.EncodeToString([]byte(":")) + "\n"
	if string(read(t, home, "argv")) != expected {
		t.Fatal("native quota/legacy capture command changed")
	}
}
func TestStatuslineBoundsFailuresAndDeadlines(t *testing.T) {
	for _, pane := range []string{"", "pane"} {
		t.Run(pane, func(t *testing.T) {
			calls := [][]string{}
			var captureDeadline time.Time
			r := Runtime{Home: "/private/fixture", Env: []string{"RELAY_SESSION=" + pane}, Run: func(ctx context.Context, program string, args []string, raw []byte, out, errout io.Writer) (int, error) {
				if program != "/private/fixture/.local/bin/relayd" && program != "bash" {
					t.Fatal("unexpected executable")
				}
				calls = append(calls, args)
				deadline, ok := ctx.Deadline()
				if !ok {
					t.Fatal("unbounded subprocess")
				}
				left := time.Until(deadline)
				if program != "bash" {
					if left <= 3*time.Second || left > 4*time.Second {
						t.Fatal("capture deadline changed")
					}
					if !captureDeadline.IsZero() && deadline != captureDeadline {
						t.Fatal("legacy/quota captures extended the shared budget")
					}
					captureDeadline = deadline
					if args[0] != "claude-status-capture" && (args[0] != "subscription-quota-statusline" || args[1] != base64.StdEncoding.EncodeToString([]byte(":"))) {
						t.Fatal("quota capture must be a no-op")
					}
					return 1, errors.New("capture unavailable")
				}
				if len(args) != 1 || args[0] != "/private/fixture/.config/relay/cc-status.sh" {
					t.Fatal("shared renderer changed")
				}
				if left <= 7*time.Second || left > 8*time.Second {
					t.Fatal("renderer deadline changed")
				}
				return 42, nil
			}}
			code, e := r.Statusline(context.Background(), strings.NewReader("payload"), io.Discard, io.Discard)
			if e != nil || code != 42 {
				t.Fatalf("capture failure blocked renderer %v", e)
			}
			expected := 2
			if pane != "" {
				expected = 3
			}
			if len(calls) != expected {
				t.Fatal("unexpected non-Relay capture")
			}
		})
	}
	calls := 0
	r := Runtime{Run: func(context.Context, string, []string, []byte, io.Writer, io.Writer) (int, error) {
		calls++
		return 0, nil
	}}
	if code, e := r.Statusline(context.Background(), bytes.NewReader(bytes.Repeat([]byte{'x'}, StatusInputLimit+1)), io.Discard, io.Discard); e == nil || code != 1 || calls != 0 {
		t.Fatal("oversized status reached subprocess")
	}
	if code, e := r.Statusline(context.Background(), bytes.NewReader(bytes.Repeat([]byte{'x'}, StatusInputLimit)), io.Discard, io.Discard); e != nil || code != 0 || calls != 2 {
		t.Fatal("exact boundary rejected")
	}
	r.Run = func(ctx context.Context, _ string, _ []string, _ []byte, _ io.Writer, _ io.Writer) (int, error) {
		<-ctx.Done()
		return 1, ctx.Err()
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e := r.Statusline(ctx, strings.NewReader("raw"), io.Discard, io.Discard); e == nil {
		t.Fatal("canceled renderer reported success")
	}
}
func TestStatuslinePreservesSignalExit(t *testing.T) {
	home, _ := fixture(t)
	// The quota helper is deliberately absent. Its failure must not suppress
	// the direct renderer, including the original negative signal outcome.
	write(t, home, ".config/relay/cc-status.sh", []byte("kill -TERM $$\n"))
	code, e := (Runtime{Home: home, Env: []string{"HOME=" + home, "PATH=/usr/bin:/bin"}}).Statusline(context.Background(), strings.NewReader("raw"), io.Discard, io.Discard)
	if e != nil || code != -15 {
		t.Fatalf("signal outcome=%d %v", code, e)
	}
}
func TestPortableBundleActualEntry(t *testing.T) {
	home, _ := fixture(t)
	raw, e := Bundle(DefaultAssets())
	if e != nil {
		t.Fatal(e)
	}
	write(t, home, "bundle", raw)
	write(t, home, ".local/bin/relay-provider-setup", []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HOME/received\"\n"))
	if e = os.Chmod(filepath.Join(home, ".local/bin/relay-provider-setup"), 0700); e != nil {
		t.Fatal(e)
	}
	r := Runtime{Env: []string{"HOME=" + home, "PATH=/usr/bin:/bin"}}
	code, e := r.run(context.Background(), "/bin/sh", []string{filepath.Join(home, "bundle"), "audit"}, nil, io.Discard, io.Discard)
	if e != nil || code != 0 {
		t.Fatalf("portable entry failed %v", e)
	}
	enc, e := encodedAssets(DefaultAssets())
	if e != nil {
		t.Fatal(e)
	}
	got := strings.Split(string(read(t, home, "received")), "\n")
	if !reflect.DeepEqual(got, []string{"--assets-base64", enc, "audit", ""}) {
		t.Fatal("portable entry arguments changed")
	}
}
func TestCLIAndAuditOutputDoNotExposeSettings(t *testing.T) {
	home, _ := fixture(t)
	data := baseSettings()
	data["custom"] = "private-settings-secret"
	write(t, home, settingsPath, jsonBytes(t, data))
	var initialOut, initialErr bytes.Buffer
	if Main(context.Background(), nil, home, strings.NewReader(""), &initialOut, &initialErr) != 1 {
		t.Fatal("default audit must report drift without applying")
	}
	if _, e := os.Stat(filepath.Join(home, ".config/relay/prompt.bash")); !os.IsNotExist(e) {
		t.Fatal("default audit changed provider configuration")
	}
	for _, args := range [][]string{{"bad"}, {"audit", "extra"}, {"--assets-base64"}, {"--assets-base64", "!!!", "apply"}} {
		var out, errout bytes.Buffer
		if Main(context.Background(), args, home, strings.NewReader(""), &out, &errout) != 1 || out.Len() != 0 {
			t.Fatal("CLI accepted bad arguments")
		}
	}
	var out, errout bytes.Buffer
	if Main(context.Background(), []string{"apply"}, home, strings.NewReader(""), &out, &errout) != 0 {
		t.Fatalf("CLI apply %s", errout.String())
	}
	if bytes.Contains(out.Bytes(), []byte("private-settings-secret")) || bytes.Contains(out.Bytes(), []byte("user-hook")) {
		t.Fatal("audit exposed user commands/settings")
	}
	report := Report{}
	if e := jsonDecodeReport(out.Bytes(), &report); e != nil || report.Drift {
		t.Fatalf("CLI output %v", e)
	}
	out.Reset()
	if Main(context.Background(), nil, home, strings.NewReader(""), &out, &errout) != 0 {
		t.Fatal("default audit failed")
	}
}
