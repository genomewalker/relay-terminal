package daemon

import (
	"errors"
	"regexp"
)

// Codex turn receipts. turn/start returns the turn ID the provider admitted
// the message under. A later Stop event with the same turn ID completes it.

const (
	paneReceiptTurnStarted   = "turn_started"
	paneReceiptTurnCompleted = "turn_completed"
)

var paneTurnID = regexp.MustCompile(`^[A-Za-z0-9_:.-]{1,256}$`)

type paneTurnReceipt struct {
	MessageID string `json:"message_id"`
	Status    string `json:"status"`
	TurnID    string `json:"turn_id,omitempty"`
}

func turnStartedReceipt(messageID, turnID string) (paneTurnReceipt, error) {
	if !paneTurnID.MatchString(turnID) || messageID == "" {
		return paneTurnReceipt{}, errors.New("invalid turn receipt")
	}
	return paneTurnReceipt{MessageID: messageID, Status: paneReceiptTurnStarted, TurnID: turnID}, nil
}

// completeTurnReceipts marks each turn_started receipt whose turn ID matches a
// Stop event. It returns the number of receipts changed. Other receipts are
// untouched, and an empty or unknown turn ID changes nothing.
func completeTurnReceipts(receipts []paneTurnReceipt, stopTurnID string) int {
	if !paneTurnID.MatchString(stopTurnID) {
		return 0
	}
	changed := 0
	for index := range receipts {
		if receipts[index].Status == paneReceiptTurnStarted && receipts[index].TurnID == stopTurnID {
			receipts[index].Status = paneReceiptTurnCompleted
			changed++
		}
	}
	return changed
}
