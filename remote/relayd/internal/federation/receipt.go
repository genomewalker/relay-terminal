// Package federation validates Chitta receipts at Relay's transport boundary.
// It neither grants execution authority nor implements Chitta persistence.
package federation

import (
	"encoding/hex"
	"errors"
)

type State string

const (
	Persisted     State = "persisted"
	Claimed       State = "claimed"
	Processing    State = "processing"
	Succeeded     State = "succeeded"
	Failed        State = "failed"
	Expired       State = "expired"
	Indeterminate State = "indeterminate"
)

// Key is structured to avoid delimiter collisions between realm/session names.
type Key struct {
	Realm         string `json:"realm"`
	SenderField   string `json:"sender_field_id"`
	SenderSession string `json:"sender_session_id"`
	Message       string `json:"transport_msg_id"`
}

type Receipt struct {
	Version       int    `json:"v"`
	Key           Key    `json:"key"`
	PayloadSHA256 string `json:"payload_sha256"`
	RecordID      string `json:"record_id"`
	State         State  `json:"state"`
}

func (r Receipt) Validate() error {
	if r.Version != 1 {
		return errors.New("unsupported federation receipt version")
	}
	for _, s := range []string{r.Key.Realm, r.Key.SenderField, r.Key.SenderSession, r.Key.Message, r.RecordID} {
		if len(s) == 0 || len(s) > 256 {
			return errors.New("invalid federation identity length")
		}
		for _, c := range s {
			if c < 32 || c == 127 {
				return errors.New("control character in federation identity")
			}
		}
	}
	b, err := hex.DecodeString(r.PayloadSHA256)
	if err != nil || len(b) != 32 {
		return errors.New("invalid payload digest")
	}
	switch r.State {
	case Persisted, Claimed, Processing, Succeeded, Failed, Expired, Indeterminate:
		return nil
	default:
		return errors.New("unknown handoff state")
	}
}

// Advance accepts snapshots, which may skip intermediate states after reconnect.
// Terminal outcomes cannot overwrite one another. An indeterminate result needs
// a separate reconciled record, not an automatic success or retry transition.
// Callers must authenticate the supplying field before invoking this function.
func Advance(previous, next Receipt) error {
	if err := previous.Validate(); err != nil {
		return err
	}
	if err := next.Validate(); err != nil {
		return err
	}
	if previous.Key != next.Key || previous.RecordID != next.RecordID || previous.PayloadSHA256 != next.PayloadSHA256 {
		return errors.New("handoff identity or payload conflict")
	}
	if previous.State == next.State {
		return nil
	}
	rank := func(s State) int {
		switch s {
		case Persisted:
			return 0
		case Claimed:
			return 1
		case Processing:
			return 2
		default:
			return 3
		}
	}
	if rank(next.State) <= rank(previous.State) {
		return errors.New("handoff state regression or conflicting outcome")
	}
	return nil
}
