import { readAccessToken } from "./credentials";

const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";

export interface UsageWindow {
  /** 0.0 ~ 1.0 */
  utilization: number;
  /** ISO 8601, 없을 수 있음 */
  resetsAt: string | null;
}

export interface UsageData {
  fiveHour: UsageWindow;
  sevenDay: UsageWindow;
  sevenDayOpus: UsageWindow | null;
  sevenDaySonnet: UsageWindow | null;
}

export class AuthError extends Error {}

function parseWindow(raw: unknown): UsageWindow | null {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const obj = raw as Record<string, unknown>;
  const util = obj.utilization;
  if (typeof util !== "number") {
    return null;
  }
  const resets = obj.resets_at;
  return {
    utilization: util,
    resetsAt: typeof resets === "string" ? resets : null,
  };
}

/** API 원시 JSON을 UsageData로 변환 (순수 함수, 테스트 대상). */
export function parseUsage(json: unknown): UsageData {
  const obj = (json && typeof json === "object" ? json : {}) as Record<string, unknown>;
  const fiveHour = parseWindow(obj.five_hour);
  const sevenDay = parseWindow(obj.seven_day);
  if (!fiveHour || !sevenDay) {
    throw new Error("usage 응답에 five_hour/seven_day가 없습니다.");
  }
  return {
    fiveHour,
    sevenDay,
    sevenDayOpus: parseWindow(obj.seven_day_opus),
    sevenDaySonnet: parseWindow(obj.seven_day_sonnet),
  };
}

/** usage 엔드포인트를 호출해 현재 사용량을 가져온다. */
export async function fetchUsage(): Promise<UsageData> {
  const token = await readAccessToken();

  const res = await fetch(USAGE_URL, {
    headers: {
      Authorization: `Bearer ${token}`,
      "anthropic-beta": "oauth-2025-04-20",
    },
  });

  if (res.status === 401 || res.status === 403) {
    throw new AuthError("인증이 만료되었습니다. Claude Code에서 재로그인하세요.");
  }
  if (!res.ok) {
    throw new Error(`usage API 오류: HTTP ${res.status}`);
  }

  const json = await res.json();
  return parseUsage(json);
}
