#!/bin/bash
# Build, sign, notarize, staple, and package Pulse.app for Developer ID distribution.
#
# This wraps build-app.sh (which produces a hardened-runtime, signed Pulse.app) and adds
# the steps required to distribute outside the Mac App Store: notarize + staple the app,
# then build a DMG and notarize + staple that too. The result passes Gatekeeper on a clean
# machine, even offline.
#
# Prerequisites (one-time):
#   1. Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in your keychain.
#   3. A saved notarytool credential profile, e.g.:
#        xcrun notarytool store-credentials pulse \
#          --apple-id "you@appleid.com" --team-id "TEAMID" --password "app-specific-pw"
#
# Usage:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./release.sh
#
# Env vars:
#   CODESIGN_IDENTITY   (required) Developer ID Application identity used to sign app + DMG.
#   NOTARY_PROFILE      (default "pulse") notarytool --keychain-profile name.
#   SKIP_DMG            set to 1 to produce only the stapled .app (no DMG).
set -euo pipefail
cd "$(dirname "$0")"

APP="Pulse.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-pulse}"

# ── Preflight ────────────────────────────────────────────────────────────────
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  echo "✗ CODESIGN_IDENTITY is not set." >&2
  echo "  Set it to your Developer ID, e.g.:" >&2
  echo '    CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./release.sh' >&2
  echo "  Available identities:" >&2
  security find-identity -v -p codesigning | grep "Developer ID Application" >&2 || \
    echo "    (none found — create one in Xcode → Settings → Accounts → Manage Certificates)" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ notarytool profile '$NOTARY_PROFILE' not found." >&2
  echo "  Create it once with:" >&2
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
  echo '      --apple-id "you@appleid.com" --team-id "TEAMID" --password "app-specific-pw"' >&2
  echo "  (or pass a different name via NOTARY_PROFILE=...)" >&2
  exit 1
fi

# ── 1. Signed build (delegates to build-app.sh) ──────────────────────────────
echo "▶ [1/5] Building + signing $APP ..."
CODESIGN_IDENTITY="$CODESIGN_IDENTITY" ./build-app.sh >/dev/null
codesign --verify --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "   Version: $VERSION"

# ── 2. Notarize the app ──────────────────────────────────────────────────────
echo "▶ [2/5] Notarizing the app ..."
ZIP="Pulse-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$ZIP"

# ── 3. Staple the app ────────────────────────────────────────────────────────
echo "▶ [3/5] Stapling the app ..."
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"   # expect: accepted, source=Notarized Developer ID

if [ "${SKIP_DMG:-0}" = "1" ]; then
  echo "✅ Done (app only): $(pwd)/$APP  (v$VERSION)"
  exit 0
fi

# ── 4. Build + sign the DMG ──────────────────────────────────────────────────
echo "▶ [4/5] Building DMG ..."
DMG="Pulse-${VERSION}.dmg"
rm -f "$DMG"
# Stage a folder with the stapled app + an Applications shortcut for drag-to-install UX.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Pulse" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"

# ── 5. Notarize + staple the DMG ─────────────────────────────────────────────
echo "▶ [5/5] Notarizing + stapling the DMG ..."
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo ""
echo "✅ Release ready: $(pwd)/$DMG  (v$VERSION)"
echo "   Distribute this DMG. Recipients: open it, drag Pulse to Applications."
