# 일시적 갱신 에러 숨김 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 일시적 갱신 에러(네트워크/5xx/429)를 짧은 백오프로 재시도하고, 그동안 마지막 성공 값을 표시 변화 없이 유지하다가, 마지막 성공이 충분히 오래된 경우에만 ⚠ stale을 노출한다.

**Architecture:** 고정 주기 타이머를 결과에 따라 다음 실행을 스스로 예약하는 1회성 타이머 루프로 교체한다. 두 개의 순수 함수 `nextRetryDelay`(다음 지연 계산: 지수 백오프, base 10s, ×2, interval cap, 429 `Retry-After` 우선) / `shouldShowStale`(`age ≥ interval×3`)를 도입해 세 포트에 미러링한다. 표시는 나이(`now - lastSuccessAt`) 기반으로 결정한다.

**Tech Stack:** TypeScript + esbuild (`src/`, source of truth, node:test), Go `getlantern/systray` (`tray-go/`), Swift/AppKit (`menubar/`).

**참고 spec:** `docs/superpowers/specs/2026-06-08-transient-error-suppression-design.md`

---

## File Structure

- **`src/format.ts`** — 순수 함수 `nextRetryDelayMs`, `shouldShowStale` 추가. **`src/format.test.ts`** — 단위 테스트(캐노니컬).
- **`src/usageClient.ts`** — `TransientError`(retryAfterMs 포함) 도입, 429 `Retry-After` 파싱(`parseRetryAfterMs`).
- **`src/extension.ts`** — self-scheduling 폴링, `lastSuccessAt`/`consecutiveFailures` 상태, 나이 기반 표시.
- **`tray-go/format.go`** — `nextRetryDelay`, `shouldShowStale`. **`tray-go/format_test.go`** — 신규 테스트 파일.
- **`tray-go/usage.go`** — `transientError`(retryAfter), 429 파싱.
- **`tray-go/main.go`** — resettable timer 루프, 상태, 나이 기반 표시.
- **`menubar/.../Format.swift`** — `nextRetryDelay`, `shouldShowStale`.
- **`menubar/.../UsageClient.swift`** — `UsageError.rateLimited(retryAfter:)`, 429 파싱.
- **`menubar/.../main.swift`** — self-scheduling `Timer`, 상태, 나이 기반 표시.

> **테스트 범위:** 캐노니컬 단위 테스트는 `src/`(기존 node:test 인프라)에 둔다. Go는 `go test`가 무설정으로 동작하므로 `format_test.go`를 추가한다. Swift는 테스트 타깃이 없어(신규 인프라 도입은 YAGNI) 순수 함수를 미러링만 하고 `swift build` + `--once`로 회귀 확인한다.

> **백오프 수열(확정):** failures 1→10s, 2→20s, 3→40s, 4→80s, … 각 단계 `interval`(기본 300s)로 cap. 429 `Retry-After`(정수 초)가 있으면 `min(retryAfter, interval)` 우선. `staleThreshold = interval × 3`(기본 900s/15분).

---

## Task 1: `src/format.ts` — 순수 함수 + 테스트 (TDD)

**Files:**
- Modify: `src/format.ts`
- Test: `src/format.test.ts`

- [ ] **Step 1: 실패 테스트 작성** — `src/format.test.ts` 끝에 추가. 파일 상단 import에 `nextRetryDelayMs, shouldShowStale`를 추가한다(기존 `import { pct, statusBarText, formatResetIn, peakUtilization, tooltipMarkdown } from "./format";` → 두 이름 추가).

```ts
test("nextRetryDelayMs: 지수 백오프, base 10s, ×2", () => {
  const interval = 300_000;
  assert.equal(nextRetryDelayMs(1, interval), 10_000);
  assert.equal(nextRetryDelayMs(2, interval), 20_000);
  assert.equal(nextRetryDelayMs(3, interval), 40_000);
  assert.equal(nextRetryDelayMs(4, interval), 80_000);
});

test("nextRetryDelayMs: interval로 cap", () => {
  const interval = 300_000;
  assert.equal(nextRetryDelayMs(6, interval), 300_000); // 10s*2^5=320s > 300s
  assert.equal(nextRetryDelayMs(99, interval), 300_000);
});

test("nextRetryDelayMs: retryAfter 우선, interval로 cap", () => {
  const interval = 300_000;
  assert.equal(nextRetryDelayMs(1, interval, 45_000), 45_000);
  assert.equal(nextRetryDelayMs(1, interval, 600_000), 300_000);
  assert.equal(nextRetryDelayMs(1, interval, 0), 10_000); // 0이면 무시하고 백오프
});

test("shouldShowStale: age >= interval*3", () => {
  const interval = 300_000;
  assert.equal(shouldShowStale(899_000, interval), false);
  assert.equal(shouldShowStale(900_000, interval), true);
  assert.equal(shouldShowStale(0, interval), false);
});
```

- [ ] **Step 2: 실패 확인**

Run: `node --test --import tsx ./src/format.test.ts`
Expected: FAIL — `nextRetryDelayMs is not a function` / import 에러.

- [ ] **Step 3: 구현** — `src/format.ts` 끝에 추가.

```ts
/**
 * 일시적 실패 후 다음 폴링까지의 지연(ms).
 * retryAfterMs가 주어지면 그 값을 interval로 cap. 아니면 지수 백오프(base 10s, ×2)를 interval로 cap.
 */
export function nextRetryDelayMs(
  consecutiveFailures: number,
  intervalMs: number,
  retryAfterMs?: number
): number {
  if (retryAfterMs != null && retryAfterMs > 0) {
    return Math.min(retryAfterMs, intervalMs);
  }
  const base = 10_000;
  const exp = base * 2 ** Math.max(0, consecutiveFailures - 1);
  return Math.min(exp, intervalMs);
}

/** 마지막 성공으로부터 ageMs가 interval*3 이상이면 stale로 표시. */
export function shouldShowStale(ageMs: number, intervalMs: number): boolean {
  return ageMs >= intervalMs * 3;
}
```

- [ ] **Step 4: 통과 확인**

Run: `node --test --import tsx ./src/format.test.ts`
Expected: PASS (전체 테스트 통과).

- [ ] **Step 5: 커밋**

```bash
git add src/format.ts src/format.test.ts
git commit -m "feat(format): nextRetryDelayMs/shouldShowStale 순수 함수 + 테스트"
```

---

## Task 2: `src/usageClient.ts` — TransientError + Retry-After 파싱

**Files:**
- Modify: `src/usageClient.ts`
- Test: `src/format.test.ts` (parseRetryAfterMs 검증)

- [ ] **Step 1: 실패 테스트 작성** — `src/format.test.ts`에 추가. 상단에 `import { parseRetryAfterMs } from "./usageClient";`를 추가(기존 `import { parseUsage, type UsageData } from "./usageClient";`와 합쳐도 됨).

```ts
test("parseRetryAfterMs: 정수 초를 ms로", () => {
  assert.equal(parseRetryAfterMs("30"), 30_000);
  assert.equal(parseRetryAfterMs("0"), 0);
});

test("parseRetryAfterMs: 없음/비정수는 undefined", () => {
  assert.equal(parseRetryAfterMs(null), undefined);
  assert.equal(parseRetryAfterMs("Wed, 21 Oct 2025 07:28:00 GMT"), undefined);
  assert.equal(parseRetryAfterMs("abc"), undefined);
});
```

- [ ] **Step 2: 실패 확인**

Run: `node --test --import tsx ./src/format.test.ts`
Expected: FAIL — `parseRetryAfterMs is not a function`.

- [ ] **Step 3: 구현** — `src/usageClient.ts` 수정. `AuthError` 정의 아래에 추가:

```ts
/** 네트워크/5xx/429 등 재시도 가능한 일시적 오류. */
export class TransientError extends Error {
  readonly retryAfterMs?: number;
  constructor(message: string, retryAfterMs?: number) {
    super(message);
    this.retryAfterMs = retryAfterMs;
  }
}

/** Retry-After 헤더(정수 초)를 ms로. 없거나 HTTP-date 등 비정수면 undefined. */
export function parseRetryAfterMs(header: string | null): number | undefined {
  if (header == null) return undefined;
  const trimmed = header.trim();
  if (!/^\d+$/.test(trimmed)) return undefined;
  return parseInt(trimmed, 10) * 1000;
}
```

그리고 `fetchUsage`의 에러 분기를 교체:

```ts
  if (res.status === 401 || res.status === 403) {
    throw new AuthError("인증이 만료되었습니다. Claude Code에서 재로그인하세요.");
  }
  if (res.status === 429) {
    throw new TransientError(
      `usage API 오류: HTTP 429`,
      parseRetryAfterMs(res.headers.get("retry-after"))
    );
  }
  if (!res.ok) {
    throw new TransientError(`usage API 오류: HTTP ${res.status}`);
  }
```

- [ ] **Step 4: 통과 확인**

Run: `node --test --import tsx ./src/format.test.ts`
Expected: PASS.

- [ ] **Step 5: 커밋**

```bash
git add src/usageClient.ts src/format.test.ts
git commit -m "feat(usageClient): TransientError + Retry-After 파싱"
```

---

## Task 3: `src/extension.ts` — self-scheduling 폴링 + 나이 기반 표시

**Files:**
- Modify: `src/extension.ts`

> 단위 테스트 없음(VSCode API 의존). `npm run compile` 타입체크 + 빌드로 검증.

- [ ] **Step 1: import/상태 갱신** — 파일 상단 import와 모듈 상태를 교체.

```ts
import * as vscode from "vscode";
import { fetchUsage, AuthError, TransientError, type UsageData } from "./usageClient";
import { CredentialsError } from "./credentials";
import { readCurrentModel, type CurrentModel } from "./model";
import { UsageStatusBar, type Thresholds } from "./statusBar";
import { nextRetryDelayMs, shouldShowStale } from "./format";

let statusBar: UsageStatusBar;
let timer: NodeJS.Timeout | undefined;
let lastUsage: UsageData | undefined;
let lastModel: CurrentModel | null = null;
let lastSuccessAt: number | undefined;
let consecutiveFailures = 0;
let inFlight = false;
```

- [ ] **Step 2: `scheduleNext` 추가 + `restartTimer` 제거** — `restartTimer` 함수를 삭제하고 다음으로 대체.

```ts
function scheduleNext(delayMs: number): void {
  if (timer) {
    clearTimeout(timer);
  }
  timer = setTimeout(() => void refresh(), delayMs);
}
```

- [ ] **Step 3: `refresh()` 교체** — 결과에 따라 다음 실행을 예약하고 나이 기반으로 표시.

```ts
async function refresh(): Promise<void> {
  if (inFlight) {
    return;
  }
  inFlight = true;
  const { intervalMs, thresholds } = readConfig();
  let nextDelayMs = intervalMs;
  try {
    const [usage, model] = await Promise.all([
      fetchUsage(),
      readCurrentModel().catch(() => null),
    ]);
    lastUsage = usage;
    lastModel = model;
    lastSuccessAt = Date.now();
    consecutiveFailures = 0;
    statusBar.showUsage(usage, new Date(), thresholds, false, model);
  } catch (err) {
    if (err instanceof AuthError || err instanceof CredentialsError) {
      statusBar.showError(err.message);
      // 인증 오류는 백오프하지 않고 정규 주기로
    } else {
      // 일시적 오류: 백오프 재시도
      consecutiveFailures += 1;
      const retryAfterMs =
        err instanceof TransientError ? err.retryAfterMs : undefined;
      nextDelayMs = nextRetryDelayMs(consecutiveFailures, intervalMs, retryAfterMs);
      const ageMs = lastSuccessAt != null ? Date.now() - lastSuccessAt : Infinity;
      if (lastUsage && !shouldShowStale(ageMs, intervalMs)) {
        // 아직 신선함 → 표시 변화 없음(직전 정상 렌더 유지, no-op)
      } else if (lastUsage) {
        statusBar.showUsage(lastUsage, new Date(), thresholds, true, lastModel);
      } else {
        const msg = err instanceof Error ? err.message : String(err);
        statusBar.showError(msg);
      }
    }
  } finally {
    inFlight = false;
    scheduleNext(nextDelayMs);
  }
}
```

- [ ] **Step 4: `readConfig` 반환에 intervalMs 유지 확인** — 기존 `readConfig`는 이미 `{ intervalMs, thresholds }`를 반환하므로 변경 불필요. (확인만.)

- [ ] **Step 5: `activate`/`deactivate` 갱신** — `restartTimer()` 호출 제거.

```ts
export function activate(context: vscode.ExtensionContext): void {
  statusBar = new UsageStatusBar();
  context.subscriptions.push({ dispose: () => statusBar.dispose() });

  context.subscriptions.push(
    vscode.commands.registerCommand("claudeUsage.refresh", () => {
      statusBar.showLoading();
      void refresh();
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("claudeUsage")) {
        void refresh();
      }
    })
  );

  void refresh();
}

export function deactivate(): void {
  if (timer) {
    clearTimeout(timer);
    timer = undefined;
  }
}
```

- [ ] **Step 6: 빌드/타입체크**

Run: `npm run compile`
Expected: 에러 없이 `dist/extension.js` 생성. 그리고 `node --test --import tsx ./src/*.test.ts` 전체 PASS.

- [ ] **Step 7: 커밋**

```bash
git add src/extension.ts
git commit -m "feat(extension): self-scheduling 폴링 + 나이 기반 stale 표시"
```

---

## Task 4: `tray-go/format.go` — 순수 함수 + 테스트

**Files:**
- Modify: `tray-go/format.go`
- Create: `tray-go/format_test.go`

- [ ] **Step 1: 실패 테스트 작성** — `tray-go/format_test.go` 생성.

```go
package main

import (
	"testing"
	"time"
)

func TestNextRetryDelay(t *testing.T) {
	interval := 300 * time.Second
	cases := []struct {
		failures int
		want     time.Duration
	}{
		{1, 10 * time.Second},
		{2, 20 * time.Second},
		{3, 40 * time.Second},
		{4, 80 * time.Second},
		{6, 300 * time.Second}, // 320s > 300s -> cap
		{99, 300 * time.Second},
	}
	for _, c := range cases {
		if got := nextRetryDelay(c.failures, interval, 0); got != c.want {
			t.Errorf("nextRetryDelay(%d)=%v want %v", c.failures, got, c.want)
		}
	}
	if got := nextRetryDelay(1, interval, 45*time.Second); got != 45*time.Second {
		t.Errorf("retryAfter 우선 실패: %v", got)
	}
	if got := nextRetryDelay(1, interval, 600*time.Second); got != interval {
		t.Errorf("retryAfter cap 실패: %v", got)
	}
}

func TestShouldShowStale(t *testing.T) {
	interval := 300 * time.Second
	if shouldShowStale(899*time.Second, interval) {
		t.Error("899s는 stale 아님")
	}
	if !shouldShowStale(900*time.Second, interval) {
		t.Error("900s는 stale")
	}
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd tray-go && go test ./...`
Expected: FAIL — `undefined: nextRetryDelay` / `undefined: shouldShowStale`.

- [ ] **Step 3: 구현** — `tray-go/format.go` 끝에 추가. (상단 import에 `"time"` 이미 존재 — 추가 불필요.)

```go
// nextRetryDelay: 일시적 실패 후 다음 폴링까지 지연.
// retryAfter>0이면 그 값을 interval로 cap, 아니면 지수 백오프(base 10s, ×2)를 interval로 cap.
func nextRetryDelay(consecutiveFailures int, interval, retryAfter time.Duration) time.Duration {
	if retryAfter > 0 {
		if retryAfter > interval {
			return interval
		}
		return retryAfter
	}
	exp := 10 * time.Second
	for i := 1; i < consecutiveFailures; i++ {
		exp *= 2
		if exp >= interval {
			return interval
		}
	}
	if exp > interval {
		return interval
	}
	return exp
}

// shouldShowStale: 마지막 성공으로부터 age가 interval*3 이상이면 stale.
func shouldShowStale(age, interval time.Duration) bool {
	return age >= interval*3
}
```

- [ ] **Step 4: 통과 확인**

Run: `cd tray-go && go test ./...`
Expected: PASS.

- [ ] **Step 5: 커밋**

```bash
git add tray-go/format.go tray-go/format_test.go
git commit -m "feat(tray-go/format): nextRetryDelay/shouldShowStale + 테스트"
```

---

## Task 5: `tray-go/usage.go` — transientError + Retry-After

**Files:**
- Modify: `tray-go/usage.go`

- [ ] **Step 1: transientError 타입 + 추출 헬퍼 추가** — `errAuth` 선언 아래에 추가. 상단 import에 `"strconv"`, `"time"`은 이미 있음(time 있음, strconv 추가 필요).

```go
// transientError: 네트워크/5xx/429 등 재시도 가능한 오류. retryAfter는 429 Retry-After(초).
type transientError struct {
	msg        string
	retryAfter time.Duration
}

func (e *transientError) Error() string { return e.msg }

// retryAfterFrom: err가 transientError면 그 retryAfter, 아니면 0.
func retryAfterFrom(err error) time.Duration {
	var te *transientError
	if errors.As(err, &te) {
		return te.retryAfter
	}
	return 0
}

// parseRetryAfter: 정수 초 헤더를 Duration으로. 비정수/빈값은 0.
func parseRetryAfter(h string) time.Duration {
	if n, err := strconv.Atoi(h); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	return 0
}
```

- [ ] **Step 2: HTTP 에러 분기 교체** — `fetchUsage`의 status 분기를 교체.

```go
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return nil, errAuth
	}
	if resp.StatusCode == 429 {
		return nil, &transientError{
			msg:        "usage API 오류: HTTP 429",
			retryAfter: parseRetryAfter(resp.Header.Get("Retry-After")),
		}
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, &transientError{msg: fmt.Sprintf("usage API 오류: HTTP %d", resp.StatusCode)}
	}
```

- [ ] **Step 3: import 추가 확인** — 파일 상단 import 블록에 `"strconv"` 추가(없으면). `"errors"`, `"fmt"`, `"time"`은 이미 존재.

- [ ] **Step 4: 빌드 확인**

Run: `cd tray-go && go build ./... && go test ./...`
Expected: 에러 없음, 테스트 PASS.

- [ ] **Step 5: 커밋**

```bash
git add tray-go/usage.go
git commit -m "feat(tray-go/usage): transientError + Retry-After 파싱"
```

---

## Task 6: `tray-go/main.go` — resettable timer 루프 + 나이 기반 표시

**Files:**
- Modify: `tray-go/main.go`

- [ ] **Step 1: 상태 + 수동 새로고침 채널 추가** — `var (...)` 블록을 갱신.

```go
var (
	detailItems     []*systray.MenuItem
	mRefresh, mQuit *systray.MenuItem
	lastUsage       *usageResp
	lastModel       *currentModel
	lastSuccessAt   time.Time
	consecutiveFailures int
	manualRefresh   = make(chan struct{}, 1)
)
```

- [ ] **Step 2: 수동 클릭을 채널로 라우팅** — `onReady`의 클릭 루프에서 `mRefresh` 케이스를 교체.

```go
			case <-mRefresh.ClickedCh:
				select {
				case manualRefresh <- struct{}{}:
				default:
				}
```

- [ ] **Step 3: `pollLoop` 교체** — ticker를 resettable timer 루프로.

```go
func pollLoop() {
	interval := 300
	if v := os.Getenv("CLAUDE_USAGE_INTERVAL"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 10 {
			interval = n
		}
	}
	intervalDur := time.Duration(interval) * time.Second

	delay := refresh(intervalDur)
	timer := time.NewTimer(delay)
	defer timer.Stop()
	for {
		select {
		case <-timer.C:
		case <-manualRefresh:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
		}
		timer.Reset(refresh(intervalDur))
	}
}
```

- [ ] **Step 4: `refresh` 교체** — 다음 지연을 반환하고 나이 기반으로 표시.

```go
func refresh(interval time.Duration) time.Duration {
	usage, err := fetchUsage()
	if err != nil {
		if errors.Is(err, errAuth) || errors.Is(err, errNoCreds) {
			applyError(err.Error())
			consecutiveFailures = 0
			return interval
		}
		// 일시적 오류: 백오프 재시도
		consecutiveFailures++
		age := time.Duration(1<<62) // lastSuccessAt 없으면 사실상 무한대
		if !lastSuccessAt.IsZero() {
			age = time.Since(lastSuccessAt)
		}
		if lastUsage != nil && !shouldShowStale(age, interval) {
			// 아직 신선함 → 표시 변화 없음(no-op)
		} else if lastUsage != nil {
			applyUsage(lastUsage, lastModel, true)
		} else {
			applyError(err.Error())
		}
		return nextRetryDelay(consecutiveFailures, interval, retryAfterFrom(err))
	}
	model, _ := readCurrentModel()
	lastUsage, lastModel = usage, model
	lastSuccessAt = time.Now()
	consecutiveFailures = 0
	applyUsage(usage, model, false)
	return interval
}
```

- [ ] **Step 5: 빌드/테스트**

Run: `cd tray-go && go build ./... && go test ./...`
Expected: 에러 없음, PASS. (`go vet ./...`도 통과해야 함.)

- [ ] **Step 6: 커밋**

```bash
git add tray-go/main.go
git commit -m "feat(tray-go): self-scheduling 폴링 루프 + 나이 기반 stale"
```

---

## Task 7: `menubar/.../Format.swift` — 순수 함수

**Files:**
- Modify: `menubar/Sources/ClaudeUsageMenuBar/Format.swift`

> Swift 테스트 타깃 없음. `swift build`로 컴파일 검증.

- [ ] **Step 1: 구현 추가** — `Format.swift` 끝에 추가. (파일 상단에 `import Foundation` 이미 존재 — `pow`/`TimeInterval` 사용 가능.)

```swift
/// 일시적 실패 후 다음 폴링까지 지연(초).
/// retryAfter가 있으면 interval로 cap, 아니면 지수 백오프(base 10s, ×2)를 interval로 cap.
func nextRetryDelay(_ consecutiveFailures: Int, _ interval: TimeInterval, _ retryAfter: TimeInterval?) -> TimeInterval {
    if let ra = retryAfter, ra > 0 {
        return min(ra, interval)
    }
    let base: TimeInterval = 10
    let exp = base * pow(2.0, Double(max(0, consecutiveFailures - 1)))
    return min(exp, interval)
}

/// 마지막 성공으로부터 age가 interval*3 이상이면 stale.
func shouldShowStale(_ age: TimeInterval, _ interval: TimeInterval) -> Bool {
    return age >= interval * 3
}
```

- [ ] **Step 2: 빌드 확인**

Run: `cd menubar && swift build -c release`
Expected: 컴파일 성공.

- [ ] **Step 3: 커밋**

```bash
git add menubar/Sources/ClaudeUsageMenuBar/Format.swift
git commit -m "feat(menubar/Format): nextRetryDelay/shouldShowStale"
```

---

## Task 8: `menubar/.../UsageClient.swift` — rateLimited + Retry-After

**Files:**
- Modify: `menubar/Sources/ClaudeUsageMenuBar/UsageClient.swift`

- [ ] **Step 1: `UsageError`에 rateLimited 추가** — enum과 errorDescription 교체.

```swift
enum UsageError: Error, LocalizedError {
    case auth
    case http(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case malformed
    var errorDescription: String? {
        switch self {
        case .auth: return "인증이 만료되었습니다. Claude Code에서 재로그인하세요."
        case .http(let c): return "usage API 오류: HTTP \(c)"
        case .rateLimited: return "usage API 오류: HTTP 429"
        case .malformed: return "usage 응답 형식 오류."
        }
    }
}
```

- [ ] **Step 2: 429 분기 추가** — `fetchUsage`의 상태 검사를 교체.

```swift
    if http.statusCode == 401 || http.statusCode == 403 {
        throw UsageError.auth
    }
    if http.statusCode == 429 {
        let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
        throw UsageError.rateLimited(retryAfter: ra.map { TimeInterval($0) })
    }
    guard (200..<300).contains(http.statusCode) else {
        throw UsageError.http(http.statusCode)
    }
```

- [ ] **Step 3: retryAfter 추출 헬퍼 추가** — `UsageError` 정의 아래에 자유 함수로 추가.

```swift
/// 에러에서 Retry-After(초)를 꺼낸다. rateLimited가 아니면 nil.
func retryAfter(from error: Error) -> TimeInterval? {
    if case UsageError.rateLimited(let ra) = error { return ra }
    return nil
}
```

- [ ] **Step 4: 빌드 확인**

Run: `cd menubar && swift build -c release`
Expected: 컴파일 성공.

- [ ] **Step 5: 커밋**

```bash
git add menubar/Sources/ClaudeUsageMenuBar/UsageClient.swift
git commit -m "feat(menubar/UsageClient): rateLimited + Retry-After 파싱"
```

---

## Task 9: `menubar/.../main.swift` — self-scheduling Timer + 나이 기반 표시

**Files:**
- Modify: `menubar/Sources/ClaudeUsageMenuBar/main.swift`

- [ ] **Step 1: 상태 프로퍼티 추가** — `AppDelegate`의 기존 상태 선언에 추가.

```swift
    private var lastUsage: UsageData?
    private var lastModel: CurrentModel?
    private var lastUpdated: Date?
    private var lastSuccessAt: Date?
    private var consecutiveFailures = 0
```

- [ ] **Step 2: 시작 시 반복 타이머 제거** — `applicationDidFinishLaunching`에서 `Timer.scheduledTimer(... repeats: true ...)` 블록을 삭제하고 `refresh()`만 남긴다(refresh가 스스로 다음을 예약).

```swift
        refresh()
```

- [ ] **Step 3: `scheduleNext` 추가** — `AppDelegate`에 메서드 추가(메인 스레드에서 호출됨).

```swift
    private func scheduleNext(_ delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }
```

- [ ] **Step 4: `refresh()` 교체** — 성공/실패 후 다음 실행을 예약.

```swift
    @objc func refresh() {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let usage = try await fetchUsage()
                let model = readCurrentModel()
                await MainActor.run {
                    self.renderUsage(usage, model)
                    self.lastSuccessAt = Date()
                    self.consecutiveFailures = 0
                    self.scheduleNext(self.interval)
                }
            } catch {
                await MainActor.run {
                    self.scheduleNext(self.handleError(error))
                }
            }
        }
    }
```

- [ ] **Step 5: `renderError` → `handleError` 교체** — 기존 `renderError(_:)`를 삭제하고 다음으로 대체(다음 지연을 반환).

```swift
    /// 에러 표시를 갱신하고 다음 폴링까지 지연(초)을 반환한다.
    private func handleError(_ error: Error) -> TimeInterval {
        if error is CredentialsError || isAuthError(error) {
            setStacked(top: "로그인", bottom: "필요", color: .systemRed)
            rebuildMenu(detailLines: [error.localizedDescription], showLogin: true)
            consecutiveFailures = 0
            return interval
        }
        // 일시적 오류: 백오프 재시도
        consecutiveFailures += 1
        let age = lastSuccessAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if let usage = lastUsage, !shouldShowStale(age, interval) {
            _ = usage  // 아직 신선함 → 표시 변화 없음(no-op)
        } else if let usage = lastUsage {
            setStacked(
                top: "\(pct(usage.fiveHour.utilization))%",
                bottom: "\(pct(usage.sevenDay.utilization))%",
                color: .systemGray
            )
            rebuildMenu(detailLines: [
                "⚠ 갱신 실패 — 이전 값 표시 중",
                error.localizedDescription,
            ])
        } else {
            setStacked(top: "로그인", bottom: "필요", color: .systemRed)
            rebuildMenu(detailLines: [error.localizedDescription], showLogin: true)
        }
        return nextRetryDelay(consecutiveFailures, interval, retryAfter(from: error))
    }
```

- [ ] **Step 6: 빌드 + 정상 경로 회귀**

Run: `cd menubar && swift build -c release && ./.build/release/ClaudeUsageMenuBar --once`
Expected: 컴파일 성공, `--once`가 현재 사용량 값을 정상 출력(에러 없으면 게이지/5시간/주간 출력).

- [ ] **Step 7: 커밋**

```bash
git add menubar/Sources/ClaudeUsageMenuBar/main.swift
git commit -m "feat(menubar): self-scheduling Timer + 나이 기반 stale"
```

---

## Task 10: 전체 검증

**Files:** 없음(검증만).

- [ ] **Step 1: src 전체 테스트**

Run: `npm test`
Expected: 전체 PASS.

- [ ] **Step 2: src 프로덕션 빌드**

Run: `npm run package`
Expected: 에러 없이 번들 생성.

- [ ] **Step 3: tray-go 빌드/테스트/vet**

Run: `cd tray-go && go build ./... && go test ./... && go vet ./...`
Expected: 모두 통과.

- [ ] **Step 4: menubar 빌드 + 1회 실행**

Run: `cd menubar && swift build -c release && ./.build/release/ClaudeUsageMenuBar --once`
Expected: 정상 값 출력.

- [ ] **Step 5: 수동 동작 확인(선택, 환경 가능 시)** — 네트워크를 잠깐 차단하거나 endpoint 도달을 막아 일시적 에러를 유발:
  - 메뉴바가 **즉시 회색/⚠로 바뀌지 않고** 이전 값을 유지하는지 확인(짧은 차질 숨김).
  - 차단을 15분 이상 유지하면 ⚠ stale로 전환되는지 확인.
  - 차단 해제 후 백오프 주기 내에 정상 값으로 복구되는지 확인.

---

## Self-Review 메모

- **Spec 커버리지:** self-scheduling(§1)=Task 3/6/9, 상태(§2)=각 Task, 나이 기반 표시(§3)=Task 3/6/9, 순수 함수+테스트(§4)=Task 1/4/7, 포트별 적용(§5)=Task 3/6/9, 에러 분류(§6)=Task 2/5/8. 비목표(설정 미노출/HTTP-date 미지원/인메모리)=준수.
- **타입 일관성:** TS `nextRetryDelayMs`(ms 단위), Go/Swift `nextRetryDelay`(Duration/TimeInterval). 포트별 단위가 다르므로 이름도 의도적으로 다르게(TS만 `Ms` 접미사) 둠 — 혼동 방지. `shouldShowStale`는 세 포트 동일 이름. 429 retry-after 추출: TS `TransientError.retryAfterMs`, Go `retryAfterFrom(err)`, Swift `retryAfter(from:)`.
- **no-op 표시:** 세 포트 모두 "신선함" 분기에서 렌더 함수를 호출하지 않아 직전 정상 표시를 유지.
