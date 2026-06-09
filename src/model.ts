import { readdir, stat, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export interface CurrentModel {
  id: string;
  name: string;
}

/**
 * Convert a model ID into a human-readable name (pure function).
 * e.g. "claude-opus-4-8" -> "Opus 4.8", "claude-3-5-sonnet-20241022" -> "Sonnet 3.5"
 */
export function friendlyModelName(id: string): string {
  if (!id) {
    return "Unknown";
  }
  const lower = id.toLowerCase();
  const family = ["opus", "sonnet", "haiku"].find((f) => lower.includes(f));
  const verMatch = lower.match(/(\d+)[-.](\d+)/);
  const version = verMatch ? `${verMatch[1]}.${verMatch[2]}` : "";
  if (family) {
    const cap = family.charAt(0).toUpperCase() + family.slice(1);
    return version ? `${cap} ${version}` : cap;
  }
  return id;
}

/**
 * Find the model of the last assistant message in transcript (JSONL) content (pure function).
 * Scans from the end and returns the first message.model found.
 */
export function extractLastModel(content: string): string | null {
  const lines = content.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line) {
      continue;
    }
    let obj: unknown;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    const model = (obj as { message?: { model?: unknown } })?.message?.model;
    if (typeof model === "string" && model.length > 0) {
      return model;
    }
  }
  return null;
}

/** Find the most recently modified transcript path under ~/.claude/projects. */
async function latestTranscriptPath(): Promise<string | null> {
  const root = join(homedir(), ".claude", "projects");
  let dirs;
  try {
    dirs = await readdir(root, { withFileTypes: true });
  } catch {
    return null;
  }

  let best: string | null = null;
  let bestMtime = -1;
  for (const d of dirs) {
    if (!d.isDirectory()) {
      continue;
    }
    const sub = join(root, d.name);
    let files: string[];
    try {
      files = await readdir(sub);
    } catch {
      continue;
    }
    for (const f of files) {
      if (!f.endsWith(".jsonl")) {
        continue;
      }
      const p = join(sub, f);
      try {
        const s = await stat(p);
        if (s.mtimeMs > bestMtime) {
          bestMtime = s.mtimeMs;
          best = p;
        }
      } catch {
        /* skip */
      }
    }
  }
  return best;
}

/**
 * Read the model in use in the most recent session (local, best-effort).
 * Returns null if not found.
 */
export async function readCurrentModel(): Promise<CurrentModel | null> {
  const path = await latestTranscriptPath();
  if (!path) {
    return null;
  }
  let content: string;
  try {
    content = await readFile(path, "utf8");
  } catch {
    return null;
  }
  const id = extractLastModel(content);
  if (!id) {
    return null;
  }
  return { id, name: friendlyModelName(id) };
}
