package main

import (
	"testing"
	"time"
)

func TestNextRetryDelay(t *testing.T) {
	interval := 300 * time.Second
	cases := []struct {
		failures int
		want     time.Duration
	}{
		{1, 60 * time.Second},
		{2, 120 * time.Second},
		{3, 240 * time.Second},
		{4, 300 * time.Second}, // 60s*2^3=480s > 300s -> cap
		{99, 300 * time.Second},
	}
	for _, c := range cases {
		if got := nextRetryDelay(c.failures, interval, 0, 0); got != c.want {
			t.Errorf("nextRetryDelay(%d)=%v want %v", c.failures, got, c.want)
		}
	}
	// Retry-After is honored (not clamped to interval), only capped at maxRetry.
	if got := nextRetryDelay(1, interval, 45*time.Second, 0); got != 45*time.Second {
		t.Errorf("retryAfter priority failed: %v", got)
	}
	if got := nextRetryDelay(1, interval, 600*time.Second, 0); got != 600*time.Second {
		t.Errorf("retryAfter honor failed: %v", got)
	}
	if got := nextRetryDelay(1, interval, 5000*time.Second, 0); got != maxRetry {
		t.Errorf("retryAfter MAX cap failed: %v", got)
	}
	// jitter: adds 0~20% of base.
	if got := nextRetryDelay(1, interval, 0, 1); got != 72*time.Second {
		t.Errorf("jitter failed: %v want 72s", got)
	}
}

func TestShouldShowStale(t *testing.T) {
	interval := 300 * time.Second
	if shouldShowStale(899*time.Second, interval) {
		t.Error("899s should not be stale")
	}
	if !shouldShowStale(900*time.Second, interval) {
		t.Error("900s should be stale")
	}
}
