#!/bin/bash
# Build the ClaudeUsageMenuBar.app bundle (for double-click launch).
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsageMenuBar.app"
BIN_NAME="ClaudeUsageMenuBar"

echo "▶ Release build..."
swift build -c release

echo "▶ Creating .app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp ".build/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"

# Copy the resource bundle SwiftPM generated (About header PNG, etc.) so Bundle.module can find it.
RES_BUNDLE=".build/release/${BIN_NAME}_${BIN_NAME}.bundle"
if [ -d "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleIdentifier</key><string>com.wemeet.claude-usage-menubar</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "✅ Done: $(pwd)/$APP"
echo "   Run: open \"$(pwd)/$APP\"   (or double-click in Finder)"
echo "   You can also move it to /Applications."
