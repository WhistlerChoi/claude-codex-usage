# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Three front-ends that display Claude Code's **5-hour / weekly usage** (and current model) in an always-visible UI surface. They all read the same data the `/usage` command uses and share identical core logic — only the presentation layer differs per platform.

| Dir | Platform / surface | Stack |
|---|---|---|
| `src/` | VSCode status bar | TypeScript + esbuild (the canonical core) |
| `tray-go/` | Windows/macOS tray, lightweight (~7MB exe) | Go (`getlantern/systray`) — core re-ported |
| `menubar/` | macOS menu bar | Swift / AppKit — core re-ported |

`src/` is the source of truth. `tray-go/` and `menubar/` are hand-ports of the same four-module design, so **a logic change in `src/` must be mirrored** into `tray-go/*.go` and `menubar/Sources/ClaudeUsageMenuBar/*.swift`.

## Shared architecture (same 4 modules in every implementation)

1. **credentials** — read the OAuth `accessToken`. Order: `~/.claude/.credentials.json` first (JSON path `claudeAiOauth.accessToken`, fallback `accessToken`); on macOS only, if the file is absent, fall back to keychain item `Claude Code-credentials` (`security find-generic-password -s ... -w`). Re-read every poll so Claude Code's token refresh is picked up automatically.
2. **usageClient** — `GET https://api.anthropic.com/api/oauth/usage` with headers `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`. Response: `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, each `{ utilization, resets_at }`. 401/403 → auth error (distinct from network errors).
3. **model** — best-effort current model. Scan `~/.claude/projects/**/*.jsonl`, pick the most recently modified transcript, read the **last** line's `message.model`. `friendlyModelName` maps e.g. `claude-opus-4-8` → `Opus 4.8`. Failure is non-fatal (model is optional in the UI).
4. **format** — pure functions (status text, tooltip, relative reset time). The unit tests live here and in `model`.

### CRITICAL: `utilization` is 0–100, not 0–1

The API returns `utilization` as a **percent (0–100)**, despite some stale doc/comments (`usageClient.ts` interface, the design spec) claiming `0.0–1.0`. Consequences, must stay consistent across all three ports:
- Display: `pct()` just rounds the value — **do not** multiply by 100.
- Threshold comparison: `peakUtilization()` divides by 100 to get a 0–1 fraction, then compares against `warnThreshold` (0.8) / `alertThreshold` (0.95).

If you "fix" this by treating it as a fraction, the status bar will show `0%` / `0%` and never warn.

### Error handling contract (all implementations)

- Auth/credentials error → show a "login required" state.
- Network/transient error **with** a previous value → keep showing the last value, mark it stale (⚠).
- Network error with no prior value → show error.

## Build & test

**VSCode extension (`src/`)** — run from repo root:
```bash
npm install
npm test                    # node --test via tsx, runs src/*.test.ts
node --test --import tsx ./src/format.test.ts   # single test file
npm run compile             # dev bundle → dist/extension.js
npm run package             # production (minified) bundle
npm run watch               # rebuild on change
npx @vscode/vsce package    # → claude-usage-<version>.vsix
```
Debug: open the repo in VSCode, press `F5` (Extension Development Host). Install: `code --install-extension claude-usage-<version>.vsix`.

**Go tray (`tray-go/`)** — from `tray-go/`:
```bash
./build-win.sh                 # cross-compile → ClaudeUsage.exe (~7MB, no cgo)
go run .                       # run on current OS
go run . --render /tmp/icon.png && open /tmp/icon.png   # preview icon only
```

**Swift menu bar (`menubar/`)** — from `menubar/`:
```bash
./build-app.sh                 # → ClaudeUsageMenuBar.app
swift build -c release && ./.build/release/ClaudeUsageMenuBar
./.build/release/ClaudeUsageMenuBar --once     # print values once, no menu bar
./.build/release/ClaudeUsageMenuBar --render /tmp/preview.png   # preview rendered title
```

## Conventions

- **UI strings are Korean.** Keep all user-facing text (tooltips, menu items, errors) in Korean to match existing copy.
- **Config / polling:** VSCode reads `claudeUsage.refreshInterval` / `warnThreshold` / `alertThreshold` from settings; the other three apps use env var `CLAUDE_USAGE_INTERVAL` (seconds, default 300, min 10). Color thresholds 80% (warn) / 95% (alert) are hard-coded in the non-VSCode ports.
- **No git repo here** — this directory is not under version control.
- Design notes: `docs/superpowers/specs/2026-06-04-claude-usage-extension-design.md` (note its `0.0–1.0` claim is outdated; see the utilization note above).
