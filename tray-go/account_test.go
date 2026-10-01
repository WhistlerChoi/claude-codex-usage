package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestKeychainServiceName(t *testing.T) {
	if got := keychainServiceName(claudeHomeDir{ConfigDir: "/Users/x/.claude"}); got != "Claude Code-credentials" {
		t.Errorf("default home: got %q", got)
	}
	// Vectors match Claude Code's own naming (and src/claudeHome.test.ts); a trailing slash is a different item.
	if got := keychainServiceName(claudeHomeDir{"/Users/test/.claude-work", true}); got != "Claude Code-credentials-03abf0ee" {
		t.Errorf("custom home: got %q", got)
	}
	if got := keychainServiceName(claudeHomeDir{"/Users/test/.claude-work/", true}); got != "Claude Code-credentials-8bd6f0f5" {
		t.Errorf("trailing slash: got %q", got)
	}
}

func TestClaudeHomeEnv(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "/x/.claude-work")
	h := claudeHome()
	if h.ConfigDir != "/x/.claude-work" || !h.Custom {
		t.Errorf("env home: %+v", h)
	}
	if got := h.globalConfigCandidates(); got[0] != "/x/.claude-work/.config.json" || got[1] != "/x/.claude-work/.claude.json" {
		t.Errorf("candidates: %v", got)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	if h := claudeHome(); h.Custom || filepath.Base(h.ConfigDir) != ".claude" {
		t.Errorf("empty env should mean ~/.claude: %+v", h)
	}
}

const sampleConfig = `{"numStartups":3,"oauthAccount":{"emailAddress":"a@example.com","displayName":"a","organizationName":"Acme","organizationType":"claude_team","accountUuid":"acc-1","organizationUuid":"org-1"}}`

func TestParseAccountInfo(t *testing.T) {
	got := parseAccountInfo([]byte(sampleConfig))
	want := accountInfo{"a@example.com", "a", "Acme", "claude_team", "acc-1", "org-1"}
	if got == nil || *got != want {
		t.Errorf("got %+v", got)
	}
	for _, raw := range []string{`{"numStartups":1}`, `{not json`, `{"oauthAccount":{"organizationName":"x"}}`} {
		if got := parseAccountInfo([]byte(raw)); got != nil {
			t.Errorf("%s: expected nil, got %+v", raw, got)
		}
	}
}

func TestReadAccountInfoCustomHome(t *testing.T) {
	dir := t.TempDir()
	h := claudeHomeDir{dir, true}
	if got := readAccountInfo(h); got != nil {
		t.Errorf("no file: got %+v", got)
	}
	os.WriteFile(filepath.Join(dir, ".claude.json"), []byte(sampleConfig), 0o600)
	if got := readAccountInfo(h); got == nil || got.Email != "a@example.com" {
		t.Errorf(".claude.json: got %+v", got)
	}
	os.WriteFile(filepath.Join(dir, ".config.json"), []byte(`{"oauthAccount":{"emailAddress":"legacy@example.com"}}`), 0o600)
	if got := readAccountInfo(h); got == nil || got.Email != "legacy@example.com" {
		t.Errorf("legacy .config.json should win: got %+v", got)
	}
}

func TestPlanLabel(t *testing.T) {
	cases := []struct{ sub, tier, want string }{
		{"max", "default_claude_max_5x", "Max 5x"},
		{"max", "default_claude_max_20x", "Max 20x"},
		{"max", "", "Max"},
		{"pro", "default_claude_pro", "Pro"},
		{"team", "default_claude_max_5x", "Team (Max 5x)"},
		{"enterprise", "", "Enterprise"},
		{"free", "", "Free"},
		{"", "default_claude_max_20x", "Max 20x"},
		{"", "", ""},
	}
	for _, c := range cases {
		if got := planLabel(c.sub, c.tier); got != c.want {
			t.Errorf("planLabel(%q, %q) = %q, want %q", c.sub, c.tier, got, c.want)
		}
	}
}

func TestAccountLine(t *testing.T) {
	team := &accountInfo{Email: "a@example.com", OrgName: "Acme", OrgType: "claude_team"}
	if got := accountLine(team, "Team (Max 5x)"); got != "a@example.com · Team (Max 5x) · Acme" {
		t.Errorf("team: %q", got)
	}
	personal := &accountInfo{Email: "a@example.com", OrgName: "a@example.com's Organization", OrgType: "claude_max"}
	if got := accountLine(personal, "Max 20x"); got != "a@example.com · Max 20x" {
		t.Errorf("personal: %q", got)
	}
	if got := accountLine(nil, "Pro"); got != "Pro" {
		t.Errorf("plan only: %q", got)
	}
	if got := accountLine(nil, ""); got != "" {
		t.Errorf("nothing: %q", got)
	}
}
