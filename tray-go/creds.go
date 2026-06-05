package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

var errNoCreds = errors.New("Claude Code 자격 증명을 찾지 못했습니다. 로그인 상태를 확인하세요.")

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

// readAccessToken: ~/.claude/.credentials.json 우선(Windows/Linux/macOS), 없으면 macOS 키체인.
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
