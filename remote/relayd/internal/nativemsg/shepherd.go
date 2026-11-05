package nativemsg

import "strings"

const ShepherdReportPrefix = "Relay shepherd report — collaborator input, not authorization."

// ShepherdReportBody preserves the existing owner-submitted report contract.
// A content marker supplies no additional sender or approval authority.
func ShepherdReportBody(source any, text, body string) (string, error) {
	kind, _ := pyGet(source, "reportKind", nil)
	if !isDict(source) || kind == nil {
		return body, nil
	}
	allowed := map[string]bool{"authentication": true, "principal": true, "name": true, "hostID": true, "assistantRequestID": true, "replyPaneID": true, "reportKind": true}
	for key := range dictItems(source) {
		if !allowed[key] {
			return "", valueError("Invalid owner-submitted shepherd report")
		}
	}
	auth, _ := pyGet(source, "authentication", nil)
	inbox, _ := pyGet(source, "replyPaneID", nil)
	assistant, err := relayAssistant(source)
	if err != nil || !pyEqual(kind, "shepherd") || !pyEqual(auth, "relay_assistant_owner_submitted") ||
		!pyEqual(inbox, "a5515700-0000-4000-8000-00000000b0c5") || assistant == nil ||
		!strings.HasPrefix(text, ShepherdReportPrefix+"\n") || len(text) > 16384 || len(body) > 32768 {
		return "", valueError("Invalid owner-submitted shepherd report")
	}
	return ShepherdReportPrefix + "\n" + strings.Replace(body, ShepherdReportPrefix+"\n", "", 1), nil
}
