package helpercli

import (
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"
)

const websiteLimit = 8 << 20

type page struct {
	ids     map[string]bool
	links   []string
	metas   map[string]string
	scripts int
}

func space(c byte) bool { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' }
func alpha(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }

// parsePage is a bounded HTML start-tag scanner, not an XML decoder: HTML void
// elements, quoted '>' and character references retain HTML semantics.
func parsePage(raw string) (page, error) {
	p := page{ids: map[string]bool{}, metas: map[string]string{}}
	if !utf8.ValidString(raw) {
		return p, errors.New("HTML contains invalid UTF-8")
	}
	if len(raw) > websiteLimit {
		return p, errors.New("HTML exceeds size limit")
	}
	for i := 0; i < len(raw); {
		n := strings.IndexByte(raw[i:], '<')
		if n < 0 {
			break
		}
		i += n
		if strings.HasPrefix(raw[i:], "<!--") {
			n = strings.Index(raw[i+4:], "-->")
			if n < 0 {
				return p, errors.New("unterminated HTML comment")
			}
			i += 4 + n + 3
			continue
		}
		start := i
		i++
		if i >= len(raw) {
			break
		}
		if !alpha(raw[i]) {
			if raw[i] != '/' && raw[i] != '!' && raw[i] != '?' {
				continue
			}
			n = strings.IndexByte(raw[i:], '>')
			if n < 0 {
				break
			}
			i += n + 1
			continue
		}
		j := i
		for i < len(raw) && !space(raw[i]) && raw[i] != '>' && raw[i] != '/' {
			i++
		}
		tag := strings.ToLower(raw[j:i])
		attrs := map[string]string{}
		closed := false
		for i < len(raw) {
			for i < len(raw) && space(raw[i]) {
				i++
			}
			if i >= len(raw) {
				break
			}
			if raw[i] == '>' {
				i++
				closed = true
				break
			}
			if raw[i] == '/' && i+1 < len(raw) && raw[i+1] == '>' {
				i += 2
				closed = true
				break
			}
			j = i
			for i < len(raw) && !space(raw[i]) && raw[i] != '=' && raw[i] != '>' {
				i++
			}
			if i == j {
				return p, errors.New("invalid HTML attribute")
			}
			key := strings.ToLower(raw[j:i])
			for i < len(raw) && space(raw[i]) {
				i++
			}
			value := ""
			if i < len(raw) && raw[i] == '=' {
				i++
				for i < len(raw) && space(raw[i]) {
					i++
				}
				if i >= len(raw) {
					break
				}
				if raw[i] == '\'' || raw[i] == '"' {
					quote := raw[i]
					i++
					j = i
					for i < len(raw) && raw[i] != quote {
						i++
					}
					if i >= len(raw) {
						return p, errors.New("unterminated HTML attribute")
					}
					value = raw[j:i]
					i++
				} else {
					j = i
					for i < len(raw) && !space(raw[i]) && raw[i] != '>' {
						i++
					}
					value = raw[j:i]
				}
			}
			attrs[key] = html.UnescapeString(value)
		}
		if !closed {
			return p, fmt.Errorf("unterminated HTML tag at %d", start)
		}
		if id, ok := attrs["id"]; ok {
			if p.ids[id] {
				return p, errors.New("duplicate element id")
			}
			p.ids[id] = true
		}
		if tag == "a" || tag == "link" {
			if v, ok := attrs["href"]; ok {
				p.links = append(p.links, v)
			}
		}
		if tag == "img" {
			if _, ok := attrs["alt"]; !ok {
				return p, errors.New("image without alternative text")
			}
			_, w := attrs["width"]
			_, h := attrs["height"]
			if !w || !h {
				return p, errors.New("image without dimensions")
			}
			src, ok := attrs["src"]
			if !ok {
				return p, errors.New("image without source")
			}
			p.links = append(p.links, src)
		}
		if tag == "meta" {
			p.metas[attrs["name"]] = attrs["content"]
		}
		if tag == "script" {
			p.scripts++
			return p, nil
		}
		if tag == "style" {
			end := strings.Index(strings.ToLower(raw[i:]), "</style")
			if end < 0 {
				return p, errors.New("unterminated style element")
			}
			i += end
		}
	}
	return p, nil
}
func truthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case string:
		return x != ""
	case []any:
		return len(x) > 0
	case map[string]any:
		return len(x) > 0
	case json.Number:
		n, _ := strconv.ParseFloat(string(x), 64)
		return n != 0
	default:
		return fmt.Sprint(v) != "0"
	}
}
func checkLink(root, link string, ids map[string]bool) error {
	// Match urlsplit's scheme/authority classification before unquoting paths.
	u, e := url.Parse(strings.TrimLeft(link, "\x00\t\r\n "))
	if e != nil {
		return fmt.Errorf("invalid URL: %s", link)
	}
	if u.Scheme != "" {
		if strings.ToLower(u.Scheme) != "https" {
			return errors.New("external URL must use HTTPS")
		}
		return nil
	}
	if u.Host != "" || strings.HasPrefix(link, "//") {
		return errors.New("protocol-relative external URL")
	}
	if u.Path != "" {
		target := u.Path
		if !filepath.IsAbs(target) {
			target = filepath.Join(root, target)
		}
		target, e = filepath.EvalSymlinks(target)
		if e != nil {
			return errors.New(link)
		}
		rel, e := filepath.Rel(root, target)
		if e != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return errors.New(link)
		}
		info, e := os.Stat(target)
		if e != nil || !info.Mode().IsRegular() {
			return errors.New(link)
		}
	} else if _, fragment, has := strings.Cut(link, "#"); has && fragment != "" && !ids[fragment] {
		return errors.New(link)
	}
	return nil
}
func ValidateWebsite(root string, production bool) error {
	root, e := filepath.Abs(root)
	if e != nil {
		return e
	}
	root, e = filepath.EvalSymlinks(root)
	if e != nil {
		return e
	}
	data, e := boundedFile(filepath.Join(root, "release-gate.json"), maxDocument)
	if e != nil {
		return e
	}
	gate, e := jsonObject(data, maxDocument)
	if e != nil {
		return e
	}
	if gate["domain"] != "relay.vaklab.dev" {
		return errors.New("Unexpected domain")
	}
	data, e = boundedFile(filepath.Join(root, "index.html"), websiteLimit)
	if e != nil {
		return e
	}
	raw := string(data)
	p, e := parsePage(raw)
	if e != nil {
		return e
	}
	if p.scripts != 0 {
		return errors.New("draft does not need JavaScript")
	}
	if _, ok := p.metas["viewport"]; !ok || !strings.Contains(raw, `lang="en"`) {
		return errors.New("Missing viewport or language")
	}
	for _, link := range p.links {
		if e = checkLink(root, link, p.ids); e != nil {
			return e
		}
	}
	ready, isBool := gate["productionReady"].(bool)
	if production {
		if !isBool || !ready {
			return errors.New("Production acceptance has not passed")
		}
		for _, key := range []string{"appVersion", "appCommit", "downloadURL", "notarizationStatus", "acceptanceRecord"} {
			if !truthy(gate[key]) {
				return fmt.Errorf("Missing production evidence: %s", key)
			}
		}
		download, ok := gate["downloadURL"].(string)
		if !ok || !strings.HasPrefix(download, "https://github.com/genomewalker/relay-terminal/releases/download/") {
			return errors.New("Unexpected release download host")
		}
		if strings.Contains(p.metas["robots"], "noindex") {
			return errors.New("Production page is noindex")
		}
	} else {
		if !isBool || ready {
			return errors.New("Use --production for a release candidate")
		}
		if !strings.Contains(p.metas["robots"], "noindex") {
			return errors.New("Preview must be noindex")
		}
		if _, e = os.Stat(filepath.Join(root, "CNAME")); e == nil {
			return errors.New("Do not configure the domain before acceptance")
		} else if !os.IsNotExist(e) {
			return e
		}
	}
	return nil
}
