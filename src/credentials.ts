import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile } from "node:fs/promises";
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

/** Read credentials from the common file path (Windows/Linux/macOS). Returns null if absent. */
async function readFromFile(): Promise<string | null> {
  const path = join(homedir(), ".claude", ".credentials.json");
  try {
    return await readFile(path, "utf8");
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

/**
 * Read Claude Code's OAuth accessToken.
 * - First ~/.claude/.credentials.json (default on Windows/Linux, and used on macOS if present)
 * - Otherwise the macOS keychain
 * Claude Code refreshes the token periodically, so re-reading every poll handles expiry automatically.
 */
export async function readAccessToken(): Promise<string> {
  const fileRaw = await readFromFile();
  if (fileRaw) {
    return extractAccessToken(fileRaw);
  }

  const keychainRaw = await readFromKeychain();
  if (keychainRaw) {
    return extractAccessToken(keychainRaw);
  }

  throw new CredentialsError(
    "Could not read credentials. Log in with Claude Code."
  );
}
