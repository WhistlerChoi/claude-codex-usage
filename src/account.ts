import { readFile, stat } from "node:fs/promises";
import { claudeHome, globalConfigCandidates, type ClaudeHome } from "./claudeHome";

/** The logged-in account, from `oauthAccount` in Claude Code's global config. */
export interface AccountInfo {
  email: string;
  displayName?: string;
  orgName?: string;
  /** e.g. "claude_team", "claude_enterprise", "claude_max" */
  orgType?: string;
  accountUuid?: string;
  orgUuid?: string;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** Parse Claude Code's global config JSON. Null when it holds no logged-in account. Pure. */
export function parseAccountInfo(raw: string): AccountInfo | null {
  let parsed: any;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  const oa = parsed?.oauthAccount;
  const email = str(oa?.emailAddress);
  if (!email) {
    return null;
  }
  return {
    email,
    displayName: str(oa.displayName),
    orgName: str(oa.organizationName),
    orgType: str(oa.organizationType),
    accountUuid: str(oa.accountUuid),
    orgUuid: str(oa.organizationUuid),
  };
}

// The global config is large and rewritten constantly by Claude Code; re-parse only on change.
const cache = new Map<string, { mtimeMs: number; size: number; info: AccountInfo | null }>();

/** Best-effort: any failure (no file, unreadable, logged out) is null, never an error. */
export async function readAccountInfo(home: ClaudeHome = claudeHome()): Promise<AccountInfo | null> {
  for (const path of globalConfigCandidates(home)) {
    let s;
    try {
      s = await stat(path);
    } catch {
      continue; // absent → next candidate
    }
    const hit = cache.get(path);
    if (hit && hit.mtimeMs === s.mtimeMs && hit.size === s.size) {
      return hit.info;
    }
    let info: AccountInfo | null = null;
    try {
      info = parseAccountInfo(await readFile(path, "utf8"));
    } catch {
      info = null;
    }
    cache.set(path, { mtimeMs: s.mtimeMs, size: s.size, info });
    return info;
  }
  return null;
}
