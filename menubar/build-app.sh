#!/bin/bash
# Build the Pulse.app bundle (for double-click launch).
set -euo pipefail
cd "$(dirname "$0")"

APP="Pulse.app"
BIN_NAME="Pulse"

echo "▶ Release build..."
swift build -c release

echo "▶ Creating .app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp ".build/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"

# About header image — copied to the standard app Resources location so Bundle.main finds it.
# (Do NOT rely on the SwiftPM-generated resource bundle / Bundle.module: its accessor traps
# when the bundle isn't at its expected path, crashing the app on other machines.)
cp "Sources/Pulse/Resources/header.png" "$APP/Contents/Resources/header.png"

# App icon (gauge glyph matching the About header). Regenerate from make-icon.swift if missing.
if [ ! -f "AppIcon.icns" ]; then
  echo "▶ Generating AppIcon.icns..."
  swift make-icon.swift
fi
cp "AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pulse</string>
  <key>CFBundleDisplayName</key><string>Pulse</string>
  <key>CFBundleIdentifier</key><string>xyz.agle.pulse</string>
  <key>CFBundleVersion</key><string>1.0.3</string>
  <key>CFBundleShortVersionString</key><string>1.0.3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Pulse opens Terminal and runs the "claude" command so you can log in to Claude Code.</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 AGLE</string>
</dict>
</plist>
PLIST

# Code signing.
# - CODESIGN_IDENTITY set (e.g. "Developer ID Application: ..."): sign with hardened
#   runtime + entitlements — required for distribution (Gatekeeper/notarization).
# - Unset: ad-hoc sign for local development. Ad-hoc apps do NOT pass Gatekeeper on
#   other machines; never distribute an unsigned/ad-hoc build.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "▶ Signing with: $CODESIGN_IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements Pulse.entitlements \
    --sign "$CODESIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "   Next (distribution): ditto -c -k --keepParent \"$APP\" Pulse.zip"
  echo "     xcrun notarytool submit Pulse.zip --keychain-profile <profile> --wait"
  echo "     xcrun stapler staple \"$APP\""
else
  echo "▶ CODESIGN_IDENTITY not set — ad-hoc signing (local dev only, not distributable)"
  codesign --force --entitlements Pulse.entitlements --sign - "$APP"
fi

echo "✅ Done: $(pwd)/$APP"
echo "   Run: open \"$(pwd)/$APP\"   (or double-click in Finder)"
echo "   You can also move it to /Applications."
