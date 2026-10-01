import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile } from "node:fs/promises";
import { claudeHome, credentialsFilePath, keychainServiceName, type ClaudeHome } from "./claudeHome";

const execFileAsync = promisify(execFile);

export class CredentialsError extends Error {}

/** Extract accessToken from a credentials JSON string. Format: { claudeAiOauth: { accessToken } } or { accessToken }. */
export function extractAccessToken(raw: string): string {
  let token: unknown;
  try {
    const parsed = JSON.parse(raw.trim());
    token = parsed?.claudeAiOauth?.accessToken ?? parsed?.accessToken;
  } catch {
    throw new CredentialsError("Could not read credentials. Log in with Claude Code.");
  }
  if (typeof token !== "string" || token.length === 0) {
    throw new CredentialsError("Could not find accessToken. You may need to log in again.");
  }
  return token;
}

/** The OAuth fields we care about, unwrapping the optional `claudeAiOauth` wrapper. */
export interface ParsedCredentials {
  accessToken: string;
  /** ms epoch, absent in older/hand-written credential blobs */
  expiresAt?: number;
  /** "pro" | "max" | "team" | "enterprise" — absent in older blobs */
  subscriptionType?: string;
  /** e.g. "default_claude_max_5x" */
  rateLimitTier?: string;
}

/**
 * Parse one credential store's JSON. Returns null instead of throwing so that one unreadable
 * store never masks a good one.
 */
export function parseCredentials(raw: string): ParsedCredentials | null {
  let parsed: any;
  try {
    parsed = JSON.parse(raw.trim());
  } catch {
    return null;
  }
  const oauth = parsed?.claudeAiOauth ?? parsed;
  const token = oauth?.accessToken;
  if (typeof token !== "string" || token.length === 0) {
    return null;
  }
  const expiresAt = oauth?.expiresAt;
  const out: ParsedCredentials = {
    accessToken: token,
    expiresAt: typeof expiresAt === "number" ? expiresAt : undefined,
  };
  // Only present keys, so callers comparing records see no `undefined` fields.
  for (const key of ["subscriptionType", "rateLimitTier"] as const) {
    const v = oauth?.[key];
    if (typeof v === "string" && v.length > 0) out[key] = v;
  }
  return out;
}

/**
 * Pick the live credentials out of every store that has one ("freshest wins").
 *
 * Both stores must be consulted because Claude Code moved to the keychain on macOS and can leave a
 * long-dead ~/.claude/.credentials.json behind: preferring the file unconditionally means every
 * poll presents an expired token, which the API eventually throttles (HTTP 429) instead of
 * rejecting cleanly. Candidates are ranked by `expiresAt`; ties go to the LAST candidate, so
 * callers pass the keychain last. Pure (no I/O) so it is testable.
 */
export function pickFreshest(candidates: Array<string | null>): ParsedCredentials | null {
  let best: ParsedCredentials | null = null;
  let bestRank = -Infinity;
  for (const raw of candidates) {
    if (raw == null) continue;
    const parsed = parseCredentials(raw);
    if (!parsed) continue;
    const rank = parsed.expiresAt ?? 0;
    if (best == null || rank >= bestRank) {
      best = parsed;
      bestRank = rank;
    }
  }
  return best;
}

/** pickFreshest, reduced to the token. */
export function pickFreshestToken(candidates: Array<string | null>): string | null {
  return pickFreshest(candidates)?.accessToken ?? null;
}

/** Read credentials from the common file path (Windows/Linux/macOS). Returns null if absent. */
async function readFromFile(home: ClaudeHome): Promise<string | null> {
  try {
    return await readFile(credentialsFilePath(home), "utf8");
  } catch {
    return null;
  }
}

/** Read credentials from the macOS keychain. Returns null if absent. */
async function readFromKeychain(home: ClaudeHome): Promise<string | null> {
  if (process.platform !== "darwin") {
    return null;
  }
  try {
    const { stdout } = await execFileAsync("security", [
      "find-generic-password",
      "-s",
      keychainServiceName(home),
      "-w",
    ]);
    return stdout;
  } catch {
    return null;
  }
}

/**
 * Read Claude Code's OAuth credentials.
 * Reads <configDir>/.credentials.json and (on macOS) the keychain, then uses whichever token is
 * fresher — see pickFreshest for why the file cannot simply win.
 * Claude Code refreshes the token periodically, so re-reading every poll handles expiry automatically.
 */
export async function readCredentials(home: ClaudeHome = claudeHome()): Promise<ParsedCredentials> {
  // Keychain last: it wins ties, matching where Claude Code stores credentials on macOS.
  const [fileRaw, keychainRaw] = await Promise.all([
    readFromFile(home),
    readFromKeychain(home),
  ]);
  const creds = pickFreshest([fileRaw, keychainRaw]);
  if (creds) {
    return creds;
  }
  if (fileRaw != null || keychainRaw != null) {
    // A store exists but holds no usable token (truncated/hand-edited blob).
    throw new CredentialsError("Could not find accessToken. You may need to log in again.");
  }

  throw new CredentialsError(
    "Could not read credentials. Log in with Claude Code."
  );
}

/** Read Claude Code's OAuth accessToken (see readCredentials). */
export async function readAccessToken(home: ClaudeHome = claudeHome()): Promise<string> {
  return (await readCredentials(home)).accessToken;
}
