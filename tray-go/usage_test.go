package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseWeeklyScoped(t *testing.T) {
	full := json.RawMessage(`[
		{"kind":"session","group":"session","percent":6,"resets_at":"2026-06-04T11:50:00+00:00","scope":null},
		{"kind":"weekly_all","group":"weekly","percent":59,"resets_at":"2026-06-10T07:00:00+00:00","scope":null},
		{"kind":"weekly_scoped","group":"weekly","percent":12,"resets_at":"2026-06-10T07:00:00+00:00",
		 "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}
	]`)
	got := parseWeeklyScoped(full)
	if len(got) != 1 || got[0].Model != "Fable" || got[0].Window.Utilization != 12 {
		t.Fatalf("full limits: got %+v", got)
	}
	if got[0].Window.ResetsAt == nil || *got[0].Window.ResetsAt != "2026-06-10T07:00:00+00:00" {
		t.Fatalf("resets_at not mapped: %+v", got[0].Window.ResetsAt)
	}
}

func TestParseWeeklyScopedLenient(t *testing.T) {
	for name, raw := range map[string]json.RawMessage{
		"absent":    nil,
		"null":      json.RawMessage(`null`),
		"string":    json.RawMessage(`"x"`),
		"number":    json.RawMessage(`5`),
		"non-array": json.RawMessage(`{"a":1}`),
	} {
		if got := parseWeeklyScoped(raw); len(got) != 0 {
			t.Errorf("%s: expected empty, got %+v", name, got)
		}
	}
	// Malformed entries are skipped individually; the valid sibling still parses.
	mixed := json.RawMessage(`[
		"junk",
		{"kind":"weekly_scoped","percent":7},
		{"kind":"weekly_scoped","percent":"12","scope":{"model":{"display_name":"X"}}},
		{"kind":"weekly_scoped","percent":7,"scope":{"model":{"display_name":null}}},
		{"kind":"weekly_all","percent":7,"scope":{"model":{"display_name":"Y"}}},
		{"kind":"weekly_scoped","percent":12,"scope":{"model":{"display_name":"Fable"}}}
	]`)
	got := parseWeeklyScoped(mixed)
	if len(got) != 1 || got[0].Model != "Fable" || got[0].Window.Utilization != 12 {
		t.Fatalf("mixed limits: got %+v", got)
	}
}

func TestDetailLinesWeeklyScoped(t *testing.T) {
	u := &usageResp{
		FiveHour:     &window{Utilization: 42},
		SevenDay:     &window{Utilization: 8},
		WeeklyScoped: []scopedWindow{{Model: "Fable", Window: window{Utilization: 12}}},
	}
	joined := strings.Join(detailLines(u, nil), "\n")
	if !strings.Contains(joined, "Weekly Fable: 12% · ") {
		t.Fatalf("missing Weekly Fable line:\n%s", joined)
	}

	// A scoped entry naming the same model as a legacy field is skipped.
	u.SevenDaySonnet = &window{Utilization: 3}
	u.WeeklyScoped = append([]scopedWindow{{Model: "Sonnet", Window: window{Utilization: 3}}}, u.WeeklyScoped...)
	joined = strings.Join(detailLines(u, nil), "\n")
	if n := strings.Count(joined, "Weekly Sonnet"); n != 1 {
		t.Fatalf("Weekly Sonnet appears %d times:\n%s", n, joined)
	}
	if !strings.Contains(joined, "Weekly Fable") {
		t.Fatalf("missing Weekly Fable line:\n%s", joined)
	}
}
