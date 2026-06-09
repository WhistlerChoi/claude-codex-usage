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
	// Retry-After는 존중(interval로 깎지 않음), maxRetry로만 cap.
	if got := nextRetryDelay(1, interval, 45*time.Second, 0); got != 45*time.Second {
		t.Errorf("retryAfter 우선 실패: %v", got)
	}
	if got := nextRetryDelay(1, interval, 600*time.Second, 0); got != 600*time.Second {
		t.Errorf("retryAfter 존중 실패: %v", got)
	}
	if got := nextRetryDelay(1, interval, 5000*time.Second, 0); got != maxRetry {
		t.Errorf("retryAfter MAX cap 실패: %v", got)
	}
	// 지터: base의 0~20% 가산.
	if got := nextRetryDelay(1, interval, 0, 1); got != 72*time.Second {
		t.Errorf("지터 실패: %v want 72s", got)
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
