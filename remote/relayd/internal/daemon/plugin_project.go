package daemon

import (
	"os"
	"strings"
)

// Inspect only fixed filenames. Project contents never become executable argv.
func pluginProjectActions(root *os.Root) []string {
	has := func(name string) bool {
		info, err := root.Stat(name)
		return err == nil && info.Mode().IsRegular()
	}
	entries := []string{}
	for _, item := range []struct{ name, suggestion string }{
		{"Package.swift", "swift build\nswift test"},
		{"go.mod", "go build ./...\ngo test ./..."},
		{"Cargo.toml", "cargo build\ncargo test"},
		{"pyproject.toml", "Inspect pyproject.toml and the README for the environment and test runner; do not install automatically."},
		{"CMakeLists.txt", "Inspect CMakeLists.txt and CMakePresets.json before choosing a build directory and configuration."},
		{"Makefile", "Inspect Makefile targets before running make; even make -n can execute project code."},
	} {
		if has(item.name) {
			entries = append(entries, item.name+":\n"+item.suggestion)
		}
	}
	if has("package.json") {
		managers := []string{}
		for _, item := range []struct{ lock, manager string }{
			{"package-lock.json", "npm"}, {"npm-shrinkwrap.json", "npm"},
			{"pnpm-lock.yaml", "pnpm"}, {"yarn.lock", "yarn"},
			{"bun.lock", "bun"}, {"bun.lockb", "bun"},
		} {
			if has(item.lock) {
				seen := false
				for _, m := range managers {
					if m == item.manager {
						seen = true
					}
				}
				if !seen {
					managers = append(managers, item.manager)
				}
			}
		}
		advice := "Inspect package.json scripts and packageManager before choosing npm, pnpm, Yarn or Bun."
		if len(managers) == 1 {
			advice = "Detected " + managers[0] + " lockfile. Inspect package.json scripts first; do not install or run scripts automatically."
		} else if len(managers) > 1 {
			advice = "Conflicting lockfiles (" + strings.Join(managers, ", ") + "). Check the README/packageManager; no package manager selected."
		}
		entries = append(entries, "package.json:\n"+advice)
	}
	if len(entries) == 0 {
		entries = append(entries, "No supported project manifest in this directory. Open the project root or inspect its README.")
	}
	return entries
}
