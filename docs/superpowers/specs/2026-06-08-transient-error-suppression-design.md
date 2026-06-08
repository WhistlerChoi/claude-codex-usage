# 일시적 갱신 에러 숨김 (백오프 재시도 + 나이 기반 stale)

- 날짜: 2026-06-08
- 대상: `src/` (source of truth), `tray-go/`, `menubar/` — 세 구현 모두 동일 로직 미러링

## 문제

갱신(usage API 폴링)이 한 번이라도 실패하면 — 예: `HTTP 429`, 일시적 네트워크 오류 — 직전 성공 값이 있어도 **즉시** 회색 처리 + `⚠ 갱신 실패 — 이전 값 표시 중`으로 전환된다. 재시도가 전혀 없고(정규 5분 주기로만 재시도), 짧은 차질에도 유저에게 곧바로 에러를 노출한다.

현재 동작 위치:
- `src/extension.ts` `refresh()` catch 블록 (40–52행)
- `menubar/Sources/ClaudeUsageMenuBar/main.swift` `renderError()` (107–123행)
- `tray-go/main.go` poll 실패 분기 (84–94행), `applyUsage(..., stale)` (128행~)

세 구현 모두 동일 패턴: 고정 주기(`time.NewTicker` / `setInterval` / 반복 `Timer`) 폴링 → 일시적 에러 + `lastUsage` 있으면 즉시 stale 표시.

## 목표

- 짧은 차질(일시적 에러)은 유저에게 **완전히 숨긴다**: 백오프로 빠르게 재시도하고, 그동안 화면은 마지막 성공 값을 아무 표시 변화 없이 유지한다.
- 지속적 장애만 ⚠로 노출한다: 마지막 성공 값이 일정 시간 이상 오래되면 그때 stale 표시로 전환.
- 인증/자격증명 에러는 기존대로 즉시 로그인 상태로 전환(숨기지 않는다).

## 설계

### 1. Self-scheduling 폴링 루프

고정 주기 타이머를 **결과에 따라 다음 실행을 스스로 예약**하는 1회성 타이머 루프로 교체한다. "재시도"와 "정규 폴링"을 하나의 메커니즘으로 통합한다.

매 갱신(`refresh`/`poll`) 종료 후, 결과에 따라 다음 실행을 예약:

| 결과 | 다음 실행 지연 |
|---|---|
| 성공 | `interval` (기본 300s) — `consecutiveFailures = 0` 리셋 |
| 일시적 실패 (네트워크 / 5xx / 429) | `nextRetryDelay(consecutiveFailures, interval, retryAfter)` |
| 인증/자격증명 에러 | `interval` (재시도해도 의미 없음) |

백오프 스텝: `10s → 30s → 60s → … `, 최대 `interval`로 cap. 429 응답에 `Retry-After` 헤더가 있으면 그 값을 사용(역시 `interval`로 cap). 백오프가 `interval`에 도달하면 사실상 정규 폴링으로 수렴 → 지속 장애 시 5분마다 폴링하며 `age`가 누적된다.

### 2. 상태 추가

각 구현에 다음 상태 추가:
- `lastSuccessAt` — 마지막 성공 시각 (없으면 null)
- `consecutiveFailures` — 연속 일시적 실패 횟수 (성공 시 0)

`lastUsage` / `lastModel`은 기존대로 유지.

### 3. 표시 로직 (나이 기반)

일시적 에러 발생 시 `age = now - lastSuccessAt`로 판단:

| 조건 | 표시 |
|---|---|
| 일시적 에러 + `lastUsage` 있음 + `age < staleThreshold` | **이전 값 그대로, 표시 변화 없음** (회색/⚠ 없음) ← 핵심 변경 |
| 일시적 에러 + `lastUsage` 있음 + `age ≥ staleThreshold` | 회색 + `⚠ 갱신 실패 — 이전 값 표시 중` (기존) |
| 일시적 에러 + `lastUsage` 없음 | 에러 표시 (기존) |
| 인증/자격증명 에러 | 로그인 필요 (기존) |

`staleThreshold = interval × 3` (기본 15분).

핵심: 일시적 에러여도 `age`가 임계값 미만이면 **렌더링을 건드리지 않는다**(직전 성공 렌더를 그대로 둔다). 짧은 차질 동안 메뉴바/상태바는 마지막 정상 값을 평소처럼 보여준다.

### 4. 순수 함수 + 테스트

계산 로직을 `format` 모듈(테스트 대상)에 순수 함수로 추가하고 세 포트에 동등 로직으로 미러링:

```
nextRetryDelay(consecutiveFailures, intervalMs, retryAfterMs?) -> ms
  - retryAfterMs가 주어지면 min(retryAfterMs, intervalMs)
  - 아니면 min(intervalMs, base * 2^(consecutiveFailures-1)), base = 10s
    (consecutiveFailures: 1→10s, 2→20s, 3→40s, 4→80s, … cap intervalMs)

shouldShowStale(ageMs, intervalMs) -> bool
  - ageMs >= intervalMs * 3
```

> 참고: 본문 표의 "10/30/60s"는 개념 예시이며, 구현은 위 지수 백오프(base 10s, ×2, cap=interval)를 사용한다. `lastSuccessAt`이 없을 때(앱 시작 후 성공 이력 없음) `age`는 무한대로 간주 → `shouldShowStale`은 true. 단, 이 경우는 보통 `lastUsage`도 없어 "에러 표시" 분기로 빠진다.

`Retry-After` 파싱: 정수 초(delta-seconds)만 우선 지원. HTTP-date 형식은 best-effort(파싱 실패 시 헤더 없는 것으로 간주, 일반 백오프 사용).

`src/format.test.ts`에 단위 테스트 추가:
- `nextRetryDelay`: 실패 횟수별 증가, interval cap, retryAfter 우선/cap
- `shouldShowStale`: 경계값(< 3×interval false, ≥ true)

Go(`format_test.go` 또는 기존 테스트 파일)와 Swift에도 동등 테스트 추가.

### 5. 포트별 적용 지점

**`src/extension.ts`** (source of truth)
- `setInterval` → `scheduleNext(delayMs)`: 기존 타이머 clear 후 `setTimeout` 1회성 예약.
- `refresh()`의 `finally`에서 결과(성공/일시적실패/인증실패)에 따라 `scheduleNext(...)` 호출.
- 상태 `lastSuccessAt`, `consecutiveFailures` 추가. 성공 시 `lastSuccessAt = Date.now()`, `consecutiveFailures = 0`. 일시적 실패 시 `consecutiveFailures++`.
- catch 분기: `lastUsage` 있고 일시적 에러면 `shouldShowStale(now - lastSuccessAt, intervalMs)`로 무표시 vs stale 결정. **무표시면 렌더 함수를 호출하지 않는다(no-op)** — 직전 정상 렌더를 그대로 둔다. 재렌더하지 않는 쪽으로 통일(세 포트 동일).
- 429 응답에서 `Retry-After` 추출: `usageClient.fetchUsage`가 일시적 에러를 던질 때 retryAfter 정보를 함께 전달해야 한다 → 일시적 에러용 에러 타입(예: `TransientError { retryAfterMs? }`) 도입 또는 에러 객체에 필드 부착.
- 수동 새로고침 커맨드(`claudeUsage.refresh`): `showLoading()` 후 `refresh()` → finally에서 재예약되므로 별도 처리 불필요(단, 진행 중 중복 예약 방지를 위해 `scheduleNext`는 항상 기존 타이머 clear).

**`tray-go/main.go`**
- `time.NewTicker` → 리셋 가능한 타이머 루프: `for { select { case <-timer.C: ...; case <-manualRefresh: ... } }`, poll 결과로 `timer.Reset(nextDelay)`.
- `poll()`이 다음 지연을 반환하거나 전역 상태 갱신 후 호출부에서 `nextRetryDelay` 계산.
- `lastSuccessAt`, `consecutiveFailures` 추가. `fetchUsage`가 429의 `Retry-After`를 일시적 에러에 실어 전달.
- `applyUsage(..., stale)` 호출 전 `shouldShowStale`로 판단; 무표시면 렌더 갱신 생략.

**`menubar/Sources/ClaudeUsageMenuBar/main.swift`**
- `Timer.scheduledTimer(repeats: true)` → 매 갱신 후 `scheduleNext(_ delay:)`로 1회성 `Timer` 재예약.
- `refresh()` 완료(MainActor) 시 결과에 따라 재예약.
- `lastSuccessAt`, `consecutiveFailures` 프로퍼티 추가.
- `renderError(_:)`에 나이 판단 추가: 일시적 에러 + `lastUsage` 있음 + `age < staleThreshold`면 **렌더 갱신 생략**(직전 표시 유지).
- `UsageClient.swift`의 `fetchUsage`가 429 `Retry-After`를 `UsageError`에 실어 전달.

### 6. 에러 분류 명확화

세 구현 모두 "일시적 에러"의 정의를 통일:
- 네트워크/연결 오류 (fetch throw, URLSession error 등)
- HTTP 5xx
- HTTP 429 (Retry-After 동반 가능)

"일시적 아님" = 인증(401/403) / 자격증명 없음 → 기존 즉시 로그인 분기.
기타 4xx(429 제외)는 일시적으로 간주(서버 측 변동 가능)하되, `lastUsage` 없으면 에러 표시로 귀결.

## 비목표 (YAGNI)

- 백오프 스텝/임계값을 사용자 설정으로 노출하지 않는다(코드 상수 또는 interval 파생). VSCode도 신규 설정 추가 없음.
- `Retry-After` HTTP-date 형식 완전 지원은 하지 않는다(정수 초만 확실히 지원, 나머지 best-effort).
- 영구 저장(앱 재시작 간 lastSuccessAt 보존) 없음 — 인메모리.

## 테스트 / 검증

- `npm test`로 `format.test.ts` 단위 테스트 통과.
- `menubar`: `--once`로 정상 경로 회귀 확인, `swift build -c release` 통과.
- `tray-go`: `go test ./...`, `go run .`.
- 수동: 네트워크 차단(또는 토큰을 잠깐 무효화하지 않고 엔드포인트 차단)으로 일시적 에러 유발 시 메뉴바가 즉시 ⚠로 바뀌지 않고 이전 값을 유지하는지, 장시간(>15분) 차단 시 ⚠로 전환되는지 확인.
