package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/getlantern/systray"
)

var (
	detailItems      []*systray.MenuItem
	mRefresh, mQuit  *systray.MenuItem
	lastUsage        *usageResp
	lastModel        *currentModel
)

const (
	colorNormal = "#2D7DF6"
	colorWarn   = "#E8A317"
	colorAlert  = "#D64545"
	colorError  = "#777777"
)

func main() {
	// --render [out.png]: 아이콘 이미지를 PNG로 저장하고 종료 (검증용)
	if len(os.Args) > 1 && os.Args[1] == "--render" {
		out := "/tmp/icon.png"
		if len(os.Args) > 2 {
			out = os.Args[2]
		}
		_ = os.WriteFile(out, renderIconPNG("42", colorNormal), 0o644)
		fmt.Println("wrote", out)
		return
	}
	systray.Run(onReady, func() {})
}

func onReady() {
	systray.SetTitle("")
	systray.SetTooltip("Claude 사용량 불러오는 중...")

	for i := 0; i < 6; i++ {
		it := systray.AddMenuItem("", "")
		it.Hide()
		detailItems = append(detailItems, it)
	}
	systray.AddSeparator()
	mRefresh = systray.AddMenuItem("지금 새로고침", "")
	mQuit = systray.AddMenuItem("종료", "")

	go pollLoop()
	go func() {
		for {
			select {
			case <-mRefresh.ClickedCh:
				refresh()
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

func pollLoop() {
	refresh()
	interval := 300
	if v := os.Getenv("CLAUDE_USAGE_INTERVAL"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 10 {
			interval = n
		}
	}
	ticker := time.NewTicker(time.Duration(interval) * time.Second)
	for range ticker.C {
		refresh()
	}
}

func refresh() {
	usage, err := fetchUsage()
	if err != nil {
		if lastUsage != nil && !errors.Is(err, errAuth) && !errors.Is(err, errNoCreds) {
			applyUsage(lastUsage, lastModel, true)
		} else {
			applyError(err.Error())
		}
		return
	}
	model, _ := readCurrentModel()
	lastUsage, lastModel = usage, model
	applyUsage(usage, model, false)
}

func bgFor(u *usageResp) string {
	peak := peakUtilization(u)
	switch {
	case peak >= 0.95:
		return colorAlert
	case peak >= 0.8:
		return colorWarn
	default:
		return colorNormal
	}
}

func detailLines(u *usageResp, model *currentModel) []string {
	now := time.Now()
	lines := []string{
		fmt.Sprintf("5시간: %d%% · %s", pct(u.FiveHour.Utilization), formatResetIn(u.FiveHour.ResetsAt, now)),
		fmt.Sprintf("주간: %d%% · %s", pct(u.SevenDay.Utilization), formatResetIn(u.SevenDay.ResetsAt, now)),
	}
	if u.SevenDayOpus != nil {
		lines = append(lines, fmt.Sprintf("주간 Opus: %d%% · %s", pct(u.SevenDayOpus.Utilization), formatResetIn(u.SevenDayOpus.ResetsAt, now)))
	}
	if u.SevenDaySonnet != nil {
		lines = append(lines, fmt.Sprintf("주간 Sonnet: %d%% · %s", pct(u.SevenDaySonnet.Utilization), formatResetIn(u.SevenDaySonnet.ResetsAt, now)))
	}
	if model != nil {
		lines = append(lines, fmt.Sprintf("현재 모델: %s (%s)", model.Name, model.ID))
	}
	return lines
}

func applyUsage(u *usageResp, model *currentModel, stale bool) {
	systray.SetIcon(iconBytes(strconv.Itoa(pct(u.FiveHour.Utilization)), bgFor(u)))

	lines := detailLines(u, model)
	shown := lines
	if stale {
		shown = append([]string{"⚠ 갱신 실패 — 이전 값 표시 중"}, lines...)
	}
	systray.SetTooltip("Claude 사용량\n" + strings.Join(shown, "\n"))

	for i, it := range detailItems {
		if i < len(shown) {
			it.SetTitle(shown[i])
			it.Show()
		} else {
			it.Hide()
		}
	}
}

func applyError(message string) {
	systray.SetIcon(iconBytes("!", colorError))
	systray.SetTooltip("Claude 사용량\n⚠ " + message)
	for i, it := range detailItems {
		if i == 0 {
			it.SetTitle(message)
			it.Show()
		} else {
			it.Hide()
		}
	}
}
