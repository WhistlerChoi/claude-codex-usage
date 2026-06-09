# Pulse — macOS menu-bar app

A native Swift app that always shows the same info as the VSCode extension (5-hour / weekly usage + current model) in the **macOS menu bar (top right)**.

The menu bar shows only a gauge icon + compact usage (to blend in with the neighboring CPU/memory/network icons):

```
◐ 5% · 4%      (5h % · weekly %)
```

Clicking it opens a dropdown with details (time remaining until reset, weekly Opus/Sonnet, current model, last update) plus `Refresh Now` / `Quit`. When usage is high, the menu-bar text color turns orange (80%+) / red (95%+).

> **Menu-bar only** — because of `LSUIElement` / `.accessory`, no Dock icon appears.

## How it works

It uses the same source as the VSCode extension (ported to Swift):

- Usage: `https://api.anthropic.com/api/oauth/usage`
- Token: `~/.claude/.credentials.json` → macOS keychain if absent
- Current model: the last `message.model` from the most recent transcript among `~/.claude/projects/**/*.jsonl`

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
