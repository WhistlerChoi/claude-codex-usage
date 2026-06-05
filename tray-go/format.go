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
		return "리셋 시각 미정"
	}
	t, err := time.Parse(time.RFC3339Nano, *resetsAt)
	if err != nil {
		return "리셋 시각 미정"
	}
	d := t.Sub(now)
	if d <= 0 {
		return "곧 리셋"
	}
	totalMin := int(d.Minutes())
	days := totalMin / (60 * 24)
	hours := (totalMin % (60 * 24)) / 60
	mins := totalMin % 60

	var parts []string
	if days > 0 {
		parts = append(parts, fmt.Sprintf("%d일", days))
	}
	if hours > 0 {
		parts = append(parts, fmt.Sprintf("%d시간", hours))
	}
	if days == 0 && mins > 0 {
		parts = append(parts, fmt.Sprintf("%d분", mins))
	}
	if len(parts) == 0 {
		parts = append(parts, "1분 미만")
	}
	return strings.Join(parts, " ") + " 후 리셋"
}

func peakUtilization(u *usageResp) float64 {
	return math.Max(u.FiveHour.Utilization, u.SevenDay.Utilization) / 100
}
