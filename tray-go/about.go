package main

import "fmt"

var appVersion = "1.4.2"

func aboutMessage() string {
	return fmt.Sprintf("Pulse\n\nVersion %s\n\nShows Claude Code and Codex usage\nin your system tray.\n\nData: ~/.claude · /usage API   ·   Poll interval: %ds\n\n© 2026 AGLE\nhttps://agle.xyz\n\nNot affiliated with or endorsed by Anthropic.\nClaude is a trademark of Anthropic, PBC.", appVersion, pollIntervalSeconds())
}
