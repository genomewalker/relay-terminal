package daemon

// A new pair admits two directional callers, each named by the identity it
// belongs to: "desktop-<session>" for messages from the desktop session, and
// "pane-<pane>" for messages from the pane. An outbound message carries the
// directional name only when the saved pair admits it, so an existing pair that
// admits a plain caller label keeps working unchanged.

func directionalDesktopCaller(session string) string { return "desktop-" + session }

func directionalPaneCaller(pane string) string { return "pane-" + pane }

// directionalPairCallers is the reviewed caller set of a desktop session pair:
// the desktop's outbound caller and the pane's reply caller.
func directionalPairCallers(session, pane string) []string {
	return []string{directionalDesktopCaller(session), directionalPaneCaller(pane)}
}

// wireCallerFor chooses the caller a verified local sender puts on the wire. A
// pair whose peer is a pane admits "pane-<peer>", so this sender is the desktop
// and goes out as "desktop-<sender>"; a pair whose peer is a desktop admits
// "desktop-<peer>", so this sender is the pane. Any other pair keeps its label.
func wireCallerFor(link CommunicationRemoteLink, sender string, label string) string {
	peer := link.PeerPaneID
	if containsCommunicationPane(link.AllowedPeerCallers, directionalPaneCaller(peer)) {
		return directionalDesktopCaller(sender)
	}
	if containsCommunicationPane(link.AllowedPeerCallers, directionalDesktopCaller(peer)) {
		return directionalPaneCaller(sender)
	}
	return label
}

// establishReplyAllowed is the caller set the proposer's half admits: the reply
// caller of a directional pair, or the single caller label of a legacy pair.
func establishReplyAllowed(plan *establishPlan) []string {
	if plan.replyCaller != "" {
		return []string{plan.replyCaller}
	}
	return []string{plan.caller}
}
