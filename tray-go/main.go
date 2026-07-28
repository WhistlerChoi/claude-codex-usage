package main

import (
	"errors"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/getlantern/systray"
)

var (
	detailItems         []*systray.MenuItem
	mRefresh, mQuit     *systray.MenuItem
	lastUsage           *usageResp
	lastModel           *currentModel
	lastSuccessAt       time.Time
	consecutiveFailures int
	manualRefresh       = make(chan struct{}, 1)
	cache               = newCredCache()
)

const (
	colorNormal = "#2D7DF6"
	colorWarn   = "#E8A317"
	colorAlert  = "#D64545"
	colorError  = "#777777"
)

func main() {
	// --render [out.png]: save the icon image as a PNG and exit (for verification)
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
	systray.SetTooltip("Pulse Loading...")

	for i := 0; i < 6; i++ {
		it := systray.AddMenuItem("", "")
		it.Hide()
		detailItems = append(detailItems, it)
	}
	systray.AddSeparator()
	mRefresh = systray.AddMenuItem("Refresh Now", "")
	mQuit = systray.AddMenuItem("Quit", "")

	go pollLoop()
	go func() {
		for {
			select {
			case <-mRefresh.ClickedCh:
				select {
				case manualRefresh <- struct{}{}:
				default:
				}
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

func pollLoop() {
	interval := 300
	if v := os.Getenv("CLAUDE_USAGE_INTERVAL"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 10 {
			interval = n
		}
	}
	intervalDur := time.Duration(interval) * time.Second

	delay := refresh(intervalDur, false)
	timer := time.NewTimer(delay)
	defer timer.Stop()
	for {
		force := false
		select {
		case <-timer.C:
		case <-manualRefresh:
			force = true
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
		}
		timer.Reset(refresh(intervalDur, force))
	}
}

func refresh(interval time.Duration, force bool) time.Duration {
	usage, err := fetchUsage(cache, force)
	if err != nil {
		if errors.Is(err, errAuth) || errors.Is(err, errNoCreds) || errors.Is(err, errKeychainDenied) {
			applyError(err.Error())
			consecutiveFailures = 0
			return interval
		}
		// transient error: retry with backoff. Compute the delay first so it can be displayed.
		consecutiveFailures++
		delay := nextRetryDelay(consecutiveFailures, interval, retryAfterFrom(err), rand.Float64())
		age := time.Duration(1 << 62) // effectively infinite if lastSuccessAt is unset
		if !lastSuccessAt.IsZero() {
			age = time.Since(lastSuccessAt)
		}
		if lastUsage != nil && !shouldShowStale(age, interval) {
			// still fresh → no display change (no-op)
		} else if lastUsage != nil {
			applyUsage(lastUsage, lastModel, true)
		} else {
			applyTransient(err.Error(), delay)
		}
		return delay
	}
	model, _ := readCurrentModel()
	lastUsage, lastModel = usage, model
	lastSuccessAt = time.Now()
	consecutiveFailures = 0
	applyUsage(usage, model, false)
	return interval
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
		fmt.Sprintf("5h: %d%% · %s", pct(u.FiveHour.Utilization), formatResetIn(u.FiveHour.ResetsAt, now)),
		fmt.Sprintf("Weekly: %d%% · %s", pct(u.SevenDay.Utilization), formatResetIn(u.SevenDay.ResetsAt, now)),
	}
	if u.SevenDayOpus != nil {
		lines = append(lines, fmt.Sprintf("Weekly Opus: %d%% · %s", pct(u.SevenDayOpus.Utilization), formatResetIn(u.SevenDayOpus.ResetsAt, now)))
	}
	if u.SevenDaySonnet != nil {
		lines = append(lines, fmt.Sprintf("Weekly Sonnet: %d%% · %s", pct(u.SevenDaySonnet.Utilization), formatResetIn(u.SevenDaySonnet.ResetsAt, now)))
	}
	if model != nil {
		lines = append(lines, fmt.Sprintf("Current model: %s (%s)", model.Name, model.ID))
	}
	return lines
}

func applyUsage(u *usageResp, model *currentModel, stale bool) {
	systray.SetIcon(iconBytes(strconv.Itoa(pct(u.FiveHour.Utilization)), bgFor(u)))

	lines := detailLines(u, model)
	shown := lines
	if stale {
		shown = append([]string{"⚠ Refresh failed — showing last value"}, lines...)
	}
	systray.SetTooltip("Pulse\n" + strings.Join(shown, "\n"))

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
	systray.SetTooltip("Pulse\n⚠ " + message)
	for i, it := range detailItems {
		if i == 0 {
			it.SetTitle(message)
			it.Show()
		} else {
			it.Hide()
		}
	}
}

// applyTransient: transient failure (network, HTTP 429) with no previous value to show. Uses a
// neutral placeholder rather than the "!" of a real error, and names the retry time, so a throttle
// is never presented as something the user has to fix by logging in.
func applyTransient(message string, retryIn time.Duration) {
	// ".." not "··": the icon is drawn with basicfont.Face7x13, which has no MIDDLE DOT glyph and
	// would render tofu boxes. The menu text below is identical to the other ports.
	systray.SetIcon(iconBytes("..", colorError))
	retry := formatRetryIn(retryIn)
	systray.SetTooltip("Pulse\n⚠ " + message + "\n" + retry)
	lines := []string{message, retry}
	for i, it := range detailItems {
		if i < len(lines) {
			it.SetTitle(lines[i])
			it.Show()
		} else {
			it.Hide()
		}
	}
}
