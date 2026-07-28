import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const execFileAsync = promisify(execFile);

const KEYCHAIN_SERVICE = "Claude Code-credentials";

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
  return {
    accessToken: token,
    expiresAt: typeof expiresAt === "number" ? expiresAt : undefined,
  };
}

/**
 * Pick the live token out of every store that has one ("freshest wins").
 *
 * Both stores must be consulted because Claude Code moved to the keychain on macOS and can leave a
 * long-dead ~/.claude/.credentials.json behind: preferring the file unconditionally means every
 * poll presents an expired token, which the API eventually throttles (HTTP 429) instead of
 * rejecting cleanly — and no amount of logging in helps, because Claude Code writes the keychain
 * while we keep reading the file. Candidates are ranked by `expiresAt`; ties go to the LAST
 * candidate, so callers pass the keychain last. Pure (no I/O) so it is testable.
 */
export function pickFreshestToken(candidates: Array<string | null>): string | null {
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
  return best?.accessToken ?? null;
}

function credentialsFilePath(): string {
  return join(homedir(), ".claude", ".credentials.json");
}

/** Read credentials from the common file path (Windows/Linux/macOS). Returns null if absent. */
async function readFromFile(): Promise<string | null> {
  try {
    return await readFile(credentialsFilePath(), "utf8");
  } catch {
    return null;
  }
}

/** Read credentials from the macOS keychain. Returns null if absent. */
async function readFromKeychain(): Promise<string | null> {
  if (process.platform !== "darwin") {
    return null;
  }
  try {
    const { stdout } = await execFileAsync("security", [
      "find-generic-password",
      "-s",
      KEYCHAIN_SERVICE,
      "-w",
    ]);
    return stdout;
  } catch {
    return null;
  }
}

/** Capture the raw "mdat" (modification date) line from `security find-generic-password` attribute output. */
export function extractKeychainMdat(output: string): string | null {
  const match = output.match(/"mdat"<timedate>=(.+)/);
  return match ? match[1].trim() : null;
}

async function readFileFingerprint(): Promise<string | null> {
  try {
    const s = await stat(credentialsFilePath());
    return `file:${s.mtimeMs}`;
  } catch {
    return null;
  }
}

async function readKeychainFingerprint(): Promise<string | null> {
  if (process.platform !== "darwin") {
    return null;
  }
  try {
    // No -w: attribute-only read, never triggers a keychain ACL prompt.
    const { stdout } = await execFileAsync("security", [
      "find-generic-password",
      "-s",
      KEYCHAIN_SERVICE,
    ]);
    const mdat = extractKeychainMdat(stdout);
    return mdat ? `keychain:${mdat}` : null;
  } catch {
    return null;
  }
}

/**
 * Join the per-store fingerprints into one. Every present store contributes, so a rotation in
 * EITHER store registers as a change; null only when no credentials exist anywhere.
 *
 * Combining is what makes "freshest wins" hold over time. A file-first fingerprint is stuck on a
 * dead file's mtime: it never changes, so the cache keeps serving the expired token and the
 * keychain rotation is never noticed. Pure (no I/O) so it is testable.
 */
export function combineFingerprints(parts: Array<string | null>): string | null {
  const present = parts.filter((p): p is string => p != null);
  return present.length > 0 ? present.join("|") : null;
}

/**
 * Prompt-free change fingerprint of the credential store: the file's mtime and the keychain item's
 * mdat attribute, combined. null means no credentials are present anywhere. The source prefixes
 * make a file<->keychain transition register as a change.
 */
export async function readFingerprint(): Promise<string | null> {
  const [file, keychain] = await Promise.all([
    readFileFingerprint(),
    readKeychainFingerprint(),
  ]);
  return combineFingerprints([file, keychain]);
}

/**
 * Read Claude Code's OAuth accessToken (the secret read — may prompt on macOS).
 * Reads ~/.claude/.credentials.json and (on macOS) the keychain, then uses whichever token is
 * fresher — see pickFreshestToken for why the file cannot simply win.
 */
export async function readAccessToken(): Promise<string> {
  // Keychain last: it wins ties, matching where Claude Code stores credentials on macOS.
  const [fileRaw, keychainRaw] = await Promise.all([
    readFromFile(),
    readFromKeychain(),
  ]);

  const token = pickFreshestToken([fileRaw, keychainRaw]);
  if (token) {
    return token;
  }
  if (fileRaw != null || keychainRaw != null) {
    // A store exists but holds no usable token (truncated/hand-edited blob).
    throw new CredentialsError("Could not find accessToken. You may need to log in again.");
  }

  throw new CredentialsError(
    "Could not read credentials. Log in with Claude Code."
  );
}
