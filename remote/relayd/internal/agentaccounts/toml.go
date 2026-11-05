package agentaccounts

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// A strict TOML reader for Codex's config.toml. It parses key paths, strings
// (with escapes), inline tables, arrays and table headers, so a key is never
// taken from inside a value. Scalars other than strings are kept as their
// validated source text. Syntax outside that subset (multi-line strings,
// dates and times, integers beyond 64 bits) is refused rather than guessed at. Errors name a line and column only: the
// file holds MCP environment values, which are never echoed.

type tomlTable struct {
	keys   []string
	values map[string]any
	// header: defined by a [table] header; dotted: by dotted keys; inline:
	// an inline table (closed after its definition).
	header, dotted, inline bool
}

// tomlTableArray is an array of tables ([[name]]).
type tomlTableArray struct{ tables []*tomlTable }

// tomlRaw is a validated non-string scalar (number or boolean).
type tomlRaw string

type tomlStatement struct {
	path   []string
	header bool
	// lineStart is the offset of the statement's line.
	lineStart int
}

type tomlDocument struct {
	root       *tomlTable
	statements []tomlStatement
}

func newTOMLTable() *tomlTable { return &tomlTable{values: map[string]any{}} }

func (t *tomlTable) set(key string, value any) {
	if _, ok := t.values[key]; !ok {
		t.keys = append(t.keys, key)
	}
	t.values[key] = value
}

func (t *tomlTable) table(key string) *tomlTable {
	table, _ := t.values[key].(*tomlTable)
	return table
}

type tomlParser struct {
	text string
	pos  int
	doc  *tomlDocument
}

type tomlError struct{ line, column int }

func (e tomlError) Error() string {
	return fmt.Sprintf("config.toml is not valid TOML that Relay can read (line %d, column %d)", e.line, e.column)
}

var errTOMLMultiline = errors.New("config.toml uses multi-line strings; Relay will not merge it automatically")

var errTOMLDateTime = errors.New("config.toml uses date or time values; Relay will not merge it automatically")

// tomlIntegerFits refuses an integer outside 64 bits, which Codex rejects.
func tomlIntegerFits(token string) bool {
	if strings.ContainsAny(token, ".eEin") && !strings.HasPrefix(token, "0x") {
		return true // a float (or inf/nan)
	}
	digits, base := strings.ReplaceAll(token, "_", ""), 10
	switch {
	case strings.HasPrefix(digits, "0x"):
		digits, base = digits[2:], 16
	case strings.HasPrefix(digits, "0o"):
		digits, base = digits[2:], 8
	case strings.HasPrefix(digits, "0b"):
		digits, base = digits[2:], 2
	}
	_, err := strconv.ParseInt(digits, base, 64)
	return err == nil
}

func (p *tomlParser) fail() error {
	line, column := 1, 1
	for _, r := range p.text[:min(p.pos, len(p.text))] {
		if r == '\n' {
			line, column = line+1, 1
		} else {
			column++
		}
	}
	return tomlError{line, column}
}

func parseTOML(text string) (*tomlDocument, error) {
	if !utf8.ValidString(text) || strings.ContainsRune(text, 0) {
		return nil, errors.New("config.toml is not valid UTF-8 text")
	}
	p := &tomlParser{text: text, doc: &tomlDocument{root: newTOMLTable()}}
	current, currentPath := p.doc.root, []string(nil)
	for {
		p.skipSpace()
		if p.pos >= len(p.text) {
			return p.doc, nil
		}
		lineStart := strings.LastIndexByte(p.text[:p.pos], '\n') + 1
		switch c := p.text[p.pos]; {
		case c == '#' || c == '\n' || c == '\r':
			if err := p.endOfLine(); err != nil {
				return nil, err
			}
			continue
		case c == '[':
			array := strings.HasPrefix(p.text[p.pos:], "[[")
			p.pos++
			if array {
				p.pos++
			}
			p.skipSpace()
			path, err := p.key()
			if err != nil {
				return nil, err
			}
			p.skipSpace()
			closing := "]"
			if array {
				closing = "]]"
			}
			if !strings.HasPrefix(p.text[p.pos:], closing) {
				return nil, p.fail()
			}
			p.pos += len(closing)
			if current, err = p.defineTable(path, array); err != nil {
				return nil, err
			}
			currentPath = path
			p.doc.statements = append(p.doc.statements, tomlStatement{path: path, header: true, lineStart: lineStart})
		default:
			path, err := p.keyValue(current)
			if err != nil {
				return nil, err
			}
			full := append(append([]string(nil), currentPath...), path...)
			p.doc.statements = append(p.doc.statements, tomlStatement{path: full, lineStart: lineStart})
		}
		p.skipSpace()
		if err := p.endOfLine(); err != nil {
			return nil, err
		}
	}
}

func (p *tomlParser) skipSpace() {
	for p.pos < len(p.text) && (p.text[p.pos] == ' ' || p.text[p.pos] == '\t') {
		p.pos++
	}
}

// endOfLine accepts an optional comment and one newline (or the end).
func (p *tomlParser) endOfLine() error {
	if p.pos < len(p.text) && p.text[p.pos] == '#' {
		for p.pos < len(p.text) && p.text[p.pos] != '\n' && !strings.HasPrefix(p.text[p.pos:], "\r\n") {
			// A carriage return only ends a line, before a newline.
			if c := p.text[p.pos]; (c < 0x20 && c != '\t') || c == 0x7f {
				return p.fail()
			}
			p.pos++
		}
	}
	if strings.HasPrefix(p.text[p.pos:], "\r\n") {
		p.pos += 2
		return nil
	}
	if p.pos >= len(p.text) {
		return nil
	}
	if p.text[p.pos] != '\n' {
		return p.fail()
	}
	p.pos++
	return nil
}

// skipBlank skips whitespace, newlines and comments (inside arrays and,
// leniently, inline tables).
func (p *tomlParser) skipBlank() error {
	for p.pos < len(p.text) {
		switch p.text[p.pos] {
		case ' ', '\t', '\n':
			p.pos++
		case '\r':
			if !strings.HasPrefix(p.text[p.pos:], "\r\n") {
				return p.fail()
			}
			p.pos += 2
		case '#':
			if err := p.endOfLine(); err != nil {
				return err
			}
		default:
			return nil
		}
	}
	return nil
}

var tomlBareKey = regexp.MustCompile(`^[A-Za-z0-9_-]+`)

// key reads a dotted key: simple keys joined by '.', each bare or quoted.
func (p *tomlParser) key() ([]string, error) {
	var path []string
	for {
		p.skipSpace()
		if p.pos >= len(p.text) {
			return nil, p.fail()
		}
		var part string
		switch p.text[p.pos] {
		case '"':
			if strings.HasPrefix(p.text[p.pos:], `"""`) {
				return nil, errTOMLMultiline
			}
			value, err := p.basicString()
			if err != nil {
				return nil, err
			}
			part = value
		case '\'':
			if strings.HasPrefix(p.text[p.pos:], `'''`) {
				return nil, errTOMLMultiline
			}
			value, err := p.literalString()
			if err != nil {
				return nil, err
			}
			part = value
		default:
			bare := tomlBareKey.FindString(p.text[p.pos:])
			if bare == "" {
				return nil, p.fail()
			}
			part = bare
			p.pos += len(bare)
		}
		path = append(path, part)
		p.skipSpace()
		if p.pos >= len(p.text) || p.text[p.pos] != '.' {
			return path, nil
		}
		p.pos++
	}
}

// keyValue parses "key = value" into table and returns the key path.
func (p *tomlParser) keyValue(table *tomlTable) ([]string, error) {
	path, err := p.key()
	if err != nil {
		return nil, err
	}
	p.skipSpace()
	if p.pos >= len(p.text) || p.text[p.pos] != '=' {
		return nil, p.fail()
	}
	p.pos++
	p.skipSpace()
	value, err := p.value()
	if err != nil {
		return nil, err
	}
	for _, part := range path[:len(path)-1] {
		next, exists := table.values[part]
		switch child := next.(type) {
		case nil:
			if exists {
				return nil, p.fail()
			}
			created := newTOMLTable()
			created.dotted = true
			table.set(part, created)
			table = created
		case *tomlTable:
			if child.inline || child.header {
				return nil, p.fail()
			}
			table = child
		default:
			return nil, p.fail()
		}
	}
	last := path[len(path)-1]
	if _, exists := table.values[last]; exists {
		return nil, p.fail()
	}
	table.set(last, value)
	return path, nil
}

// defineTable opens [path] or appends to [[path]].
func (p *tomlParser) defineTable(path []string, array bool) (*tomlTable, error) {
	table := p.doc.root
	for _, part := range path[:len(path)-1] {
		switch child := table.values[part].(type) {
		case nil:
			created := newTOMLTable()
			table.set(part, created)
			table = created
		case *tomlTable:
			if child.inline {
				return nil, p.fail()
			}
			table = child
		case *tomlTableArray:
			table = child.tables[len(child.tables)-1]
		default:
			return nil, p.fail()
		}
	}
	last := path[len(path)-1]
	existing, exists := table.values[last]
	if array {
		switch child := existing.(type) {
		case nil:
			if exists {
				return nil, p.fail()
			}
			created := newTOMLTable()
			created.header = true
			table.set(last, &tomlTableArray{tables: []*tomlTable{created}})
			return created, nil
		case *tomlTableArray:
			created := newTOMLTable()
			created.header = true
			child.tables = append(child.tables, created)
			return created, nil
		}
		return nil, p.fail()
	}
	switch child := existing.(type) {
	case nil:
		if exists {
			return nil, p.fail()
		}
		created := newTOMLTable()
		created.header = true
		table.set(last, created)
		return created, nil
	case *tomlTable:
		if child.header || child.dotted || child.inline {
			return nil, p.fail()
		}
		child.header = true
		return child, nil
	}
	return nil, p.fail()
}

var (
	tomlScalarToken = regexp.MustCompile(`^[0-9A-Za-z_+\-.:]+`)
	tomlNumber      = regexp.MustCompile(`^[+-]?(0|[1-9](_?[0-9])*)(\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?$|^0x[0-9A-Fa-f](_?[0-9A-Fa-f])*$|^0o[0-7](_?[0-7])*$|^0b[01](_?[01])*$|^[+-]?(inf|nan)$`)
	tomlDateTime    = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}|^[0-9]{2}:[0-9]{2}`)
)

func (p *tomlParser) value() (any, error) {
	if p.pos >= len(p.text) {
		return nil, p.fail()
	}
	switch p.text[p.pos] {
	case '"':
		if strings.HasPrefix(p.text[p.pos:], `"""`) {
			return nil, errTOMLMultiline
		}
		return p.basicString()
	case '\'':
		if strings.HasPrefix(p.text[p.pos:], `'''`) {
			return nil, errTOMLMultiline
		}
		return p.literalString()
	case '[':
		return p.array()
	case '{':
		return p.inlineTable()
	}
	token := tomlScalarToken.FindString(p.text[p.pos:])
	switch {
	case token == "true" || token == "false":
	case tomlNumber.MatchString(token):
		if !tomlIntegerFits(token) {
			return nil, p.fail()
		}
	case tomlDateTime.MatchString(token):
		// Codex's settings use no dates or times. Refusing them avoids
		// validating calendar and clock ranges, and passing on a value
		// Codex itself would reject.
		return nil, errTOMLDateTime
	default:
		return nil, p.fail()
	}
	p.pos += len(token)
	return tomlRaw(token), nil
}

func (p *tomlParser) basicString() (string, error) {
	p.pos++ // opening quote
	var out strings.Builder
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		switch {
		case c == '"':
			p.pos++
			return out.String(), nil
		case c == '\\':
			if p.pos+1 >= len(p.text) {
				return "", p.fail()
			}
			escape := p.text[p.pos+1]
			p.pos += 2
			switch escape {
			case 'b':
				out.WriteByte('\b')
			case 't':
				out.WriteByte('\t')
			case 'n':
				out.WriteByte('\n')
			case 'f':
				out.WriteByte('\f')
			case 'r':
				out.WriteByte('\r')
			case '"':
				out.WriteByte('"')
			case '\\':
				out.WriteByte('\\')
			case 'u', 'U':
				size := map[byte]int{'u': 4, 'U': 8}[escape]
				if p.pos+size > len(p.text) {
					return "", p.fail()
				}
				code, err := strconv.ParseUint(p.text[p.pos:p.pos+size], 16, 32)
				if err != nil || !utf8.ValidRune(rune(code)) {
					return "", p.fail()
				}
				out.WriteRune(rune(code))
				p.pos += size
			default:
				return "", p.fail()
			}
		case (c < 0x20 && c != '\t') || c == 0x7f:
			return "", p.fail()
		default:
			out.WriteByte(c)
			p.pos++
		}
	}
	return "", p.fail()
}

func (p *tomlParser) literalString() (string, error) {
	p.pos++
	start := p.pos
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		if c == '\'' {
			value := p.text[start:p.pos]
			p.pos++
			return value, nil
		}
		if (c < 0x20 && c != '\t') || c == 0x7f {
			return "", p.fail()
		}
		p.pos++
	}
	return "", p.fail()
}

func (p *tomlParser) array() ([]any, error) {
	p.pos++
	values := []any{}
	for {
		if err := p.skipBlank(); err != nil {
			return nil, err
		}
		if p.pos >= len(p.text) {
			return nil, p.fail()
		}
		if p.text[p.pos] == ']' {
			p.pos++
			return values, nil
		}
		value, err := p.value()
		if err != nil {
			return nil, err
		}
		values = append(values, value)
		if err := p.skipBlank(); err != nil {
			return nil, err
		}
		if p.pos < len(p.text) && p.text[p.pos] == ',' {
			p.pos++
			continue
		}
		if p.pos >= len(p.text) || p.text[p.pos] != ']' {
			return nil, p.fail()
		}
	}
}

func (p *tomlParser) inlineTable() (*tomlTable, error) {
	p.pos++
	table := newTOMLTable()
	// TOML 1.0: an inline table is one line, without a trailing comma.
	p.skipSpace()
	if p.pos < len(p.text) && p.text[p.pos] == '}' {
		p.pos++
		table.inline = true
		return table, nil
	}
	for {
		p.skipSpace()
		if _, err := p.keyValue(table); err != nil {
			return nil, err
		}
		p.skipSpace()
		if p.pos < len(p.text) && p.text[p.pos] == ',' {
			p.pos++
			continue
		}
		if p.pos >= len(p.text) || p.text[p.pos] != '}' {
			return nil, p.fail()
		}
		p.pos++
		table.inline = true
		closeInline(table)
		return table, nil
	}
}

// closeInline marks an inline table and the tables its dotted keys made as
// complete, so later headers or keys cannot extend them.
func closeInline(table *tomlTable) {
	table.inline = true
	for _, value := range table.values {
		if child, ok := value.(*tomlTable); ok {
			closeInline(child)
		}
	}
}

// tomlWalk calls visit with every key path in table, depth first.
func tomlWalk(table *tomlTable, path []string, visit func([]string)) {
	for _, key := range table.keys {
		here := append(append([]string(nil), path...), key)
		visit(here)
		switch child := table.values[key].(type) {
		case *tomlTable:
			tomlWalk(child, here, visit)
		case *tomlTableArray:
			for _, element := range child.tables {
				tomlWalk(element, here, visit)
			}
		case []any:
			tomlWalkArray(child, here, visit)
		}
	}
}

func tomlWalkArray(values []any, path []string, visit func([]string)) {
	for _, value := range values {
		switch child := value.(type) {
		case *tomlTable:
			tomlWalk(child, path, visit)
		case []any:
			tomlWalkArray(child, path, visit)
		}
	}
}

// tomlWithout returns a copy of value with every key named name removed at
// any depth.
func tomlWithout(value any, name string) any {
	switch child := value.(type) {
	case *tomlTable:
		copied := newTOMLTable()
		copied.header, copied.dotted, copied.inline = child.header, child.dotted, child.inline
		for _, key := range child.keys {
			if key != name {
				copied.set(key, tomlWithout(child.values[key], name))
			}
		}
		return copied
	case *tomlTableArray:
		copied := &tomlTableArray{}
		for _, element := range child.tables {
			copied.tables = append(copied.tables, tomlWithout(element, name).(*tomlTable))
		}
		return copied
	case []any:
		copied := make([]any, 0, len(child))
		for _, element := range child {
			copied = append(copied, tomlWithout(element, name))
		}
		return copied
	}
	return value
}

func tomlKeyText(key string) string {
	if key != "" && tomlBareKey.FindString(key) == key {
		return key
	}
	return tomlQuote(key)
}

func tomlPathText(path []string) string {
	parts := make([]string, len(path))
	for index, key := range path {
		parts[index] = tomlKeyText(key)
	}
	return strings.Join(parts, ".")
}

func tomlQuote(value string) string {
	var out strings.Builder
	out.WriteByte('"')
	for _, r := range value {
		switch {
		case r == '"':
			out.WriteString(`\"`)
		case r == '\\':
			out.WriteString(`\\`)
		case r == '\n':
			out.WriteString(`\n`)
		case r == '\t':
			out.WriteString(`\t`)
		case r == '\r':
			out.WriteString(`\r`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&out, `\u%04X`, r)
		default:
			out.WriteRune(r)
		}
	}
	out.WriteByte('"')
	return out.String()
}

func tomlInlineText(value any) string {
	switch child := value.(type) {
	case string:
		return tomlQuote(child)
	case tomlRaw:
		return string(child)
	case []any:
		parts := make([]string, len(child))
		for index, element := range child {
			parts[index] = tomlInlineText(element)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case *tomlTable:
		parts := make([]string, len(child.keys))
		for index, key := range child.keys {
			parts[index] = tomlKeyText(key) + " = " + tomlInlineText(child.values[key])
		}
		if len(parts) == 0 {
			return "{}"
		}
		return "{ " + strings.Join(parts, ", ") + " }"
	case *tomlTableArray:
		parts := make([]string, len(child.tables))
		for index, element := range child.tables {
			parts[index] = tomlInlineText(element)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	}
	return `""`
}

// tomlEmitTable writes [path] with its values, then its sub-tables as their
// own headers. Output is deterministic for the same tree.
func tomlEmitTable(out *strings.Builder, path []string, table *tomlTable) {
	out.WriteString("[" + tomlPathText(path) + "]\n")
	tomlEmitBody(out, path, table)
}

func tomlEmitBody(out *strings.Builder, path []string, table *tomlTable) {
	for _, key := range table.keys {
		switch table.values[key].(type) {
		case *tomlTable, *tomlTableArray:
			continue
		}
		out.WriteString(tomlKeyText(key) + " = " + tomlInlineText(table.values[key]) + "\n")
	}
	for _, key := range table.keys {
		here := append(append([]string(nil), path...), key)
		switch child := table.values[key].(type) {
		case *tomlTable:
			tomlEmitTable(out, here, child)
		case *tomlTableArray:
			for _, element := range child.tables {
				out.WriteString("[[" + tomlPathText(here) + "]]\n")
				tomlEmitBody(out, here, element)
			}
		}
	}
}
