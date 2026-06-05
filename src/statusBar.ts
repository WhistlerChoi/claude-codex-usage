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
    this.item.command = "claudeUsage.refresh";
    this.item.text = "$(sync~spin) Claude 사용량";
    this.item.tooltip = "Claude Code 사용량을 불러오는 중...";
    this.item.show();
  }

  showLoading(): void {
    this.item.text = "$(sync~spin) Claude 사용량";
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
        (stale ? "\n\n⚠ 마지막 갱신 실패 — 이전 값 표시 중" : "")
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
    this.item.text = "$(error) Claude 로그인 필요";
    this.item.backgroundColor = new vscode.ThemeColor("statusBarItem.errorBackground");
    const md = new vscode.MarkdownString(`**사용량을 가져올 수 없습니다**\n\n${message}\n\n클릭하면 다시 시도`);
    this.item.tooltip = md;
  }

  dispose(): void {
    this.item.dispose();
  }
}
