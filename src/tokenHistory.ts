/**
 * Daily token ledger shared by every Pulse front-end, so 7-day / 30-day totals and their trend
 * survive Claude Code's transcript cleanup (`cleanupPeriodDays`, default 30) without any server.
 *
 * Files under `$PULSE_HOME` (default `~/.pulse`), all apps read and write the same ones:
 *   token-history.json          — the ledger: { version, since: {provider: date}, days: {date: {provider: totals}} }
 *   cache/<provider>-files.json — per-transcript parse cache: { version, files: {path: {mtime, size, days}} }
 *
 * The one rule that keeps this correct with deletions and several writers: a day's value in the
 * ledger is the per-field MAX of what has ever been observed for it. A day's total only grows
 * while its transcripts are appended to and only shrinks when a transcript is deleted, so max
 * preserves deleted files' contribution, never double counts, and is the merge rule for
 * concurrent apps too (read → max-merge → atomic rename).
 */
import { mkdir, readdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { addTotals, tokenTotalsText, totalTokens, ZERO_TOTALS, type DailyTotals, type TokenTotals } from "./tokens";

export type DateKey = string; // "YYYY-MM-DD" in local time

export interface TokenLedger {
  version: 1;
  since: Record<string, DateKey>;
  days: Record<DateKey, Record<string, TokenTotals>>;
}

export interface TokenStats {
  today: TokenTotals;
  last7: TokenTotals;
  prev7: TokenTotals | null; // null until the ledger covers the prior window
  last30: TokenTotals;
  prev30: TokenTotals | null;
}

export interface TokenRow {
  label: string;
  value: string;
}

/** Only transcripts modified within this many days are stat'ed and parsed; older days live in the ledger. */
export const SCAN_WINDOW_DAYS = 61;
/** Ledger days older than this are pruned. */
export const LEDGER_RETENTION_DAYS = 400;

export function emptyLedger(): TokenLedger {
  return { version: 1, since: {}, days: {} };
}

export function localDateKey(d: Date): DateKey {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

export function dateShift(key: DateKey, days: number): DateKey {
  const [y, m, d] = key.split("-").map(Number);
  return localDateKey(new Date(y, m - 1, d + days));
}

function maxTotals(a: TokenTotals, b: TokenTotals): TokenTotals {
  return {
    input: Math.max(a.input, b.input),
    output: Math.max(a.output, b.output),
    cacheRead: Math.max(a.cacheRead, b.cacheRead),
    cacheCreate: Math.max(a.cacheCreate, b.cacheCreate),
  };
}

function sameTotals(a: TokenTotals, b: TokenTotals): boolean {
  return a.input === b.input && a.output === b.output && a.cacheRead === b.cacheRead && a.cacheCreate === b.cacheCreate;
}

/**
 * Fold one provider's freshly computed per-day totals into the ledger with the max rule.
 * `today` marks when observation started if the provider is new. Returns whether anything changed.
 */
export function mergeDailyIntoLedger(ledger: TokenLedger, provider: string, daily: DailyTotals, today: DateKey): boolean {
  let changed = false;
  for (const [date, totals] of Object.entries(daily)) {
    const day = (ledger.days[date] ??= {});
    const merged = maxTotals(day[provider] ?? ZERO_TOTALS, totals);
    if (!day[provider] || !sameTotals(day[provider], merged)) {
      day[provider] = merged;
      changed = true;
    }
  }
  const since = ledger.since[provider];
  if (!since || today < since) {
    ledger.since[provider] = today;
    changed = true;
  }
  return changed;
}

/** Merge two ledgers (e.g. ours and one another app wrote meanwhile): max per field, earliest since. */
export function mergeLedgers(a: TokenLedger, b: TokenLedger): TokenLedger {
  const out = emptyLedger();
  for (const src of [a, b]) {
    for (const [date, providers] of Object.entries(src.days)) {
      const day = (out.days[date] ??= {});
      for (const [provider, totals] of Object.entries(providers)) {
        day[provider] = maxTotals(day[provider] ?? ZERO_TOTALS, totals);
      }
    }
    for (const [provider, since] of Object.entries(src.since)) {
      if (!out.since[provider] || since < out.since[provider]) out.since[provider] = since;
    }
  }
  return out;
}

/** Inclusive [from, to] sum for one provider; days without an entry count as zero. */
export function sumRange(ledger: TokenLedger, provider: string, from: DateKey, to: DateKey): TokenTotals {
  let total = ZERO_TOTALS;
  for (const [date, providers] of Object.entries(ledger.days)) {
    if (date < from || date > to) continue;
    const t = providers[provider];
    if (t) total = addTotals(total, t);
  }
  return total;
}

/** "▲ 12%" / "▼ 5%" / "± 0%" on total tokens; "—" when there is nothing to compare against. */
export function trendText(cur: TokenTotals, prev: TokenTotals | null): string {
  if (!prev) return "—";
  const base = totalTokens(prev);
  if (base <= 0) return "—";
  const pct = Math.round(((totalTokens(cur) - base) / base) * 100);
  if (pct > 0) return `▲ ${pct}%`;
  if (pct < 0) return `▼ ${-pct}%`;
  return "± 0%";
}

/** First day the ledger can vouch for: the earliest recorded day or the first observation, whichever is earlier. */
function coverageStart(ledger: TokenLedger, provider: string): DateKey | null {
  let start = ledger.since[provider] ?? null;
  for (const [date, providers] of Object.entries(ledger.days)) {
    if (providers[provider] && (!start || date < start)) start = date;
  }
  return start;
}

export function statsFrom(ledger: TokenLedger, provider: string, today: DateKey): TokenStats {
  const start = coverageStart(ledger, provider);
  const window = (len: number, endOffset: number): TokenTotals =>
    sumRange(ledger, provider, dateShift(today, endOffset - len + 1), dateShift(today, endOffset));
  const prior = (len: number): TokenTotals | null =>
    start && start <= dateShift(today, -(2 * len - 1)) ? window(len, -len) : null;
  return {
    today: sumRange(ledger, provider, today, today),
    last7: window(7, 0),
    prev7: prior(7),
    last30: window(30, 0),
    prev30: prior(30),
  };
}

/** The three rows every port renders (label bolding / prefixing is per surface). */
export function tokenRows(s: TokenStats): TokenRow[] {
  return [
    { label: "Tokens today", value: tokenTotalsText(s.today) },
    { label: "Tokens 7d", value: `${tokenTotalsText(s.last7)} · ${trendText(s.last7, s.prev7)} vs prior 7d` },
    { label: "Tokens 30d", value: `${tokenTotalsText(s.last30)} · ${trendText(s.last30, s.prev30)} vs prior 30d` },
  ];
}

export function pulseHome(): string {
  return process.env.PULSE_HOME || join(homedir(), ".pulse");
}

// ---- persistence -------------------------------------------------------------------------------

interface FileCache {
  version: 1;
  files: Record<string, { mtime: number; size: number; days: DailyTotals }>;
}

async function writeAtomic(path: string, data: string): Promise<void> {
  const tmp = `${path}.tmp-${process.pid}`;
  await writeFile(tmp, data, "utf8");
  await rename(tmp, path);
}

async function readJson(path: string): Promise<unknown | undefined> {
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch {
    return undefined; // absent
  }
  try {
    return JSON.parse(text);
  } catch {
    return null; // present but corrupt
  }
}

function isLedger(v: unknown): v is TokenLedger {
  const o = v as TokenLedger | null;
  return !!o && typeof o === "object" && o.version === 1 && typeof o.days === "object" && typeof o.since === "object";
}

/** Load the ledger; a corrupt file is moved aside (never overwritten) and a fresh ledger starts. */
async function loadLedger(path: string): Promise<TokenLedger> {
  const v = await readJson(path);
  if (v === undefined) return emptyLedger();
  if (isLedger(v)) return v;
  try {
    await rename(path, `${path}.corrupt-${Date.now()}`);
  } catch {
    /* best effort */
  }
  return emptyLedger();
}

async function loadFileCache(path: string): Promise<FileCache> {
  const v = (await readJson(path)) as FileCache | null | undefined;
  return v && v.version === 1 && v.files && typeof v.files === "object" ? v : { version: 1, files: {} };
}

function pruneLedger(ledger: TokenLedger, today: DateKey): void {
  const cutoff = dateShift(today, -LEDGER_RETENTION_DAYS);
  for (const date of Object.keys(ledger.days)) {
    if (date < cutoff) delete ledger.days[date];
  }
}

async function listJsonl(dir: string, out: string[]): Promise<void> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) await listJsonl(p, out);
    else if (e.isFile() && e.name.endsWith(".jsonl")) out.push(p);
  }
}

export interface UpdateOptions {
  provider: string;
  /** Transcript root, e.g. ~/.claude/projects (walked recursively). */
  root: string;
  extract: (content: string) => DailyTotals;
  home?: string;
  now?: Date;
}

/**
 * One poll: parse changed transcripts (per-file cache), fold today's per-day totals into the
 * shared ledger, persist both atomically, and return the stats to display. `null` when `root`
 * does not exist, so callers omit the rows.
 */
export async function updateTokenHistory(opts: UpdateOptions): Promise<TokenStats | null> {
  const now = opts.now ?? new Date();
  const home = opts.home ?? pulseHome();
  const today = localDateKey(now);
  try {
    const s = await stat(opts.root);
    if (!s.isDirectory()) return null;
  } catch {
    return null;
  }

  const cacheDir = join(home, "cache");
  await mkdir(cacheDir, { recursive: true });
  const cachePath = join(cacheDir, `${opts.provider}-files.json`);
  const cache = await loadFileCache(cachePath);
  const cutoffMs = now.getTime() - SCAN_WINDOW_DAYS * 86_400_000;

  const files: string[] = [];
  await listJsonl(opts.root, files);
  const live = new Set<string>();
  let cacheChanged = false;
  for (const path of files) {
    let st;
    try {
      st = await stat(path);
    } catch {
      continue;
    }
    if (st.mtimeMs < cutoffMs) continue;
    live.add(path);
    const hit = cache.files[path];
    if (hit && hit.mtime === st.mtimeMs && hit.size === st.size) continue;
    let content: string;
    try {
      content = await readFile(path, "utf8");
    } catch {
      continue;
    }
    cache.files[path] = { mtime: st.mtimeMs, size: st.size, days: opts.extract(content) };
    cacheChanged = true;
  }
  for (const path of Object.keys(cache.files)) {
    if (!live.has(path)) {
      delete cache.files[path];
      cacheChanged = true;
    }
  }
  if (cacheChanged) {
    await writeAtomic(cachePath, JSON.stringify(cache));
  }

  const daily: DailyTotals = {};
  for (const entry of Object.values(cache.files)) {
    for (const [date, totals] of Object.entries(entry.days)) {
      daily[date] = addTotals(daily[date] ?? ZERO_TOTALS, totals);
    }
  }

  const ledgerPath = join(home, "token-history.json");
  let ledger = await loadLedger(ledgerPath);
  if (mergeDailyIntoLedger(ledger, opts.provider, daily, today)) {
    // Another app may have written meanwhile: fold its view in before replacing the file.
    const onDisk = await readJson(ledgerPath);
    if (isLedger(onDisk)) ledger = mergeLedgers(onDisk, ledger);
    pruneLedger(ledger, today);
    await writeAtomic(ledgerPath, JSON.stringify(ledger));
  }
  return statsFrom(ledger, opts.provider, today);
}
