package main

import (
	"strings"
	"testing"
	"time"
)

func codexRecord(ts, respID string, in, cached, write, out int) string {
	return `{"timestamp":"` + ts + `","type":"token_usage_record","payload":{"response_id":"` + respID + `","usage":{"input_tokens":` + itoa(in) + `,"cached_input_tokens":` + itoa(cached) + `,"cache_write_input_tokens":` + itoa(write) + `,"output_tokens":` + itoa(out) + `,"reasoning_output_tokens":0,"total_tokens":` + itoa(in+out) + `}}}`
}

func codexTokenCount(ts string, in, cached, write, out int) string {
	return `{"timestamp":"` + ts + `","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999999},"last_token_usage":{"input_tokens":` + itoa(in) + `,"cached_input_tokens":` + itoa(cached) + `,"cache_write_input_tokens":` + itoa(write) + `,"output_tokens":` + itoa(out) + `,"reasoning_output_tokens":0,"total_tokens":` + itoa(in+out) + `}},"rate_limits":null}}`
}

// input_tokens includes cached_input_tokens on the Codex side; the shared totals keep them apart.
// Fixture timestamps are 01:00-01:02 UTC on 2026-09-26 plus one six days earlier; the
// bucket key is the local date of 2026-09-26T01:00Z.
func TestExtractCodexTokenTotalsPrefersUsageRecords(t *testing.T) {
	content := strings.Join([]string{
		`{"timestamp":"2026-09-26T01:00:00Z","type":"turn_context","payload":{"model":"gpt-6-astra"}}`,
		codexRecord("2026-09-26T01:00:00Z", "r1", 1000, 600, 0, 50),
		codexTokenCount("2026-09-26T01:00:00.5Z", 1000, 600, 0, 50),
		codexRecord("2026-09-26T01:01:00Z", "r2", 300, 0, 20, 5),
		codexTokenCount("2026-09-26T01:01:00.5Z", 300, 0, 20, 5),
		codexRecord("2026-09-26T01:01:00Z", "r2", 300, 0, 20, 5), // duplicate response_id
		codexRecord("2026-09-20T01:00:00Z", "r0", 5000, 0, 0, 5000),
	}, "\n")
	got := extractCodexDailyTotals(content)[localDateKey(time.Date(2026, 9, 26, 1, 0, 0, 0, time.UTC))]
	want := tokenTotals{Input: 700, Output: 55, CacheRead: 600, CacheCreate: 20}
	if got != want {
		t.Fatalf("got %+v want %+v", got, want)
	}
}

func TestExtractCodexTokenTotalsFallsBackToTokenCountEvents(t *testing.T) {
	content := strings.Join([]string{
		codexTokenCount("2026-09-26T01:00:00Z", 1000, 600, 0, 50),
		codexTokenCount("2026-09-26T01:00:01Z", 1000, 600, 0, 50), // consecutive repeat of the same usage
		`{"timestamp":"2026-09-26T01:00:02Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}`,
		codexTokenCount("2026-09-26T01:02:00Z", 300, 0, 20, 5),
		codexTokenCount("2026-09-20T01:00:00Z", 5000, 0, 0, 5000),
	}, "\n")
	got := extractCodexDailyTotals(content)[localDateKey(time.Date(2026, 9, 26, 1, 0, 0, 0, time.UTC))]
	want := tokenTotals{Input: 700, Output: 55, CacheRead: 600, CacheCreate: 20}
	if got != want {
		t.Fatalf("got %+v want %+v", got, want)
	}
}

func TestExtractCodexTokenTotalsJunk(t *testing.T) {
	if got := extractCodexDailyTotals("junk\n\n{\"type\":\"session_meta\"}"); len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}
