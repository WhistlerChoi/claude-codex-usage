package main

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"os/exec"
	"runtime"
)

var errNoCreds = errors.New("could not read credentials")

// parsedCreds: the OAuth fields we care about, unwrapping the optional claudeAiOauth wrapper.
type parsedCreds struct {
	Token            string
	ExpiresAt        float64 // ms epoch, 0 when absent
	SubscriptionType string  // "pro" | "max" | "team" | "enterprise", empty in older blobs
	RateLimitTier    string  // e.g. "default_claude_max_5x"
}

type oauthFields struct {
	AccessToken      string  `json:"accessToken"`
	ExpiresAt        float64 `json:"expiresAt"`
	SubscriptionType string  `json:"subscriptionType"`
	RateLimitTier    string  `json:"rateLimitTier"`
}

// parseCreds: one credential store's JSON. Empty Token = unusable.
func parseCreds(b []byte) parsedCreds {
	var c struct {
		ClaudeAiOauth oauthFields `json:"claudeAiOauth"`
		oauthFields
	}
	if json.Unmarshal(b, &c) == nil {
		for _, o := range []oauthFields{c.ClaudeAiOauth, c.oauthFields} {
			if o.AccessToken != "" {
				return parsedCreds{o.AccessToken, o.ExpiresAt, o.SubscriptionType, o.RateLimitTier}
			}
		}
	}
	return parsedCreds{}
}

// extractCreds: the accessToken plus its expiry (ms epoch, 0 when absent). Empty token = unusable.
func extractCreds(b []byte) (string, float64) {
	c := parseCreds(b)
	return c.Token, c.ExpiresAt
}

// pickFreshest: the live credentials out of every store that has them ("freshest wins").
//
// Both stores must be consulted because Claude Code moved to the keychain on macOS and can leave a
// long-dead ~/.claude/.credentials.json behind: preferring the file unconditionally means every poll
// presents an expired token, which the API eventually throttles (HTTP 429) instead of rejecting
// cleanly. Candidates are ranked by expiresAt; ties go to the LAST candidate, so callers pass the
// keychain last. Pure (no I/O) so it is testable.
func pickFreshest(candidates [][]byte) *parsedCreds {
	var best *parsedCreds
	bestRank := math.Inf(-1)
	for _, b := range candidates {
		c := parseCreds(b)
		if c.Token == "" {
			continue
		}
		if best == nil || c.ExpiresAt >= bestRank {
			best, bestRank = &c, c.ExpiresAt
		}
	}
	return best
}

// pickFreshestToken: pickFreshest, reduced to the token.
func pickFreshestToken(candidates [][]byte) string {
	if c := pickFreshest(candidates); c != nil {
		return c.Token
	}
	return ""
}

// readCredentials: read <configDir>/.credentials.json and (on macOS) the keychain, then use
// whichever is fresher. See pickFreshest for why the file cannot simply win.
func readCredentials(h claudeHomeDir) (*parsedCreds, error) {
	var candidates [][]byte
	if b, e := os.ReadFile(h.credentialsPath()); e == nil {
		candidates = append(candidates, b)
	}
	// Keychain last: it wins ties, matching where Claude Code stores credentials on macOS.
	if runtime.GOOS == "darwin" {
		if out, e := exec.Command("security", "find-generic-password", "-s", keychainServiceName(h), "-w").Output(); e == nil {
			candidates = append(candidates, out)
		}
	}
	if c := pickFreshest(candidates); c != nil {
		return c, nil
	}
	return nil, errNoCreds
}
