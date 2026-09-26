# Pulse

Keep Claude Code's **5-hour and weekly usage** visible without interrupting your workflow.
Pulse also detects the current Claude model, and the macOS menu-bar app displays **Codex usage** alongside Claude Code.
Claude usage comes from the same source as Claude Code's `/usage` command, with integrations for VSCode, macOS, and Windows.

<img width="381" height="408" alt="Screenshot 2026-09-26 at 23 54 16" src="https://github.com/user-attachments/assets/63d05b21-b6ca-4b31-8bba-c5de524a7c1d" />

> **Privacy Notice:** Pulse does not collect, store, or transmit any personal information or usage data. It only reads the credentials required to retrieve usage information and sends them to the corresponding official service endpoints.  
> No analytics, tracking, or hidden data collection is ever performed.

## Implementations

| Folder | Surface | Stack | Notes |
| --- | --- | --- | --- |
| [`src/`](src/) | VSCode status bar | TypeScript + esbuild | Canonical core (documented below) |
| [`tray-go/`](tray-go/) | Windows/macOS tray (lightweight) | Go (`systray`) | Claude + Codex, single ~7MB exe |
| [`menubar/`](menubar/) | macOS menu bar | Swift / AppKit | Claude + Codex, menu-bar only (no Dock icon) |

`src/` is the reference implementation; `tray-go` and `menubar` are hand-ports of the same design in each language.
The macOS menu bar and Windows tray both show Codex alongside Claude; the Codex provider remains independent from the Claude usage provider.
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
- Shows today's token usage per provider (`Tokens today: 1.2M in · 48K out · 9.8M cache`); hover that row to see the last 7 days and the last 30 days with the change against the prior window (`Tokens 7d: 41M in · 2.9M out · 620M cache · ▲ 12% vs prior 7d`), computed locally from the Claude Code transcripts and Codex session logs and kept in a small daily ledger at `~/.pulse/token-history.json` so history outlives Claude Code's 30-day transcript cleanup
- Refreshes automatically every five minutes by default, with `Refresh Now` for an immediate update
- Offers an optional `Auto Wakeup` switch that keeps the 5-hour row from going blank when the window has no recorded activity (off by default; see below)
- Refreshes Claude OAuth credentials automatically and keeps the result synchronized with Claude Code's credential store
- Preserves the last successful value during transient failures, marks it stale, and retries with backoff
- Offers provider-specific login actions only when credentials are missing or authentication has expired
- Includes `About` and `Quit`, and runs without a Dock icon

### Auto Wakeup (optional, off by default)

When you have not used Claude Code during the current 5-hour window, the usage API omits that window's reset time and the `5h` row falls back to `—` with no countdown. Switching `Auto Wakeup` on in the dropdown makes Pulse send one minimal request in that state (about 9 tokens) so a reset time is reported again.

It spends a small amount of real quota automatically, so it stays off until you turn it on. Note that Claude's 5-hour window is clock-aligned — it rolls over on the hour whether or not anything is sent — so Auto Wakeup only restores the missing reset time and cannot start a window earlier. A failed wakeup never disturbs the displayed values and never triggers a login prompt. Codex is not covered yet.

See the [macOS menu-bar documentation](menubar/README.md#auto-wakeup) for the guards against repeat sends and the `defaults` escape hatch.

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
- Hover for a detailed tooltip: time remaining until each window resets, weekly Opus/Sonnet split, current model ID, today's token usage with a `7d / 30d ▸` link that reveals the 7-day / 30-day totals and their change against the prior window (computed locally from the transcripts, kept in `~/.pulse/token-history.json`; `pulse.showTokens` turns it off), and last update time
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
