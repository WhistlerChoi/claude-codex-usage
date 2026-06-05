# claude-usage VSCode 확장 — 설계

## 목적
Claude Code의 5시간/주간 사용률을 VSCode 상태바에 항상 표시하고, 호버 시 상세를 보여준다. macOS 전용.

## 데이터 소스
`GET https://api.anthropic.com/api/oauth/usage`
- 헤더: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`
- accessToken은 macOS 키체인 항목 `Claude Code-credentials`의 `claudeAiOauth.accessToken`
- 응답: `five_hour.{utilization,resets_at}`, `seven_day.{...}`, `seven_day_opus`, `seven_day_sonnet` (utilization은 0.0~1.0)

## 컴포넌트
| 파일 | 책임 |
|---|---|
| `src/credentials.ts` | 키체인에서 accessToken 읽기 (`security find-generic-password`) |
| `src/usageClient.ts` | usage API 호출 → `UsageData` 반환, 401/네트워크 에러 구분 |
| `src/format.ts` | 순수 함수: 상태바 문자열·툴팁 Markdown·상대시간 포맷 (단위 테스트 대상) |
| `src/statusBar.ts` | StatusBarItem 렌더링 + 색상 임계값 |
| `src/extension.ts` | activate/deactivate, 폴링 루프, 설정/명령 등록 |

## 표시
- 상태바: `$(pulse) 5h 42% · wk 8%`, 80%↑ 경고색, 95%↑ 에러색
- 호버 툴팁: 5시간/주간 사용률 + 리셋까지 남은 시간, Opus/Sonnet(값 있을 때), 마지막 갱신 시각

## 설정
- `claudeUsage.refreshInterval` (초, 기본 300)
- `claudeUsage.warnThreshold` (기본 0.8)
- `claudeUsage.alertThreshold` (기본 0.95)

## 명령
- `claudeUsage.refresh` — 즉시 새로고침 (상태바 클릭에 연결)

## 에러 처리
- 키체인 없음 / 401 → `$(error) Claude 로그인 필요`
- 네트워크 실패 → 마지막 값 유지 + 툴팁에 갱신 실패 표기

## 범위 제외 (YAGNI)
토큰 사용량 집계, 그래프/히스토리, Windows/Linux, 다계정, 마켓플레이스 게시.

## 빌드
TypeScript + esbuild. `vsce package`로 `.vsix` 생성 후 로컬 설치.
