package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Daily token ledger shared by every Pulse front-end (mirrors src/tokenHistory.ts), so 7-day /
// 30-day totals and their trend survive Claude Code's transcript cleanup (cleanupPeriodDays,
// default 30) without any server.
//
// Files under $PULSE_HOME (default ~/.pulse); all apps read and write the same ones:
//   token-history.json          — the ledger: {version, since: {provider: date}, days: {date: {provider: totals}}}
//   cache/<provider>-files.json — per-transcript parse cache: {version, files: {path: {mtime, size, days}}}
//
// The one rule that keeps this correct with deletions and several writers: a day's value in the
// ledger is the per-field MAX of what has ever been observed for it. A day's total only grows
// while its transcripts are appended to and only shrinks when a transcript is deleted, so max
// preserves deleted files' contribution, never double counts, and is the merge rule for
// concurrent apps too (read → max-merge → atomic rename).

// scanWindowDays: only transcripts modified within this many days are stat'ed and parsed; older
// days live in the ledger. ledgerRetentionDays: ledger days older than this are pruned.
const (
	scanWindowDays      = 61
	ledgerRetentionDays = 400
)

type tokenLedger struct {
	Version int                               `json:"version"`
	Since   map[string]string                 `json:"since"`
	Days    map[string]map[string]tokenTotals `json:"days"`
}

func newLedger() *tokenLedger {
	return &tokenLedger{Version: 1, Since: map[string]string{}, Days: map[string]map[string]tokenTotals{}}
}

type tokenStats struct {
	Today  tokenTotals
	Last7  tokenTotals
	Prev7  *tokenTotals // nil until the ledger covers the prior window
	Last30 tokenTotals
	Prev30 *tokenTotals
}

type tokenRow struct{ Label, Value string }

func localDateKey(t time.Time) string { return t.In(time.Local).Format("2006-01-02") }

func dateShift(key string, days int) string {
	t, err := time.ParseInLocation("2006-01-02", key, time.Local)
	if err != nil {
		return key
	}
	return t.AddDate(0, 0, days).Format("2006-01-02")
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func maxTotals(a, b tokenTotals) tokenTotals {
	return tokenTotals{max64(a.Input, b.Input), max64(a.Output, b.Output), max64(a.CacheRead, b.CacheRead), max64(a.CacheCreate, b.CacheCreate)}
}

// mergeDailyIntoLedger folds one provider's freshly computed per-day totals into the ledger with
// the max rule. today marks when observation started if the provider is new. Reports any change.
func mergeDailyIntoLedger(l *tokenLedger, provider string, daily dailyTotals, today string) bool {
	changed := false
	for date, totals := range daily {
		day := l.Days[date]
		if day == nil {
			day = map[string]tokenTotals{}
			l.Days[date] = day
		}
		prev, had := day[provider]
		merged := maxTotals(prev, totals)
		if !had || merged != prev {
			day[provider] = merged
			changed = true
		}
	}
	if since, ok := l.Since[provider]; !ok || today < since {
		l.Since[provider] = today
		changed = true
	}
	return changed
}

// mergeLedgers: union of two ledgers with per-field max and the earliest since.
func mergeLedgers(a, b *tokenLedger) *tokenLedger {
	out := newLedger()
	for _, src := range []*tokenLedger{a, b} {
		for date, providers := range src.Days {
			day := out.Days[date]
			if day == nil {
				day = map[string]tokenTotals{}
				out.Days[date] = day
			}
			for provider, totals := range providers {
				day[provider] = maxTotals(day[provider], totals)
			}
		}
		for provider, since := range src.Since {
			if cur, ok := out.Since[provider]; !ok || since < cur {
				out.Since[provider] = since
			}
		}
	}
	return out
}

// sumRange: inclusive [from, to] sum for one provider; days without an entry count as zero.
func sumRange(l *tokenLedger, provider, from, to string) tokenTotals {
	var total tokenTotals
	for date, providers := range l.Days {
		if date < from || date > to {
			continue
		}
		if t, ok := providers[provider]; ok {
			total = total.add(t)
		}
	}
	return total
}

// trendText: "▲ 12%" / "▼ 5%" / "± 0%" on total tokens; "—" when there is nothing to compare against.
func trendText(cur tokenTotals, prev *tokenTotals) string {
	if prev == nil || prev.total() <= 0 {
		return "—"
	}
	base := float64(prev.total())
	pct := int(roundHalfAway((float64(cur.total()) - base) / base * 100))
	switch {
	case pct > 0:
		return fmt.Sprintf("▲ %d%%", pct)
	case pct < 0:
		return fmt.Sprintf("▼ %d%%", -pct)
	default:
		return "± 0%"
	}
}

func roundHalfAway(v float64) float64 {
	if v < 0 {
		return -float64(int64(-v + 0.5))
	}
	return float64(int64(v + 0.5))
}

// coverageStart: the first day the ledger can vouch for — the earliest recorded day or the first
// observation, whichever is earlier. "" when the provider is unknown.
func coverageStart(l *tokenLedger, provider string) string {
	start := l.Since[provider]
	for date, providers := range l.Days {
		if _, ok := providers[provider]; ok && (start == "" || date < start) {
			start = date
		}
	}
	return start
}

func statsFrom(l *tokenLedger, provider, today string) tokenStats {
	start := coverageStart(l, provider)
	window := func(length, endOffset int) tokenTotals {
		return sumRange(l, provider, dateShift(today, endOffset-length+1), dateShift(today, endOffset))
	}
	prior := func(length int) *tokenTotals {
		if start == "" || start > dateShift(today, -(2*length-1)) {
			return nil
		}
		t := window(length, -length)
		return &t
	}
	return tokenStats{
		Today:  sumRange(l, provider, today, today),
		Last7:  window(7, 0),
		Prev7:  prior(7),
		Last30: window(30, 0),
		Prev30: prior(30),
	}
}

// tokenRows: the three rows every port renders (label prefixing is per surface).
func tokenRows(s tokenStats) []tokenRow {
	return []tokenRow{
		{"Tokens today", tokenTotalsText(s.Today)},
		{"Tokens 7d", tokenTotalsText(s.Last7) + " · " + trendText(s.Last7, s.Prev7) + " vs prior 7d"},
		{"Tokens 30d", tokenTotalsText(s.Last30) + " · " + trendText(s.Last30, s.Prev30) + " vs prior 30d"},
	}
}

func pulseHome() string {
	if v := os.Getenv("PULSE_HOME"); v != "" {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".pulse"
	}
	return filepath.Join(home, ".pulse")
}

// ---- persistence ------------------------------------------------------------------------------

type fileCacheEntry struct {
	Mtime int64       `json:"mtime"` // unix milliseconds
	Size  int64       `json:"size"`
	Days  dailyTotals `json:"days"`
}

type fileCache struct {
	Version int                       `json:"version"`
	Files   map[string]fileCacheEntry `json:"files"`
}

func writeAtomic(path string, data []byte) error {
	tmp := fmt.Sprintf("%s.tmp-%d", path, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// loadLedger: absent → fresh; corrupt → moved aside (never overwritten) and fresh.
func loadLedger(path string) *tokenLedger {
	b, err := os.ReadFile(path)
	if err != nil {
		return newLedger()
	}
	if l := parseLedger(b); l != nil {
		return l
	}
	_ = os.Rename(path, fmt.Sprintf("%s.corrupt-%d", path, time.Now().UnixMilli()))
	return newLedger()
}

func parseLedger(b []byte) *tokenLedger {
	var l tokenLedger
	if json.Unmarshal(b, &l) != nil || l.Version != 1 || l.Days == nil || l.Since == nil {
		return nil
	}
	return &l
}

func loadFileCache(path string) *fileCache {
	b, err := os.ReadFile(path)
	if err == nil {
		var c fileCache
		if json.Unmarshal(b, &c) == nil && c.Version == 1 && c.Files != nil {
			return &c
		}
	}
	return &fileCache{Version: 1, Files: map[string]fileCacheEntry{}}
}

func pruneLedger(l *tokenLedger, today string) {
	cutoff := dateShift(today, -ledgerRetentionDays)
	for date := range l.Days {
		if date < cutoff {
			delete(l.Days, date)
		}
	}
}

// updateTokenHistory runs one poll for a provider: parse changed transcripts under root (per-file
// cache), fold the per-day totals into the shared ledger, persist both atomically, and return the
// stats to display. nil when root does not exist, so callers omit the rows.
func updateTokenHistory(provider, root string, extract func(string) dailyTotals, home string, now time.Time) *tokenStats {
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		return nil
	}
	today := localDateKey(now)
	cacheDir := filepath.Join(home, "cache")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return nil
	}
	cachePath := filepath.Join(cacheDir, provider+"-files.json")
	cache := loadFileCache(cachePath)
	cutoff := now.Add(-scanWindowDays * 24 * time.Hour)

	live := map[string]bool{}
	cacheChanged := false
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".jsonl") {
			return nil
		}
		info, err := d.Info()
		if err != nil || info.ModTime().Before(cutoff) {
			return nil
		}
		live[path] = true
		if hit, ok := cache.Files[path]; ok && hit.Mtime == info.ModTime().UnixMilli() && hit.Size == info.Size() {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		cache.Files[path] = fileCacheEntry{Mtime: info.ModTime().UnixMilli(), Size: info.Size(), Days: extract(string(b))}
		cacheChanged = true
		return nil
	})
	for path := range cache.Files {
		if !live[path] {
			delete(cache.Files, path)
			cacheChanged = true
		}
	}
	if cacheChanged {
		if b, err := json.Marshal(cache); err == nil {
			_ = writeAtomic(cachePath, b)
		}
	}

	daily := dailyTotals{}
	for _, entry := range cache.Files {
		for date, totals := range entry.Days {
			daily[date] = daily[date].add(totals)
		}
	}

	ledgerPath := filepath.Join(home, "token-history.json")
	ledger := loadLedger(ledgerPath)
	if mergeDailyIntoLedger(ledger, provider, daily, today) {
		// Another app may have written meanwhile: fold its view in before replacing the file.
		if b, err := os.ReadFile(ledgerPath); err == nil {
			if onDisk := parseLedger(b); onDisk != nil {
				ledger = mergeLedgers(onDisk, ledger)
			}
		}
		pruneLedger(ledger, today)
		if b, err := json.Marshal(ledger); err == nil {
			_ = writeAtomic(ledgerPath, b)
		}
	}
	s := statsFrom(ledger, provider, today)
	return &s
}

// readTokenStats / readCodexTokenStats: the per-provider entry points used by the poll loop.
func readTokenStats() *tokenStats {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	return updateTokenHistory("claude", filepath.Join(home, ".claude", "projects"), extractDailyTotals, pulseHome(), time.Now())
}

func readCodexTokenStats() *tokenStats {
	return updateTokenHistory("codex", filepath.Join(codexHome(), "sessions"), extractCodexDailyTotals, pulseHome(), time.Now())
}

// sortedDates is used by --tokens to print the ledger deterministically.
func sortedDates(l *tokenLedger) []string {
	dates := make([]string, 0, len(l.Days))
	for d := range l.Days {
		dates = append(dates, d)
	}
	sort.Strings(dates)
	return dates
}
