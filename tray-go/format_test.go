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
		{1, 10 * time.Second},
		{2, 20 * time.Second},
		{3, 40 * time.Second},
		{4, 80 * time.Second},
		{6, 300 * time.Second}, // 320s > 300s -> cap
		{99, 300 * time.Second},
	}
	for _, c := range cases {
		if got := nextRetryDelay(c.failures, interval, 0); got != c.want {
			t.Errorf("nextRetryDelay(%d)=%v want %v", c.failures, got, c.want)
		}
	}
	if got := nextRetryDelay(1, interval, 45*time.Second); got != 45*time.Second {
		t.Errorf("retryAfter 우선 실패: %v", got)
	}
	if got := nextRetryDelay(1, interval, 600*time.Second); got != interval {
		t.Errorf("retryAfter cap 실패: %v", got)
	}
}

func TestShouldShowStale(t *testing.T) {
	interval := 300 * time.Second
	if shouldShowStale(899*time.Second, interval) {
		t.Error("899s는 stale 아님")
	}
	if !shouldShowStale(900*time.Second, interval) {
		t.Error("900s는 stale")
	}
}
