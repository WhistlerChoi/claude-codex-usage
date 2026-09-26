package main

import (
	"encoding/json"
	"strings"
)

// Token accounting for Codex, read from the rollout logs under CODEX_HOME/sessions/**/*.jsonl.
// Two record shapes carry per-response usage:
//   - top-level type == "token_usage_record" (newer CLIs): payload.usage, deduplicated by
//     payload.response_id;
//   - type == "event_msg" with payload.type == "token_count": payload.info.last_token_usage.
//     payload.info may be null, and the same usage is sometimes re-emitted on consecutive events,
//     so consecutive repeats are dropped. payload.info.total_token_usage is the session's running
//     total and must never be summed.
//
// When a file has any token_usage_record, only those are used for that file.
//
// Codex's input_tokens already includes cached_input_tokens; the shared totals keep them apart
// (Input = uncached input, CacheRead = cached input, CacheCreate = cache_write_input_tokens).
type codexUsageCounts struct {
	Input      int64 `json:"input_tokens"`
	Cached     int64 `json:"cached_input_tokens"`
	CacheWrite int64 `json:"cache_write_input_tokens"`
	Output     int64 `json:"output_tokens"`
}

func (c codexUsageCounts) totals() tokenTotals {
	uncached := c.Input - c.Cached
	if uncached < 0 {
		uncached = 0
	}
	return tokenTotals{Input: uncached, Output: c.Output, CacheRead: c.Cached, CacheCreate: c.CacheWrite}
}

// extractCodexDailyTotals buckets per-response usage by the local date of the record timestamp.
func extractCodexDailyTotals(content string) dailyTotals {
	fromRecords, fromEvents := dailyTotals{}, dailyTotals{}
	haveRecords := false
	seenResponses := map[string]bool{}
	var prevEvent *codexUsageCounts
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		var rec struct {
			Timestamp string `json:"timestamp"`
			Type      string `json:"type"`
			Payload   struct {
				Type       string            `json:"type"`
				ResponseID string            `json:"response_id"`
				Usage      *codexUsageCounts `json:"usage"`
				Info       *struct {
					Last *codexUsageCounts `json:"last_token_usage"`
				} `json:"info"`
			} `json:"payload"`
		}
		if json.Unmarshal([]byte(line), &rec) != nil {
			continue
		}
		ts, hasTime := parseRecordTime(rec.Timestamp)
		switch {
		case rec.Type == "token_usage_record" && rec.Payload.Usage != nil:
			haveRecords = true
			if rec.Payload.ResponseID != "" {
				if seenResponses[rec.Payload.ResponseID] {
					continue
				}
				seenResponses[rec.Payload.ResponseID] = true
			}
			if hasTime {
				key := localDateKey(ts)
				fromRecords[key] = fromRecords[key].add(rec.Payload.Usage.totals())
			}
		case rec.Type == "event_msg" && rec.Payload.Type == "token_count" && rec.Payload.Info != nil && rec.Payload.Info.Last != nil:
			last := rec.Payload.Info.Last
			if prevEvent != nil && *prevEvent == *last {
				continue
			}
			prevEvent = last
			if hasTime {
				key := localDateKey(ts)
				fromEvents[key] = fromEvents[key].add(last.totals())
			}
		}
	}
	if haveRecords {
		return fromRecords
	}
	return fromEvents
}
