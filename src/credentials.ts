import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const execFileAsync = promisify(execFile);

const KEYCHAIN_SERVICE = "Claude Code-credentials";

export class CredentialsError extends Error {}

/** 자격 증명 JSON 문자열에서 accessToken을 뽑는다. 형식: { claudeAiOauth: { accessToken } } 또는 { accessToken }. */
export function extractAccessToken(raw: string): string {
  let token: unknown;
  try {
    const parsed = JSON.parse(raw.trim());
    token = parsed?.claudeAiOauth?.accessToken ?? parsed?.accessToken;
  } catch {
    throw new CredentialsError("자격 증명 형식을 해석하지 못했습니다.");
  }
  if (typeof token !== "string" || token.length === 0) {
    throw new CredentialsError("accessToken을 찾지 못했습니다. 재로그인이 필요할 수 있습니다.");
  }
  return token;
}

/** Windows/Linux/macOS 공통 파일 경로의 자격 증명을 읽는다. 없으면 null. */
async function readFromFile(): Promise<string | null> {
  const path = join(homedir(), ".claude", ".credentials.json");
  try {
    return await readFile(path, "utf8");
  } catch {
    return null;
  }
}

/** macOS 키체인에서 자격 증명을 읽는다. 없으면 null. */
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
 * Claude Code의 OAuth accessToken을 읽는다.
 * - 우선 ~/.claude/.credentials.json (Windows/Linux 기본, macOS도 있으면 사용)
 * - 없으면 macOS 키체인
 * Claude Code가 토큰을 주기적으로 갱신하므로, 폴링마다 새로 읽으면 만료에 자동 대응된다.
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
    "Claude Code 자격 증명을 찾지 못했습니다. Claude Code에 로그인했는지 확인하세요."
  );
}
