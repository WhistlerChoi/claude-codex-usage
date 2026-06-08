import { test } from "node:test";
import assert from "node:assert/strict";
import { pct, statusBarText, formatResetIn, peakUtilization, tooltipMarkdown, nextRetryDelayMs, shouldShowStale } from "./format";
import { parseUsage, type UsageData } from "./usageClient";

// utilization은 퍼센트 단위(0~100)
const sampleRaw = {
  five_hour: { utilization: 42, resets_at: "2026-06-04T11:50:00+00:00" },
  seven_day: { utilization: 8, resets_at: "2026-06-10T07:00:00+00:00" },
  seven_day_opus: null,
  seven_day_sonnet: { utilization: 3, resets_at: null },
};

test("parseUsage maps fields", () => {
  const u = parseUsage(sampleRaw);
  assert.equal(u.fiveHour.utilization, 42);
  assert.equal(u.sevenDay.resetsAt, "2026-06-10T07:00:00+00:00");
  assert.equal(u.sevenDayOpus, null);
  assert.equal(u.sevenDaySonnet?.utilization, 3);
});

test("parseUsage throws when required windows missing", () => {
  assert.throws(() => parseUsage({ five_hour: { utilization: 10 } }));
});

test("pct rounds percent value directly", () => {
  assert.equal(pct(42.6), 43);
  assert.equal(pct(100), 100);
  assert.equal(pct(2), 2);
  assert.equal(pct(0), 0);
});

test("statusBarText format", () => {
  const u = parseUsage(sampleRaw);
  assert.equal(statusBarText(u), "$(pulse) 5h 42% · wk 8%");
});

test("formatResetIn handles hours and minutes", () => {
  const now = new Date("2026-06-04T10:00:00Z");
  assert.equal(formatResetIn("2026-06-04T11:50:00Z", now), "1시간 50분 후 리셋");
});

test("formatResetIn handles days", () => {
  const now = new Date("2026-06-04T10:00:00Z");
  assert.equal(formatResetIn("2026-06-10T07:00:00Z", now), "5일 21시간 후 리셋");
});

test("formatResetIn past is 곧 리셋", () => {
  const now = new Date("2026-06-04T12:00:00Z");
  assert.equal(formatResetIn("2026-06-04T11:50:00Z", now), "곧 리셋");
});

test("formatResetIn null", () => {
  assert.equal(formatResetIn(null), "리셋 시각 미정");
});

test("peakUtilization picks max as 0~1 fraction", () => {
  const u = parseUsage(sampleRaw);
  assert.equal(peakUtilization(u), 0.42);
});

test("tooltipMarkdown includes sonnet but not opus when opus null", () => {
  const u: UsageData = parseUsage(sampleRaw);
  const now = new Date("2026-06-04T10:00:00Z");
  const md = tooltipMarkdown(u, now, now);
  assert.match(md, /5시간/);
  assert.match(md, /주간 Sonnet/);
  assert.doesNotMatch(md, /주간 Opus/);
});

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
