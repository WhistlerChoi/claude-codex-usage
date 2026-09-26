/**
 * Token accounting primitives for Claude Code transcripts (`~/.claude/projects/**\/*.jsonl`).
 * The usage API only reports rate-limit percentages, so token counts can only come from these
 * files. Pure parsing lives here; the daily ledger that turns it into today / 7d / 30d figures
 * is in `tokenHistory.ts`. Everything is best-effort: a failure means the token rows are
 * omitted, never an error state.
 */
import { localDateKey } from "./tokenHistory";

export interface TokenTotals {
  input: number;
  output: number;
  cacheRead: number;
  cacheCreate: number;
}

export const ZERO_TOTALS: TokenTotals = { input: 0, output: 0, cacheRead: 0, cacheCreate: 0 };

export function addTotals(a: TokenTotals, b: TokenTotals): TokenTotals {
  return {
    input: a.input + b.input,
    output: a.output + b.output,
    cacheRead: a.cacheRead + b.cacheRead,
    cacheCreate: a.cacheCreate + b.cacheCreate,
  };
}

export function totalTokens(t: TokenTotals): number {
  return t.input + t.output + t.cacheRead + t.cacheCreate;
}

/** Per local calendar day ("YYYY-MM-DD") totals of one transcript. */
export type DailyTotals = Record<string, TokenTotals>;

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

/**
 * Bucket `message.usage` of the `assistant` records by the local date of their `timestamp`
 * (pure function).
 *
 * Claude Code writes one `assistant` line per content block of a response; those lines share
 * `message.id` and carry identical usage, so each id is counted once. Records without a
 * timestamp cannot be attributed to a day and are skipped. `usage.iterations[]` is ignored.
 */
export function extractDailyTotals(content: string): DailyTotals {
  const days: DailyTotals = {};
  const seen = new Set<string>();
  for (const raw of content.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    let obj: unknown;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    const rec = obj as {
      type?: unknown;
      timestamp?: unknown;
      message?: { id?: unknown; usage?: Record<string, unknown> };
    };
    if (rec?.type !== "assistant") continue;
    if (typeof rec.timestamp !== "string") continue;
    const ts = Date.parse(rec.timestamp);
    if (Number.isNaN(ts)) continue;
    const usage = rec.message?.usage;
    if (!usage || typeof usage !== "object") continue;
    const id = rec.message?.id;
    if (typeof id === "string" && id) {
      if (seen.has(id)) continue;
      seen.add(id);
    }
    const key = localDateKey(new Date(ts));
    days[key] = addTotals(days[key] ?? ZERO_TOTALS, {
      input: num(usage.input_tokens),
      output: num(usage.output_tokens),
      cacheRead: num(usage.cache_read_input_tokens),
      cacheCreate: num(usage.cache_creation_input_tokens),
    });
  }
  return days;
}

/** 0 → "0", 1234 → "1.2K", 48000 → "48K", 9_800_000 → "9.8M", 13_500_000 → "14M", 2.1e9 → "2.1B". */
export function formatTokens(n: number): string {
  const scaled = (unit: number, suffix: string): string => {
    const v = n / unit;
    return (v < 10 ? v.toFixed(1) : String(Math.round(v))) + suffix;
  };
  if (n < 1000) return String(Math.round(n));
  if (n < 999_500) return scaled(1_000, "K");
  if (n < 999_500_000) return scaled(1_000_000, "M");
  return scaled(1_000_000_000, "B");
}

/** "1.2M in · 48K out · 9.8M cache" — cache is read + creation. Identical in all ports. */
export function tokenTotalsText(t: TokenTotals): string {
  return `${formatTokens(t.input)} in · ${formatTokens(t.output)} out · ${formatTokens(t.cacheRead + t.cacheCreate)} cache`;
}
