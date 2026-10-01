package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
)

// claudeHomeDir: where one Claude Code installation keeps its state. Custom is true when the
// directory came from CLAUDE_CONFIG_DIR, which changes the keychain service name and the global
// config path.
type claudeHomeDir struct {
	ConfigDir string
	Custom    bool
}

// claudeHome: CLAUDE_CONFIG_DIR (an empty value counts as unset, as in Claude Code), else ~/.claude.
func claudeHome() claudeHomeDir {
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		return claudeHomeDir{ConfigDir: dir, Custom: true}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = ""
	}
	return claudeHomeDir{ConfigDir: filepath.Join(home, ".claude")}
}

// keychainServiceName: the keychain service Claude Code stores this home's OAuth credentials
// under — "Claude Code-credentials", plus "-<first 8 hex of sha256(configDir)>" for a
// CLAUDE_CONFIG_DIR home. Claude Code hashes the raw string (no tilde expansion, no realpath, a
// trailing slash changes the hash). It also NFC-normalizes first; that is skipped here to avoid a
// golang.org/x/text dependency, which only matters for non-ASCII paths. Pure.
func keychainServiceName(h claudeHomeDir) string {
	const base = "Claude Code-credentials"
	if !h.Custom {
		return base
	}
	sum := sha256.Sum256([]byte(h.ConfigDir))
	return base + "-" + hex.EncodeToString(sum[:])[:8]
}

func (h claudeHomeDir) credentialsPath() string {
	return filepath.Join(h.ConfigDir, ".credentials.json")
}

func (h claudeHomeDir) projectsDir() string { return filepath.Join(h.ConfigDir, "projects") }

// globalConfigCandidates: Claude Code's global config (holds oauthAccount), in the order Claude
// Code consults them: a legacy <configDir>/.config.json wins when it exists, else .claude.json in
// CLAUDE_CONFIG_DIR (custom home) or the user's home directory.
func (h claudeHomeDir) globalConfigCandidates() []string {
	dir := h.ConfigDir
	if !h.Custom {
		if home, err := os.UserHomeDir(); err == nil {
			dir = home
		}
	}
	return []string{filepath.Join(h.ConfigDir, ".config.json"), filepath.Join(dir, ".claude.json")}
}
