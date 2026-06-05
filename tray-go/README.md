# Claude Usage — 트레이 앱 (Go, 경량)

Claude Code 사용량을 시스템 트레이에 표시하는 **Go 네이티브** 앱입니다.
Electron 버전(~146MB)을 대체하는 **단일 exe ~7MB**, 런타임 의존성 없음.

## 표시 방식

- **아이콘**: 5시간 사용률 숫자 색상 배지 (`42`) — 파랑(정상)/주황(80%↑)/빨강(95%↑)
- **호버 툴팁**: 5시간·주간·Opus/Sonnet·현재 모델·리셋까지 시간
- **우클릭 메뉴**: 상세 + `지금 새로고침` / `종료`

## 동작 방식

- 사용률: `https://api.anthropic.com/api/oauth/usage`
- 토큰: `~/.claude/.credentials.json` (Windows: `%USERPROFILE%\.claude\.credentials.json`), macOS는 없으면 키체인
- 현재 모델: `~/.claude/projects/**/*.jsonl` 중 최신 트랜스크립트의 마지막 `message.model`

## 빌드

```bash
# 맥/리눅스에서 Windows exe 크로스컴파일 (Wine 불필요)
./build-win.sh                 # → ClaudeUsage.exe (~7MB)

# 또는 직접:
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
  go build -ldflags "-H windowsgui -s -w" -o ClaudeUsage.exe .

# 현재 OS용으로 실행 (맥/리눅스 테스트)
go run .

# 아이콘 모양만 PNG로 확인
go run . --render /tmp/icon.png && open /tmp/icon.png
```

생성된 `ClaudeUsage.exe`를 Windows로 복사해 더블클릭하면 트레이에 표시됩니다.

## 설정

- 갱신 주기: 환경변수 `CLAUDE_USAGE_INTERVAL`(초, 기본 300, 최소 10)

## 크기 비교

| 구현 | 크기 |
|---|---|
| Electron (`../tray`) | ~146MB |
| **Go (이 폴더)** | **~7MB** |

## 요구 사항

빌드: Go 1.23+. 실행: 없음(단일 정적 바이너리). Windows 빌드는 cgo 불필요.
