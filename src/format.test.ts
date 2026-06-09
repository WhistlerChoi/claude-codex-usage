import { test } from "node:test";
import assert from "node:assert/strict";
import { pct, statusBarText, formatResetIn, peakUtilization, tooltipMarkdown, nextRetryDelayMs, shouldShowStale } from "./format";
import { parseUsage, parseRetryAfterMs, type UsageData } from "./usageClient";

// utilization is a percent (0-100)
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
  assert.equal(formatResetIn("2026-06-04T11:50:00Z", now), "resets in 1h 50m");
});

test("formatResetIn handles days", () => {
  const now = new Date("2026-06-04T10:00:00Z");
  assert.equal(formatResetIn("2026-06-10T07:00:00Z", now), "resets in 5d 21h");
});

test("formatResetIn past is 'resets soon'", () => {
  const now = new Date("2026-06-04T12:00:00Z");
  assert.equal(formatResetIn("2026-06-04T11:50:00Z", now), "resets soon");
});

test("formatResetIn null", () => {
  assert.equal(formatResetIn(null), "reset time unknown");
});

test("peakUtilization picks max as 0~1 fraction", () => {
  const u = parseUsage(sampleRaw);
  assert.equal(peakUtilization(u), 0.42);
});

test("tooltipMarkdown includes sonnet but not opus when opus null", () => {
  const u: UsageData = parseUsage(sampleRaw);
  const now = new Date("2026-06-04T10:00:00Z");
  const md = tooltipMarkdown(u, now, now);
  assert.match(md, /5h/);
  assert.match(md, /Weekly Sonnet/);
  assert.doesNotMatch(md, /Weekly Opus/);
});

const noJitter = () => 0; // jitter 0 → base unchanged

test("nextRetryDelayMs: exponential backoff, floor 60s, ×2", () => {
  const interval = 300_000;
  assert.equal(nextRetryDelayMs(1, interval, undefined, noJitter), 60_000);
  assert.equal(nextRetryDelayMs(2, interval, undefined, noJitter), 120_000);
  assert.equal(nextRetryDelayMs(3, interval, undefined, noJitter), 240_000);
});

test("nextRetryDelayMs: capped at interval", () => {
  const interval = 300_000;
  assert.equal(nextRetryDelayMs(4, interval, undefined, noJitter), 300_000); // 60s*2^3=480s > 300s
  assert.equal(nextRetryDelayMs(99, interval, undefined, noJitter), 300_000);
});

test("nextRetryDelayMs: retryAfter is respected (not shrunk by interval), only capped at MAX", () => {
  const interval = 300_000;
  assert.equal(nextRetryDelayMs(1, interval, 45_000, noJitter), 45_000);
  assert.equal(nextRetryDelayMs(1, interval, 600_000, noJitter), 600_000); // respected even beyond interval
  assert.equal(nextRetryDelayMs(1, interval, 5_000_000, noJitter), 3_600_000); // 1h MAX cap
  assert.equal(nextRetryDelayMs(1, interval, 0, noJitter), 60_000); // 0 is ignored, falls back to floor backoff
});

test("nextRetryDelayMs: jitter adds 0~20% of base", () => {
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

test("parseRetryAfterMs: integer seconds to ms", () => {
  assert.equal(parseRetryAfterMs("30"), 30_000);
  assert.equal(parseRetryAfterMs("0"), 0);
});

test("parseRetryAfterMs: missing/non-integer is undefined", () => {
  assert.equal(parseRetryAfterMs(null), undefined);
  assert.equal(parseRetryAfterMs("Wed, 21 Oct 2025 07:28:00 GMT"), undefined);
  assert.equal(parseRetryAfterMs("abc"), undefined);
});
