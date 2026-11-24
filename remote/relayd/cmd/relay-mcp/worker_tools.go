package main

// workerTools are the built-in Claude tools a profile-worker launch may keep.
// Relay passes the chosen set as --tools, which Claude enforces at launch.
// Bash is a shell: a set that includes it does not contain the worker.
var workerTools = []string{"Bash", "Read", "Grep", "Glob"}

// workerToolList validates a requested worker tool set and returns it as the
// comma-separated value Relay passes to --tools, in the caller's order.
func workerToolList(names []string) (string, bool) {
	if len(names) == 0 || len(names) > len(workerTools) {
		return "", false
	}
	seen := map[string]bool{}
	out := ""
	for _, name := range names {
		known := false
		for _, tool := range workerTools {
			known = known || name == tool
		}
		if !known || seen[name] {
			return "", false
		}
		seen[name] = true
		if out != "" {
			out += ","
		}
		out += name
	}
	return out, true
}
