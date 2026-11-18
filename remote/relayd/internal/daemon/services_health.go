package daemon

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const serviceProbeTimeout = 2 * time.Second

func (h *ServiceHealth) target() (network, address, host string) {
	if h.Unix != "" {
		return "unix", h.Unix, "localhost"
	}
	address = h.TCP
	if _, err := strconv.Atoi(address); err == nil {
		address = "127.0.0.1:" + address
	}
	host = address
	return "tcp", address, host
}

func (h *ServiceHealth) accepts(status int) bool {
	if len(h.Accept) == 0 {
		return status >= 200 && status < 400
	}
	for _, code := range h.Accept {
		if code == status {
			return true
		}
	}
	return false
}

// probeServiceHealth makes one bounded probe. Redirects are not followed: the
// status the service itself returns is the evidence.
func probeServiceHealth(h *ServiceHealth, timeout time.Duration) error {
	network, address, host := h.target()
	dialer := &net.Dialer{Timeout: timeout}
	if h.HTTPPath == "" {
		connection, err := dialer.Dial(network, address)
		if err != nil {
			return err
		}
		return connection.Close()
	}
	client := &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return dialer.DialContext(ctx, network, address)
			},
			DisableKeepAlives: true,
			Proxy:             nil,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Get("http://" + host + h.HTTPPath)
	if err != nil {
		// The URL holds only the probe's own address and path.
		return fmt.Errorf("no HTTP answer: %s", strings.TrimPrefix(err.Error(), "Get "))
	}
	response.Body.Close()
	if !h.accepts(response.StatusCode) {
		return fmt.Errorf("HTTP %d is not an accepted status", response.StatusCode)
	}
	return nil
}

func serviceHealthWord(h *ServiceHealth) string {
	if h == nil {
		return "none"
	}
	if err := probeServiceHealth(h, serviceProbeTimeout); err != nil {
		return "unhealthy"
	}
	return "healthy"
}

// Probe reports "healthy", "unhealthy" or "none" from one bounded probe.
func (h *ServiceHealth) Probe() string { return serviceHealthWord(h) }
