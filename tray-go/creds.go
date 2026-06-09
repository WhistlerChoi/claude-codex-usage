package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

var errNoCreds = errors.New("could not read credentials")

func extractToken(b []byte) string {
	var c struct {
		ClaudeAiOauth struct {
			AccessToken string `json:"accessToken"`
		} `json:"claudeAiOauth"`
		AccessToken string `json:"accessToken"`
	}
	if json.Unmarshal(b, &c) == nil {
		if c.ClaudeAiOauth.AccessToken != "" {
			return c.ClaudeAiOauth.AccessToken
		}
		if c.AccessToken != "" {
			return c.AccessToken
		}
	}
	return ""
}

// readAccessToken: prefer ~/.claude/.credentials.json (Windows/Linux/macOS); on macOS fall back to the keychain if absent.
func readAccessToken() (string, error) {
	if home, err := os.UserHomeDir(); err == nil {
		path := filepath.Join(home, ".claude", ".credentials.json")
		if b, e := os.ReadFile(path); e == nil {
			if t := extractToken(b); t != "" {
				return t, nil
			}
		}
	}
	if runtime.GOOS == "darwin" {
		out, e := exec.Command("security", "find-generic-password", "-s", "Claude Code-credentials", "-w").Output()
		if e == nil {
			if t := extractToken(out); t != "" {
				return t, nil
			}
		}
	}
	return "", errNoCreds
}
