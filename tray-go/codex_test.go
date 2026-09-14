package main

import (
	"testing"
	"time"
)

func TestParseCodexUsage(t *testing.T) {
	now := time.Date(2026, 9, 14, 12, 0, 0, 0, time.UTC)
	u, err := parseCodexUsage([]byte(`{"rate_limit":{"primary_window":{"used_percent":18,"reset_after_seconds":3600},"secondary_window":{"used_percent":43,"reset_at":1789387200}}}`), now)
	if err != nil {
		t.Fatal(err)
	}
	if u.FiveHour.UsedPercent != 18 || u.Weekly == nil || u.Weekly.UsedPercent != 43 {
		t.Fatalf("unexpected usage: %#v", u)
	}
	if u.FiveHour.ResetsAt == nil || *u.FiveHour.ResetsAt != "2026-09-14T13:00:00Z" {
		t.Fatalf("unexpected primary reset: %v", u.FiveHour.ResetsAt)
	}
}

func TestParseCodexUsageRequiresPrimaryWindow(t *testing.T) {
	if _, err := parseCodexUsage([]byte(`{"rate_limit":{}}`), time.Now()); err == nil {
		t.Fatal("expected malformed response error")
	}
}

func TestExtractLastCodexModel(t *testing.T) {
	content := "{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\"}}\n{\"type\":\"event_msg\",\"payload\":{\"model\":\"ignored\"}}\n{\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-terra\"}}"
	if got := extractLastCodexModel(content); got != "gpt-5.6-terra" {
		t.Fatalf("got %q", got)
	}
}
