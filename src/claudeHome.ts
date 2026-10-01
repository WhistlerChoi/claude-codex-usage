import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Where one Claude Code installation keeps its state. `custom` is true when the directory came
 * from CLAUDE_CONFIG_DIR, which changes the keychain service name and the global config path.
 */
export interface ClaudeHome {
  configDir: string;
  custom: boolean;
}

/** CLAUDE_CONFIG_DIR (an empty value counts as unset, as in Claude Code), else ~/.claude. */
export function claudeHome(env: NodeJS.ProcessEnv = process.env): ClaudeHome {
  const dir = env.CLAUDE_CONFIG_DIR;
  if (dir) {
    return { configDir: dir.normalize("NFC"), custom: true };
  }
  return { configDir: join(homedir(), ".claude"), custom: false };
}

/**
 * Keychain service Claude Code stores this home's OAuth credentials under:
 * "Claude Code-credentials", plus "-<first 8 hex of sha256(configDir)>" for a CLAUDE_CONFIG_DIR
 * home. Claude Code hashes the raw (NFC) string — no tilde expansion, no realpath, and a trailing
 * slash changes the hash — so configDir must be passed exactly as exported. Pure.
 */
export function keychainServiceName(home: ClaudeHome): string {
  const base = "Claude Code-credentials";
  if (!home.custom) {
    return base;
  }
  const hash = createHash("sha256").update(home.configDir.normalize("NFC"), "utf8").digest("hex");
  return `${base}-${hash.slice(0, 8)}`;
}

export function credentialsFilePath(home: ClaudeHome): string {
  return join(home.configDir, ".credentials.json");
}

/**
 * Claude Code's global config (holds `oauthAccount`), in the order Claude Code consults them: a
 * legacy `<configDir>/.config.json` wins when it exists, else `.claude.json` in CLAUDE_CONFIG_DIR
 * (custom home) or the user's home directory.
 */
export function globalConfigCandidates(home: ClaudeHome): string[] {
  return [
    join(home.configDir, ".config.json"),
    join(home.custom ? home.configDir : homedir(), ".claude.json"),
  ];
}

export function projectsDir(home: ClaudeHome): string {
  return join(home.configDir, "projects");
}
