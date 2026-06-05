# Claude Usage — macOS 메뉴바 앱

VSCode 확장과 동일한 정보(5시간/주간 사용률 + 현재 모델)를 **macOS 메뉴바(우측 상단)**에 항상 표시하는 네이티브 Swift 앱입니다.

메뉴바에는 게이지 아이콘 + 압축 사용률만 표시합니다 (옆의 CPU/메모리/네트워크 아이콘들과 어울리도록):

```
◐ 5% · 4%      (5시간 % · 주간 %)
```

클릭하면 드롭다운에 상세(리셋까지 남은 시간, 주간 Opus/Sonnet, 현재 모델, 마지막 갱신)와 `지금 새로고침`/`종료`가 나옵니다. 사용률이 높으면 메뉴바 글자색이 주황(80%↑)/빨강(95%↑)으로 바뀝니다.

> **메뉴바 전용** — `LSUIElement`/`.accessory`라 Dock 아이콘은 뜨지 않습니다.

## 동작 방식

VSCode 확장과 같은 소스를 씁니다 (Swift로 이식):

- 사용률: `https://api.anthropic.com/api/oauth/usage`
- 토큰: `~/.claude/.credentials.json` → 없으면 macOS 키체인
- 현재 모델: `~/.claude/projects/**/*.jsonl` 중 가장 최근 트랜스크립트의 마지막 `message.model`

## 빌드 & 실행

```bash
# 1) 더블클릭 가능한 .app 만들기 (권장)
./build-app.sh
open ./ClaudeUsageMenuBar.app          # 또는 Finder에서 더블클릭

# 2) 터미널에서 바로 실행
swift build -c release
./.build/release/ClaudeUsageMenuBar

# 값 한 번만 확인 (메뉴바 없이)
./.build/release/ClaudeUsageMenuBar --once
```

종료는 메뉴바 아이콘 클릭 → `종료` (또는 `pkill -f ClaudeUsageMenuBar`).

## 설정 / 미세조정

2줄 표시는 메뉴바 높이에 맞춰 이미지로 그립니다. 옆 항목과 줄 위치가 안 맞으면 아래 값으로 조정하세요.

| 항목 | 환경변수 | `defaults` 키 | 기본 |
|---|---|---|---|
| 갱신 주기(초) | `CLAUDE_USAGE_INTERVAL` | `Interval` | 300 |
| 글자 크기 | `CLAUDE_USAGE_FONT_SIZE` | `FontSize` | 9 |
| 글자 굵기 | `CLAUDE_USAGE_FONT_WEIGHT` | `FontWeight` | 0.4 (bold) |
| 두 줄 간격(중심거리) | `CLAUDE_USAGE_LINE_GAP` | `LineGap` | 10 |
| 전체 세로 이동(+위/−아래) | `CLAUDE_USAGE_Y_OFFSET` | `YOffset` | 0 |

**터미널 실행 시** — 환경변수:
```bash
CLAUDE_USAGE_LINE_GAP=12 CLAUDE_USAGE_FONT_SIZE=9 ./.build/release/ClaudeUsageMenuBar
```

**더블클릭한 .app** (환경변수가 안 먹으므로 `defaults` 사용):
```bash
defaults write com.wemeet.claude-usage-menubar LineGap 12
defaults write com.wemeet.claude-usage-menubar FontSize 9
# 적용: 앱 종료 후 다시 실행
```

표시 모양만 PNG로 미리 확인:
```bash
CLAUDE_USAGE_LINE_GAP=12 ./.build/release/ClaudeUsageMenuBar --render /tmp/preview.png
open /tmp/preview.png
```

## 요구 사항

macOS 13+, Swift 6 / Xcode 커맨드라인 툴.
