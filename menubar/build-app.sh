#!/bin/bash
# ClaudeUsageMenuBar.app 번들을 빌드한다 (더블클릭 실행용).
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsageMenuBar.app"
BIN_NAME="ClaudeUsageMenuBar"

echo "▶ 릴리스 빌드..."
swift build -c release

echo "▶ .app 번들 생성..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp ".build/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"

# SwiftPM이 생성한 리소스 번들(About 헤더 PNG 등)을 복사해 Bundle.module이 찾도록 한다.
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

echo "✅ 완료: $(pwd)/$APP"
echo "   실행: open \"$(pwd)/$APP\"   (또는 Finder에서 더블클릭)"
echo "   /Applications 로 옮겨도 됩니다."
