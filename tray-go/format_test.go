package main

import (
	"strings"
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

func TestFormatRetryIn(t *testing.T) {
	cases := []struct {
		d    time.Duration
		want string
	}{
		{0, "Retrying in 0s"},
		{45 * time.Second, "Retrying in 45s"},
		{-5 * time.Second, "Retrying in 0s"},
		{60 * time.Second, "Retrying in 1m"},
		{3599 * time.Second, "Retrying in 59m"}, // never "60m"
		{3600 * time.Second, "Retrying in 1h"},
		{3900 * time.Second, "Retrying in 1h 5m"},
	}
	for _, c := range cases {
		if got := formatRetryIn(c.d); got != c.want {
			t.Errorf("formatRetryIn(%v)=%q want %q", c.d, got, c.want)
		}
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

func TestUsageRow(t *testing.T) {
	// The reset time goes into the tab-aligned right column, which Windows renders as the
	// native accelerator column. Everything before the tab stays one left-aligned run.
	got := usageRow("5h", 41, "resets in 2h 17m")
	if got != "5h: 41%\tresets in 2h 17m" {
		t.Fatalf("unexpected row: %q", got)
	}
	// Exactly one tab per row, or Windows splits the line at the wrong place.
	if strings.Count(got, "\t") != 1 {
		t.Fatalf("expected exactly one tab, got %q", got)
	}
	// A single-digit percent must not be padded: the tab does the aligning, and padding
	// with spaces in a proportional font only makes the column ragged.
	if got := usageRow("5h", 0, "resets in 4h 59m"); got != "5h: 0%\tresets in 4h 59m" {
		t.Fatalf("unexpected single-digit row: %q", got)
	}
	// An unknown reset time still produces a well-formed row, never a dangling tab.
	if got := usageRow("Weekly", 6, ""); got != "Weekly: 6%" {
		t.Fatalf("unexpected row with no reset: %q", got)
	}
}
