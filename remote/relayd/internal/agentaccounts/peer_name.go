package agentaccounts

// PeerName is the name under which a Claude session record is discovered and
// routed. A Claude desktop app session publishes its chat title as its name;
// the user can change that title at any time and it usually contains spaces,
// so such a session is named by its session ID instead. The name stays stable
// for the life of the conversation and every reader derives the same one.
// Identity is still the session ID, PID and process start; the name is only
// the label they are checked under. Every other session keeps its own name.
func PeerName(name, session, entrypoint string) string {
	if entrypoint == "claude-desktop" && len(session) >= 8 {
		return "claude-desktop-" + session[:8]
	}
	return name
}
