import { test } from "node:test";
import assert from "node:assert/strict";
import { extractDailyTotals, formatTokens, tokenTotalsText, type TokenTotals } from "./tokens";
import { localDateKey } from "./tokenHistory";

function assistantLine(id: string, ts: string, usage: Record<string, unknown>, extra: Record<string, unknown> = {}) {
  return JSON.stringify({ type: "assistant", timestamp: ts, requestId: `req_${id}`, message: { id, model: "claude-fable-5-1", usage }, ...extra });
}

test("extractDailyTotals: buckets assistant usage by local date", () => {
  const dayA = new Date(2026, 8, 25, 22, 0, 0);
  const dayB = new Date(2026, 8, 26, 1, 0, 0);
  const content = [
    assistantLine("a", dayA.toISOString(), { input_tokens: 10, output_tokens: 20, cache_creation_input_tokens: 30, cache_read_input_tokens: 40 }),
    assistantLine("b", dayB.toISOString(), { input_tokens: 1, output_tokens: 2, cache_creation_input_tokens: 3, cache_read_input_tokens: 4 }),
    assistantLine("c", dayB.toISOString(), { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 1, cache_read_input_tokens: 1 }),
  ].join("\n");
  assert.deepEqual(extractDailyTotals(content), {
    [localDateKey(dayA)]: { input: 10, output: 20, cacheCreate: 30, cacheRead: 40 },
    [localDateKey(dayB)]: { input: 2, output: 3, cacheCreate: 4, cacheRead: 5 },
  });
});

test("extractDailyTotals: counts a message.id only once (streamed content blocks repeat the line)", () => {
  const usage = { input_tokens: 5, output_tokens: 7, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
  const ts = new Date(2026, 8, 26, 1).toISOString();
  const content = [assistantLine("same", ts, usage), assistantLine("same", ts, usage), assistantLine("same", ts, usage)].join("\n");
  assert.deepEqual(extractDailyTotals(content), { "2026-09-26": { input: 5, output: 7, cacheCreate: 0, cacheRead: 0 } });
});

test("extractDailyTotals: skips records without a timestamp, non-assistant, malformed and usage-less lines; missing fields are 0", () => {
  const ts = new Date(2026, 8, 26, 1).toISOString();
  const content = [
    JSON.stringify({ type: "assistant", message: { id: "nots", usage: { input_tokens: 100 } } }),
    JSON.stringify({ type: "user", timestamp: ts, message: { usage: { input_tokens: 999 } } }),
    "not json at all",
    "",
    JSON.stringify({ type: "assistant", timestamp: ts, message: { id: "nousage", model: "x" } }),
    assistantLine("partial", ts, { output_tokens: 3 }),
  ].join("\n");
  assert.deepEqual(extractDailyTotals(content), { "2026-09-26": { input: 0, output: 3, cacheCreate: 0, cacheRead: 0 } });
});

test("extractDailyTotals: empty content is an empty map", () => {
  assert.deepEqual(extractDailyTotals(""), {});
});

test("formatTokens: plain below 1000", () => {
  assert.equal(formatTokens(0), "0");
  assert.equal(formatTokens(999), "999");
});

test("formatTokens: K with one decimal below 10K, integer above", () => {
  assert.equal(formatTokens(1234), "1.2K");
  assert.equal(formatTokens(48_000), "48K");
  assert.equal(formatTokens(310_400), "310K");
});

test("formatTokens: M with one decimal below 10M, integer above", () => {
  assert.equal(formatTokens(999_999), "1.0M");
  assert.equal(formatTokens(9_800_000), "9.8M");
  assert.equal(formatTokens(13_500_000), "14M");
});

test("formatTokens: B with one decimal below 10B", () => {
  assert.equal(formatTokens(999_999_999), "1.0B");
  assert.equal(formatTokens(2_100_000_000), "2.1B");
});

test("tokenTotalsText: in · out · cache (cache = read + creation)", () => {
  const t: TokenTotals = { input: 1_200_000, output: 48_000, cacheRead: 9_000_000, cacheCreate: 800_000 };
  assert.equal(tokenTotalsText(t), "1.2M in · 48K out · 9.8M cache");
});
