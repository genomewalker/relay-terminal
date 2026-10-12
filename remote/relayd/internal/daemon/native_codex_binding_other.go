//go:build !darwin && !linux

package daemon

import (
	"context"
)

func nativeCodexEndpoint(ctx context.Context, frontend int) (NativeCodexEndpoint, error) {
	return NativeCodexEndpoint{}, errNativeRuntimeUnsupported
}
