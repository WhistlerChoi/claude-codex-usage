import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let interval: TimeInterval

    private var lastUsage: UsageData?
    private var lastModel: CurrentModel?
    private var lastUpdated: Date?
    private var lastSuccessAt: Date?
    private var consecutiveFailures = 0
    private var inFlight = false
    private var aboutWindow: NSWindow?

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
    }

    @objc func refresh() {
        if inFlight { return }
        inFlight = true
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let usage = try await fetchUsage()
                let model = readCurrentModel()
                await MainActor.run {
                    self.inFlight = false
                    self.renderUsage(usage, model)
                    self.lastSuccessAt = Date()
                    self.consecutiveFailures = 0
                    self.scheduleNext(self.interval)
                }
            } catch {
                await MainActor.run {
                    self.inFlight = false
                    self.scheduleNext(self.handleError(error))
                }
            }
        }
    }

    private func scheduleNext(_ delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func login() {
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        if let s = NSAppleScript(source: script) {
            var err: NSDictionary?
            s.executeAndReturnError(&err)
        }
    }

    private static let repoURL = "https://github.com/WhistlerChoi/claude-usage"

    @objc func openGitHub() {
        if let url = URL(string: AppDelegate.repoURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 정보(About) 창

    @objc func showAbout() {
        // 이미 떠 있으면 재사용해 앞으로 가져온다.
        if let win = aboutWindow {
            presentAboutWindow(win)
            return
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.1.0"

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "Claude Usage 정보"
        win.isReleasedWhenClosed = false
        win.contentView = makeAboutContentView(version: version)

        // 항상 다른 앱(풀스크린 앱 포함) 위에 보이도록 한다.
        // - level=.floating: 일반 창보다 위 레이어
        // - canJoinAllSpaces: 현재 활성 스페이스(풀스크린 스페이스 포함)에 함께 표시
        // - fullScreenAuxiliary: 다른 앱이 풀스크린이어도 그 위에 겹쳐 표시(스페이스 전환 없이)
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        aboutWindow = win
        presentAboutWindow(win)
    }

    /// About 창을 화면 중앙에 띄우고 최상위로 가져온다.
    private func presentAboutWindow(_ win: NSWindow) {
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()  // 비활성/풀스크린 상황에서도 강제로 앞에 표시
    }

    func makeAboutContentView(version: String) -> NSView {
        let width: CGFloat = 460
        let bannerHeight: CGFloat = 150
        let contentWidth: CGFloat = 412

        let container = NSView()

        // 상단 헤더 배너 — visualize 스킬로 생성한 PNG(번들 리소스).
        // 리소스를 못 찾으면 코드로 그린 그라데이션으로 폴백.
        let banner = NSImageView()
        banner.image = headerBannerImage(size: NSSize(width: width, height: bannerHeight))
        banner.imageScaling = .scaleAxesIndependently
        banner.translatesAutoresizingMaskIntoConstraints = false

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = .systemFont(ofSize: size, weight: weight)
            f.textColor = color
            f.alignment = .center
            f.lineBreakMode = .byWordWrapping
            f.maximumNumberOfLines = 0
            f.preferredMaxLayoutWidth = contentWidth
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            return f
        }

        let versionLabel = label("버전 \(version)", size: 12, color: .secondaryLabelColor)
        let desc = label(
            "Claude Code의 5시간·주간 사용량과 현재 모델을\n메뉴바에 항상 표시합니다.",
            size: 12, color: .labelColor)
        let meta = label(
            "데이터: ~/.claude · /usage API   ·   폴링 주기: \(Int(interval))초",
            size: 11, color: .secondaryLabelColor)

        // GitHub 링크 버튼
        let github = NSButton(title: "GitHub", target: self, action: #selector(openGitHub))
        github.bezelStyle = .inline
        github.isBordered = false
        github.contentTintColor = .linkColor
        github.attributedTitle = NSAttributedString(
            string: "GitHub",
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: 12),
            ])

        let copyright = label("© 2026 AGLE", size: 11, color: .tertiaryLabelColor)

        let stack = NSStackView(views: [versionLabel, desc, meta, github, copyright])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: meta)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(banner)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: bannerHeight),

            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 18),
            stack.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        return container
    }

    /// About 헤더 배너 이미지를 반환한다.
    /// 번들에 포함된 PNG(visualize 스킬 생성물)를 우선 사용하고,
    /// 없으면 코드로 그린 그라데이션으로 폴백한다.
    private func headerBannerImage(size: NSSize) -> NSImage {
        if let url = Bundle.module.url(forResource: "header", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            // PNG는 @2x(920x300) 픽셀. 논리 크기를 배너 포인트 크기로 맞춰
            // 레티나에서 1:1로 또렷하게 그려지도록 한다.
            img.size = size
            return img
        }
        return gradientBannerImage(size: size)
    }

    /// 폴백용 그라데이션 배너 이미지를 그린다 (Claude 계열 따뜻한 톤).
    private func gradientBannerImage(size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.85, green: 0.46, blue: 0.31, alpha: 1.0),  // 밝은 코랄
            NSColor(srgbRed: 0.60, green: 0.25, blue: 0.16, alpha: 1.0),  // 짙은 테라코타
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -55)
        img.unlockFocus()
        return img
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

    /// 에러 표시를 갱신하고 다음 폴링까지 지연(초)을 반환한다.
    private func handleError(_ error: Error) -> TimeInterval {
        if error is CredentialsError || isAuthError(error) {
            setStacked(top: "로그인", bottom: "필요", color: .systemRed)
            rebuildMenu(detailLines: [error.localizedDescription], showLogin: true)
            consecutiveFailures = 0
            return interval
        }
        // 일시적 오류: 백오프 재시도
        consecutiveFailures += 1
        let age = lastSuccessAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if let usage = lastUsage, !shouldShowStale(age, interval) {
            _ = usage  // 아직 신선함 → 표시 변화 없음(no-op)
        } else if let usage = lastUsage {
            setStacked(
                top: "\(pct(usage.fiveHour.utilization))%",
                bottom: "\(pct(usage.sevenDay.utilization))%",
                color: .systemGray
            )
            rebuildMenu(detailLines: [
                "⚠ 갱신 실패 — 이전 값 표시 중",
                error.localizedDescription,
            ])
        } else {
            setStacked(top: "로그인", bottom: "필요", color: .systemRed)
            rebuildMenu(detailLines: [error.localizedDescription], showLogin: true)
        }
        return nextRetryDelay(consecutiveFailures, interval, retryAfter(from: error))
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

    private func rebuildMenu(detailLines: [String], showLogin: Bool = false) {
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
        if showLogin {
            let loginItem = NSMenuItem(
                title: "Claude Code에서 로그인", action: #selector(login), keyEquivalent: "l")
            loginItem.target = self
            menu.addItem(loginItem)
        }
        let aboutItem = NSMenuItem(title: "정보 (About)", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
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

// --about: 정보(About) 창 내용을 오프스크린으로 PNG로 저장 (레이아웃 시각 검증용)
if let idx = CommandLine.arguments.firstIndex(of: "--about") {
    let outPath = CommandLine.arguments.indices.contains(idx + 1)
        ? CommandLine.arguments[idx + 1] : "/tmp/about.png"
    let size = NSSize(width: 460, height: 340)
    let view = AppDelegate().makeAboutContentView(version: "0.1.0")
    view.frame = NSRect(origin: .zero, size: size)
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: outPath))
            print("저장: \(outPath)")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // Dock 아이콘 없이 메뉴바에만 상주
app.run()
