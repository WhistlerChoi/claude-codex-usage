import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let interval: TimeInterval

    private var lastUsage: UsageData?
    private var lastModel: CurrentModel?
    private var lastUpdated: Date?

    // 2줄 표시 미세조정 (환경변수로 조정, 재빌드 불필요)
    private let fontSize: CGFloat       // CLAUDE_USAGE_FONT_SIZE (기본 9)
    private let lineGap: CGFloat        // CLAUDE_USAGE_LINE_GAP  (두 줄 중심 간격, 기본 10)
    private let yOffset: CGFloat        // CLAUDE_USAGE_Y_OFFSET  (전체 세로 이동, 기본 0)
    private let fontWeight: NSFont.Weight  // CLAUDE_USAGE_FONT_WEIGHT (굵기, 기본 medium≈0.23)

    override init() {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        // 우선순위: 환경변수(CLAUDE_USAGE_*) > UserDefaults(defaults write) > 기본값
        func num(_ envKey: String, _ defaultsKey: String, _ def: Double) -> Double {
            if let raw = env[envKey], let v = Double(raw) { return v }
            if defaults.object(forKey: defaultsKey) != nil { return defaults.double(forKey: defaultsKey) }
            return def
        }
        interval = max(10, num("CLAUDE_USAGE_INTERVAL", "Interval", 300))
        fontSize = CGFloat(num("CLAUDE_USAGE_FONT_SIZE", "FontSize", 9))
        lineGap = CGFloat(num("CLAUDE_USAGE_LINE_GAP", "LineGap", 10))
        yOffset = CGFloat(num("CLAUDE_USAGE_Y_OFFSET", "YOffset", 0))
        fontWeight = NSFont.Weight(
            num("CLAUDE_USAGE_FONT_WEIGHT", "FontWeight", Double(NSFont.Weight.bold.rawValue)))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStacked(top: "··", bottom: "··", color: nil)
        rebuildMenu(detailLines: ["불러오는 중..."])

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let usage = try await fetchUsage()
                let model = readCurrentModel()
                await MainActor.run { self.renderUsage(usage, model) }
            } catch {
                await MainActor.run { self.renderError(error) }
            }
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 렌더링

    private func renderUsage(_ usage: UsageData, _ model: CurrentModel?) {
        lastUsage = usage
        lastModel = model
        lastUpdated = Date()

        setStacked(
            top: "\(pct(usage.fiveHour.utilization))%",
            bottom: "\(pct(usage.sevenDay.utilization))%",
            color: colorForPeak(peakUtilization(usage))
        )

        var lines: [String] = [
            "5시간: \(pct(usage.fiveHour.utilization))% · \(formatResetIn(usage.fiveHour.resetsAt))",
            "주간: \(pct(usage.sevenDay.utilization))% · \(formatResetIn(usage.sevenDay.resetsAt))",
        ]
        if let opus = usage.sevenDayOpus {
            lines.append("주간 Opus: \(pct(opus.utilization))% · \(formatResetIn(opus.resetsAt))")
        }
        if let sonnet = usage.sevenDaySonnet {
            lines.append("주간 Sonnet: \(pct(sonnet.utilization))% · \(formatResetIn(sonnet.resetsAt))")
        }
        if let model = model {
            lines.append("현재 모델: \(model.name) (\(model.id))")
        }
        lines.append("갱신: \(clockString(lastUpdated!))")
        rebuildMenu(detailLines: lines)
    }

    private func renderError(_ error: Error) {
        // 일시적 네트워크 오류면 직전 값 유지 + 표시
        if let usage = lastUsage, !(error is CredentialsError) && !isAuthError(error) {
            setStacked(
                top: "\(pct(usage.fiveHour.utilization))%",
                bottom: "\(pct(usage.sevenDay.utilization))%",
                color: .systemGray
            )
            rebuildMenu(detailLines: [
                "⚠ 갱신 실패 — 이전 값 표시 중",
                error.localizedDescription,
            ])
            return
        }
        setStacked(top: "로그인", bottom: "필요", color: .systemRed)
        rebuildMenu(detailLines: [error.localizedDescription])
    }

    private func isAuthError(_ error: Error) -> Bool {
        if case UsageError.auth = error { return true }
        return false
    }

    private func colorForPeak(_ peak: Double) -> NSColor? {
        if peak >= 0.95 { return .systemRed }
        if peak >= 0.8 { return .systemOrange }
        return nil
    }

    /// 위/아래 두 줄을 메뉴바에 표시 (네트워크 속도 인디케이터 스타일).
    /// 메뉴바 높이에 맞춰 이미지로 직접 그려 세로 위치를 정확히 제어한다.
    private func setStacked(top: String, bottom: String, color: NSColor?) {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = renderStackedImage(top: top, bottom: bottom, color: color)
    }

    private func renderStackedImage(top: String, bottom: String, color: NSColor?) -> NSImage {
        renderStacked(
            top: top, bottom: bottom, color: color,
            fontSize: fontSize, weight: fontWeight, lineGap: lineGap, yOffset: yOffset,
            height: NSStatusBar.system.thickness)
    }

    private func rebuildMenu(detailLines: [String]) {
        let menu = NSMenu()
        menu.autoenablesItems = false  // 정보 줄을 흐리게(disabled) 표시하지 않도록
        for line in detailLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = true
            item.attributedTitle = NSAttributedString(
                string: line,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "지금 새로고침", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }
}

/// 위/아래 두 줄을 height(메뉴바 높이)에 맞춰 이미지로 렌더한다.
func renderStacked(
    top: String, bottom: String, color: NSColor?,
    fontSize: CGFloat, weight: NSFont.Weight, lineGap: CGFloat, yOffset: CGFloat, height: CGFloat
) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
    let drawColor = color ?? .black
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: drawColor]

    let topSize = (top as NSString).size(withAttributes: attrs)
    let botSize = (bottom as NSString).size(withAttributes: attrs)
    let width = ceil(max(topSize.width, botSize.width)) + 2

    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    let centerY = height / 2 + yOffset
    let topY = centerY + lineGap / 2 - topSize.height / 2
    let botY = centerY - lineGap / 2 - botSize.height / 2
    (top as NSString).draw(
        at: NSPoint(x: (width - topSize.width) / 2, y: topY), withAttributes: attrs)
    (bottom as NSString).draw(
        at: NSPoint(x: (width - botSize.width) / 2, y: botY), withAttributes: attrs)
    image.unlockFocus()
    image.isTemplate = (color == nil)
    return image
}

// --render: 메뉴바 표시 이미지를 확대해 PNG로 저장 (오프스크린 시각 검증용)
if let idx = CommandLine.arguments.firstIndex(of: "--render") {
    let outPath = CommandLine.arguments.indices.contains(idx + 1)
        ? CommandLine.arguments[idx + 1] : "/tmp/stacked.png"
    let env = ProcessInfo.processInfo.environment
    func num(_ k: String, _ d: Double) -> CGFloat {
        if let r = env[k], let v = Double(r) { return CGFloat(v) }
        return CGFloat(d)
    }
    let height = NSStatusBar.system.thickness
    // 레이아웃 확인용으로 검은 글씨(비템플릿) 사용
    let img = renderStacked(
        top: "5%", bottom: "4%", color: .black,
        fontSize: num("CLAUDE_USAGE_FONT_SIZE", 9),
        weight: NSFont.Weight(num("CLAUDE_USAGE_FONT_WEIGHT", Double(NSFont.Weight.bold.rawValue))),
        lineGap: num("CLAUDE_USAGE_LINE_GAP", 10),
        yOffset: num("CLAUDE_USAGE_Y_OFFSET", 0),
        height: height)

    let scale: CGFloat = 12
    let big = NSImage(size: NSSize(width: img.size.width * scale, height: img.size.height * scale))
    big.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: big.size).fill()
    NSGraphicsContext.current?.imageInterpolation = .none
    img.draw(in: NSRect(origin: .zero, size: big.size))
    big.unlockFocus()
    if let tiff = big.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outPath))
        print("저장: \(outPath)  (메뉴바 높이=\(height), 항목크기=\(img.size))")
    }
    exit(0)
}

// --once: 메뉴바 없이 현재 값을 한 번 출력하고 종료 (검증/디버그용)
if CommandLine.arguments.contains("--once") {
    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            let usage = try await fetchUsage()
            let model = readCurrentModel()
            print("[gauge] " + menuBarText(usage))
            print("  5시간: \(pct(usage.fiveHour.utilization))% · \(formatResetIn(usage.fiveHour.resetsAt))")
            print("  주간:  \(pct(usage.sevenDay.utilization))% · \(formatResetIn(usage.sevenDay.resetsAt))")
            if let model = model { print("  모델:  \(model.name) (\(model.id))") }
        } catch {
            print("오류: \(error.localizedDescription)")
        }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // Dock 아이콘 없이 메뉴바에만 상주
app.run()
