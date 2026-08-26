# Pulse

Keep Claude Code's **5-hour and weekly usage** visible without interrupting your workflow.
Pulse also detects the current Claude model, and the macOS menu-bar app displays **Codex usage** alongside Claude Code.
Claude usage comes from the same source as Claude Code's `/usage` command, with integrations for VSCode, macOS, and Windows.

<img width="430" height="317" alt="Screenshot 2026-08-26 at 13 43 29" src="https://github.com/user-attachments/assets/68538655-f369-4308-8604-6e92ac848f64" />

## Implementations

| Folder | Surface | Stack | Notes |
| --- | --- | --- | --- |
| [`src/`](src/) | VSCode status bar | TypeScript + esbuild | Canonical core (documented below) |
| [`tray-go/`](tray-go/) | Windows/macOS tray (lightweight) | Go (`systray`) | Single ~7MB exe, no dependencies |
| [`menubar/`](menubar/) | macOS menu bar | Swift / AppKit | Claude + Codex, menu-bar only (no Dock icon) |

`src/` is the reference implementation; `tray-go` and `menubar` are hand-ports of the same design in each language.
The Codex integration is currently implemented in `menubar/` only and is kept independent from the Claude usage provider.
For platform-specific build, distribution, and troubleshooting instructions, see the README in each folder.

---

## macOS Menu Bar App

Pulse places a compact, two-line display in the macOS menu bar so Claude and Codex can be checked at a glance:

```text
Cl 5%  ▮▮▮▮▯
Cx 20% ▮▮▯▯▯
```

`Cl` and `Cx` show each provider's 5-hour usage. The five segments form a countdown gauge, with each filled segment representing approximately one hour until that window resets.

### Features

- Shows Claude Code and Codex 5-hour usage together in one menu-bar item
- Displays a five-segment time-remaining gauge for each provider's 5-hour window
- Colors Claude and Codex independently: orange at 80% usage and red at 95%
- Provides a detailed dropdown with Claude 5-hour, weekly, and per-model weekly limits such as `Weekly Fable`
- Shows Codex 5-hour and weekly limits, including the reset time for each window
- Detects the current Claude model from the latest local session transcript
- Refreshes automatically every five minutes by default, with `Refresh Now` for an immediate update
- Refreshes Claude OAuth credentials automatically and keeps the result synchronized with Claude Code's credential store
- Preserves the last successful value during transient failures, marks it stale, and retries with backoff
- Offers provider-specific login actions only when credentials are missing or authentication has expired
- Includes `About` and `Quit`, and runs without a Dock icon

### Authentication and privacy

No separate Pulse account is required. For Claude Code, Pulse checks both `~/.claude/.credentials.json` and the `Claude Code-credentials` keychain item on every refresh, then uses the credential with the latest expiry. Keychain access goes through macOS's `/usr/bin/security` tool so it remains compatible with Claude Code.

For Codex, Pulse reads the access token from `CODEX_HOME/auth.json` or `~/.codex/auth.json`. It never reads or writes the Codex refresh token. Credentials are used only with the corresponding Anthropic or OpenAI endpoints, and Pulse includes no analytics or telemetry.

> The Claude and Codex usage endpoints are internal client APIs and may change in future versions.

### Build and run

Requires macOS 13+ and Swift 6 / Xcode command-line tools.

```bash
cd menubar
./build-app.sh
open ./Pulse.app
```

See the [macOS menu-bar documentation](menubar/README.md) for terminal mode, appearance settings, signed and notarized releases, security details, and troubleshooting.

---

## VSCode Extension

Always shows Claude Code's 5-hour / weekly usage in the VSCode status bar.

![status bar example](https://img.shields.io/badge/status%20bar-5h%2042%25%20%C2%B7%20wk%208%25-blue)


### Features

- Shows usage + current model in the status bar as `5h 42% · wk 8% · Opus 4.8`
- The current model is read from the most recent session transcript (`~/.claude/projects/**/*.jsonl`)
- Hover for a detailed tooltip: time remaining until each window resets, weekly Opus/Sonnet split, current model ID, and last update time
- Status-bar color warns (yellow) / alerts (red) when usage is high
- Refresh interval and warn/alert thresholds are configurable in settings
- Click the status bar to refresh immediately

### How it works

It calls the same endpoint the `/usage` command uses
(`https://api.anthropic.com/api/oauth/usage`). No separate login is
required — if you are signed in to Claude Code, it works right away.

Where the auth token is read from (cross-OS, auto-detected):

- **Windows / Linux**: `~/.claude/.credentials.json`
- **macOS**: checks both the file above and the keychain item `Claude Code-credentials`, then uses the credential with the latest expiry

### Settings

| Setting | Default | Description |
|---|---|---|
| `pulse.refreshInterval` | `300` | Refresh interval in seconds (minimum 10) |
| `pulse.warnThreshold` | `0.8` | Usage threshold for the warning color (0–1) |
| `pulse.alertThreshold` | `0.95` | Usage threshold for the alert color (0–1) |

### Development / Build

```bash
npm install
npm test          # unit tests
npm run package   # build dist/extension.js bundle
npx @vscode/vsce package   # build .vsix
```

Debugging: open this folder in VSCode and press `F5` (Extension Development Host).

Install: `code --install-extension pulse-0.4.0.vsix`
