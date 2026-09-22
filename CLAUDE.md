# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Three front-ends that display Claude Code's **5-hour / weekly usage** (and current model) in an always-visible UI surface. The macOS menu-bar app additionally displays current Codex usage. The Claude provider shares identical core logic across platforms; the Codex provider is currently menubar-specific.

| Dir | Platform / surface | Stack |
|---|---|---|
| `src/` | VSCode status bar | TypeScript + esbuild (the canonical core) |
| `tray-go/` | Windows/macOS tray, lightweight (~7MB exe) | Go (`getlantern/systray`) — core re-ported |
| `menubar/` | macOS menu bar | Swift / AppKit — core re-ported |

`src/` is the source of truth. `tray-go/` and `menubar/` are hand-ports of the same four-module design, so **a logic change in `src/` must be mirrored** into `tray-go/*.go` and `menubar/Sources/Pulse/*.swift`.

`menubar/` also contains `CodexUsageClient.swift`. It reads the Codex access token from
`CODEX_HOME/auth.json` (or `~/.codex/auth.json`) and displays the current Codex rate-limit
usage in the existing Pulse menu-bar item. This provider is independent from the Claude
provider and is not part of the VSCode or tray implementations. `CodexModel.swift` reads the
current Codex model (best-effort, menubar-only) from the newest `CODEX_HOME/sessions/**/*.jsonl`
rollout log — the `payload.model` of its last `turn_context` record — and maps the slug to a
display name via `CODEX_HOME/models_cache.json`. The menu bar identifies the
two providers with brand-colored vector marks (`ProviderIcon.swift`, fixed colors, drawn in code
via `NSBezierPath`) rather than text prefixes; the marks are menubar-only and need no mirroring.
In the dropdown each provider header shows its current model at the right edge, and the
last-updated time (the later of the two providers' last successful polls) rides on the
`Refresh Now` item in a smaller font rather than sitting under either provider's section.

`menubar/` also contains `AutoWakeup.swift` (**menubar-only, deliberately not mirrored** to
`src/`/`tray-go/`, like the Codex provider). Off by default. When the current 5h window has no
recorded activity the API omits `resets_at` and the 5h row degrades to "reset time unknown"/"—";
with the toggle on, Pulse sends one minimal `POST /v1/messages` (Haiku, `max_tokens: 1`) so a
reset time is reported again. Two facts that constrain any change here: the Claude 5h window is
**clock-aligned** (it resets on the hour whether or not anything is sent, so a wakeup can never
move the boundary earlier — it only repopulates `resets_at`), and Codex's window is *not*
clock-aligned. The trigger is **absence of `resets_at` only** — never `utilization == 0`, since an
active window rounds to 0% and would re-fire every poll. Guards (persisted across restarts, so a
relaunch loop cannot re-send): 30-minute cooldown, in-flight flag, state recorded *before* the
request. The wakeup path has no access to the display layer by construction, satisfying the error
contract below. `sendCodexWakeup()` throws `.notConfigured` until the chatgpt.com request shape is
confirmed — do not guess it.

## Shared architecture (same 4 modules in every implementation)

1. **credentials** — read the OAuth `accessToken` from `~/.claude/.credentials.json` (JSON path `claudeAiOauth.accessToken`, fallback `accessToken`) **and**, on macOS, keychain item `Claude Code-credentials`. **Freshest wins** — see below. Re-read every poll so Claude Code's token refresh is picked up automatically.
2. **usageClient** — `GET https://api.anthropic.com/api/oauth/usage` with headers `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`. Response: `five_hour`, `seven_day` (each `{ utilization, resets_at }`), legacy `seven_day_opus`/`seven_day_sonnet` (now typically `null`), and a `limits` array whose `kind == "weekly_scoped"` entries carry per-model weekly usage as `{ percent, resets_at, scope.model.display_name }` — note the value key is `percent` (integer 0–100, same unit as `utilization`), and these render as `Weekly <display_name>` (e.g. "Weekly Fable"). `limits` parsing is lenient in all three ports (missing/malformed → empty list, never fatal); a scoped entry whose model name a legacy field already rendered is skipped. 401/403 → auth error (distinct from network errors).
3. **model** — best-effort current model. Scan `~/.claude/projects/**/*.jsonl`, pick the most recently modified transcript, read the **last** line's `message.model`. `friendlyModelName` maps e.g. `claude-opus-4-8` → `Opus 4.8`. Failure is non-fatal (model is optional in the UI).
4. **format** — pure functions (status text, tooltip, relative reset time). The unit tests live here and in `model`.

### CRITICAL: credential store selection is "freshest wins", never file-first

Claude Code on macOS stores its OAuth credentials in the **keychain** and can leave a long-dead
`~/.claude/.credentials.json` behind from an older version. Preferring the file unconditionally
means every poll presents an expired token; the API then answers **HTTP 429** (throttled) rather
than a clean 401, the UI shows a "login required" state, and logging in cannot help because
Claude Code writes the keychain while the app keeps reading the file. That loop is unbreakable
from the user's side — do not reintroduce it.

So all three ports read **every** store that has credentials and use the one with the later
`expiresAt` (`pickFreshest` / `pickFreshestToken`, pure and unit-tested in each port):

- Candidates are passed **file first, keychain last**, and ties go to the **last** candidate. The
  tie-break matters for writeback: a refreshed (rotated) token must land where Claude Code reads
  it, or Claude Code's own stored refresh token gets revoked out from under it.
- An unparseable or tokenless store is skipped, never fatal.
- Consequence on macOS: the keychain is read every poll **through the `security` CLI** (see the
  next CRITICAL section), which is **promptless** in the healthy state. Any keychain permission
  dialog naming `Claude Code-credentials` is a symptom of a corrupted partition list, not
  expected behavior — see the Troubleshooting section in `menubar/README.md`.

Only `menubar/` refreshes tokens itself (`TokenRefresh.swift`). Two rules there: never send a token
already past `expiresAt` (report instead — a doomed request is what earns the 429), and keep every
refreshed token in the in-memory cache even when writeback fails, so the next poll cannot reuse an
already-rotated (revoked) refresh token.

### CRITICAL: keychain access goes through `/usr/bin/security`, never Security.framework

Claude Code manages the `Claude Code-credentials` item exclusively via the `security` CLI
(find/add/delete-generic-password), so the item carries the **`apple-tool:` partition list** and
every `security`-based reader — Claude Code itself and all three ports — reads it with **zero
prompts**. A single native `SecItemAdd`/`SecItemUpdate` write from any app re-stamps the item with
*that app's* partition instead; from then on Claude Code's own `security find-generic-password`
fails the partition check and macOS shows a **keychain password dialog on every Claude Code
start** — repeatedly, because the item keeps being rewritten, so granting access never sticks.
This shipped once (menubar commit `1a85f32`, reverted) and produced exactly that popup loop.

Rules, all ports:

- Every touch of the item — read **and** write — must spawn `/usr/bin/security` (menubar uses the
  absolute path; do not "harden" it back to `SecItem*`).
- Writeback (`menubar/` only) is **update-only**: if the item is absent, Claude Code has logged
  out — never create it (resurrecting stale credentials mid-login races Claude Code's own
  delete+add). The secret is passed hex-encoded (`-X`) over `security -i` stdin, never argv.
- The write path self-heals a corrupted item: when `add-generic-password -U` is denied, it
  deletes and re-adds, restoring the `apple-tool:` partition.

### CRITICAL: `utilization` is 0–100, not 0–1

The API returns `utilization` as a **percent (0–100)**, despite some stale doc/comments (`usageClient.ts` interface, the design spec) claiming `0.0–1.0`. Consequences, must stay consistent across all three ports:
- Display: `pct()` just rounds the value — **do not** multiply by 100.
- Threshold comparison: `peakUtilization()` divides by 100 to get a 0–1 fraction, then compares against `warnThreshold` (0.8) / `alertThreshold` (0.95).

If you "fix" this by treating it as a fraction, the status bar will show `0%` / `0%` and never warn.

### Error handling contract (all implementations)

- Auth/credentials error → show a "login required" state (and, in `menubar/`, the "Log In via Claude Code" item). **Only** auth/credentials errors may say this.
- Network/transient error **with** a previous value → keep showing the last value, mark it stale (⚠) once `shouldShowStale`.
- Network/transient error (incl. HTTP 429) with **no** prior value → neutral `··` placeholder in gray, the error text, and `formatRetryIn(delay)`; **no** login prompt. Telling the user to log in cannot fix a rate limit and sends them in circles.

## Build & test

**VSCode extension (`src/`)** — run from repo root:
```bash
npm install
npm test                    # node --test via tsx, runs src/*.test.ts
node --test --import tsx ./src/format.test.ts   # single test file
npm run compile             # dev bundle → dist/extension.js
npm run package             # production (minified) bundle
npm run watch               # rebuild on change
npx @vscode/vsce package    # → pulse-<version>.vsix
```
Debug: open the repo in VSCode, press `F5` (Extension Development Host). Install: `code --install-extension pulse-<version>.vsix`.

**Go tray (`tray-go/`)** — from `tray-go/`:
```bash
./build-win.sh                 # cross-compile → Pulse.exe (~7MB, no cgo)
go run .                       # run on current OS
go run . --render /tmp/icon.png && open /tmp/icon.png   # preview icon only
```

**Swift menu bar (`menubar/`)** — from `menubar/`:
```bash
./build-app.sh                 # → Pulse.app
CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" ./release.sh   # + notarize/staple/DMG (NOTARY_PROFILE, SKIP_DMG=1)
swift build -c release && ./.build/release/Pulse
./.build/release/Pulse --once     # print values once, no menu bar
./.build/release/Pulse --render /tmp/preview.png   # preview rendered title
```

## Conventions

- **UI strings are English (English-only).** Keep all user-facing text (tooltips, menu items, errors) in English. Shared UI strings must read identically across all three ports (e.g. "Refresh Now", "About", "Quit", "Login needed", "resets in 1h 50m", window labels "5h"/"Weekly"/"Weekly Opus"/"Weekly Sonnet"/`Weekly <model>` from `scope.model.display_name`, e.g. "Weekly Fable").
- **Config / polling:** VSCode reads `pulse.refreshInterval` / `warnThreshold` / `alertThreshold` from settings; the other two apps use env var `CLAUDE_USAGE_INTERVAL` (seconds, default 300, min 10). Color thresholds 80% (warn) / 95% (alert) are hard-coded in the non-VSCode ports.
- **Git:** remote `WhistlerChoi/claude-usage`; branch off **`main`** and target it in PRs (every PR to date does). `dev` is a stale leftover branch sitting behind `main` — ignore it, even though local `origin/HEAD` may still point there.
- Design notes: `docs/superpowers/specs/2026-06-04-claude-usage-extension-design.md` (note its `0.0–1.0` claim is outdated; see the utilization note above).
