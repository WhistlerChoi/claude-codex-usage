# Codex usage integration design

## Goal

Show the current ChatGPT Codex rate-limit usage in the macOS menu bar while keeping
the existing Claude Code display and failure behavior unchanged.

## Architecture

- `CodexUsageClient.swift` is an independent provider.
- It reads only `CODEX_HOME/auth.json` (or `~/.codex/auth.json`) and uses the stored
  access token for a read-only request to Codex's current client endpoint:
  `https://chatgpt.com/backend-api/wham/usage`.
- Refresh tokens are never used or written by Pulse.
- Claude and Codex have separate timers, cached values, error states, and menu items.
- The existing Pulse status item is reused. Its two lines display Claude 5-hour usage
  and Codex usage (`Cl <percent>%` / `Cx <percent>%`) once both providers have loaded.
  The existing detail menu contains the Codex row as well.

## Data mapping

| API field | UI |
|---|---|
| `rate_limit.primary_window.used_percent` | Current Codex usage percentage |
| `rate_limit.primary_window.reset_at` | Reset time |
| `rate_limit.primary_window.reset_after_seconds` | Fallback reset duration |
| `plan_type` | Plan label |
| `credits.has_credits` / `credits.unlimited` | Credit status |

## Failure and security behavior

- A missing or expired Codex login shows `CX Login` and a `Log In via Codex` action.
- Network, HTTP, or parsing failures show `CX ··` without affecting Claude.
- No token is logged, transmitted anywhere except the Codex usage endpoint, or
  persisted by Pulse.

The endpoint is an internal Codex client endpoint rather than a public stable API;
the parser is intentionally narrow and this integration may require maintenance when
Codex changes its client protocol.
