package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Token accounting primitives for Claude Code transcripts (~/.claude/projects/**/*.jsonl); mirrors
// src/tokens.ts. The usage API only reports rate-limit percentages, so token counts can only come
// from these files. Pure parsing lives here; the daily ledger that turns it into today / 7d / 30d
// figures is in tokens_history.go. Best-effort throughout: a failure means the token rows are
// omitted, never an error state.
type tokenTotals struct {
	Input       int64 `json:"input"`
	Output      int64 `json:"output"`
	CacheRead   int64 `json:"cacheRead"`
	CacheCreate int64 `json:"cacheCreate"`
}

func (t tokenTotals) add(o tokenTotals) tokenTotals {
	return tokenTotals{t.Input + o.Input, t.Output + o.Output, t.CacheRead + o.CacheRead, t.CacheCreate + o.CacheCreate}
}

func (t tokenTotals) total() int64 { return t.Input + t.Output + t.CacheRead + t.CacheCreate }

// dailyTotals: per local calendar day ("YYYY-MM-DD") totals of one transcript.
type dailyTotals map[string]tokenTotals

// extractDailyTotals buckets message.usage of the assistant records by the local date of their
// timestamp. Claude Code writes one assistant line per content block of a response; those lines
// share message.id with identical usage, so each id counts once. Records without a timestamp
// cannot be attributed to a day and are skipped. usage.iterations[] is ignored.
func extractDailyTotals(content string) dailyTotals {
	days := dailyTotals{}
	seen := map[string]bool{}
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		var rec struct {
			Type      string `json:"type"`
			Timestamp string `json:"timestamp"`
			Message   struct {
				ID    string           `json:"id"`
				Usage *json.RawMessage `json:"usage"`
			} `json:"message"`
		}
		if json.Unmarshal([]byte(line), &rec) != nil || rec.Type != "assistant" || rec.Message.Usage == nil {
			continue
		}
		ts, ok := parseRecordTime(rec.Timestamp)
		if !ok {
			continue
		}
		var usage struct {
			Input       int64 `json:"input_tokens"`
			Output      int64 `json:"output_tokens"`
			CacheCreate int64 `json:"cache_creation_input_tokens"`
			CacheRead   int64 `json:"cache_read_input_tokens"`
		}
		if json.Unmarshal(*rec.Message.Usage, &usage) != nil {
			continue
		}
		if rec.Message.ID != "" {
			if seen[rec.Message.ID] {
				continue
			}
			seen[rec.Message.ID] = true
		}
		key := localDateKey(ts)
		days[key] = days[key].add(tokenTotals{usage.Input, usage.Output, usage.CacheRead, usage.CacheCreate})
	}
	return days
}

// parseRecordTime: RFC 3339 timestamp of a log record; missing or unparseable → false.
func parseRecordTime(ts string) (time.Time, bool) {
	if ts == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, ts)
	return t, err == nil
}

// formatTokens: 0 → "0", 1234 → "1.2K", 48000 → "48K", 9_800_000 → "9.8M", 13_500_000 → "14M", 2.1e9 → "2.1B".
func formatTokens(n int64) string {
	scaled := func(unit float64, suffix string) string {
		v := float64(n) / unit
		if v < 10 {
			return fmt.Sprintf("%.1f%s", v, suffix)
		}
		return fmt.Sprintf("%.0f%s", v, suffix)
	}
	switch {
	case n < 1000:
		return fmt.Sprintf("%d", n)
	case n < 999_500:
		return scaled(1_000, "K")
	case n < 999_500_000:
		return scaled(1_000_000, "M")
	default:
		return scaled(1_000_000_000, "B")
	}
}

// tokenTotalsText: "1.2M in · 48K out · 9.8M cache" — cache is read + creation. Identical in all ports.
func tokenTotalsText(t tokenTotals) string {
	return fmt.Sprintf("%s in · %s out · %s cache", formatTokens(t.Input), formatTokens(t.Output), formatTokens(t.CacheRead+t.CacheCreate))
}
