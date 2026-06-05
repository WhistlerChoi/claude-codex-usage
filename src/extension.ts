import * as vscode from "vscode";
import { fetchUsage, AuthError, type UsageData } from "./usageClient";
import { CredentialsError } from "./credentials";
import { readCurrentModel, type CurrentModel } from "./model";
import { UsageStatusBar, type Thresholds } from "./statusBar";

let statusBar: UsageStatusBar;
let timer: NodeJS.Timeout | undefined;
let lastUsage: UsageData | undefined;
let lastModel: CurrentModel | null = null;
let inFlight = false;

function readConfig(): { intervalMs: number; thresholds: Thresholds } {
  const cfg = vscode.workspace.getConfiguration("claudeUsage");
  const intervalSec = Math.max(10, cfg.get<number>("refreshInterval", 300));
  return {
    intervalMs: intervalSec * 1000,
    thresholds: {
      warn: cfg.get<number>("warnThreshold", 0.8),
      alert: cfg.get<number>("alertThreshold", 0.95),
    },
  };
}

async function refresh(): Promise<void> {
  if (inFlight) {
    return;
  }
  inFlight = true;
  const { thresholds } = readConfig();
  try {
    // 사용량(API)과 모델(로컬 파일)을 병렬로. 모델은 best-effort라 실패해도 무시.
    const [usage, model] = await Promise.all([
      fetchUsage(),
      readCurrentModel().catch(() => null),
    ]);
    lastUsage = usage;
    lastModel = model;
    statusBar.showUsage(usage, new Date(), thresholds, false, model);
  } catch (err) {
    if (err instanceof AuthError || err instanceof CredentialsError) {
      statusBar.showError(err.message);
    } else if (lastUsage) {
      // 네트워크 등 일시적 오류: 마지막 값을 유지하고 stale 표시
      statusBar.showUsage(lastUsage, new Date(), thresholds, true, lastModel);
    } else {
      const msg = err instanceof Error ? err.message : String(err);
      statusBar.showError(msg);
    }
  } finally {
    inFlight = false;
  }
}

function restartTimer(): void {
  if (timer) {
    clearInterval(timer);
  }
  const { intervalMs } = readConfig();
  timer = setInterval(() => void refresh(), intervalMs);
}

export function activate(context: vscode.ExtensionContext): void {
  statusBar = new UsageStatusBar();
  context.subscriptions.push({ dispose: () => statusBar.dispose() });

  context.subscriptions.push(
    vscode.commands.registerCommand("claudeUsage.refresh", () => {
      statusBar.showLoading();
      void refresh();
    })
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("claudeUsage")) {
        restartTimer();
        void refresh();
      }
    })
  );

  void refresh();
  restartTimer();
}

export function deactivate(): void {
  if (timer) {
    clearInterval(timer);
    timer = undefined;
  }
}
