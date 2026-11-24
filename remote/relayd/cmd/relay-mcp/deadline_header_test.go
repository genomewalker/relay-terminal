package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

// Every Relay request carries the moment relay-mcp stops waiting, so Relay
// can refuse a mutation it reaches only after the caller reported an unknown
// outcome (2026-11-24, relay_exec r0584rb ran 24 minutes late).
func TestExchangeStampsTheClientDeadline(t *testing.T) {
	var got string
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get(deadlineHeader)
		w.Write([]byte(`{}`))
	}))
	defer relay.Close()

	s := &server{token: "t", endpoint: relay.URL, client: &http.Client{Timeout: 60 * time.Second}}
	before := time.Now()
	if _, err := s.exchange("POST", "/api/host/request", []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	ms, err := strconv.ParseInt(got, 10, 64)
	if err != nil {
		t.Fatalf("deadline header %q: %v", got, err)
	}
	deadline := time.UnixMilli(ms)
	if deadline.Before(before.Add(59*time.Second)) || deadline.After(time.Now().Add(61*time.Second)) {
		t.Fatalf("deadline %v is not about 60 s after the request", deadline)
	}
}

func TestExchangeWithoutAnyDeadlineIsNotStamped(t *testing.T) {
	var present bool
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, present = r.Header[http.CanonicalHeaderKey(deadlineHeader)]
		w.Write([]byte(`{}`))
	}))
	defer relay.Close()
	s := &server{token: "t", endpoint: relay.URL, client: &http.Client{}}
	if _, err := s.exchange("GET", "/api/panes", nil); err != nil {
		t.Fatal(err)
	}
	if present {
		t.Fatal("a request that waits indefinitely must not claim a deadline")
	}
}

func TestRequestDeadlineTakesTheEarlierBound(t *testing.T) {
	now := time.Date(2026, 11, 24, 15, 57, 52, 0, time.UTC)
	ctx, cancel := context.WithDeadline(context.Background(), now.Add(10*time.Second))
	defer cancel()
	if d, ok := requestDeadline(now, 60*time.Second, ctx); !ok || !d.Equal(now.Add(10*time.Second)) {
		t.Fatalf("context deadline earlier than the client timeout: got %v %v", d, ok)
	}
	if d, ok := requestDeadline(now, 60*time.Second, context.Background()); !ok || !d.Equal(now.Add(60*time.Second)) {
		t.Fatalf("client timeout only: got %v %v", d, ok)
	}
	if _, ok := requestDeadline(now, 0, context.Background()); ok {
		t.Fatal("no bound must leave the request unstamped")
	}
}
