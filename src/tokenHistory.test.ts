import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, utimes, rm, readFile, readdir, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  localDateKey,
  dateShift,
  mergeDailyIntoLedger,
  mergeLedgers,
  sumRange,
  trendText,
  statsFrom,
  tokenRows,
  updateTokenHistory,
  emptyLedger,
  type TokenLedger,
} from "./tokenHistory";
import { extractDailyTotals, type TokenTotals } from "./tokens";

const T = (input: number, output = 0, cacheRead = 0, cacheCreate = 0): TokenTotals => ({ input, output, cacheRead, cacheCreate });

function assistantLine(id: string, ts: string, usage: Record<string, unknown>) {
  return JSON.stringify({ type: "assistant", timestamp: ts, requestId: `req_${id}`, message: { id, model: "claude-fable-5-1", usage } });
}

test("localDateKey / dateShift: local calendar arithmetic", () => {
  assert.equal(localDateKey(new Date(2026, 8, 26, 23, 59)), "2026-09-26");
  assert.equal(dateShift("2026-09-26", -6), "2026-09-20");
  assert.equal(dateShift("2026-03-01", -1), "2026-02-28");
  assert.equal(dateShift("2026-01-01", -1), "2025-12-31");
});

test("mergeDailyIntoLedger: takes the per-field max, never adds; records since", () => {
  const ledger = emptyLedger();
  let changed = mergeDailyIntoLedger(ledger, "claude", { "2026-09-25": T(10, 5), "2026-09-26": T(1, 1) }, "2026-09-26");
  assert.equal(changed, true);
  // A later scan with a deleted file (lower total) must not shrink history; a larger one grows it.
  changed = mergeDailyIntoLedger(ledger, "claude", { "2026-09-25": T(4, 9), "2026-09-26": T(1, 1) }, "2026-09-26");
  assert.equal(changed, true);
  assert.deepEqual(ledger.days["2026-09-25"].claude, T(10, 9));
  changed = mergeDailyIntoLedger(ledger, "claude", { "2026-09-26": T(1, 1) }, "2026-09-26");
  assert.equal(changed, false);
  assert.equal(ledger.since.claude, "2026-09-26");
  // Another provider on the same day lives beside it.
  mergeDailyIntoLedger(ledger, "codex", { "2026-09-26": T(7) }, "2026-09-26");
  assert.deepEqual(ledger.days["2026-09-26"], { claude: T(1, 1), codex: T(7) });
});

test("mergeLedgers: union of days with per-field max and earliest since", () => {
  const a = emptyLedger();
  mergeDailyIntoLedger(a, "claude", { "2026-09-20": T(100) }, "2026-09-20");
  const b = emptyLedger();
  mergeDailyIntoLedger(b, "claude", { "2026-09-20": T(50, 50), "2026-09-21": T(1) }, "2026-09-21");
  const m = mergeLedgers(a, b);
  assert.deepEqual(m.days["2026-09-20"].claude, T(100, 50));
  assert.deepEqual(m.days["2026-09-21"].claude, T(1));
  assert.equal(m.since.claude, "2026-09-20");
});

test("sumRange: inclusive date range for one provider, missing days count as zero", () => {
  const ledger = emptyLedger();
  mergeDailyIntoLedger(ledger, "claude", { "2026-09-20": T(1), "2026-09-21": T(2), "2026-09-22": T(4), "2026-09-23": T(8) }, "2026-09-23");
  mergeDailyIntoLedger(ledger, "codex", { "2026-09-21": T(1000) }, "2026-09-23");
  assert.deepEqual(sumRange(ledger, "claude", "2026-09-21", "2026-09-22"), T(6));
  assert.deepEqual(sumRange(ledger, "claude", "2026-09-10", "2026-09-30"), T(15));
});

test("trendText: total-token change vs the prior window", () => {
  assert.equal(trendText(T(112, 0, 0, 0), T(100)), "▲ 12%");
  assert.equal(trendText(T(95), T(100)), "▼ 5%");
  assert.equal(trendText(T(50, 50), T(60, 40)), "± 0%");
  assert.equal(trendText(T(5), T(0)), "—");
  assert.equal(trendText(T(5), null), "—");
});

test("statsFrom: today / rolling 7d and 30d, prior windows only once coverage allows", () => {
  const ledger = emptyLedger();
  // Coverage begins 2026-09-13 (14 days incl. today) → prior 7d available, prior 30d not.
  const daily: Record<string, TokenTotals> = {};
  for (let i = 0; i < 14; i++) daily[dateShift("2026-09-26", -i)] = T(1);
  mergeDailyIntoLedger(ledger, "claude", daily, "2026-09-26");
  const s = statsFrom(ledger, "claude", "2026-09-26");
  assert.deepEqual(s.today, T(1));
  assert.deepEqual(s.last7, T(7));
  assert.deepEqual(s.prev7, T(7));
  assert.deepEqual(s.last30, T(14));
  assert.equal(s.prev30, null);
});

test("tokenRows: three label/value rows with identical wording across ports", () => {
  const rows = tokenRows({
    today: T(5_900, 406_000, 78_000_000, 2_300_000),
    last7: T(41_000_000, 2_900_000, 600_000_000, 20_000_000),
    prev7: T(30_000_000, 2_000_000, 550_000_000, 10_000_000),
    last30: T(120_000_000, 9_100_000, 2_000_000_000, 100_000_000),
    prev30: null,
  });
  assert.deepEqual(rows, [
    { label: "Tokens today", value: "5.9K in · 406K out · 80M cache" },
    { label: "Tokens 7d", value: "41M in · 2.9M out · 620M cache · ▲ 12% vs prior 7d" },
    { label: "Tokens 30d", value: "120M in · 9.1M out · 2.1B cache · — vs prior 30d" },
  ]);
});

async function fixtureRoot(): Promise<{ root: string; home: string; proj: string }> {
  const base = await mkdtemp(join(tmpdir(), "pulse-hist-"));
  const root = join(base, "projects");
  const home = join(base, "pulse-home");
  const proj = join(root, "-Users-me-proj");
  await mkdir(join(proj, "sess1", "subagents"), { recursive: true });
  return { root, home, proj };
}

test("updateTokenHistory: backfills per-day buckets (subagents included), persists ledger and cache", async () => {
  const { root, home, proj } = await fixtureRoot();
  try {
    const now = new Date(2026, 8, 26, 12, 0, 0);
    const d0 = new Date(2026, 8, 26, 10, 0, 0).toISOString();
    const d1 = new Date(2026, 8, 25, 10, 0, 0).toISOString();
    await writeFile(join(proj, "sess1.jsonl"), [assistantLine("a", d0, { input_tokens: 10 }), assistantLine("b", d1, { input_tokens: 3 })].join("\n") + "\n");
    await writeFile(join(proj, "sess1", "subagents", "agent-x.jsonl"), assistantLine("c", d0, { output_tokens: 7 }) + "\n");
    const stats = await updateTokenHistory({ provider: "claude", root, extract: extractDailyTotals, home, now });
    assert.deepEqual(stats?.today, T(10, 7));
    assert.deepEqual(stats?.last7, T(13, 7));
    const ledger = JSON.parse(await readFile(join(home, "token-history.json"), "utf8")) as TokenLedger;
    assert.deepEqual(ledger.days["2026-09-26"].claude, T(10, 7));
    assert.deepEqual(ledger.days["2026-09-25"].claude, T(3));
    assert.equal(ledger.since.claude, "2026-09-26"); // first observation day; coverage also honors earlier backfilled days
    const cache = JSON.parse(await readFile(join(home, "cache", "claude-files.json"), "utf8"));
    assert.equal(Object.keys(cache.files).length, 2);
  } finally {
    await rm(join(root, ".."), { recursive: true, force: true });
  }
});

test("updateTokenHistory: a deleted transcript keeps its contribution in the ledger", async () => {
  const { root, home, proj } = await fixtureRoot();
  try {
    const now = new Date(2026, 8, 26, 12, 0, 0);
    const d1 = new Date(2026, 8, 25, 10, 0, 0).toISOString();
    const old = join(proj, "old.jsonl");
    await writeFile(old, assistantLine("a", d1, { input_tokens: 100 }) + "\n");
    await writeFile(join(proj, "live.jsonl"), assistantLine("b", d1, { input_tokens: 1 }) + "\n");
    assert.deepEqual((await updateTokenHistory({ provider: "claude", root, extract: extractDailyTotals, home, now }))?.last7, T(101));
    await rm(old);
    assert.deepEqual((await updateTokenHistory({ provider: "claude", root, extract: extractDailyTotals, home, now }))?.last7, T(101));
  } finally {
    await rm(join(root, ".."), { recursive: true, force: true });
  }
});

test("updateTokenHistory: unchanged files are not re-read; files older than the scan window are skipped", async () => {
  const { root, home, proj } = await fixtureRoot();
  try {
    const now = new Date(2026, 8, 26, 12, 0, 0);
    const d0 = new Date(2026, 8, 26, 10, 0, 0).toISOString();
    const file = join(proj, "s.jsonl");
    await writeFile(file, assistantLine("a", d0, { input_tokens: 1 }) + "\n");
    const ancient = join(proj, "ancient.jsonl");
    await writeFile(ancient, assistantLine("z", d0, { input_tokens: 999 }) + "\n");
    const long_ago = (now.getTime() - 90 * 86400_000) / 1000;
    await utimes(ancient, long_ago, long_ago);
    let reads = 0;
    const counting = (content: string) => { reads++; return extractDailyTotals(content); };
    await updateTokenHistory({ provider: "claude", root, extract: counting, home, now });
    assert.equal(reads, 1);
    const s2 = await updateTokenHistory({ provider: "claude", root, extract: counting, home, now });
    assert.equal(reads, 1);
    assert.deepEqual(s2?.today, T(1));
    // Appending changes mtime/size → exactly one more read.
    await writeFile(file, [assistantLine("a", d0, { input_tokens: 1 }), assistantLine("b", d0, { input_tokens: 2 })].join("\n") + "\n");
    const s3 = await updateTokenHistory({ provider: "claude", root, extract: counting, home, now });
    assert.equal(reads, 2);
    assert.deepEqual(s3?.today, T(3));
  } finally {
    await rm(join(root, ".."), { recursive: true, force: true });
  }
});

test("updateTokenHistory: a corrupt ledger is quarantined, never overwritten", async () => {
  const { root, home, proj } = await fixtureRoot();
  try {
    const now = new Date(2026, 8, 26, 12, 0, 0);
    await mkdir(home, { recursive: true });
    await writeFile(join(home, "token-history.json"), "{not json");
    await writeFile(join(proj, "s.jsonl"), assistantLine("a", new Date(2026, 8, 26, 10).toISOString(), { input_tokens: 1 }) + "\n");
    const stats = await updateTokenHistory({ provider: "claude", root, extract: extractDailyTotals, home, now });
    assert.deepEqual(stats?.today, T(1));
    const names = await readdir(home);
    assert.ok(names.some((n) => n.startsWith("token-history.json.corrupt-")), names.join(","));
    assert.ok((await stat(join(home, "token-history.json"))).size > 0);
  } finally {
    await rm(join(root, ".."), { recursive: true, force: true });
  }
});

test("updateTokenHistory: missing root returns null and writes nothing", async () => {
  const base = await mkdtemp(join(tmpdir(), "pulse-hist-"));
  try {
    const stats = await updateTokenHistory({ provider: "claude", root: join(base, "nope"), extract: extractDailyTotals, home: join(base, "home") });
    assert.equal(stats, null);
    await assert.rejects(stat(join(base, "home", "token-history.json")));
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});
