# Pulse — Tray App (Go, lightweight)

A **native Go** app that shows Claude Code usage in the system tray.
**Single exe ~7MB**, no runtime dependencies.

## What it shows

- **Icon**: a colored badge with the 5-hour usage number (`42`) — blue (normal) / orange (80%+) / red (95%+)
- **Hover tooltip**: 5-hour, weekly, Opus/Sonnet, current model, time until reset
- **Right-click menu**: details + `Refresh Now` / `Quit`

## How it works

- Usage: `https://api.anthropic.com/api/oauth/usage`
- Token: `~/.claude/.credentials.json` (Windows: `%USERPROFILE%\.claude\.credentials.json`); on macOS, fall back to the keychain if absent
- Current model: the last `message.model` from the most recent transcript among `~/.claude/projects/**/*.jsonl`

## Build

```bash
# Cross-compile a Windows exe on macOS/Linux (no Wine needed)
./build-win.sh                 # → Pulse.exe (~7MB)

# Or directly:
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go build -ldflags "-H windowsgui -s -w" -o Pulse.exe .

# Run on the current OS (macOS/Linux testing)
go run .

# Preview the icon as a PNG only
go run . --render /tmp/icon.png && open /tmp/icon.png
```

Copy the generated `Pulse.exe` to Windows and double-click it to show it in the tray.

## Configuration

- Refresh interval: env var `CLAUDE_USAGE_INTERVAL` (seconds, default 300, min 10)

## Requirements

Build: Go 1.23+. Runtime: none (single static binary). The Windows build does not need cgo.
