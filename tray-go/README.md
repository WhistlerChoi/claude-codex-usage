# Pulse — Tray App (Go, lightweight)

A **native Go** app that shows Claude Code and Codex usage in the system tray.
**Single exe ~7MB**, no runtime dependencies.

## What it shows

- **Icon**: a gauge glyph on a colored rounded square — blue (normal) / orange (80%+) / red (95%+). The color follows Claude's usage, or Codex's when Claude's is unavailable. The percentages themselves are in the tooltip.
- **Hover tooltip / right-click menu**: separate Claude and Codex sections with 5-hour, weekly, per-model Claude limits, current model, today's token usage (`Tokens today: …`; hover it in the right-click menu for the 7-day / 30-day totals and their change against the prior window), and time until reset. In the menu the reset times sit in a tab-aligned right column, so they line up across the Claude and Codex sections.
- **Right-click menu**: details + `About` / `Refresh Now` / `Quit`

## How it works

- Usage: `https://api.anthropic.com/api/oauth/usage`
- Token: `~/.claude/.credentials.json` (Windows: `%USERPROFILE%\.claude\.credentials.json`); on macOS, fall back to the keychain if absent
- Current model: the last `message.model` from the most recent transcript among `~/.claude/projects/**/*.jsonl`
- Tokens: `message.usage` from the `~/.claude/projects/**/*.jsonl` transcripts (including `subagents/`), one count per `message.id`, and for Codex the per-response usage records in `CODEX_HOME/sessions/**/*.jsonl`, bucketed by local day. Daily totals are kept in `~/.pulse/token-history.json` (override the directory with `PULSE_HOME`; shared with the other Pulse apps) so 7-day / 30-day figures survive Claude Code's 30-day transcript cleanup; `~/.pulse/cache/` holds a per-file parse cache so a poll re-reads only changed files. Everything is computed locally; nothing from the logs is transmitted. `Pulse.exe --tokens` updates the ledger, prints the rows and exits.
- Codex usage: `https://chatgpt.com/backend-api/wham/usage`, using the access token in `CODEX_HOME/auth.json` (or `~/.codex/auth.json`). Its current model comes from the newest `CODEX_HOME/sessions/**/*.jsonl` rollout log and is named through `models_cache.json` when available.

## Build

```bash
# Cross-compile a Windows exe on macOS/Linux (no Wine needed)
./build-win.sh                 # → Pulse.exe (~7MB)

# Build from Windows PowerShell
.\build-win.ps1                # → Pulse.exe (~7MB)

# Or directly:
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go build -ldflags "-H windowsgui -s -w" -o Pulse.exe .

# Run on the current OS (macOS/Linux testing)
go run .

# Preview the icon as a PNG only
go run . --render /tmp/icon.png && open /tmp/icon.png
```

Copy the generated `Pulse.exe` to Windows and double-click it to show it in the tray.

## MSI installer

Install WiX once (requires the .NET SDK):

```powershell
dotnet tool install --global wix
```

WiX 7 requires accepting its EULA before use. Review it, then accept it once on the build machine:

```powershell
wix eula accept wix7
```

Build the EXE and installer together:

```powershell
.\build-msi.ps1                 # → Pulse-1.5.0-x64.msi
```

The installer adds a Start menu shortcut and, after a new installation, shows a checked
`Launch Pulse` option on the completion screen. Click `Finish` to start the tray app.

For a release version, pass the version once; it is applied to the EXE, MSI metadata, and output name:

```powershell
.\build-msi.ps1 -Version 1.2.3  # → Pulse-1.2.3-x64.msi
```

## Configuration

- Refresh interval: env var `CLAUDE_USAGE_INTERVAL` (seconds, default 300, min 10)

## Requirements

Build: Go 1.23+. Runtime: none (single static binary). The Windows build does not need cgo.
