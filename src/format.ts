import type { UsageData, UsageWindow } from "./usageClient";
import type { CurrentModel } from "./model";

/**
 * The API's utilization is already a percent (0-100). Just round to an integer.
 */
export function pct(utilization: number): number {
  return Math.round(utilization);
}

/** Status bar single line: "$(pulse) 5h 42% · wk 8% · Opus 4.8" */
export function statusBarText(usage: UsageData, modelName?: string): string {
  const base = `$(pulse) 5h ${pct(usage.fiveHour.utilization)}% · wk ${pct(usage.sevenDay.utilization)}%`;
  return modelName ? `${base} · ${modelName}` : base;
}

/**
 * Human-readable English time remaining until resetsAt.
 * now is injectable for tests.
 */
export function formatResetIn(resetsAt: string | null, now: Date = new Date()): string {
  if (!resetsAt) {
    return "reset time unknown";
  }
  const target = new Date(resetsAt);
  if (Number.isNaN(target.getTime())) {
    return "reset time unknown";
  }
  let diffMs = target.getTime() - now.getTime();
  if (diffMs <= 0) {
    return "resets soon";
  }
  const totalMin = Math.floor(diffMs / 60000);
  const days = Math.floor(totalMin / (60 * 24));
  const hours = Math.floor((totalMin % (60 * 24)) / 60);
  const mins = totalMin % 60;

  const parts: string[] = [];
  if (days > 0) parts.push(`${days}d`);
  if (hours > 0) parts.push(`${hours}h`);
  if (days === 0 && mins > 0) parts.push(`${mins}m`);
  if (parts.length === 0) parts.push("<1m");
  return `resets in ${parts.join(" ")}`;
}

function windowLine(label: string, w: UsageWindow, now: Date): string {
  return `**${label}**: ${pct(w.utilization)}% · ${formatResetIn(w.resetsAt, now)}`;
}

/** Hover tooltip Markdown body. */
export function tooltipMarkdown(
  usage: UsageData,
  lastUpdated: Date,
  now: Date = new Date(),
  model?: CurrentModel | null
): string {
  const lines: string[] = [
    "### Pulse",
    "",
    windowLine("5h", usage.fiveHour, now),
    windowLine("Weekly", usage.sevenDay, now),
  ];
  const legacyModels = new Set<string>();
  if (usage.sevenDayOpus) {
    lines.push(windowLine("Weekly Opus", usage.sevenDayOpus, now));
    legacyModels.add("Opus");
  }
  if (usage.sevenDaySonnet) {
    lines.push(windowLine("Weekly Sonnet", usage.sevenDaySonnet, now));
    legacyModels.add("Sonnet");
  }
  for (const scoped of usage.weeklyScoped) {
    if (legacyModels.has(scoped.model)) continue; // legacy field already rendered this model
    lines.push(windowLine(`Weekly ${scoped.model}`, scoped.window, now));
  }
  if (model) {
    lines.push("", `**Current model**: ${model.name} (\`${model.id}\`)`);
  }
  lines.push("", `_Updated: ${formatClock(lastUpdated)}_`, "", "Click to refresh now");
  return lines.join("\n");
}

function formatClock(d: Date): string {
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  const ss = String(d.getSeconds()).padStart(2, "0");
  return `${hh}:${mm}:${ss}`;
}

/**
 * Returns the highest utilization of the two windows as a 0-1 fraction (for status bar color threshold comparison).
 * utilization is a percent (0-100), so divide by 100.
 */
export function peakUtilization(usage: UsageData): number {
  return Math.max(usage.fiveHour.utilization, usage.sevenDay.utilization) / 100;
}

/** Upper bound on retry delay (1 hour). Ensures we never stall indefinitely even if Retry-After is abnormally large. */
const MAX_RETRY_MS = 3_600_000;
/** Floor for 429 backoff (60s). Avoids hammering the rate limiter too often and getting another 429. */
const RETRY_FLOOR_MS = 60_000;

/**
 * Delay (ms) until the next poll after a transient failure.
 * - If retryAfterMs is present, "respect" it (the server-dictated minimum wait). Do not shrink it with interval; only cap with MAX.
 * - Otherwise, exponential backoff (×2) starting at 60s, capped at interval (min 60s).
 * Finally add 0-20% jitter to spread out concurrent poll collisions.
 * @param rand 0-1 random source (for test injection, defaults to Math.random).
 */
export function nextRetryDelayMs(
  consecutiveFailures: number,
  intervalMs: number,
  retryAfterMs?: number,
  rand: () => number = Math.random
): number {
  let base: number;
  if (retryAfterMs != null && retryAfterMs > 0) {
    base = Math.min(retryAfterMs, MAX_RETRY_MS);
  } else {
    const exp = RETRY_FLOOR_MS * 2 ** Math.max(0, consecutiveFailures - 1);
    base = Math.min(exp, Math.max(intervalMs, RETRY_FLOOR_MS));
  }
  return Math.round(base + base * 0.2 * rand());
}

/**
 * Line telling the user when the next automatic retry happens, e.g. "Retrying in 45s",
 * "Retrying in 2m", "Retrying in 1h 5m". Shown for transient failures (network, HTTP 429) so a
 * throttle is never mistaken for a login problem.
 */
export function formatRetryIn(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  if (total < 60) return `Retrying in ${total}s`;
  if (total < 3600) return `Retrying in ${Math.floor(total / 60)}m`;
  const hours = Math.floor(total / 3600);
  const mins = Math.floor((total % 3600) / 60);
  return mins > 0 ? `Retrying in ${hours}h ${mins}m` : `Retrying in ${hours}h`;
}

/** Mark as stale if ageMs since the last success is at least interval*3. */
export function shouldShowStale(ageMs: number, intervalMs: number): boolean {
  return ageMs >= intervalMs * 3;
}
