package subscriptionquota

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

func TestCodexCLIFallback(t *testing.T) {
	for _, mode := range []string{"success", "changed-account", "error", "malformed", "unknown-account"} {
		t.Run(mode, func(t *testing.T) {
			r := testReader(t)
			auth := filepath.Join(r.home, ".codex/auth.json")
			if mode != "unknown-account" {
				putPrivate(t, auth, map[string]any{"tokens": map[string]any{"account_id": "original"}})
			}
			calls := 0
			r.codexCLI = func(ctx context.Context, provider, root string) ([]byte, error) {
				calls++
				if provider != "codex" || root != filepath.Join(r.home, ".codex") {
					t.Fatal("wrong scope")
				}
				if _, ok := ctx.Deadline(); !ok {
					t.Fatal("unbounded read")
				}
				if mode == "changed-account" {
					putPrivate(t, auth, map[string]any{"tokens": map[string]any{"account_id": "other"}})
				}
				if mode == "error" {
					return nil, errors.New("private error")
				}
				if mode == "malformed" {
					return []byte(`{"id":2,"error":{"message":"private"}}`), nil
				}
				return []byte("{\"id\":3,\"result\":{\"account\":{\"email\":\"private\"}}}\n" + `{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20}},"private":"secret"}}`), nil
			}
			raw, err := r.Read(context.Background(), nil)
			if err != nil {
				t.Fatal(err)
			}
			var rows []map[string]any
			if err = json.Unmarshal(raw, &rows); err != nil {
				t.Fatal(err)
			}
			observations := 0
			for _, row := range rows {
				if row["provider"] == "codex" && row["observation"] != nil {
					observations++
					if row["account_scope"] != r.accountScope("codex") {
						t.Fatal("scope mismatch")
					}
				}
			}
			want := 0
			if mode == "success" {
				want = 1
			}
			if observations != want {
				t.Fatalf("observations %d want %d", observations, want)
			}
			if mode == "unknown-account" && calls != 0 {
				t.Fatal("read without verified account")
			}
			if strings.Contains(string(raw), "private") || strings.Contains(string(raw), "secret") {
				t.Fatal("private fields exported")
			}
			if string(raw) == "" {
				t.Fatal("empty")
			}
		})
	}
}
