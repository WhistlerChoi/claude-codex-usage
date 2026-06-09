import * as vscode from "vscode";
import type { UsageData } from "./usageClient";
import type { CurrentModel } from "./model";
import { statusBarText, tooltipMarkdown, peakUtilization } from "./format";

export interface Thresholds {
  warn: number;
  alert: number;
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

  showUsage(
    usage: UsageData,
    lastUpdated: Date,
    thresholds: Thresholds,
    stale = false,
    model?: CurrentModel | null
  ): void {
    this.item.text = statusBarText(usage, model?.name) + (stale ? " $(warning)" : "");
    const md = new vscode.MarkdownString(
      tooltipMarkdown(usage, lastUpdated, new Date(), model) +
        (stale ? "\n\n⚠ Last refresh failed — showing previous value" : "")
    );
    md.isTrusted = false;
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

  showError(message: string): void {
    this.item.text = "$(error) Claude login required";
    this.item.backgroundColor = new vscode.ThemeColor("statusBarItem.errorBackground");
    const md = new vscode.MarkdownString(`**Could not fetch usage**\n\n${message}\n\nClick to retry`);
    this.item.tooltip = md;
  }

  dispose(): void {
    this.item.dispose();
  }
}
