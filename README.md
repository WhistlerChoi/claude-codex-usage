# Claude Code Usage (VSCode 확장)

Claude Code의 **5시간 / 주간 사용률**을 VSCode 상태바에 항상 표시합니다.

![상태바 예시](https://img.shields.io/badge/status%20bar-5h%2042%25%20%C2%B7%20wk%208%25-blue)

## 기능

- 상태바에 `5h 42% · wk 8% · Opus 4.8` 형태로 사용률 + 현재 모델 표시
- 현재 모델은 가장 최근 세션 트랜스크립트(`~/.claude/projects/**/*.jsonl`)에서 읽음
- 마우스를 올리면 상세 툴팁: 각 윈도우 리셋까지 남은 시간, 주간 Opus/Sonnet 분리, 현재 모델 ID, 마지막 갱신 시각
- 사용률이 높으면 상태바 색상 경고(노랑) / 위험(빨강)
- 갱신 주기, 경고/위험 임계값을 설정에서 조정
- 상태바 클릭 시 즉시 새로고침

## 동작 방식

`/usage` 명령이 쓰는 것과 동일한 엔드포인트
(`https://api.anthropic.com/api/oauth/usage`)를 호출합니다. 별도 로그인이
필요 없으며, Claude Code에 로그인되어 있으면 바로 동작합니다.

인증 토큰을 읽는 위치(OS 공통, 자동 판별):

- **Windows / Linux**: `~/.claude/.credentials.json`
- **macOS**: 위 파일이 있으면 사용, 없으면 키체인 항목 `Claude Code-credentials`

## 설정

| 설정 | 기본값 | 설명 |
|---|---|---|
| `claudeUsage.refreshInterval` | `300` | 갱신 주기(초), 최소 10 |
| `claudeUsage.warnThreshold` | `0.8` | 경고색 임계 사용률 (0~1) |
| `claudeUsage.alertThreshold` | `0.95` | 위험색 임계 사용률 (0~1) |

## 개발 / 빌드

```bash
npm install
npm test          # 단위 테스트
npm run package   # dist/extension.js 번들 생성
npx @vscode/vsce package   # .vsix 생성
```

디버깅: VSCode에서 이 폴더를 열고 `F5`(Extension Development Host).

설치: `code --install-extension claude-usage-0.1.0.vsix`
