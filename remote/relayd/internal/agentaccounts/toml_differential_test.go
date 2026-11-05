package agentaccounts

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// The reference answers are Python's standard tomllib, recorded once for every
// document of the fixed corpus below and for every document Relay re-emits
// from it (testdata/toml_differential/tomllib.json, keyed by the SHA-256 of
// the document). For each the record says whether the document parses, its
// key paths, and its string values at table keys (never printed by the test).
// A null answer is a document tomllib refuses.
type tomllibAnswer struct {
	Paths   []string          `json:"paths"`
	Strings map[string]string `json:"strings"`
}

func loadTomllibAnswers(t *testing.T) map[string]*tomllibAnswer {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "toml_differential", "tomllib.json"))
	if err != nil {
		t.Fatal(err)
	}
	var golden struct {
		Answers map[string]*tomllibAnswer `json:"answers"`
	}
	if err := json.Unmarshal(data, &golden); err != nil || len(golden.Answers) < 8000 {
		t.Fatalf("invalid tomllib golden (%d answers): %v", len(golden.Answers), err)
	}
	return golden.Answers
}

// tomllibAnswerFor is the recorded answer for text; known is false for a
// document tomllib was never asked about.
func tomllibAnswerFor(answers map[string]*tomllibAnswer, text string) (answer *tomllibAnswer, known bool) {
	sum := sha256.Sum256([]byte(text))
	answer, known = answers[hex.EncodeToString(sum[:])]
	return answer, known
}

func relayTOMLAnswer(document *tomlDocument) tomllibAnswer {
	answer := tomllibAnswer{Strings: map[string]string{}}
	seen := map[string]bool{}
	var walk func(table *tomlTable, path []string)
	walk = func(table *tomlTable, path []string) {
		for _, key := range table.keys {
			here := append(append([]string(nil), path...), key)
			joined := strings.Join(here, "\x00")
			seen[joined] = true
			switch child := table.values[key].(type) {
			case string:
				answer.Strings[joined] = child
			case *tomlTable:
				walk(child, here)
			}
		}
	}
	walk(document.root, nil)
	tomlWalk(document.root, nil, func(path []string) { seen[strings.Join(path, "\x00")] = true })
	for path := range seen {
		answer.Paths = append(answer.Paths, path)
	}
	sort.Strings(answer.Paths)
	return answer
}

// tomlDifferentialCorpus is the fixed documents of the TOML tests and the
// review, Codex-shaped configs, deterministic mutations of all of them and the
// inputs the native fuzzer saved; fixed counts them. Documents from
// RELAY_TOML_DIFFERENTIAL_CORPUS follow.
func tomlDifferentialCorpus(t *testing.T) (corpus []string, fixed int) {
	seeds := []string{
		"a = 1\n", "[t]\nb = \"x\\\"y\"\n", "e = { k = [1, { x = 'y' }] }\n", "[[a.b]]\nc.d = 9223372036854775807\n",
		"x = \"\\u00e9\"\r\n", "0.0=0\n00=0",
		"[mcp_servers.fixture]\ncommand=\"node\"\ninvalid_date=2000-99-99\n", "a = 25:61:00\n",
		"a = 1979-05-27T07:32:00Z\n", "a = 1979-05-27 07:32:00\n", "a = 07:32:00\n", "a = 1979-05-27\n",
		"model = \"o3\" # trailing\n[mcp_servers.db]\ncommand = \"node\"\nargs = [\"a\", 'b', [1, 2.5e3], { k = \"v\" }]\n" +
			"env = { TOKEN = \"prefix\\\", NOT_A_KEY = suffix\", \"QUOTED.KEY\" = 'x', nested.deep = true }\n" +
			"[mcp_servers.\"web app\".http_headers]\nAuthorization = \"Bearer \\u0041\"\n",
		"forced_login_method = \"chatgpt\"\nforced_chatgpt_workspace_id = \"w\"\n[profiles.p]\nmodel = \"m\"\n",
		"[mcp_servers.a]\ncommand = \"npx\"\nargs = [\"-y\", \"pkg\"]\nenv = { A = \"1\" }\nstartup_timeout_sec = 20.5\n",
		"[mcp_servers.h]\nurl = \"https://example.invalid/mcp\"\nhttp_headers = { \"X-Key\" = \"v\" }\nenv_http_headers = { X = \"Y\" }\n",
		"a.b.c = 1\na.b.d = 2\n[a.e]\nf = 3\n", "[a]\nb = 1\n[a.c]\nd = 2\n[[a.list]]\nx = 1\n[[a.list]]\nx = 2\n",
		"a = [\n  1,\n  2, # c\n]\n", "a = { }\n", "\"\" = 1\n", "'lit.key' = 'v'\n", "a = 0x1F\nb = 0o17\nc = 0b1\nd = -0\ne = +1_000\n",
		"a = inf\nb = -nan\nc = 1e-5\nd = 6.626e-34\n", "a = \"\\b\\t\\n\\f\\r\\\"\\\\\\U0001F600\"\n",
		"a = 9223372036854775808\n", "a = 0x1_0000_0000_0000_0000\n", "a = 01\n", "a = 1.\n", "a = .5\n", "a = 1__0\n",
		"a = \"\"\"x\"\"\"\n", "a = '''x'''\n", "a = \"x\\q\"\n", "a = 1\na = 2\n", "[t]\n[t]\n", "t.a = 1\n[t]\nb = 2\n",
		"t = { a = 1 }\n[t.b]\nc = 2\n", "a = 1 b = 2\n", "a = 1\n[[a]]\n", "a = \"x\x01y\"\n", "[a]b = 1\n", "a = [1,,2]\n",
		"a = { b = 1, }\n", "a = { b = 1\n}\n", "[a.]\n", "[.a]\n", "a..b = 1\n", "= 1\n", "a =\n", "a = true\nb = false\n",
		"a = TRUE\n", "a=1#c\n", "[ a . b ]\nc=1\n", "[[ a ]]\n", "a = \"\\u00\"\n", "a = \"\\uD800\"\n",
	}
	alphabet := []byte("\"'=[]{}.,#\n \t\\-:+_0123456789abcetTZx")
	random := rand.New(rand.NewSource(20261017))
	corpus = append([]string(nil), seeds...)
	for _, seed := range seeds {
		for round := 0; round < 150; round++ {
			text := []byte(seed)
			for edits := 1 + random.Intn(3); edits > 0; edits-- {
				position := random.Intn(len(text) + 1)
				switch random.Intn(3) {
				case 0:
					text = append(text[:position], append([]byte{alphabet[random.Intn(len(alphabet))]}, text[position:]...)...)
				case 1:
					if position < len(text) {
						text = append(text[:position], text[position+1:]...)
					}
				default:
					if position < len(text) {
						end := position + random.Intn(len(text)-position) + 1
						text = append(text[:end], append(append([]byte(nil), text[position:end]...), text[end:]...)...)
					}
				}
			}
			corpus = append(corpus, string(text))
		}
	}
	// Inputs the native fuzzer saved, and optionally its cached corpus
	// (RELAY_TOML_DIFFERENTIAL_CORPUS: $(go env GOCACHE)/fuzz/<module>/internal/agentaccounts/FuzzParseTOML).
	for _, directory := range []string{filepath.Join("testdata", "fuzz", "FuzzParseTOML"), os.Getenv("RELAY_TOML_DIFFERENTIAL_CORPUS")} {
		if directory != filepath.Join("testdata", "fuzz", "FuzzParseTOML") {
			fixed = len(corpus)
		}
		if directory == "" {
			continue
		}
		entries, err := os.ReadDir(directory)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			data, err := os.ReadFile(filepath.Join(directory, entry.Name()))
			if err == nil {
				if value, ok := strings.CutPrefix(string(data), "go test fuzz v1\nstring("); ok {
					if text, err := strconv.Unquote(strings.TrimSuffix(strings.TrimSpace(value), ")")); err == nil {
						corpus = append(corpus, text)
					}
				}
			}
		}
	}
	return corpus, fixed
}

// Relay's reader may refuse more than standard TOML (multi-line strings,
// dates and times, integers beyond 64 bits), but whatever it accepts the
// standard reader must accept with the same key paths and string values, and
// what Relay writes back from it must also be standard TOML that Relay reads
// back to the same keys. A document of the fixed corpus, or a re-emitted one,
// without a recorded answer fails: the corpus, the parser and the emitter are
// pinned to the recording. Documents only from RELAY_TOML_DIFFERENTIAL_CORPUS
// have no recorded answer and get the round-trip check alone.
func TestTOMLDifferentialAgainstRecordedTomllib(t *testing.T) {
	answers := loadTomllibAnswers(t)
	corpus, fixed := tomlDifferentialCorpus(t)
	accepted, emittedCount, refusedValid, bothRefused, unrecorded := 0, 0, 0, 0, 0
	for index, text := range corpus {
		document, err := parseTOML(text)
		reference, known := tomllibAnswerFor(answers, text)
		if !known && index < fixed {
			t.Fatalf("document %d of the fixed corpus has no recorded tomllib answer", index)
		}
		switch {
		case !known:
			unrecorded++
		case err != nil && reference == nil:
			bothRefused++
			continue
		case err != nil:
			refusedValid++
			continue
		case reference == nil:
			t.Errorf("document %d: Relay accepted TOML the standard reader refuses %q", index, text)
			continue
		}
		if err != nil {
			continue
		}
		ours := relayTOMLAnswer(document)
		if known {
			accepted++
			if strings.Join(ours.Paths, "\x01") != strings.Join(reference.Paths, "\x01") {
				t.Errorf("document %d: key paths differ from the standard reader", index)
			}
			for path, value := range reference.Strings {
				if ours.Strings[path] != value {
					t.Errorf("document %d: a string value differs from the standard reader", index)
					break
				}
			}
		}
		var out strings.Builder
		tomlEmitBody(&out, nil, document.root)
		emitted := out.String()
		if known {
			emittedCount++
			rewritten, recorded := tomllibAnswerFor(answers, emitted)
			if !recorded {
				t.Errorf("document %d: Relay emitted a document tomllib never checked; the emitter changed", index)
			} else if rewritten == nil || strings.Join(rewritten.Paths, "\x01") != strings.Join(ours.Paths, "\x01") {
				t.Errorf("emitted document %d is not standard TOML with the same key paths", index)
			}
		}
		reread, err := parseTOML(emitted)
		if err != nil {
			t.Errorf("document %d: Relay cannot read its own emitted document: %v", index, err)
			continue
		}
		again := relayTOMLAnswer(reread)
		if strings.Join(again.Paths, "\x01") != strings.Join(ours.Paths, "\x01") ||
			len(again.Strings) != len(ours.Strings) {
			t.Errorf("document %d: re-emitted document reads back to other keys", index)
			continue
		}
		for path, value := range ours.Strings {
			if again.Strings[path] != value {
				t.Errorf("document %d: re-emitted document reads back to another string", index)
				break
			}
		}
	}
	if accepted < 900 || bothRefused < 1000 {
		t.Fatalf("corpus lost coverage: both accept %d, both refuse %d", accepted, bothRefused)
	}
	t.Logf("corpus %d: both accept %d (re-emitted %d, all standard), both refuse %d, only Relay refuses %d, unrecorded %d",
		len(corpus), accepted, emittedCount, bothRefused, refusedValid, unrecorded)
}

// The recorded corpus has no raw control character inside a string or
// comment, so the rule tomllib applies there (TOML 1.0: only tab is allowed)
// is stated directly: every C0 control except tab, and DEL, is refused in a
// basic string, a literal string and a comment, while tab is accepted.
func TestTOMLRefusesControlCharactersLikeTomllib(t *testing.T) {
	forms := map[string]string{"basic string": "a = \"x%sy\"\n", "literal string": "a = 'x%sy'\n", "comment": "a = 1 # x%sy\n"}
	for name, form := range forms {
		for c := 0; c <= 0x7f; c++ {
			if c >= 0x20 && c != 0x7f || c == '\n' || c == '\r' {
				continue
			}
			text := strings.Replace(form, "%s", string(rune(c)), 1)
			_, err := parseTOML(text)
			if c == '\t' && err != nil {
				t.Fatalf("%s: tab refused: %v", name, err)
			}
			if c != '\t' && err == nil {
				t.Fatalf("%s: control 0x%02x accepted", name, c)
			}
		}
	}
}
