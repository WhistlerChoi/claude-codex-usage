package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

var errCodexAuth = errors.New("Codex authentication expired. Log in again.")
var errNoCodexCreds = errors.New("Could not read Codex credentials. Log in with Codex.")

type codexWindow struct {
	UsedPercent int
	ResetsAt    *string
}

type codexUsage struct {
	FiveHour codexWindow
	Weekly   *codexWindow
}

func codexHome() string {
	if home := os.Getenv("CODEX_HOME"); home != "" {
		return home
	}
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".codex")
	}
	return ".codex"
}

func readCodexCredentials() (token, accountID string, err error) {
	b, err := os.ReadFile(filepath.Join(codexHome(), "auth.json"))
	if err != nil {
		return "", "", errNoCodexCreds
	}
	var auth struct {
		Tokens struct {
			AccessToken string `json:"access_token"`
			AccountID   string `json:"account_id"`
		} `json:"tokens"`
	}
	if json.Unmarshal(b, &auth) != nil || auth.Tokens.AccessToken == "" {
		return "", "", errNoCodexCreds
	}
	return auth.Tokens.AccessToken, auth.Tokens.AccountID, nil
}

func parseCodexUsage(data []byte, now time.Time) (*codexUsage, error) {
	var response struct {
		RateLimit struct {
			PrimaryWindow   *codexUsageWindow `json:"primary_window"`
			SecondaryWindow *codexUsageWindow `json:"secondary_window"`
		} `json:"rate_limit"`
	}
	if json.Unmarshal(data, &response) != nil {
		return nil, errors.New("malformed Codex usage response")
	}
	primary := response.RateLimit.PrimaryWindow.toWindow(now)
	if primary == nil {
		return nil, errors.New("malformed Codex usage response")
	}
	return &codexUsage{FiveHour: *primary, Weekly: response.RateLimit.SecondaryWindow.toWindow(now)}, nil
}

type codexUsageWindow struct {
	UsedPercent       *float64 `json:"used_percent"`
	ResetAfterSeconds *float64 `json:"reset_after_seconds"`
	ResetAt           *float64 `json:"reset_at"`
}

func (w *codexUsageWindow) toWindow(now time.Time) *codexWindow {
	if w == nil || w.UsedPercent == nil {
		return nil
	}
	p := pct(*w.UsedPercent)
	if p < 0 {
		p = 0
	}
	if p > 100 {
		p = 100
	}
	var reset *string
	if w.ResetAt != nil {
		s := time.Unix(int64(*w.ResetAt), 0).UTC().Format(time.RFC3339)
		reset = &s
	} else if w.ResetAfterSeconds != nil {
		s := now.Add(time.Duration(*w.ResetAfterSeconds * float64(time.Second))).UTC().Format(time.RFC3339)
		reset = &s
	}
	return &codexWindow{UsedPercent: p, ResetsAt: reset}
}

func fetchCodexUsage() (*codexUsage, error) {
	token, accountID, err := readCodexCredentials()
	if err != nil {
		return nil, err
	}
	req, _ := http.NewRequest("GET", "https://chatgpt.com/backend-api/wham/usage", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	if accountID != "" {
		req.Header.Set("ChatGPT-Account-Id", accountID)
	}
	req.Header.Set("User-Agent", "Pulse/1.0")
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return nil, errCodexAuth
	}
	if resp.StatusCode == 429 {
		return nil, &transientError{msg: "Codex usage API rate limited", retryAfter: parseRetryAfter(resp.Header.Get("Retry-After"))}
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, &transientError{msg: fmt.Sprintf("Codex usage API error: HTTP %d", resp.StatusCode)}
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	return parseCodexUsage(b, time.Now())
}
