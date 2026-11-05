package daemon

import (
	"context"
	"io"

	"github.com/relay-terminal/relayd/internal/subscriptionquota"
)

// ReadSubscriptionQuota reads existing observations only. It does not start a
// provider, authenticate, refresh credentials or submit inference.
func ReadSubscriptionQuota(ctx context.Context, panes []string) ([]byte, error) {
	reader, err := subscriptionquota.NewReader()
	if err != nil {
		return nil, err
	}
	return reader.Read(ctx, panes)
}

// RunSubscriptionQuotaStatusline captures reported windows, then forwards the
// exact bounded input to the user's pre-existing statusline command.
func RunSubscriptionQuotaStatusline(ctx context.Context, encodedCommand string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	reader, err := subscriptionquota.NewReader()
	if err != nil {
		return 1, err
	}
	return reader.RunStatusline(ctx, encodedCommand, stdin, stdout, stderr)
}
