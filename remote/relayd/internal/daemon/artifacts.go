package daemon

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

const maxInlineArtifactBytes = 12 << 20

var imagePathPattern = regexp.MustCompile(`(?:file://)?(/[A-Za-z0-9_~.%+@:/-]+\.(?i:png|jpe?g|gif|webp))`)

type artifactDetector struct {
	tail string
	seen map[string]bool
}

func (detector *artifactDetector) ingest(data []byte) []string {
	if detector.seen == nil {
		detector.seen = make(map[string]bool)
	}
	candidate := detector.tail + string(data)
	if len(candidate) > 4096 {
		detector.tail = candidate[len(candidate)-4096:]
	} else {
		detector.tail = candidate
	}
	matches := imagePathPattern.FindAllStringSubmatch(candidate, -1)
	paths := make([]string, 0, len(matches))
	for _, match := range matches {
		path := strings.ReplaceAll(match[1], "%20", " ")
		if !detector.seen[path] {
			detector.seen[path] = true
			paths = append(paths, path)
		}
	}
	return paths
}

func loadInlineArtifact(requested string) ([]byte, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	resolved, err := filepath.EvalSymlinks(filepath.Clean(requested))
	if err != nil {
		return nil, err
	}
	allowedRoots := []string{home, filepath.Join("/tmp", "claude-"+strconv.Itoa(os.Getuid()))}
	allowed := false
	for _, root := range allowedRoots {
		if canonical, rootErr := filepath.EvalSymlinks(root); rootErr == nil {
			root = canonical
		}
		relative, relErr := filepath.Rel(root, resolved)
		if relErr == nil && relative != ".." && !filepath.IsAbs(relative) && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			allowed = true
			break
		}
	}
	if !allowed {
		return nil, os.ErrPermission
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxInlineArtifactBytes {
		return nil, os.ErrInvalid
	}
	return os.ReadFile(resolved)
}
