package rotationtext

import (
	"os"
	"regexp"
	"strings"
	"unicode"
)

// Python's re differs from RE2 in three ways that matter here: \b uses
// Unicode word characters, \s is str.isspace, and IGNORECASE folds 'i' with
// U+0130/U+0131. The patterns below spell out \s and those folds explicitly;
// \b is checked around each candidate by subBounded.
const pySpace = `\t\n\x0b\x0c\r\x1c-\x20\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}`

var (
	pemPattern     = regexp.MustCompile(`-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----`)
	skPattern      = regexp.MustCompile(`sk-(?:ant-)?[A-Za-z0-9_-]{16,}`)
	githubPattern  = regexp.MustCompile(`(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})`)
	awsPattern     = regexp.MustCompile(`(?:AKIA|ASIA)[A-Z0-9]{16}`)
	jwtPattern     = regexp.MustCompile(`eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`)
	bearerPattern  = regexp.MustCompile(`(?i)Bearer[ \t]+[A-Za-z0-9._~+/\x{130}\x{131}-]{8,}=*`)
	assignPattern  = regexp.MustCompile(`(?i)((?:ap[i\x{130}\x{131}][_-]?key|access[_-]?token|refresh[_-]?token|cl[i\x{130}\x{131}]ent[_-]?secret|password|author[i\x{130}\x{131}]zat[i\x{130}\x{131}]on)["']?[` + pySpace + `]*[:=][` + pySpace + `]*["']?)([^` + pySpace + `,"'}]{8,})`)
	secretPattern  = regexp.MustCompile(`(?i)(token|secret|passwd|ap[i\x{130}\x{131}][_-]?key)(["']?[` + pySpace + `]*[:=][` + pySpace + `]*["']?)([^` + pySpace + `,"'}]{6,})`)
	credentialEnvs = []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"}
)

// pyIsWord is the sre word class for str patterns: str.isalnum() or "_".
func pyIsWord(r rune) bool {
	return r == '_' || unicode.IsLetter(r) || unicode.IsNumber(r)
}

func wordBefore(s string, i int) bool {
	if i == 0 {
		return false
	}
	j := i - 1
	for j > 0 && s[j]&0xc0 == 0x80 {
		j--
	}
	r, _ := decodeWTF8(s, j)
	return pyIsWord(r)
}

func wordAt(s string, i int) bool {
	if i >= len(s) {
		return false
	}
	r, _ := decodeWTF8(s, i)
	return pyIsWord(r)
}

// subBounded is re.subn for a pattern that, with lead, begins with \b and,
// with trail, ends with \b next to word characters. A candidate rejected by a
// boundary fails at that start position only, as in a backtracking engine.
func subBounded(pattern *regexp.Regexp, s string, lead, trail bool, replace func(groups []string) string) (string, int) {
	var out strings.Builder
	last, pos, count := 0, 0, 0
	for pos <= len(s) {
		loc := pattern.FindStringSubmatchIndex(s[pos:])
		if loc == nil {
			break
		}
		start, end := pos+loc[0], pos+loc[1]
		if lead && wordBefore(s, start) || trail && wordAt(s, end) {
			_, size := decodeWTF8(s, start)
			pos = start + size
			continue
		}
		groups := make([]string, len(loc)/2)
		for g := range groups {
			if loc[2*g] >= 0 {
				groups[g] = s[pos+loc[2*g] : pos+loc[2*g+1]]
			}
		}
		out.WriteString(s[last:start])
		out.WriteString(replace(groups))
		last, pos = end, end
		count++
		if end == start {
			pos++
		}
	}
	if count == 0 {
		return s, 0
	}
	out.WriteString(s[last:])
	return out.String(), count
}

func redacted([]string) string { return "[REDACTED]" }

// redactEvidence is redact_evidence: best-effort credential redaction,
// supplementary to the source allowlist.
func redactEvidence(evidence string) (string, int) {
	count := 0
	for _, name := range credentialEnvs {
		secret := pyStrip(os.Getenv(name))
		if pyLen(secret) >= 8 && strings.Contains(evidence, secret) {
			count += strings.Count(evidence, secret)
			evidence = strings.ReplaceAll(evidence, secret, "[REDACTED]")
		}
	}
	var found int
	evidence, found = subBounded(pemPattern, evidence, false, false, redacted)
	count += found
	for _, step := range []struct {
		pattern *regexp.Regexp
		trail   bool
	}{{skPattern, false}, {githubPattern, false}, {awsPattern, true}, {jwtPattern, false}, {bearerPattern, false}} {
		evidence, found = subBounded(step.pattern, evidence, true, step.trail, redacted)
		count += found
	}
	evidence, found = subBounded(assignPattern, evidence, true, false, func(groups []string) string {
		return groups[1] + "[REDACTED]"
	})
	return evidence, count + found
}

// containsSKToken is re.search(r"\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}", s).
func containsSKToken(s string) bool {
	_, found := subBounded(skPattern, s, true, false, redacted)
	return found > 0
}

// redactAssistantPayload redacts a copy of a value sent to the model: every
// string at every depth, whatever its key name; dictionary keys are kept.
// depth counts Python frames so deep nesting fails as RecursionError would.
func redactAssistantPayload(value any, key string, depth int) any {
	if depth > assistantRedactionDepthLimit {
		raise("RecursionError")
	}
	switch v := value.(type) {
	case string:
		// redact_evidence and re.subn/_compile reach four frames deeper (measured).
		if depth+4 > assistantRedactionDepthLimit {
			raise("RecursionError")
		}
		text, _ := redactEvidence(v)
		// Broader than drafts: any token/secret assignment, as the app redacts.
		text, _ = subBounded(secretPattern, text, true, false, func(groups []string) string {
			return groups[1] + groups[2] + "[REDACTED]"
		})
		if key != "" && pyLen(key) >= 8 {
			text = strings.ReplaceAll(text, key, "[REDACTED]")
		}
		return text
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = redactAssistantPayload(item, key, depth+1)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for name, item := range v {
			out[name] = redactAssistantPayload(item, key, depth+1)
		}
		return out
	}
	return value
}

// redactAssistantMessages keeps only the exact envelope fields verbatim
// (message role; block type; tool_use id and name; tool_result tool_use_id
// and is_error). Everything else, including tool input and results, is redacted.
func redactAssistantMessages(messages []any, key string) []any {
	envelope := map[string][]string{"tool_use": {"type", "id", "name"}, "tool_result": {"type", "tool_use_id", "is_error"}, "thinking": {"type", "thinking", "signature"}, "redacted_thinking": {"type", "data"}}
	out := make([]any, 0, len(messages))
	for _, raw := range messages {
		message := raw.(map[string]any)
		content := message["content"]
		if blocks, ok := content.([]any); ok {
			redactedBlocks := make([]any, 0, len(blocks))
			for _, rawBlock := range blocks {
				block := rawBlock.(map[string]any)
				kind, _ := block["type"].(string)
				kept, ok := envelope[kind]
				if !ok {
					kept = []string{"type"}
				}
				copyBlock := make(map[string]any, len(block))
				for name, item := range block {
					if strIn(name, kept...) {
						copyBlock[name] = item
					} else {
						copyBlock[name] = redactAssistantPayload(item, key, 1)
					}
				}
				redactedBlocks = append(redactedBlocks, copyBlock)
			}
			content = redactedBlocks
		} else {
			content = redactAssistantPayload(content, key, 1)
		}
		out = append(out, map[string]any{"role": message["role"], "content": content})
	}
	return out
}
