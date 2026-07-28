package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

var errNoCreds = errors.New("Could not read credentials. Log in with Claude Code.")

var mdatRe = regexp.MustCompile(`"mdat"<timedate>=(.+)`)

// extractKeychainMdat captures the raw "mdat" (modification date) line from
// `security find-generic-password` attribute output. "" if absent.
func extractKeychainMdat(output string) string {
	if m := mdatRe.FindStringSubmatch(output); m != nil {
		return strings.TrimSpace(m[1])
	}
	return ""
}

func credentialsFilePath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".claude", ".credentials.json")
}

// combineFingerprints joins the per-store fingerprints into one. Every present store contributes,
// so a rotation in EITHER store registers as a change; "" only when no credentials exist anywhere.
//
// Combining is what makes "freshest wins" hold over time. A file-first fingerprint is stuck on a
// dead file's mtime: it never changes, so the cache keeps serving the expired token and the keychain
// rotation is never noticed. Pure (no I/O) so it is testable.
func combineFingerprints(parts []string) string {
	var present []string
	for _, p := range parts {
		if p != "" {
			present = append(present, p)
		}
	}
	return strings.Join(present, "|")
}

// readFingerprint returns a prompt-free change fingerprint of the credential
// store: the file's mtime and the keychain item's mdat attribute, combined
// (attribute-only read, never triggers an ACL prompt). "" means no credentials
// are present anywhere. The source prefixes make a file<->keychain transition
// register as a change.
func readFingerprint() string {
	var parts []string
	if path := credentialsFilePath(); path != "" {
		if fi, err := os.Stat(path); err == nil {
			parts = append(parts, fmt.Sprintf("file:%d", fi.ModTime().UnixNano()))
		}
	}
	if runtime.GOOS == "darwin" {
		// No -w: attributes only.
		out, err := exec.Command("security", "find-generic-password", "-s", "Claude Code-credentials").Output()
		if err == nil {
			if mdat := extractKeychainMdat(string(out)); mdat != "" {
				parts = append(parts, "keychain:"+mdat)
			}
		}
	}
	return combineFingerprints(parts)
}

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
// cleanly — and no amount of logging in helps, because Claude Code writes the keychain while we keep
// reading the file. Candidates are ranked by expiresAt; ties go to the LAST candidate, so callers
// pass the keychain last. Pure (no I/O) so it is testable.
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
	if path := credentialsFilePath(); path != "" {
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
