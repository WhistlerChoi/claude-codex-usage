import type { UsageData, UsageWindow } from "./usageClient";
import type { CurrentModel } from "./model";

/**
 * API의 utilization은 이미 퍼센트 단위(0~100)다. 정수로 반올림만 한다.
 */
export function pct(utilization: number): number {
  return Math.round(utilization);
}

/** 상태바 한 줄: "$(pulse) 5h 42% · wk 8% · Opus 4.8" */
export function statusBarText(usage: UsageData, modelName?: string): string {
  const base = `$(pulse) 5h ${pct(usage.fiveHour.utilization)}% · wk ${pct(usage.sevenDay.utilization)}%`;
  return modelName ? `${base} · ${modelName}` : base;
}

/**
 * resetsAt까지 남은 시간을 사람이 읽는 한국어로.
 * now는 테스트를 위해 주입 가능.
 */
export function formatResetIn(resetsAt: string | null, now: Date = new Date()): string {
  if (!resetsAt) {
    return "리셋 시각 미정";
  }
  const target = new Date(resetsAt);
  if (Number.isNaN(target.getTime())) {
    return "리셋 시각 미정";
  }
  let diffMs = target.getTime() - now.getTime();
  if (diffMs <= 0) {
    return "곧 리셋";
  }
  const totalMin = Math.floor(diffMs / 60000);
  const days = Math.floor(totalMin / (60 * 24));
  const hours = Math.floor((totalMin % (60 * 24)) / 60);
  const mins = totalMin % 60;

  const parts: string[] = [];
  if (days > 0) parts.push(`${days}일`);
  if (hours > 0) parts.push(`${hours}시간`);
  if (days === 0 && mins > 0) parts.push(`${mins}분`);
  if (parts.length === 0) parts.push("1분 미만");
  return `${parts.join(" ")} 후 리셋`;
}

function windowLine(label: string, w: UsageWindow, now: Date): string {
  return `**${label}**: ${pct(w.utilization)}% · ${formatResetIn(w.resetsAt, now)}`;
}

/** 호버 툴팁 Markdown 본문. */
export function tooltipMarkdown(
  usage: UsageData,
  lastUpdated: Date,
  now: Date = new Date(),
  model?: CurrentModel | null
): string {
  const lines: string[] = [
    "### Claude Code 사용량",
    "",
    windowLine("5시간", usage.fiveHour, now),
    windowLine("주간", usage.sevenDay, now),
  ];
  if (usage.sevenDayOpus) {
    lines.push(windowLine("주간 Opus", usage.sevenDayOpus, now));
  }
  if (usage.sevenDaySonnet) {
    lines.push(windowLine("주간 Sonnet", usage.sevenDaySonnet, now));
  }
  if (model) {
    lines.push("", `**현재 모델**: ${model.name} (\`${model.id}\`)`);
  }
  lines.push("", `_갱신: ${formatClock(lastUpdated)}_`, "", "클릭하면 지금 새로고침");
  return lines.join("\n");
}

function formatClock(d: Date): string {
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  const ss = String(d.getSeconds()).padStart(2, "0");
  return `${hh}:${mm}:${ss}`;
}

/**
 * 두 윈도우 중 가장 높은 사용률을 0~1 분수로 반환 (상태바 색상 임계값 비교용).
 * utilization은 퍼센트(0~100)이므로 100으로 나눈다.
 */
export function peakUtilization(usage: UsageData): number {
  return Math.max(usage.fiveHour.utilization, usage.sevenDay.utilization) / 100;
}

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
