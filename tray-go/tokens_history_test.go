package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func tt(in, out, cr, cc int64) tokenTotals {
	return tokenTotals{Input: in, Output: out, CacheRead: cr, CacheCreate: cc}
}

func TestLocalDateKeyAndDateShift(t *testing.T) {
	if got := localDateKey(time.Date(2026, 9, 26, 23, 59, 0, 0, time.Local)); got != "2026-09-26" {
		t.Fatalf("localDateKey %q", got)
	}
	for _, c := range []struct {
		in, want string
		n        int
	}{{"2026-09-26", "2026-09-20", -6}, {"2026-03-01", "2026-02-28", -1}, {"2026-01-01", "2025-12-31", -1}} {
		if got := dateShift(c.in, c.n); got != c.want {
			t.Errorf("dateShift(%s,%d)=%s want %s", c.in, c.n, got, c.want)
		}
	}
}

func TestMergeDailyIntoLedgerMax(t *testing.T) {
	l := newLedger()
	if !mergeDailyIntoLedger(l, "claude", dailyTotals{"2026-09-25": tt(10, 5, 0, 0), "2026-09-26": tt(1, 1, 0, 0)}, "2026-09-26") {
		t.Fatal("first merge should change")
	}
	if !mergeDailyIntoLedger(l, "claude", dailyTotals{"2026-09-25": tt(4, 9, 0, 0), "2026-09-26": tt(1, 1, 0, 0)}, "2026-09-26") {
		t.Fatal("second merge should change (output grew)")
	}
	if l.Days["2026-09-25"]["claude"] != tt(10, 9, 0, 0) {
		t.Fatalf("max not applied: %+v", l.Days["2026-09-25"]["claude"])
	}
	if mergeDailyIntoLedger(l, "claude", dailyTotals{"2026-09-26": tt(1, 1, 0, 0)}, "2026-09-26") {
		t.Fatal("no-op merge reported change")
	}
	if l.Since["claude"] != "2026-09-26" {
		t.Fatalf("since %q", l.Since["claude"])
	}
	mergeDailyIntoLedger(l, "codex", dailyTotals{"2026-09-26": tt(7, 0, 0, 0)}, "2026-09-26")
	if l.Days["2026-09-26"]["codex"] != tt(7, 0, 0, 0) || l.Days["2026-09-26"]["claude"] != tt(1, 1, 0, 0) {
		t.Fatalf("providers: %+v", l.Days["2026-09-26"])
	}
}

func TestMergeLedgers(t *testing.T) {
	a, b := newLedger(), newLedger()
	mergeDailyIntoLedger(a, "claude", dailyTotals{"2026-09-20": tt(100, 0, 0, 0)}, "2026-09-20")
	mergeDailyIntoLedger(b, "claude", dailyTotals{"2026-09-20": tt(50, 50, 0, 0), "2026-09-21": tt(1, 0, 0, 0)}, "2026-09-21")
	m := mergeLedgers(a, b)
	if m.Days["2026-09-20"]["claude"] != tt(100, 50, 0, 0) || m.Days["2026-09-21"]["claude"] != tt(1, 0, 0, 0) || m.Since["claude"] != "2026-09-20" {
		t.Fatalf("merged %+v since %v", m.Days, m.Since)
	}
}

func TestSumRangeTrendStats(t *testing.T) {
	l := newLedger()
	mergeDailyIntoLedger(l, "claude", dailyTotals{"2026-09-20": tt(1, 0, 0, 0), "2026-09-21": tt(2, 0, 0, 0), "2026-09-22": tt(4, 0, 0, 0), "2026-09-23": tt(8, 0, 0, 0)}, "2026-09-23")
	mergeDailyIntoLedger(l, "codex", dailyTotals{"2026-09-21": tt(1000, 0, 0, 0)}, "2026-09-23")
	if got := sumRange(l, "claude", "2026-09-21", "2026-09-22"); got != tt(6, 0, 0, 0) {
		t.Fatalf("sumRange %+v", got)
	}
	cases := []struct {
		cur  tokenTotals
		prev *tokenTotals
		want string
	}{
		{tt(112, 0, 0, 0), &tokenTotals{Input: 100}, "▲ 12%"},
		{tt(95, 0, 0, 0), &tokenTotals{Input: 100}, "▼ 5%"},
		{tt(50, 50, 0, 0), &tokenTotals{Input: 60, Output: 40}, "± 0%"},
		{tt(5, 0, 0, 0), &tokenTotals{}, "—"},
		{tt(5, 0, 0, 0), nil, "—"},
	}
	for _, c := range cases {
		if got := trendText(c.cur, c.prev); got != c.want {
			t.Errorf("trendText=%q want %q", got, c.want)
		}
	}
	// 14 days of coverage: prior 7d available, prior 30d not.
	l2 := newLedger()
	daily := dailyTotals{}
	for i := 0; i < 14; i++ {
		daily[dateShift("2026-09-26", -i)] = tt(1, 0, 0, 0)
	}
	mergeDailyIntoLedger(l2, "claude", daily, "2026-09-26")
	s := statsFrom(l2, "claude", "2026-09-26")
	if s.Today != tt(1, 0, 0, 0) || s.Last7 != tt(7, 0, 0, 0) || s.Prev7 == nil || *s.Prev7 != tt(7, 0, 0, 0) || s.Last30 != tt(14, 0, 0, 0) || s.Prev30 != nil {
		t.Fatalf("stats %+v", s)
	}
}

func TestTokenRows(t *testing.T) {
	prev := tt(30_000_000, 2_000_000, 550_000_000, 10_000_000)
	rows := tokenRows(tokenStats{
		Today: tt(5_900, 406_000, 78_000_000, 2_300_000),
		Last7: tt(41_000_000, 2_900_000, 600_000_000, 20_000_000), Prev7: &prev,
		Last30: tt(120_000_000, 9_100_000, 2_000_000_000, 100_000_000),
	})
	want := []tokenRow{
		{"Tokens today", "5.9K in · 406K out · 80M cache"},
		{"Tokens 7d", "41M in · 2.9M out · 620M cache · ▲ 12% vs prior 7d"},
		{"Tokens 30d", "120M in · 9.1M out · 2.1B cache · — vs prior 30d"},
	}
	for i := range want {
		if rows[i] != want[i] {
			t.Errorf("row %d = %+v want %+v", i, rows[i], want[i])
		}
	}
}

func histFixture(t *testing.T) (root, home, proj string) {
	base := t.TempDir()
	root, home = filepath.Join(base, "projects"), filepath.Join(base, "pulse-home")
	proj = filepath.Join(root, "-Users-me-proj")
	if err := os.MkdirAll(filepath.Join(proj, "sess1", "subagents"), 0o755); err != nil {
		t.Fatal(err)
	}
	return
}

func writeLines(t *testing.T, p string, lines ...string) {
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestUpdateTokenHistoryBackfillsAndPersists(t *testing.T) {
	root, home, proj := histFixture(t)
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.Local)
	d0 := time.Date(2026, 9, 26, 10, 0, 0, 0, time.Local).UTC().Format(time.RFC3339Nano)
	d1 := time.Date(2026, 9, 25, 10, 0, 0, 0, time.Local).UTC().Format(time.RFC3339Nano)
	writeLines(t, filepath.Join(proj, "sess1.jsonl"), assistantLine("a", d0, 10, 0, 0, 0), assistantLine("b", d1, 3, 0, 0, 0))
	writeLines(t, filepath.Join(proj, "sess1", "subagents", "agent-x.jsonl"), assistantLine("c", d0, 0, 7, 0, 0))
	s := updateTokenHistory("claude", root, extractDailyTotals, home, now)
	if s == nil || s.Today != tt(10, 7, 0, 0) || s.Last7 != tt(13, 7, 0, 0) {
		t.Fatalf("stats %+v", s)
	}
	b, err := os.ReadFile(filepath.Join(home, "token-history.json"))
	if err != nil {
		t.Fatal(err)
	}
	var l tokenLedger
	if err := json.Unmarshal(b, &l); err != nil {
		t.Fatal(err)
	}
	if l.Days["2026-09-26"]["claude"] != tt(10, 7, 0, 0) || l.Days["2026-09-25"]["claude"] != tt(3, 0, 0, 0) || l.Since["claude"] != "2026-09-26" {
		t.Fatalf("ledger %+v since %v", l.Days, l.Since)
	}
	if _, err := os.Stat(filepath.Join(home, "cache", "claude-files.json")); err != nil {
		t.Fatal("cache not written")
	}
}

func TestUpdateTokenHistoryKeepsDeletedFiles(t *testing.T) {
	root, home, proj := histFixture(t)
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.Local)
	d1 := time.Date(2026, 9, 25, 10, 0, 0, 0, time.Local).UTC().Format(time.RFC3339Nano)
	old := filepath.Join(proj, "old.jsonl")
	writeLines(t, old, assistantLine("a", d1, 100, 0, 0, 0))
	writeLines(t, filepath.Join(proj, "live.jsonl"), assistantLine("b", d1, 1, 0, 0, 0))
	if s := updateTokenHistory("claude", root, extractDailyTotals, home, now); s.Last7 != tt(101, 0, 0, 0) {
		t.Fatalf("first %+v", s)
	}
	os.Remove(old)
	if s := updateTokenHistory("claude", root, extractDailyTotals, home, now); s.Last7 != tt(101, 0, 0, 0) {
		t.Fatalf("after delete %+v", s)
	}
}

func TestUpdateTokenHistoryCacheAndScanWindow(t *testing.T) {
	root, home, proj := histFixture(t)
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.Local)
	d0 := time.Date(2026, 9, 26, 10, 0, 0, 0, time.Local).UTC().Format(time.RFC3339Nano)
	file := filepath.Join(proj, "s.jsonl")
	writeLines(t, file, assistantLine("a", d0, 1, 0, 0, 0))
	ancient := filepath.Join(proj, "ancient.jsonl")
	writeLines(t, ancient, assistantLine("z", d0, 999, 0, 0, 0))
	longAgo := now.Add(-90 * 24 * time.Hour)
	os.Chtimes(ancient, longAgo, longAgo)
	reads := 0
	counting := func(c string) dailyTotals { reads++; return extractDailyTotals(c) }
	updateTokenHistory("claude", root, counting, home, now)
	s := updateTokenHistory("claude", root, counting, home, now)
	if reads != 1 || s.Today != tt(1, 0, 0, 0) {
		t.Fatalf("reads=%d stats=%+v", reads, s)
	}
	writeLines(t, file, assistantLine("a", d0, 1, 0, 0, 0), assistantLine("b", d0, 2, 0, 0, 0))
	s = updateTokenHistory("claude", root, counting, home, now)
	if reads != 2 || s.Today != tt(3, 0, 0, 0) {
		t.Fatalf("after append reads=%d stats=%+v", reads, s)
	}
}

func TestUpdateTokenHistoryQuarantinesCorruptLedger(t *testing.T) {
	root, home, proj := histFixture(t)
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.Local)
	os.MkdirAll(home, 0o755)
	os.WriteFile(filepath.Join(home, "token-history.json"), []byte("{not json"), 0o644)
	writeLines(t, filepath.Join(proj, "s.jsonl"), assistantLine("a", now.UTC().Format(time.RFC3339Nano), 1, 0, 0, 0))
	if s := updateTokenHistory("claude", root, extractDailyTotals, home, now); s == nil || s.Today != tt(1, 0, 0, 0) {
		t.Fatalf("stats %+v", s)
	}
	entries, _ := os.ReadDir(home)
	found := false
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "token-history.json.corrupt-") {
			found = true
		}
	}
	if !found {
		t.Fatal("corrupt ledger not quarantined")
	}
}

func TestUpdateTokenHistoryMissingRoot(t *testing.T) {
	base := t.TempDir()
	if s := updateTokenHistory("claude", filepath.Join(base, "nope"), extractDailyTotals, filepath.Join(base, "home"), time.Now()); s != nil {
		t.Fatalf("expected nil, got %+v", s)
	}
	if _, err := os.Stat(filepath.Join(base, "home")); err == nil {
		t.Fatal("home should not be created for a missing root")
	}
}

func TestDetailLinesHaveNoTokenRows(t *testing.T) {
	u := &usageResp{FiveHour: &window{Utilization: 1}, SevenDay: &window{Utilization: 2}}
	lines := detailLines(u, &currentModel{ID: "claude-fable-5-1", Name: "Fable 5.1"})
	for _, l := range lines {
		if strings.HasPrefix(l, "Tokens") {
			t.Fatalf("token row leaked into detail lines: %q", l)
		}
	}
	c := &codexUsage{FiveHour: codexWindow{UsedPercent: 5}}
	for _, l := range codexDetailLines(c, nil) {
		if strings.HasPrefix(l, "Tokens") {
			t.Fatalf("token row leaked into codex detail lines: %q", l)
		}
	}
}

func TestTokenMenuTitles(t *testing.T) {
	st := tokenStats{Today: tt(1200, 48, 100, 0), Last7: tt(7, 0, 0, 0), Last30: tt(30, 0, 0, 0)}
	parent, children := tokenMenuTitles(st)
	if parent != "Tokens today: 1.2K in · 48 out · 100 cache" {
		t.Fatalf("parent %q", parent)
	}
	if len(children) != 2 || children[0] != "Tokens 7d: 7 in · 0 out · 0 cache · — vs prior 7d" || children[1] != "Tokens 30d: 30 in · 0 out · 0 cache · — vs prior 30d" {
		t.Fatalf("children %q", children)
	}
}
