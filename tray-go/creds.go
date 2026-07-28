package main

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

var errNoCreds = errors.New("could not read credentials")

// extractCreds: the accessToken plus its expiry (ms epoch, 0 when absent). Empty token = unusable.
func extractCreds(b []byte) (string, float64) {
	var c struct {
		ClaudeAiOauth struct {
			AccessToken string  `json:"accessToken"`
			ExpiresAt   float64 `json:"expiresAt"`
		} `json:"claudeAiOauth"`
		AccessToken string  `json:"accessToken"`
		ExpiresAt   float64 `json:"expiresAt"`
	}
	if json.Unmarshal(b, &c) == nil {
		if c.ClaudeAiOauth.AccessToken != "" {
			return c.ClaudeAiOauth.AccessToken, c.ClaudeAiOauth.ExpiresAt
		}
		if c.AccessToken != "" {
			return c.AccessToken, c.ExpiresAt
		}
	}
	return "", 0
}

// pickFreshestToken: the live token out of every store that has one ("freshest wins").
//
// Both stores must be consulted because Claude Code moved to the keychain on macOS and can leave a
// long-dead ~/.claude/.credentials.json behind: preferring the file unconditionally means every poll
// presents an expired token, which the API eventually throttles (HTTP 429) instead of rejecting
// cleanly. Candidates are ranked by expiresAt; ties go to the LAST candidate, so callers pass the
// keychain last. Pure (no I/O) so it is testable.
func pickFreshestToken(candidates [][]byte) string {
	best := ""
	bestRank := math.Inf(-1)
	for _, b := range candidates {
		token, expiresAt := extractCreds(b)
		if token == "" {
			continue
		}
		if best == "" || expiresAt >= bestRank {
			best, bestRank = token, expiresAt
		}
	}
	return best
}

// readAccessToken: read ~/.claude/.credentials.json and (on macOS) the keychain, then use whichever
// token is fresher. See pickFreshestToken for why the file cannot simply win.
func readAccessToken() (string, error) {
	var candidates [][]byte
	if home, err := os.UserHomeDir(); err == nil {
		path := filepath.Join(home, ".claude", ".credentials.json")
		if b, e := os.ReadFile(path); e == nil {
			candidates = append(candidates, b)
		}
	}
	// Keychain last: it wins ties, matching where Claude Code stores credentials on macOS.
	if runtime.GOOS == "darwin" {
		if out, e := exec.Command("security", "find-generic-password", "-s", "Claude Code-credentials", "-w").Output(); e == nil {
			candidates = append(candidates, out)
		}
	}
	if t := pickFreshestToken(candidates); t != "" {
		return t, nil
	}
	return "", errNoCreds
}
