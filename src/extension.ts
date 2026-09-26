import * as vscode from "vscode";
import { fetchUsage, AuthError, TransientError, type UsageData } from "./usageClient";
import { CredentialsError } from "./credentials";
import { readCurrentModel, type CurrentModel } from "./model";
import { extractDailyTotals } from "./tokens";
import { updateTokenHistory, type TokenStats } from "./tokenHistory";
import { homedir } from "node:os";
import { join } from "node:path";
import { UsageStatusBar, type Thresholds } from "./statusBar";
import { nextRetryDelayMs, shouldShowStale } from "./format";

let statusBar: UsageStatusBar;
let timer: NodeJS.Timeout | undefined;
let lastUsage: UsageData | undefined;
let lastModel: CurrentModel | null = null;
let lastTokens: TokenStats | null = null;
let lastUpdatedAt: Date | undefined;
let lastStale = false;
/** Whether the tooltip shows the 7d / 30d token rows (toggled from the tooltip link; not persisted). */
let showTokenHistory = false;
let lastSuccessAt: number | undefined;
let consecutiveFailures = 0;
let inFlight = false;

function readConfig(): { intervalMs: number; thresholds: Thresholds; showTokens: boolean } {
  const cfg = vscode.workspace.getConfiguration("pulse");
  const intervalSec = Math.max(10, cfg.get<number>("refreshInterval", 300));
  return {
    intervalMs: intervalSec * 1000,
    showTokens: cfg.get<boolean>("showTokens", true),
    thresholds: {
      warn: cfg.get<number>("warnThreshold", 0.8),
      alert: cfg.get<number>("alertThreshold", 0.95),
    },
  };
}

function scheduleNext(delayMs: number): void {
  if (timer) {
    clearTimeout(timer);
  }
  timer = setTimeout(() => void refresh(), delayMs);
}

async function refresh(): Promise<void> {
  if (inFlight) {
    return;
  }
  inFlight = true;
  const { intervalMs, thresholds, showTokens } = readConfig();
  let nextDelayMs = intervalMs;
  try {
    const [usage, model, tokens] = await Promise.all([
      fetchUsage(),
      readCurrentModel().catch(() => null),
      showTokens
        ? updateTokenHistory({
            provider: "claude",
            root: join(homedir(), ".claude", "projects"),
            extract: extractDailyTotals,
          }).catch(() => null)
        : Promise.resolve(null),
    ]);
    lastUsage = usage;
    lastModel = model;
    lastTokens = tokens;
    lastSuccessAt = Date.now();
    consecutiveFailures = 0;
    lastUpdatedAt = new Date();
    lastStale = false;
    statusBar.showUsage(usage, lastUpdatedAt, thresholds, false, model, tokens, showTokenHistory);
  } catch (err) {
    if (err instanceof AuthError || err instanceof CredentialsError) {
      statusBar.showError(err.message);
      consecutiveFailures = 0;
      // Auth errors do not back off; stay on the regular interval
    } else {
      // Transient error: retry with backoff
      consecutiveFailures += 1;
      const retryAfterMs =
        err instanceof TransientError ? err.retryAfterMs : undefined;
      nextDelayMs = nextRetryDelayMs(consecutiveFailures, intervalMs, retryAfterMs);
      const ageMs = lastSuccessAt != null ? Date.now() - lastSuccessAt : Infinity;
      if (lastUsage && !shouldShowStale(ageMs, intervalMs)) {
        // Still fresh → no display change (keep the last good render, no-op)
      } else if (lastUsage) {
        lastUpdatedAt = new Date();
        lastStale = true;
        statusBar.showUsage(lastUsage, lastUpdatedAt, thresholds, true, lastModel, lastTokens, showTokenHistory);
      } else {
        // No value to fall back on — but this is transient (network, HTTP 429), not an auth
        // problem, so do not tell the user to log in.
        const msg = err instanceof Error ? err.message : String(err);
        statusBar.showTransient(msg, nextDelayMs);
      }
    }
  } finally {
    inFlight = false;
    scheduleNext(nextDelayMs);
  }
}

export function activate(context: vscode.ExtensionContext): void {
  statusBar = new UsageStatusBar();
  context.subscriptions.push({ dispose: () => statusBar.dispose() });

  context.subscriptions.push(
    vscode.commands.registerCommand("pulse.refresh", () => {
      if (!inFlight) {
        statusBar.showLoading();
      }
      void refresh();
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("pulse.toggleTokenHistory", () => {
      showTokenHistory = !showTokenHistory;
      // Re-render from cached state only — toggling must never trigger a network poll.
      if (lastUsage && lastUpdatedAt) {
        statusBar.showUsage(lastUsage, lastUpdatedAt, readConfig().thresholds, lastStale, lastModel, lastTokens, showTokenHistory);
      }
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("pulse")) {
        void refresh();
      }
    })
  );

  void refresh();
}

export function deactivate(): void {
  if (timer) {
    clearTimeout(timer);
    timer = undefined;
  }
}
