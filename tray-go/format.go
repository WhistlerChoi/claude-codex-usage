package main

import (
	"fmt"
	"math"
	"regexp"
	"strings"
	"time"
)

var reVer = regexp.MustCompile(`(\d+)[-.](\d+)`)

func pct(u float64) int {
	return int(math.Round(u))
}

// friendlyModelName: "claude-opus-4-8" -> "Opus 4.8"
func friendlyModelName(id string) string {
	if id == "" {
		return "Unknown"
	}
	lower := strings.ToLower(id)
	fam := ""
	for _, f := range []string{"opus", "sonnet", "haiku"} {
		if strings.Contains(lower, f) {
			fam = f
			break
		}
	}
	ver := ""
	if m := reVer.FindStringSubmatch(lower); m != nil {
		ver = m[1] + "." + m[2]
	}
	if fam != "" {
		cap := strings.ToUpper(fam[:1]) + fam[1:]
		if ver != "" {
			return cap + " " + ver
		}
		return cap
	}
	return id
}

func formatResetIn(resetsAt *string, now time.Time) string {
	if resetsAt == nil || *resetsAt == "" {
		return "reset time unknown"
	}
	t, err := time.Parse(time.RFC3339Nano, *resetsAt)
	if err != nil {
		return "reset time unknown"
	}
	d := t.Sub(now)
	if d <= 0 {
		return "resets soon"
	}
	totalMin := int(d.Minutes())
	days := totalMin / (60 * 24)
	hours := (totalMin % (60 * 24)) / 60
	mins := totalMin % 60

	var parts []string
	if days > 0 {
		parts = append(parts, fmt.Sprintf("%dd", days))
	}
	if hours > 0 {
		parts = append(parts, fmt.Sprintf("%dh", hours))
	}
	if days == 0 && mins > 0 {
		parts = append(parts, fmt.Sprintf("%dm", mins))
	}
	if len(parts) == 0 {
		parts = append(parts, "<1m")
	}
	return "resets in " + strings.Join(parts, " ")
}

func peakUtilization(u *usageResp) float64 {
	return math.Max(u.FiveHour.Utilization, u.SevenDay.Utilization) / 100
}

const maxRetry = 3600 * time.Second // upper bound on retry delay (1 hour)
const retryFloor = 60 * time.Second  // floor for 429 backoff (60s)

// nextRetryDelay: delay until the next poll after a transient failure.
//   - if retryAfter>0, honor it (do not clamp to interval; only cap at maxRetry).
//   - otherwise exponential backoff (×2) starting at 60s, capped at interval (min 60s).
//
// jitter (0~1) adds 0~20% of base to spread out concurrent polling.
func nextRetryDelay(consecutiveFailures int, interval, retryAfter time.Duration, jitter float64) time.Duration {
	var base time.Duration
	if retryAfter > 0 {
		base = retryAfter
		if base > maxRetry {
			base = maxRetry
		}
	} else {
		ceiling := interval
		if ceiling < retryFloor {
			ceiling = retryFloor
		}
		base = retryFloor
		for i := 1; i < consecutiveFailures; i++ {
			base *= 2
			if base >= ceiling {
				base = ceiling
				break
			}
		}
		if base > ceiling {
			base = ceiling
		}
	}
	return base + time.Duration(float64(base)*0.2*jitter)
}

// shouldShowStale: stale if age since last success is at least interval*3.
func shouldShowStale(age, interval time.Duration) bool {
	return age >= interval*3
}
