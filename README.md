# Claude Code Usage

Always-visible display of Claude Code's **5-hour / weekly usage** (plus the current model).
It reads the same data the `/usage` command uses, and offers the same core logic across three platform UIs.

## Implementations

| Folder | Surface | Stack | Notes |
| --- | --- | --- | --- |
| [`src/`](src/) | VSCode status bar | TypeScript + esbuild | Canonical core (documented below) |
| [`tray-go/`](tray-go/) | Windows/macOS tray (lightweight) | Go (`systray`) | Single ~7MB exe, no dependencies |
| [`menubar/`](menubar/) | macOS menu bar | Swift / AppKit | Menu-bar only (no Dock icon) |

`src/` is the reference implementation; `tray-go` and `menubar` are hand-ports of the same design in each language.
For building/running the tray and menu-bar apps, see the README in each folder. Below are instructions for the **VSCode extension**.

---

## VSCode Extension

Always shows Claude Code's 5-hour / weekly usage in the VSCode status bar.

![status bar example](https://img.shields.io/badge/status%20bar-5h%2042%25%20%C2%B7%20wk%208%25-blue)

## Features

- Shows usage + current model in the status bar as `5h 42% · wk 8% · Opus 4.8`
- The current model is read from the most recent session transcript (`~/.claude/projects/**/*.jsonl`)
- Hover for a detailed tooltip: time remaining until each window resets, weekly Opus/Sonnet split, current model ID, and last update time
- Status-bar color warns (yellow) / alerts (red) when usage is high
- Refresh interval and warn/alert thresholds are configurable in settings
- Click the status bar to refresh immediately

## How it works

It calls the same endpoint the `/usage` command uses
(`https://api.anthropic.com/api/oauth/usage`). No separate login is
required — if you are signed in to Claude Code, it works right away.

Where the auth token is read from (cross-OS, auto-detected):

- **Windows / Linux**: `~/.claude/.credentials.json`
- **macOS**: uses the file above if present, otherwise the keychain item `Claude Code-credentials`

## Settings

| Setting | Default | Description |
|---|---|---|
| `claudeUsage.refreshInterval` | `300` | Refresh interval in seconds (minimum 10) |
| `claudeUsage.warnThreshold` | `0.8` | Usage threshold for the warning color (0–1) |
| `claudeUsage.alertThreshold` | `0.95` | Usage threshold for the alert color (0–1) |

## Development / Build

```bash
npm install
npm test          # unit tests
npm run package   # build dist/extension.js bundle
npx @vscode/vsce package   # build .vsix
```

Debugging: open this folder in VSCode and press `F5` (Extension Development Host).

Install: `code --install-extension claude-usage-0.1.0.vsix`
