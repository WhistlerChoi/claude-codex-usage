import * as vscode from "vscode";
import { fetchUsage, AuthError, TransientError, type UsageData } from "./usageClient";
import { CredentialsError } from "./credentials";
import { readCurrentModel, type CurrentModel } from "./model";
import { UsageStatusBar, type Thresholds } from "./statusBar";
import { nextRetryDelayMs, shouldShowStale } from "./format";

let statusBar: UsageStatusBar;
let timer: NodeJS.Timeout | undefined;
let lastUsage: UsageData | undefined;
let lastModel: CurrentModel | null = null;
let lastSuccessAt: number | undefined;
let consecutiveFailures = 0;
let inFlight = false;

function readConfig(): { intervalMs: number; thresholds: Thresholds } {
  const cfg = vscode.workspace.getConfiguration("pulse");
  const intervalSec = Math.max(10, cfg.get<number>("refreshInterval", 300));
  return {
    intervalMs: intervalSec * 1000,
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
  const { intervalMs, thresholds } = readConfig();
  let nextDelayMs = intervalMs;
  try {
    const [usage, model] = await Promise.all([
      fetchUsage(),
      readCurrentModel().catch(() => null),
    ]);
    lastUsage = usage;
    lastModel = model;
    lastSuccessAt = Date.now();
    consecutiveFailures = 0;
    statusBar.showUsage(usage, new Date(), thresholds, false, model);
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
        statusBar.showUsage(lastUsage, new Date(), thresholds, true, lastModel);
      } else {
        const msg = err instanceof Error ? err.message : String(err);
        statusBar.showError(msg);
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
