import * as vscode from "vscode";
import type { UsageData } from "./usageClient";
import type { CurrentModel } from "./model";
import type { TokenStats } from "./tokenHistory";
import { statusBarText, tooltipMarkdown, peakUtilization, formatRetryIn, TOGGLE_TOKEN_HISTORY_COMMAND } from "./format";

export interface Thresholds {
  warn: number;
  alert: number;
}

/** Everything one usage render needs besides the usage itself. */
export interface UsageView {
  lastUpdated: Date;
  thresholds: Thresholds;
  stale?: boolean;
  model?: CurrentModel | null;
  tokens?: TokenStats | null;
  showTokenHistory?: boolean;
  /** accountLine() — "email · plan · org" */
  account?: string | null;
}

export class UsageStatusBar {
  private readonly item: vscode.StatusBarItem;

  constructor() {
    this.item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    this.item.command = "pulse.refresh";
    this.item.text = "$(sync~spin) Pulse";
    this.item.tooltip = "Loading Claude Code usage...";
    this.item.show();
  }

  showLoading(): void {
    this.item.text = "$(sync~spin) Pulse";
  }

  showUsage(usage: UsageData, view: UsageView): void {
    const { lastUpdated, thresholds, stale = false, model, tokens, showTokenHistory = false, account } = view;
    this.item.text = statusBarText(usage, model?.name) + (stale ? " $(warning)" : "");
    const md = new vscode.MarkdownString(
      tooltipMarkdown(usage, lastUpdated, new Date(), model, tokens, showTokenHistory, account) +
        (stale ? "\n\n⚠ Last refresh failed — showing previous value" : "")
    );
    // Trust only the token-history toggle link; every other command link stays inert.
    md.isTrusted = { enabledCommands: [TOGGLE_TOKEN_HISTORY_COMMAND] };
    this.item.tooltip = md;

    const peak = peakUtilization(usage);
    if (peak >= thresholds.alert) {
      this.item.backgroundColor = new vscode.ThemeColor("statusBarItem.errorBackground");
    } else if (peak >= thresholds.warn) {
      this.item.backgroundColor = new vscode.ThemeColor("statusBarItem.warningBackground");
    } else {
      this.item.backgroundColor = undefined;
    }
  }

  /** Auth / credentials failure — the user really does have to log in. */
  showError(message: string): void {
    this.item.text = "$(error) Claude login required";
    this.item.backgroundColor = new vscode.ThemeColor("statusBarItem.errorBackground");
    const md = new vscode.MarkdownString(`**Could not fetch usage**\n\n${message}\n\nClick to retry`);
    this.item.tooltip = md;
  }

  /**
   * Transient failure (network, HTTP 429) with no previous value to show. Deliberately does NOT say
   * "login required": logging in cannot fix a rate limit, and saying so sends the user in circles.
   */
  showTransient(message: string, retryInMs: number): void {
    this.item.text = "$(warning) Pulse ··";
    this.item.backgroundColor = new vscode.ThemeColor("statusBarItem.warningBackground");
    const md = new vscode.MarkdownString(
      `**Could not fetch usage**\n\n${message}\n\n${formatRetryIn(retryInMs)} · Click to retry now`
    );
    this.item.tooltip = md;
  }

  dispose(): void {
    this.item.dispose();
  }
}
