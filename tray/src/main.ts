import { app, Tray, Menu, nativeImage } from "electron";
import { fetchUsage, AuthError, type UsageData } from "../../src/usageClient";
import { CredentialsError } from "../../src/credentials";
import { readCurrentModel, type CurrentModel } from "../../src/model";
import { pct, formatResetIn } from "../../src/format";
import { IconRenderer } from "./iconRenderer";

const COLORS = { normal: "#2D7DF6", warn: "#E8A317", alert: "#D64545", error: "#777777" };

let tray: Tray | null = null;
let renderer: IconRenderer;
let timer: NodeJS.Timeout | undefined;
let lastUsage: UsageData | undefined;
let lastModel: CurrentModel | null = null;
let inFlight = false;

function intervalMs(): number {
  const raw = process.env.CLAUDE_USAGE_INTERVAL;
  const sec = raw ? Number(raw) : 300;
  return Math.max(10, Number.isFinite(sec) ? sec : 300) * 1000;
}

function bgFor(usage: UsageData): string {
  const peak = Math.max(usage.fiveHour.utilization, usage.sevenDay.utilization) / 100;
  if (peak >= 0.95) return COLORS.alert;
  if (peak >= 0.8) return COLORS.warn;
  return COLORS.normal;
}

function detailLines(usage: UsageData, model: CurrentModel | null): string[] {
  const lines = [
    `5시간: ${pct(usage.fiveHour.utilization)}% · ${formatResetIn(usage.fiveHour.resetsAt)}`,
    `주간: ${pct(usage.sevenDay.utilization)}% · ${formatResetIn(usage.sevenDay.resetsAt)}`,
  ];
  if (usage.sevenDayOpus) {
    lines.push(`주간 Opus: ${pct(usage.sevenDayOpus.utilization)}% · ${formatResetIn(usage.sevenDayOpus.resetsAt)}`);
  }
  if (usage.sevenDaySonnet) {
    lines.push(`주간 Sonnet: ${pct(usage.sevenDaySonnet.utilization)}% · ${formatResetIn(usage.sevenDaySonnet.resetsAt)}`);
  }
  if (model) {
    lines.push(`현재 모델: ${model.name} (${model.id})`);
  }
  return lines;
}

function buildMenu(lines: string[]): Menu {
  const template: Electron.MenuItemConstructorOptions[] = lines.map((l) => ({ label: l, enabled: false }));
  template.push(
    { type: "separator" },
    { label: "지금 새로고침", click: () => void refresh() },
    { label: "종료", click: () => app.quit() }
  );
  return Menu.buildFromTemplate(template);
}

async function applyUsage(usage: UsageData, model: CurrentModel | null, stale = false): Promise<void> {
  if (!tray) return;
  const icon = await renderer.render(String(pct(usage.fiveHour.utilization)), bgFor(usage));
  tray.setImage(icon);

  const lines = detailLines(usage, model);
  const tip = lines.join("\n") + (stale ? "\n⚠ 갱신 실패 — 이전 값" : "");
  tray.setToolTip("Claude 사용량\n" + tip);
  tray.setContextMenu(buildMenu(stale ? ["⚠ 갱신 실패 — 이전 값 표시 중", ...lines] : lines));
}

function applyError(message: string): void {
  if (!tray) return;
  tray.setImage(nativeImage.createEmpty());
  tray.setTitle?.("!");
  tray.setToolTip("Claude 사용량\n⚠ " + message);
  tray.setContextMenu(buildMenu([message]));
}

async function refresh(): Promise<void> {
  if (inFlight) return;
  inFlight = true;
  try {
    const [usage, model] = await Promise.all([fetchUsage(), readCurrentModel().catch(() => null)]);
    lastUsage = usage;
    lastModel = model;
    await applyUsage(usage, model);
  } catch (err) {
    if (err instanceof AuthError || err instanceof CredentialsError) {
      applyError(err.message);
    } else if (lastUsage) {
      await applyUsage(lastUsage, lastModel, true);
    } else {
      applyError(err instanceof Error ? err.message : String(err));
    }
  } finally {
    inFlight = false;
  }
}

app.whenReady().then(() => {
  renderer = new IconRenderer();
  tray = new Tray(nativeImage.createEmpty());
  tray.setToolTip("Claude 사용량 불러오는 중...");

  void refresh();
  timer = setInterval(() => void refresh(), intervalMs());

  // macOS Dock 숨김 (트레이 전용)
  app.dock?.hide();
});

app.on("window-all-closed", () => {
  // 트레이 앱이므로 창이 없어도 종료하지 않음
});

app.on("before-quit", () => {
  if (timer) clearInterval(timer);
  renderer?.dispose();
});
