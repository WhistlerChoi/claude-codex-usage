import { readAccessToken } from "./credentials";

const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";

export interface UsageWindow {
  /** percent, 0-100 */
  utilization: number;
  /** ISO 8601, may be absent */
  resetsAt: string | null;
}

export interface UsageData {
  fiveHour: UsageWindow;
  sevenDay: UsageWindow;
  sevenDayOpus: UsageWindow | null;
  sevenDaySonnet: UsageWindow | null;
}

export class AuthError extends Error {}

/** Retryable transient error (network/5xx/429, etc.). */
export class TransientError extends Error {
  readonly retryAfterMs?: number;
  constructor(message: string, retryAfterMs?: number) {
    super(message);
    this.retryAfterMs = retryAfterMs;
  }
}

/** Convert the Retry-After header (integer seconds) to ms. undefined if absent or non-integer (e.g. HTTP-date). */
export function parseRetryAfterMs(header: string | null): number | undefined {
  if (header == null) return undefined;
  const trimmed = header.trim();
  if (!/^\d+$/.test(trimmed)) return undefined;
  return parseInt(trimmed, 10) * 1000;
}

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

/** Convert raw API JSON into UsageData (pure function, tested). */
export function parseUsage(json: unknown): UsageData {
  const obj = (json && typeof json === "object" ? json : {}) as Record<string, unknown>;
  const fiveHour = parseWindow(obj.five_hour);
  const sevenDay = parseWindow(obj.seven_day);
  if (!fiveHour || !sevenDay) {
    throw new Error("usage response is missing five_hour/seven_day.");
  }
  return {
    fiveHour,
    sevenDay,
    sevenDayOpus: parseWindow(obj.seven_day_opus),
    sevenDaySonnet: parseWindow(obj.seven_day_sonnet),
  };
}

/** Call the usage endpoint to fetch current usage. */
export async function fetchUsage(): Promise<UsageData> {
  const token = await readAccessToken();

  const res = await fetch(USAGE_URL, {
    headers: {
      Authorization: `Bearer ${token}`,
      "anthropic-beta": "oauth-2025-04-20",
    },
  });

  if (res.status === 401 || res.status === 403) {
    throw new AuthError("Authentication expired. Log in again.");
  }
  if (res.status === 429) {
    throw new TransientError(
      `usage API error: HTTP 429`,
      parseRetryAfterMs(res.headers.get("retry-after"))
    );
  }
  if (!res.ok) {
    throw new TransientError(`usage API error: HTTP ${res.status}`);
  }

  const json = await res.json();
  return parseUsage(json);
}
