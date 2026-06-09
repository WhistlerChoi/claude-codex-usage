#!/bin/bash
# Cross-compile ClaudeUsage.exe for Windows on macOS/Linux (no Wine needed).
set -euo pipefail
cd "$(dirname "$0")"

echo "Building for Windows x64..."
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go build -ldflags "-H windowsgui -s -w" -o ClaudeUsage.exe .

echo "Done: $(pwd)/ClaudeUsage.exe ($(du -h ClaudeUsage.exe | cut -f1))"
echo "   Copy this file to Windows and double-click it to show it in the tray."
