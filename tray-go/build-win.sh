#!/bin/bash
# Cross-compile Pulse.exe for Windows on macOS/Linux (no Wine needed).
set -euo pipefail
cd "$(dirname "$0")"

echo "Building for Windows x64..."
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go build -ldflags "-H windowsgui -s -w" -o Pulse.exe .

echo "Done: $(pwd)/Pulse.exe ($(du -h Pulse.exe | cut -f1))"
echo "   Copy this file to Windows and double-click it to show it in the tray."
