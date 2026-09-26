package main

import (
	"strconv"
	"strings"
	"testing"
	"time"
)

func assistantLine(id, ts string, in, out, create, read int) string {
	return `{"type":"assistant","timestamp":"` + ts + `","requestId":"req_` + id + `","message":{"id":"` + id + `","model":"claude-fable-5-1","usage":{"input_tokens":` + itoa(in) + `,"output_tokens":` + itoa(out) + `,"cache_creation_input_tokens":` + itoa(create) + `,"cache_read_input_tokens":` + itoa(read) + `}}}`
}

func itoa(n int) string { return strconv.Itoa(n) }

func TestExtractDailyTotalsBucketsByLocalDate(t *testing.T) {
	dayA := time.Date(2026, 9, 25, 22, 0, 0, 0, time.Local)
	dayB := time.Date(2026, 9, 26, 1, 0, 0, 0, time.Local)
	content := strings.Join([]string{
		assistantLine("a", dayA.UTC().Format(time.RFC3339Nano), 10, 20, 30, 40),
		assistantLine("b", dayB.UTC().Format(time.RFC3339Nano), 1, 2, 3, 4),
		assistantLine("c", dayB.UTC().Format(time.RFC3339Nano), 1, 1, 1, 1),
	}, "\n")
	got := extractDailyTotals(content)
	if len(got) != 2 || got["2026-09-25"] != (tokenTotals{Input: 10, Output: 20, CacheCreate: 30, CacheRead: 40}) || got["2026-09-26"] != (tokenTotals{Input: 2, Output: 3, CacheCreate: 4, CacheRead: 5}) {
		t.Fatalf("got %+v", got)
	}
}

func TestExtractDailyTotalsDedupsMessageID(t *testing.T) {
	content := strings.Join([]string{
		assistantLine("same", "2026-09-26T01:00:00Z", 5, 7, 0, 0),
		assistantLine("same", "2026-09-26T01:00:01Z", 5, 7, 0, 0),
	}, "\n")
	got := extractDailyTotals(content)
	if len(got) != 1 || got[localDateKey(time.Date(2026, 9, 26, 1, 0, 0, 0, time.UTC))] != (tokenTotals{Input: 5, Output: 7}) {
		t.Fatalf("got %+v", got)
	}
}

func TestExtractDailyTotalsSkipsJunk(t *testing.T) {
	content := strings.Join([]string{
		`{"type":"user","timestamp":"2026-09-26T01:00:00Z","message":{"usage":{"input_tokens":999}}}`,
		"not json",
		"",
		`{"type":"assistant","message":{"id":"nots","usage":{"input_tokens":50}}}`,
		`{"type":"assistant","timestamp":"2026-09-26T01:00:00Z","message":{"id":"nousage"}}`,
		`{"type":"assistant","timestamp":"2026-09-26T01:00:00Z","message":{"id":"partial","usage":{"output_tokens":3}}}`,
	}, "\n")
	got := extractDailyTotals(content)
	if len(got) != 1 || got[localDateKey(time.Date(2026, 9, 26, 1, 0, 0, 0, time.UTC))] != (tokenTotals{Output: 3}) {
		t.Fatalf("got %+v", got)
	}
	if got := extractDailyTotals(""); len(got) != 0 {
		t.Fatalf("empty: %+v", got)
	}
}

func TestFormatTokens(t *testing.T) {
	cases := map[int64]string{0: "0", 999: "999", 1234: "1.2K", 48000: "48K", 310400: "310K", 999999: "1.0M", 9800000: "9.8M", 13500000: "14M", 999999999: "1.0B", 2100000000: "2.1B"}
	for n, want := range cases {
		if got := formatTokens(n); got != want {
			t.Errorf("formatTokens(%d)=%q want %q", n, got, want)
		}
	}
}

func TestTokenTotalsText(t *testing.T) {
	got := tokenTotalsText(tokenTotals{Input: 1_200_000, Output: 48_000, CacheRead: 9_000_000, CacheCreate: 800_000})
	if got != "1.2M in · 48K out · 9.8M cache" {
		t.Fatalf("got %q", got)
	}
}
