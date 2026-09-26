import { test } from "node:test";
import assert from "node:assert/strict";
import { pct, statusBarText, formatResetIn, peakUtilization, tooltipMarkdown, nextRetryDelayMs, shouldShowStale, formatRetryIn } from "./format";
import { parseUsage, parseRetryAfterMs, type UsageData } from "./usageClient";

// utilization is a percent (0-100)
const sampleRaw = {
  five_hour: { utilization: 42, resets_at: "2026-06-04T11:50:00+00:00" },
  seven_day: { utilization: 8, resets_at: "2026-06-10T07:00:00+00:00" },
  seven_day_opus: null,
  seven_day_sonnet: { utilization: 3, resets_at: null },
  limits: [
    { kind: "session", group: "session", percent: 42, resets_at: "2026-06-04T11:50:00+00:00", scope: null },
    { kind: "weekly_all", group: "weekly", percent: 8, resets_at: "2026-06-10T07:00:00+00:00", scope: null },
    {
      kind: "weekly_scoped",
      group: "weekly",
      percent: 12,
      resets_at: "2026-06-10T07:00:00+00:00",
      scope: { model: { id: null, display_name: "Fable" }, surface: null },
    },
  ],
};

test("parseUsage maps fields", () => {
  const u = parseUsage(sampleRaw);
  assert.equal(u.fiveHour.utilization, 42);
  assert.equal(u.sevenDay.resetsAt, "2026-06-10T07:00:00+00:00");
  assert.equal(u.sevenDayOpus, null);
  assert.equal(u.sevenDaySonnet?.utilization, 3);
  assert.deepEqual(u.weeklyScoped, [
    { model: "Fable", window: { utilization: 12, resetsAt: "2026-06-10T07:00:00+00:00" } },
  ]);
});

test("parseUsage throws when required windows missing", () => {
  assert.throws(() => parseUsage({ five_hour: { utilization: 10 } }));
});

test("parseUsage tolerates missing/malformed limits", () => {
  const base = { five_hour: { utilization: 1 }, seven_day: { utilization: 2 } };
  assert.deepEqual(parseUsage(base).weeklyScoped, []);
  assert.deepEqual(parseUsage({ ...base, limits: null }).weeklyScoped, []);
  assert.deepEqual(parseUsage({ ...base, limits: "x" }).weeklyScoped, []);
  assert.deepEqual(parseUsage({ ...base, limits: 5 }).weeklyScoped, []);
  // Malformed entries are skipped individually; the valid sibling still parses.
  const u = parseUsage({
    ...base,
    limits: [
      "junk",
      { kind: "weekly_scoped", percent: 7 }, // no scope
      { kind: "weekly_scoped", percent: "12", scope: { model: { display_name: "X" } } }, // percent not a number
      { kind: "weekly_scoped", percent: 7, scope: { model: { display_name: null } } },
      { kind: "weekly_all", percent: 7, scope: { model: { display_name: "Y" } } }, // wrong kind
      { kind: "weekly_scoped", percent: 12, scope: { model: { display_name: "Fable" } } },
    ],
  });
  assert.deepEqual(u.weeklyScoped, [{ model: "Fable", window: { utilization: 12, resetsAt: null } }]);
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

test("tooltipMarkdown includes scoped weekly windows after Weekly", () => {
  const u = parseUsage(sampleRaw);
  const now = new Date("2026-06-04T10:00:00Z");
  const md = tooltipMarkdown(u, now, now);
  assert.match(md, /\*\*Weekly Fable\*\*: 12% · resets in 5d 21h/);
  assert.ok(md.indexOf("**Weekly Fable**") > md.indexOf("**Weekly**"));
});

test("tooltipMarkdown dedupes scoped entry against legacy field", () => {
  const u = parseUsage({
    ...sampleRaw,
    limits: [
      { kind: "weekly_scoped", percent: 3, scope: { model: { display_name: "Sonnet" } } },
      { kind: "weekly_scoped", percent: 12, scope: { model: { display_name: "Fable" } } },
    ],
  });
  const now = new Date("2026-06-04T10:00:00Z");
  const md = tooltipMarkdown(u, now, now);
  assert.equal(md.match(/Weekly Sonnet/g)?.length, 1); // legacy seven_day_sonnet wins
  assert.match(md, /Weekly Fable/);
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

test("formatRetryIn: seconds, minutes, hours", () => {
  assert.equal(formatRetryIn(0), "Retrying in 0s");
  assert.equal(formatRetryIn(45_000), "Retrying in 45s");
  assert.equal(formatRetryIn(-5_000), "Retrying in 0s");
  assert.equal(formatRetryIn(60_000), "Retrying in 1m");
  assert.equal(formatRetryIn(3_599_000), "Retrying in 59m"); // never "60m"
  assert.equal(formatRetryIn(3_600_000), "Retrying in 1h");
  assert.equal(formatRetryIn(3_900_000), "Retrying in 1h 5m");
});

const TOK = (input: number, output = 0, cacheRead = 0, cacheCreate = 0) => ({ input, output, cacheRead, cacheCreate });
const STATS = { today: TOK(1_200_000, 48_000, 9_000_000, 800_000), last7: TOK(112), prev7: TOK(100), last30: TOK(200), prev30: null };

test("tooltipMarkdown: by default shows only Tokens today plus a 7d / 30d toggle link", () => {
  const md = tooltipMarkdown(parseUsage(sampleRaw), new Date(), new Date(), { id: "claude-fable-5-1", name: "Fable 5.1" }, STATS);
  const lines = md.split("\n");
  const modelIdx = lines.findIndex((l) => l.startsWith("**Current model**"));
  assert.equal(
    lines[modelIdx + 1],
    "**Tokens today**: 1.2M in · 48K out · 9.8M cache · [7d / 30d ▸](command:pulse.toggleTokenHistory)"
  );
  assert.ok(!md.includes("**Tokens 7d**"));
  assert.ok(!md.includes("**Tokens 30d**"));
});

test("tooltipMarkdown: expanded shows 7d and 30d rows and a Hide link", () => {
  const md = tooltipMarkdown(parseUsage(sampleRaw), new Date(), new Date(), { id: "m", name: "M" }, STATS, true);
  const lines = md.split("\n");
  const todayIdx = lines.findIndex((l) => l.startsWith("**Tokens today**"));
  assert.ok(lines[todayIdx].endsWith("[Hide ▾](command:pulse.toggleTokenHistory)"), lines[todayIdx]);
  assert.equal(lines[todayIdx + 1], "**Tokens 7d**: 112 in · 0 out · 0 cache · ▲ 12% vs prior 7d");
  assert.equal(lines[todayIdx + 2], "**Tokens 30d**: 200 in · 0 out · 0 cache · — vs prior 30d");
});

test("tooltipMarkdown: no token rows and no toggle link when stats are absent", () => {
  const md = tooltipMarkdown(parseUsage(sampleRaw), new Date(), new Date(), { id: "m", name: "M" }, null, true);
  assert.ok(!md.includes("**Tokens"));
  assert.ok(!md.includes("pulse.toggleTokenHistory"));
});
