import { test } from "node:test";
import assert from "node:assert/strict";
import { pct, statusBarText, formatResetIn, peakUtilization, tooltipMarkdown, nextRetryDelayMs, shouldShowStale } from "./format";
import { parseUsage, parseRetryAfterMs, type UsageData } from "./usageClient";

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

const noJitter = () => 0; // 지터 0 → base 그대로

test("nextRetryDelayMs: 지수 백오프, 바닥 60s, ×2", () => {
  const interval = 300_000;
  assert.equal(nextRetryDelayMs(1, interval, undefined, noJitter), 60_000);
  assert.equal(nextRetryDelayMs(2, interval, undefined, noJitter), 120_000);
  assert.equal(nextRetryDelayMs(3, interval, undefined, noJitter), 240_000);
});

test("nextRetryDelayMs: interval로 cap", () => {
  const interval = 300_000;
  assert.equal(nextRetryDelayMs(4, interval, undefined, noJitter), 300_000); // 60s*2^3=480s > 300s
  assert.equal(nextRetryDelayMs(99, interval, undefined, noJitter), 300_000);
});

test("nextRetryDelayMs: retryAfter는 존중(interval로 깎지 않음), MAX로만 cap", () => {
  const interval = 300_000;
  assert.equal(nextRetryDelayMs(1, interval, 45_000, noJitter), 45_000);
  assert.equal(nextRetryDelayMs(1, interval, 600_000, noJitter), 600_000); // interval 넘어도 존중
  assert.equal(nextRetryDelayMs(1, interval, 5_000_000, noJitter), 3_600_000); // 1h MAX cap
  assert.equal(nextRetryDelayMs(1, interval, 0, noJitter), 60_000); // 0이면 무시하고 바닥 백오프
});

test("nextRetryDelayMs: 지터는 base의 0~20% 가산", () => {
  const interval = 300_000;
  assert.equal(nextRetryDelayMs(1, interval, undefined, () => 1), 72_000); // 60s + 20%
  assert.equal(nextRetryDelayMs(1, interval, 100_000, () => 1), 120_000); // 100s + 20%
});

test("shouldShowStale: age >= interval*3", () => {
  const interval = 300_000;
  assert.equal(shouldShowStale(899_000, interval), false);
  assert.equal(shouldShowStale(900_000, interval), true);
  assert.equal(shouldShowStale(0, interval), false);
});

test("parseRetryAfterMs: 정수 초를 ms로", () => {
  assert.equal(parseRetryAfterMs("30"), 30_000);
  assert.equal(parseRetryAfterMs("0"), 0);
});

test("parseRetryAfterMs: 없음/비정수는 undefined", () => {
  assert.equal(parseRetryAfterMs(null), undefined);
  assert.equal(parseRetryAfterMs("Wed, 21 Oct 2025 07:28:00 GMT"), undefined);
  assert.equal(parseRetryAfterMs("abc"), undefined);
});
