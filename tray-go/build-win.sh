#!/bin/bash
# 맥/리눅스에서 Windows용 ClaudeUsage.exe 크로스컴파일 (Wine 불필요).
set -euo pipefail
cd "$(dirname "$0")"

echo "▶ Windows x64 빌드..."
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go build -ldflags "-H windowsgui -s -w" -o ClaudeUsage.exe .

echo "✅ 완료: $(pwd)/ClaudeUsage.exe ($(du -h ClaudeUsage.exe | cut -f1))"
echo "   이 파일을 Windows로 복사해 더블클릭하면 트레이에 표시됩니다."
