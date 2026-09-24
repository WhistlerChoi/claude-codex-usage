# Pulse — macOS menu-bar app

A native Swift app that always shows the same info as the VSCode extension (5-hour / weekly usage + current model) in the **macOS menu bar (top right)**.

The menu bar shows Claude and Codex usage together in the original Pulse item (to blend in with the neighboring CPU/memory/network icons). Each line starts with a small brand-colored provider mark instead of a text label — a terracotta sunburst for Claude, a green knot for Codex (drawn in code, see `ProviderIcon.swift`). Five small segments after each percentage show the approximate time remaining in its 5-hour window; each filled segment is about one hour:

```
✳ 5% ▮▮▮▮▯      (Claude, terracotta mark)
⬡ 20% ▮▮▯▯▯     (Codex, green mark)
```

Clicking it opens a dropdown with separate Claude and Codex sections, each headed by the same provider mark and name, with that provider's current model at the right end of the header row (e.g. `Opus (claude-opus-5)`, `GPT-5.6-Terra (gpt-5.6-terra)`). Each section lists its 5-hour and weekly windows with the time remaining until each resets, under a single `resets in` column caption; the Claude section additionally shows weekly per-model limits. `Refresh Now` (⌘R) re-polls both providers and carries the last-updated clock time next to its label in a smaller, de-emphasized font (the later of the two providers' last successful polls). When usage is high, the menu-bar text color turns orange (80%+) / red (95%+).

> **Menu-bar only** — because of `LSUIElement` / `.accessory`, no Dock icon appears.

## How it works

It uses the same source as the VSCode extension (ported to Swift):

- Usage: `https://api.anthropic.com/api/oauth/usage`
- Token: `~/.claude/.credentials.json` → macOS keychain if absent
- Current model: the last `message.model` from the most recent transcript among `~/.claude/projects/**/*.jsonl`

Codex usage is fetched independently from `https://chatgpt.com/backend-api/wham/usage`.
The app reads the Codex access token from `CODEX_HOME/auth.json` or `~/.codex/auth.json`,
but never uses or writes the refresh token. The Codex endpoint is an internal client
endpoint and may change with future Codex versions. The current Codex model is the `model`
of the last `turn_context` record in the most recent rollout log under
`CODEX_HOME/sessions/**/*.jsonl`, named via `CODEX_HOME/models_cache.json` (slug →
display name); if either is unavailable the header simply omits the model.

## Build & run

```bash
# 1) Make a double-clickable .app (recommended)
./build-app.sh
open ./Pulse.app          # or double-click in Finder

# 2) Run directly from the terminal
swift build -c release
./.build/release/Pulse

# Print the values once (no menu bar)
./.build/release/Pulse --once
```

To quit: click the menu-bar icon → `Quit` (or `pkill -f Pulse`).

### Diagnostic flags

Each of these prints or renders once and exits, without starting the menu-bar item:

| Flag | What it does |
|---|---|
| `--once` | Print the current Claude values |
| `--codex-once` | Print the current Codex values |
| `--codex-wakeup` | Send one Codex Auto Wakeup request and print the result (spends a tiny amount of Codex quota) |
| `--selftest` | Run the unit tests (pure functions: formatting, credentials, usage parsing, Auto Wakeup). Exits non-zero on failure — this is the project's test command |
| `--menu <out.png>` | Render the dropdown offscreen to a PNG (column-alignment regression check) |
| `--dark` | Combined with `--menu`, renders under the dark appearance so colour choices can be checked in both themes |
| `--about` | Render the About window to a PNG |
| `--render <out.png>` | Render just the menu-bar title image |

## Distribution (signing & notarization)

> See [docs/RELEASE.md](docs/RELEASE.md) for the full pre-deployment checklist and the
> security-review summary.

`./build-app.sh` alone produces an **ad-hoc signed** app — fine for your own machine, but
Gatekeeper blocks it on anyone else's. To distribute, sign with a Developer ID certificate
and notarize. Once set up, `release.sh` does the whole thing in one command:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./release.sh
# → Pulse-<version>.dmg, notarized + stapled, ready to hand out
```

Under the hood that runs:

```bash
# 1) Sign (hardened runtime + entitlements, done by build-app.sh)
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build-app.sh

# 2) Notarize and staple the app
ditto -c -k --keepParent Pulse.app Pulse.zip
xcrun notarytool submit Pulse.zip --keychain-profile <profile> --wait
xcrun stapler staple Pulse.app

# 3) Verify
spctl --assess --type execute Pulse.app
```

`Pulse.entitlements` grants `com.apple.security.automation.apple-events`, which the
"Log In via Claude Code" menu item needs to open Terminal under the hardened runtime
(macOS will still ask the user for Automation permission on first use).

## Security & privacy

- **What it reads:** the Claude Code OAuth access token (`~/.claude/.credentials.json`,
  falling back to the `Claude Code-credentials` keychain item) and, to show the current
  model, the local transcripts under `~/.claude/projects/**/*.jsonl` — only the
  `message.model` field is used; conversation content is never displayed or transmitted.
  For Codex, it reads `CODEX_HOME/auth.json` or `~/.codex/auth.json` and, for the current
  model, the rollout logs under `CODEX_HOME/sessions/**/*.jsonl` plus `models_cache.json` —
  again only the model field is used; nothing from those logs is displayed or transmitted.
- **Where data goes:** the Claude token is sent only to `https://api.anthropic.com` and
  the Codex token only to `https://chatgpt.com` to fetch usage. Nothing else leaves your
  machine; there is no analytics or telemetry.
- **What it stores:** nothing of its own. When Pulse refreshes the OAuth token (see
  `TokenRefresh.swift`) it writes the rotated token back to the store Claude Code reads,
  so the two stay in sync; otherwise the token lives only in memory.
- **How the keychain is accessed:** via `/usr/bin/security` — the same mechanism Claude
  Code itself uses — so no keychain permission dialog appears. On writes the token is
  passed hex-encoded over `security -i` stdin, never on the command line.
- **Heads-up:** the usage endpoint (`/api/oauth/usage`) is an undocumented Claude Code
  internal API and may change or stop working without notice.
- **Affiliation:** Pulse is an independent product, not affiliated with or endorsed by
  Anthropic. Claude is a trademark of Anthropic, PBC.
- **Codex notice:** Codex and ChatGPT are trademarks of OpenAI. Pulse is not affiliated
  with or endorsed by OpenAI.

## Troubleshooting

### macOS keeps asking for a password for "Claude Code-credentials"

A repeating dialog like *"security wants to access key 'Claude Code-credentials' in your
keychain"* (with a password field) means the keychain item's partition list was corrupted:
some app once rewrote the item with the native keychain API instead of the `security` CLI,
which locks Claude Code out of its own credentials. (Pulse versions before 2026-07 could do
this during token writeback; current Pulse cannot, and self-heals the item on its next
writeback.) One-time fixes, either of:

```bash
# Repair the partition list in place (asks for your login keychain password once):
security set-generic-password-partition-list -S apple-tool:,apple: -s "Claude Code-credentials"
```

or run `/logout` followed by `/login` inside Claude Code, which recreates the item cleanly.

If a "wants to access" dialog ever does appear, click **Always Allow** — plain "Allow"
grants access once and the dialog returns on the next poll.

## Auto Wakeup

**Off by default.** Toggle it with the switch on the menu's "Auto Wakeup" row; the setting
persists across restarts. Once it has fired, the row also shows the time of the last attempt.

When no activity has been recorded in the current 5-hour window, the API omits `resets_at` and
the 5h row shows "reset time unknown" / "—" instead of a countdown. With Auto Wakeup on, Pulse
sends **one minimal request** in that state (Claude: `POST /v1/messages`, Haiku, `max_tokens: 1`
— about 9 tokens) so the provider starts reporting a reset time again and the row stays populated.

Things worth knowing before enabling it:

- **It consumes real quota.** The amount is tiny, but it is not zero, and it is sent
  automatically without further confirmation.
- Claude's 5-hour window is **clock-aligned** (it resets on the hour regardless of activity), so a
  successful wakeup keeps the row populated until the next boundary — at most one request per
  5 hours. A wakeup does **not** move the window boundary earlier; nothing can.
- A wakeup never affects the display: if it fails, the usage values stay as they were and no
  login prompt appears.
- **Codex** uses the same rule. In the same idle state it sends one minimal turn to
  `POST https://chatgpt.com/backend-api/codex/responses` (the endpoint Codex itself uses) with a
  `"."` prompt and empty instructions, on the current Codex model (fallback: the first listed model
  in `models_cache.json`). Claude and Codex keep separate cooldowns, and the row's "last" time
  shows the later of the two.

Escape hatch (the app must not be running):

```bash
defaults write com.wemeet.pulse AutoWakeupEnabled -bool false   # force off
defaults delete com.wemeet.pulse AutoWakeupEnabled              # back to the default (off)
```

## Settings / fine-tuning

The two-line display is drawn into an image sized to the menu-bar height. If the line positions do not align with neighboring items, adjust the values below.

| Setting | Env var | `defaults` key | Default |
|---|---|---|---|
| Refresh interval (seconds) | `CLAUDE_USAGE_INTERVAL` | `Interval` | 300 |
| Font size | `CLAUDE_USAGE_FONT_SIZE` | `FontSize` | 9 |
| Font weight | `CLAUDE_USAGE_FONT_WEIGHT` | `FontWeight` | 0.4 (bold) |
| Line gap (center-to-center) | `CLAUDE_USAGE_LINE_GAP` | `LineGap` | 10 |
| Overall vertical shift (+up / −down) | `CLAUDE_USAGE_Y_OFFSET` | `YOffset` | 0 |

**When running from the terminal** — use env vars:
```bash
CLAUDE_USAGE_LINE_GAP=12 CLAUDE_USAGE_FONT_SIZE=9 ./.build/release/Pulse
```

**For the double-clicked .app** (env vars do not apply, so use `defaults`):
```bash
defaults write com.wemeet.pulse LineGap 12
defaults write com.wemeet.pulse FontSize 9
# To apply: quit and relaunch the app
```

Preview just the display appearance as a PNG:
```bash
CLAUDE_USAGE_LINE_GAP=12 ./.build/release/Pulse --render /tmp/preview.png
open /tmp/preview.png
```

## Requirements

macOS 13+, Swift 6 / Xcode command-line tools.
