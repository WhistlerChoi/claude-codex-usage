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

const maxRetry = 3600 * time.Second // 재시도 지연 상한(1시간)
const retryFloor = 60 * time.Second  // 429 백오프 바닥(60s)

// nextRetryDelay: 일시적 실패 후 다음 폴링까지 지연.
//   - retryAfter>0이면 그 값을 "존중"한다(interval로 깎지 않고 maxRetry로만 cap).
//   - 없으면 60s에서 시작하는 지수 백오프(×2)를 interval(최소 60s)로 cap.
//
// jitter(0~1)만큼 base의 0~20%를 더해 동시 폴링 충돌을 분산한다.
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

// shouldShowStale: 마지막 성공으로부터 age가 interval*3 이상이면 stale.
func shouldShowStale(age, interval time.Duration) bool {
	return age >= interval*3
}
