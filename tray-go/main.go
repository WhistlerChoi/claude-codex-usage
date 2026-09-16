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
	detailItems             []*systray.MenuItem
	mAbout, mRefresh, mQuit *systray.MenuItem
	lastUsage               *usageResp
	lastModel               *currentModel
	lastCodexUsage          *codexUsage
	lastCodexModel          *currentModel
	lastSuccessAt           time.Time
	lastCodexSuccessAt      time.Time
	consecutiveFailures     int
	manualRefresh           = make(chan struct{}, 1)
)

const (
	colorNormal = "#2D7DF6"
	colorWarn   = "#E8A317"
	colorAlert  = "#D64545"
	colorError  = "#777777"
)

// systray cannot add items later. This covers both providers plus up to four Claude scoped limits.
const maxDetailItems = 18

func main() {
	// --render [out.png]: save the icon image as a PNG and exit (for verification)
	if len(os.Args) > 1 && os.Args[1] == "--render" {
		out := "/tmp/icon.png"
		if len(os.Args) > 2 {
			out = os.Args[2]
		}
		_ = os.WriteFile(out, renderIconPNG(colorNormal), 0o644)
		fmt.Println("wrote", out)
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "--render-ico" {
		out := "installer/Pulse.ico"
		if len(os.Args) > 2 {
			out = os.Args[2]
		}
		_ = os.WriteFile(out, pngToICO(renderAppIconPNG()), 0o644)
		fmt.Println("wrote", out)
		return
	}
	systray.Run(onReady, func() {})
}

func onReady() {
	systray.SetTitle("")
	systray.SetTooltip("Pulse Loading...")

	for i := 0; i < maxDetailItems; i++ {
		it := systray.AddMenuItem("", "")
		it.Hide()
		detailItems = append(detailItems, it)
	}
	systray.AddSeparator()
	mAbout = systray.AddMenuItem("About", "About Pulse")
	mRefresh = systray.AddMenuItem("Refresh Now", "")
	mQuit = systray.AddMenuItem("Quit", "")

	go pollLoop()
	go func() {
		for {
			select {
			case <-mAbout.ClickedCh:
				showAbout()
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
	interval := pollIntervalSeconds()
	intervalDur := time.Duration(interval) * time.Second

	delay := refresh(intervalDur)
	timer := time.NewTimer(delay)
	defer timer.Stop()
	for {
		select {
		case <-timer.C:
		case <-manualRefresh:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
		}
		timer.Reset(refresh(intervalDur))
	}
}

func refresh(interval time.Duration) time.Duration {
	type claudeResult struct {
		usage *usageResp
		err   error
	}
	type codexFetchResult struct {
		usage *codexUsage
		err   error
	}
	claudeCh := make(chan claudeResult, 1)
	codexCh := make(chan codexFetchResult, 1)
	go func() { u, err := fetchUsage(); claudeCh <- claudeResult{u, err} }()
	go func() { u, err := fetchCodexUsage(); codexCh <- codexFetchResult{u, err} }()
	claude := <-claudeCh
	codexFetch := <-codexCh
	usage, err := claude.usage, claude.err
	codex, codexErr := codexFetch.usage, codexFetch.err
	now := time.Now()
	if err == nil {
		lastUsage, lastModel, lastSuccessAt = usage, readModel(readCurrentModel), now
	}
	if codexErr == nil {
		lastCodexUsage, lastCodexModel, lastCodexSuccessAt = codex, readModel(readCurrentCodexModel), now
	}

	transient := isTransient(err) || isTransient(codexErr)
	var delay = interval
	if transient {
		consecutiveFailures++
		delay = nextRetryDelay(consecutiveFailures, interval, maxRetryAfter(err, codexErr), rand.Float64())
	} else {
		consecutiveFailures = 0
	}
	applyCombined(err, codexErr, interval, delay)
	return delay
}

func readModel(read func() (*currentModel, error)) *currentModel { model, _ := read(); return model }

func isTransient(err error) bool {
	var target *transientError
	return errors.As(err, &target) || (err != nil && !errors.Is(err, errAuth) && !errors.Is(err, errNoCreds) && !errors.Is(err, errCodexAuth) && !errors.Is(err, errNoCodexCreds))
}

func maxRetryAfter(errs ...error) time.Duration {
	var result time.Duration
	for _, err := range errs {
		if d := retryAfterFrom(err); d > result {
			result = d
		}
	}
	return result
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

func bgForCodex(u *codexUsage) string {
	peak := u.FiveHour.UsedPercent
	if u.Weekly != nil && u.Weekly.UsedPercent > peak {
		peak = u.Weekly.UsedPercent
	}
	switch {
	case peak >= 95:
		return colorAlert
	case peak >= 80:
		return colorWarn
	default:
		return colorNormal
	}
}

func pollIntervalSeconds() int {
	if v := os.Getenv("CLAUDE_USAGE_INTERVAL"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 10 {
			return n
		}
	}
	return 300
}

func detailLines(u *usageResp, model *currentModel) []string {
	now := time.Now()
	lines := []string{
		usageRow("5h", pct(u.FiveHour.Utilization), formatResetIn(u.FiveHour.ResetsAt, now)),
		usageRow("Weekly", pct(u.SevenDay.Utilization), formatResetIn(u.SevenDay.ResetsAt, now)),
	}
	legacyModels := map[string]bool{}
	if u.SevenDayOpus != nil {
		lines = append(lines, usageRow("Weekly Opus", pct(u.SevenDayOpus.Utilization), formatResetIn(u.SevenDayOpus.ResetsAt, now)))
		legacyModels["Opus"] = true
	}
	if u.SevenDaySonnet != nil {
		lines = append(lines, usageRow("Weekly Sonnet", pct(u.SevenDaySonnet.Utilization), formatResetIn(u.SevenDaySonnet.ResetsAt, now)))
		legacyModels["Sonnet"] = true
	}
	for _, s := range u.WeeklyScoped {
		if legacyModels[s.Model] { // legacy field already rendered this model
			continue
		}
		lines = append(lines, usageRow("Weekly "+s.Model, pct(s.Window.Utilization), formatResetIn(s.Window.ResetsAt, now)))
	}
	if model != nil {
		lines = append(lines, fmt.Sprintf("Current model: %s (%s)", model.Name, model.ID))
	}
	return lines
}

func codexDetailLines(u *codexUsage, model *currentModel) []string {
	now := time.Now()
	lines := []string{usageRow("5h", u.FiveHour.UsedPercent, formatResetIn(u.FiveHour.ResetsAt, now))}
	if u.Weekly != nil {
		lines = append(lines, usageRow("Weekly", u.Weekly.UsedPercent, formatResetIn(u.Weekly.ResetsAt, now)))
	}
	if model != nil {
		lines = append(lines, fmt.Sprintf("Current model: %s (%s)", model.Name, model.ID))
	}
	return lines
}

// compactTooltip keeps the Windows shell tooltip short enough that both
// providers remain visible. The context menu still contains the full details.
func compactTooltip(claudeErr, codexErr error) string {
	parts := []string{}
	if lastUsage != nil {
		parts = append(parts, fmt.Sprintf("Claude 5h %d%% / wk %d%%", pct(lastUsage.FiveHour.Utilization), pct(lastUsage.SevenDay.Utilization)))
	} else if claudeErr != nil {
		parts = append(parts, "Claude: "+claudeErr.Error())
	}
	if lastCodexUsage != nil {
		codex := fmt.Sprintf("Codex 5h %d%%", lastCodexUsage.FiveHour.UsedPercent)
		if lastCodexUsage.Weekly != nil {
			codex += fmt.Sprintf(" / wk %d%%", lastCodexUsage.Weekly.UsedPercent)
		}
		parts = append(parts, codex)
	} else if codexErr != nil {
		parts = append(parts, "Codex: "+codexErr.Error())
	}
	return strings.Join(parts, "\n")
}

func applyUsage(u *usageResp, model *currentModel, stale bool) {
	systray.SetIcon(iconBytes(bgFor(u)))

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

// applyCombined renders the two independent providers together. A failure in one provider never
// hides the last successful value of the other one.
func applyCombined(claudeErr, codexErr error, interval, retryIn time.Duration) {
	claudeStale := claudeErr != nil && lastUsage != nil && shouldShowStale(time.Since(lastSuccessAt), interval)
	codexStale := codexErr != nil && lastCodexUsage != nil && shouldShowStale(time.Since(lastCodexSuccessAt), interval)
	lines := []string{}
	if lastUsage != nil {
		lines = append(lines, "Claude")
		if claudeStale {
			lines = append(lines, "⚠ Refresh failed — showing last value")
		}
		lines = append(lines, detailLines(lastUsage, lastModel)...)
	} else if claudeErr != nil {
		lines = append(lines, "Claude: "+claudeErr.Error())
	}
	if lastCodexUsage != nil {
		lines = append(lines, "Codex")
		if codexStale {
			lines = append(lines, "⚠ Refresh failed — showing last value")
		}
		lines = append(lines, codexDetailLines(lastCodexUsage, lastCodexModel)...)
	} else if codexErr != nil {
		lines = append(lines, "Codex: "+codexErr.Error())
	}
	if isTransient(claudeErr) || isTransient(codexErr) {
		lines = append(lines, formatRetryIn(retryIn))
	}

	if lastUsage != nil {
		systray.SetIcon(iconBytes(bgFor(lastUsage)))
	} else if lastCodexUsage != nil {
		systray.SetIcon(iconBytes(bgForCodex(lastCodexUsage)))
	} else if isTransient(claudeErr) || isTransient(codexErr) {
		systray.SetIcon(iconBytes(colorError))
	} else {
		systray.SetIcon(iconBytes(colorError))
	}
	systray.SetTooltip(compactTooltip(claudeErr, codexErr))
	for i, it := range detailItems {
		if i < len(lines) {
			it.SetTitle(lines[i])
			it.Show()
		} else {
			it.Hide()
		}
	}
}

func applyError(message string) {
	systray.SetIcon(iconBytes(colorError))
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
// neutral "··" rather than the "!" of a real error, and names the retry time, so a throttle is
// never presented as something the user has to fix.
func applyTransient(message string, retryIn time.Duration) {
	systray.SetIcon(iconBytes(colorError))
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
