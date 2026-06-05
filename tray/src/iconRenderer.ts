import { BrowserWindow, nativeImage, type NativeImage } from "electron";

/**
 * 숨겨진 창의 canvas로 트레이 아이콘을 그린다.
 * 메인 프로세스엔 DOM이 없으므로, 오프스크린 창에서 그려 dataURL을 받아온다.
 */
export class IconRenderer {
  private win: BrowserWindow | null = null;
  private ready: Promise<void>;

  constructor() {
    this.win = new BrowserWindow({
      width: 64,
      height: 64,
      show: false,
      webPreferences: { offscreen: true },
    });

    const html = `<!doctype html><html><body><canvas id="c"></canvas>
<script>
function drawIcon(text, bg) {
  const size = 32;
  const c = document.getElementById('c');
  c.width = size; c.height = size;
  const ctx = c.getContext('2d');
  ctx.clearRect(0, 0, size, size);

  // 배경 라운드 사각형 (어떤 작업표시줄 테마에서도 보이도록)
  const r = 7, pad = 1, x = pad, y = pad, w = size - pad * 2, h = size - pad * 2;
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
  ctx.fillStyle = bg;
  ctx.fill();

  // 숫자
  let fontSize = text.length >= 3 ? 15 : text.length === 2 ? 19 : 22;
  ctx.fillStyle = '#ffffff';
  ctx.font = 'bold ' + fontSize + 'px Segoe UI, -apple-system, Arial, sans-serif';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, size / 2, size / 2 + 1);

  return c.toDataURL('image/png');
}
</script></body></html>`;

    this.ready = this.win.loadURL("data:text/html;charset=utf-8," + encodeURIComponent(html));
  }

  /** text(예: "42")와 배경색으로 트레이 아이콘 이미지를 만든다. */
  async render(text: string, bg: string): Promise<NativeImage> {
    await this.ready;
    if (!this.win) {
      return nativeImage.createEmpty();
    }
    const dataURL: string = await this.win.webContents.executeJavaScript(
      `drawIcon(${JSON.stringify(text)}, ${JSON.stringify(bg)})`
    );
    return nativeImage.createFromDataURL(dataURL);
  }

  dispose(): void {
    this.win?.destroy();
    this.win = null;
  }
}
