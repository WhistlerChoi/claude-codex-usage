import { readdir, stat, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export interface CurrentModel {
  id: string;
  name: string;
}

/**
 * 모델 ID를 사람이 읽는 이름으로 변환 (순수 함수).
 * 예: "claude-opus-4-8" -> "Opus 4.8", "claude-3-5-sonnet-20241022" -> "Sonnet 3.5"
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
 * 트랜스크립트(JSONL) 내용에서 마지막 assistant 메시지의 model을 찾는다 (순수 함수).
 * 끝에서부터 스캔해 처음 발견되는 message.model을 반환.
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

/** ~/.claude/projects 아래에서 가장 최근에 수정된 트랜스크립트 경로를 찾는다. */
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
 * 가장 최근 세션에서 사용 중인 모델을 읽는다 (로컬, best-effort).
 * 찾지 못하면 null.
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
