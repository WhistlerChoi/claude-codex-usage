# Pulse — Release & Security Notes

Pre-deployment checklist and the security-review summary for the macOS menu-bar app
(`menubar/`). Scope is the `menubar/` directory only.

## One-command release

Once the one-time setup is done (Developer ID cert + saved notarytool profile), the whole
build → sign → notarize → staple → DMG flow is a single command:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./release.sh
# → Pulse-<version>.dmg (notarized + stapled, ready to distribute)
```

One-time prerequisites:

```bash
# 1) Developer ID Application certificate: Xcode → Settings → Accounts → Manage Certificates → +
# 2) Saved notarization profile (app-specific password from appleid.apple.com):
xcrun notarytool store-credentials pulse \
  --apple-id "you@appleid.com" --team-id "TEAMID" --password "xxxx-xxxx-xxxx-xxxx"
```

The manual steps below are what `release.sh` runs under the hood, kept for reference and
troubleshooting.

## Pre-deployment checklist

- [ ] **Sign with a Developer ID certificate.** An ad-hoc build (plain `./build-app.sh`)
      is blocked by Gatekeeper on other machines.
      ```bash
      CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build-app.sh
      codesign --verify --strict --verbose=2 Pulse.app   # expect "valid on disk"
      ```
- [ ] **Notarize and staple.**
      ```bash
      ditto -c -k --keepParent Pulse.app Pulse.zip
      xcrun notarytool submit Pulse.zip --keychain-profile <profile> --wait
      xcrun stapler staple Pulse.app
      spctl --assess --type execute Pulse.app          # expect "accepted, source=Notarized Developer ID"
      ```
- [ ] **Verify the entitlement is present** (needed so the "Log In via Claude Code"
      menu item can drive Terminal under the hardened runtime):
      ```bash
      codesign -dv --entitlements - Pulse.app | grep apple-events
      ```
- [ ] **Smoke-test the signed app on a clean machine** (or a second account): launch,
      confirm the menu bar shows usage, and that "Log In via Claude Code" prompts for
      Automation permission instead of failing silently.
- [ ] **Bump the version** in `build-app.sh` (`CFBundleVersion` /
      `CFBundleShortVersionString`) for each release.
- [ ] **Confirm no secrets** are bundled: `Pulse.app` ships only the binary, the header
      PNG, and the icon — no credentials.

## Security review summary (2026-06-10)

Full review covered every source file under `menubar/`. **No code-level vulnerabilities
(token leakage, injection, insecure transport) were found.** The items below were the
gaps for *commercial distribution*; all code fixes have been applied.

### Verified safe (no action needed)

- OAuth token is held only in memory and sent only to `https://api.anthropic.com` over
  HTTPS. It never appears in logs, error messages, or the UI.
- No third-party dependencies (`Package.swift`) — minimal supply-chain surface.
- Untrusted input (API responses, transcript JSONL) is parsed with `JSONSerialization`
  + type checks and rendered as plain `NSMenuItem` text — no injection vector.
- 429 / exponential-backoff handling prevents API abuse. No secrets committed.

### Fixes applied

| # | Issue | Fix |
|---|-------|-----|
| 1 | No code signing / notarization → Gatekeeper blocks distribution | `build-app.sh` signs with hardened runtime + entitlements when `CODESIGN_IDENTITY` is set; ad-hoc otherwise. `Pulse.entitlements` added. |
| 2 | AppleScript (Terminal automation) entitlement undeclared → login menu silently breaks once signed | `Pulse.entitlements` grants `com.apple.security.automation.apple-events`; `Info.plist` adds `NSAppleEventsUsageDescription`; `login()` now shows an `NSAlert` on failure. |
| 3 | No user-facing disclosure of sensitive-data access | "Security & privacy" section added to `README.md`. |
| 4 | Keychain read via `/usr/bin/security` subprocess | Replaced with Security.framework `SecItemCopyMatching` (no process spawn). |
| 5 | Debug render paths used shared `/tmp` (symlink-following risk) | Switched to `NSTemporaryDirectory()`. |

### Open operational risk (not a code fix)

- **Undocumented API dependency.** The usage endpoint
  `https://api.anthropic.com/api/oauth/usage` (header `anthropic-beta: oauth-2025-04-20`)
  is a Claude Code internal/undocumented API. It may change or be blocked without notice,
  and basing a commercial product on it carries Terms-of-Service risk. Before shipping,
  confirm acceptable use and have a fallback/incident plan for when the endpoint changes.
- **Trademark / affiliation.** Pulse uses the "Claude" name to describe what it reads.
  A non-affiliation notice ("Not affiliated with or endorsed by Anthropic. Claude is a
  trademark of Anthropic, PBC.") now ships in the About window and `README.md`. Keep the
  product's own branding ("Pulse") primary in all store/marketing copy; use "Claude" only
  nominatively (to describe compatibility), never in a way that implies endorsement.

## What the app accesses (for privacy disclosures)

- **Reads:** the Claude Code OAuth access token (`~/.claude/.credentials.json`, falling
  back to the `Claude Code-credentials` keychain item) and local transcripts under
  `~/.claude/projects/**/*.jsonl` — only the `message.model` field is used.
- **Sends:** the token to `https://api.anthropic.com` to fetch usage. Nothing else leaves
  the machine; no analytics or telemetry.
- **Stores:** nothing — the token is re-read from disk/keychain on every poll.
