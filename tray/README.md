# Claude Usage — 트레이 앱 (Windows / macOS)

Claude Code 사용량을 **시스템 트레이(Windows 알림 영역)**에 표시하는 Electron 앱입니다.
VSCode 확장의 코어 로직(`../src`의 `usageClient`·`credentials`·`model`·`format`)을 그대로 재사용합니다.

## 표시 방식 (Windows 트레이 특성)

Windows 트레이는 macOS 메뉴바와 달리 **아이콘**이 기본입니다:

- **아이콘**: 5시간 사용률 숫자를 색상 배지로 (`42`) — 파랑(정상) / 주황(80%↑) / 빨강(95%↑)
- **마우스 호버 → 툴팁**: 5시간·주간·Opus/Sonnet·현재 모델·리셋까지 시간 전체
- **우클릭 메뉴**: 상세 + `지금 새로고침` / `종료`

## 동작 방식

- 사용률: `https://api.anthropic.com/api/oauth/usage`
- 토큰: `%USERPROFILE%\.claude\.credentials.json` (Windows는 키체인이 없어 파일 사용 — 코어가 이미 파일 우선)
- 현재 모델: `%USERPROFILE%\.claude\projects\**\*.jsonl` 중 최신 트랜스크립트의 마지막 `message.model`

## 빌드 / 실행 (Windows에서)

```powershell
cd tray
npm install
npm run build          # dist/main.js 번들
npm start              # 바로 실행 (트레이에 아이콘 표시)

# 배포용 단일 실행파일(.exe) 만들기
npm run dist:win       # electron-builder, portable .exe 생성 → dist/
```

> macOS에서도 `npm start`로 동작 확인 가능(트레이가 메뉴바에 표시됩니다). 단, 작업표시줄 테마 등 Windows 고유 모양은 Windows에서 확인하세요.

## 설정

- 갱신 주기: 환경변수 `CLAUDE_USAGE_INTERVAL`(초, 기본 300, 최소 10)
  ```powershell
  $env:CLAUDE_USAGE_INTERVAL=60; npm start
  ```

## 요구 사항

Node 18+, (배포 시) Windows x64. Electron 30.
