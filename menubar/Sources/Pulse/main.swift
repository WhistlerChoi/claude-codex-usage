import AppKit

func colorForPercent(_ percent: Int) -> NSColor? {
    if percent >= 95 { return .systemRed }
    if percent >= 80 { return .systemOrange }
    return nil
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var codexTimer: Timer?
    private let interval: TimeInterval

    private var lastUsage: UsageData?
    private var lastModel: CurrentModel?
    private var lastUpdated: Date?
    private var lastSuccessAt: Date?
    private var consecutiveFailures = 0
    private var inFlight = false
    private var aboutWindow: NSWindow?
    private var lastCodexUsage: CodexUsage?
    private var codexLoginNeeded = false
    private var codexInFlight = false

    // Two-line display fine-tuning (adjustable via env vars, no rebuild needed)
    private let fontSize: CGFloat       // CLAUDE_USAGE_FONT_SIZE (default 9)
    private let lineGap: CGFloat        // CLAUDE_USAGE_LINE_GAP  (center-to-center gap of the two lines, default 10)
    private let yOffset: CGFloat        // CLAUDE_USAGE_Y_OFFSET  (overall vertical shift, default 0)
    private let fontWeight: NSFont.Weight  // CLAUDE_USAGE_FONT_WEIGHT (weight, default medium≈0.23)

    override init() {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        // Priority: env vars (CLAUDE_USAGE_*) > UserDefaults (defaults write) > default value
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
        rebuildMenu(detailLines: ["Loading..."])

        refresh()
        refreshCodex()
    }

    @objc func refresh() {
        if inFlight { return }
        inFlight = true
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let usage = try await fetchUsageAutoRefreshing()
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

    @objc func refreshCodex() {
        if codexInFlight { return }
        codexInFlight = true
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let usage = try await fetchCodexUsage()
                await MainActor.run {
                    self.codexInFlight = false
                    self.renderCodexUsage(usage)
                    self.scheduleNextCodex(self.interval)
                }
            } catch {
                await MainActor.run {
                    self.codexInFlight = false
                    self.handleCodexError(error)
                    self.scheduleNextCodex(self.interval)
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

    private func scheduleNextCodex(_ delay: TimeInterval) {
        codexTimer?.invalidate()
        codexTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.refreshCodex()
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func login() {
        openTerminal(command: "claude")
    }

    @objc func loginCodex() {
        openTerminal(command: "codex login")
    }

    private func openTerminal(command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        var err: NSDictionary?
        if let s = NSAppleScript(source: script) {
            s.executeAndReturnError(&err)
        }
        if let err = err {
            let detail = err[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error."
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not open Terminal"
            alert.informativeText = """
                Pulse needs permission to control Terminal. \
                Allow it in System Settings > Privacy & Security > Automation, \
                or run "\(command)" in a terminal yourself.

                (\(detail))
                """
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private static let companyURL = "https://agle.xyz"

    @objc func openCompanySite() {
        if let url = URL(string: AppDelegate.companyURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - About window

    @objc func showAbout() {
        // If it is already open, reuse it and bring it to the front.
        if let win = aboutWindow {
            presentAboutWindow(win)
            return
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "1.2.2"

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "About Pulse"
        win.isReleasedWhenClosed = false
        win.contentView = makeAboutContentView(version: version)

        // Always show above other apps (including full-screen apps).
        // - level=.floating: a layer above normal windows
        // - canJoinAllSpaces: show on the currently active space (including full-screen spaces)
        // - fullScreenAuxiliary: overlay on top even when another app is full-screen (no space switch)
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        aboutWindow = win
        presentAboutWindow(win)
    }

    /// Center the About window on screen and bring it to the front.
    private func presentAboutWindow(_ win: NSWindow) {
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()  // force to front even when inactive or in full-screen
    }

    func makeAboutContentView(version: String) -> NSView {
        let width: CGFloat = 460
        let bannerHeight: CGFloat = 150
        let contentWidth: CGFloat = 412

        let container = NSView()

        // Top header banner — a PNG generated by the visualize skill (bundle resource).
        // Falls back to a code-drawn gradient if the resource cannot be found.
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

        let versionLabel = label("Version \(version)", size: 12, color: .secondaryLabelColor)
        let desc = label(
            "Shows Claude Code and Codex usage\nin your menu bar.",
            size: 12, color: .labelColor)
        let meta = label(
            "Data: ~/.claude · /usage API   ·   Poll interval: \(Int(interval))s",
            size: 11, color: .secondaryLabelColor)

        // Copyright doubles as the company link → https://agle.xyz
        let copyright = NSButton(title: "© 2026 AGLE", target: self, action: #selector(openCompanySite))
        copyright.bezelStyle = .inline
        copyright.isBordered = false
        copyright.contentTintColor = .linkColor
        copyright.attributedTitle = NSAttributedString(
            string: "© 2026 AGLE",
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: 11),
            ])

        // Trademark / non-affiliation notice. Pulse is an independent product; it
        // reads Claude Code's local data but is not affiliated with Anthropic.
        let disclaimer = label(
            "Not affiliated with or endorsed by Anthropic.\nClaude is a trademark of Anthropic, PBC.",
            size: 10, color: .tertiaryLabelColor)

        let stack = NSStackView(views: [versionLabel, desc, meta, copyright, disclaimer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: meta)
        stack.setCustomSpacing(12, after: copyright)
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

    /// Locate the About header PNG without ever trapping.
    ///
    /// NEVER use `Bundle.module` here. SwiftPM's generated accessor falls back to the
    /// build machine's *absolute* `.build` path and `fatalError`s when neither candidate
    /// exists — so About worked on the build machine and hard-crashed the app on every
    /// other Mac. Search plain candidate URLs instead and let the caller fall back.
    private func headerBannerURL() -> URL? {
        // 1. Packaged .app: build-app.sh copies the PNG to Contents/Resources.
        if let url = Bundle.main.url(forResource: "header", withExtension: "png") {
            return url
        }
        let fm = FileManager.default
        let candidates = [
            // 2. Older .app layout that carried the whole SwiftPM resource bundle.
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/Pulse_Pulse.bundle/header.png"),
            // 3. Dev runs of the bare binary (./.build/release/Pulse, --about renders).
            Bundle.main.bundleURL.appendingPathComponent("Pulse_Pulse.bundle/header.png"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// Return the About header banner image.
    /// Prefers the bundled PNG (generated by the visualize skill),
    /// falling back to a code-drawn gradient if absent.
    private func headerBannerImage(size: NSSize) -> NSImage {
        if let url = headerBannerURL(),
           let img = NSImage(contentsOf: url) {
            // The PNG is @2x (920x300) pixels. Set the logical size to the banner's
            // point size so it draws crisply 1:1 on Retina.
            img.size = size
            return img
        }
        return gradientBannerImage(size: size)
    }

    /// Draw the fallback gradient banner image (warm Claude-family tone).
    private func gradientBannerImage(size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.85, green: 0.46, blue: 0.31, alpha: 1.0),  // light coral
            NSColor(srgbRed: 0.60, green: 0.25, blue: 0.16, alpha: 1.0),  // deep terracotta
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -55)
        img.unlockFocus()
        return img
    }

    private func renderCodexUsage(_ usage: CodexUsage) {
        lastCodexUsage = usage
        codexLoginNeeded = false
        if let usage = lastUsage {
            renderUsage(usage, lastModel)
        } else {
            // Codex only (no Claude value yet): 5h on top, weekly below, like the Claude-only layout.
            let color = colorForPercent(usage.fiveHour.usedPercent)
            setStacked(
                top: "\(usage.fiveHour.usedPercent)%",
                bottom: usage.weekly.map { "\($0.usedPercent)%" } ?? "··",
                topColor: color, bottomColor: color, topIcon: lineIcon(.codex))
            var lines = [
                "Codex 5h: \(usage.fiveHour.usedPercent)% · \(formatResetIn(usage.fiveHour.resetsAt))"
            ]
            if let weekly = usage.weekly {
                lines.append("Codex Weekly: \(weekly.usedPercent)% · \(formatResetIn(weekly.resetsAt))")
            }
            rebuildMenu(detailLines: lines)
        }
    }

    private func handleCodexError(_ error: Error) {
        if case CodexUsageError.credentialsNotFound = error {
            codexLoginNeeded = true
            if let usage = lastUsage {
                renderUsage(usage, lastModel)
            } else {
                setStacked(
                    top: "Login", bottom: "needed", topColor: .systemRed, bottomColor: .systemRed,
                    topIcon: lineIcon(.codex))
                rebuildMenu(detailLines: [error.localizedDescription], showCodexLogin: true)
            }
        } else if case CodexUsageError.auth = error {
            codexLoginNeeded = true
            if let usage = lastUsage {
                renderUsage(usage, lastModel)
            } else {
                setStacked(
                    top: "Login", bottom: "needed", topColor: .systemRed, bottomColor: .systemRed,
                    topIcon: lineIcon(.codex))
                rebuildMenu(detailLines: [error.localizedDescription], showCodexLogin: true)
            }
        } else if let usage = lastUsage {
            renderUsage(usage, lastModel)
        } else {
            rebuildMenu(detailLines: [error.localizedDescription])
        }
    }

    // MARK: - Rendering

    private func renderUsage(_ usage: UsageData, _ model: CurrentModel?) {
        lastUsage = usage
        lastModel = model
        lastUpdated = Date()

        renderPrimaryDisplay()

        var claudeRows: [UsageRow] = [
            UsageRow(label: "5h", pct: pct(usage.fiveHour.utilization),
                     reset: formatResetIn(usage.fiveHour.resetsAt)),
            UsageRow(label: "Weekly", pct: pct(usage.sevenDay.utilization),
                     reset: formatResetIn(usage.sevenDay.resetsAt)),
        ]
        var legacyModels = Set<String>()
        if let opus = usage.sevenDayOpus {
            claudeRows.append(UsageRow(label: "Weekly Opus", pct: pct(opus.utilization),
                                 reset: formatResetIn(opus.resetsAt)))
            legacyModels.insert("Opus")
        }
        if let sonnet = usage.sevenDaySonnet {
            claudeRows.append(UsageRow(label: "Weekly Sonnet", pct: pct(sonnet.utilization),
                                 reset: formatResetIn(sonnet.resetsAt)))
            legacyModels.insert("Sonnet")
        }
        for scoped in usage.weeklyScoped where !legacyModels.contains(scoped.model) {
            claudeRows.append(UsageRow(label: "Weekly \(scoped.model)", pct: pct(scoped.window.utilization),
                                 reset: formatResetIn(scoped.window.resetsAt)))
        }
        var codexRows: [UsageRow] = []
        if let codex = lastCodexUsage {
            codexRows.append(UsageRow(label: "5h", pct: codex.fiveHour.usedPercent,
                                      reset: formatResetIn(codex.fiveHour.resetsAt)))
            if let weekly = codex.weekly {
                codexRows.append(UsageRow(label: "Weekly", pct: weekly.usedPercent,
                                          reset: formatResetIn(weekly.resetsAt)))
            }
        }

        var footer: [String] = []
        if let model = model {
            footer.append("Current model: \(model.name) (\(model.id))")
        }
        footer.append("Updated: \(clockString(lastUpdated!))")

        rebuildMenu(
            claudeRows: claudeRows, codexRows: codexRows, footerLines: footer,
            showCodexLogin: codexLoginNeeded)
    }

    /// Keep both providers in the original, always-visible status item. A second
    /// status item can be hidden by macOS when the menu bar is crowded, so the
    /// primary item is the reliable display path for Codex too.
    private func renderPrimaryDisplay() {
        guard let usage = lastUsage else { return }
        if let codex = lastCodexUsage {
            let claudePercent = pct(usage.fiveHour.utilization)
            setStacked(
                top: "\(claudePercent)%",
                bottom: "\(codex.fiveHour.usedPercent)%",
                topColor: colorForPercent(claudePercent),
                bottomColor: colorForPercent(codex.fiveHour.usedPercent),
                topGauge: resetProgress(until: usage.fiveHour.resetsAt),
                bottomGauge: resetProgress(until: codex.fiveHour.resetsAt),
                topIcon: lineIcon(.claude), bottomIcon: lineIcon(.codex))
            statusItem.button?.toolTip = [
                "Claude 5h: \(formatResetIn(usage.fiveHour.resetsAt))",
                "Codex 5h: \(formatResetIn(codex.fiveHour.resetsAt))",
                "Each gauge segment is about 1h remaining.",
            ].joined(separator: "\n")
        } else {
            setStacked(
                top: "\(pct(usage.fiveHour.utilization))%",
                bottom: "\(pct(usage.sevenDay.utilization))%",
                color: colorForPeak(peakUtilization(usage)))
            statusItem.button?.toolTip = nil
        }
    }

    /// Update the error display and return the delay (seconds) until the next poll.
    private func handleError(_ error: Error) -> TimeInterval {
        if error is CredentialsError || isAuthError(error) {
            setStacked(top: "Login", bottom: "needed", color: .systemRed)
            rebuildMenu(detailLines: [error.localizedDescription], showLogin: true)
            consecutiveFailures = 0
            return interval
        }
        // Transient error: retry with backoff. Compute the delay first so it can be displayed.
        consecutiveFailures += 1
        let delay = nextRetryDelay(consecutiveFailures, interval, retryAfter(from: error))
        let age = lastSuccessAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if let usage = lastUsage, !shouldShowStale(age, interval) {
            _ = usage  // still fresh -> no display change (no-op)
        } else if let usage = lastUsage {
            setStacked(
                top: "\(pct(usage.fiveHour.utilization))%",
                bottom: "\(pct(usage.sevenDay.utilization))%",
                color: .systemGray
            )
            rebuildMenu(detailLines: [
                "⚠ Refresh failed — showing last value",
                error.localizedDescription,
            ])
        } else {
            // No value to fall back on. This is a transient failure (network, HTTP 429), NOT an
            // auth problem: show a neutral placeholder and no Login item, so the user is not sent
            // on a pointless login round trip that cannot fix a rate limit.
            setStacked(top: "··", bottom: "··", color: .systemGray)
            rebuildMenu(detailLines: [error.localizedDescription, formatRetryIn(delay)])
        }
        return delay
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

    /// Display two stacked lines in the menu bar (network-speed-indicator style).
    /// Draw directly into an image sized to the menu-bar height for precise vertical control.
    private func setStacked(top: String, bottom: String, color: NSColor?) {
        setStacked(top: top, bottom: bottom, topColor: color, bottomColor: color)
    }

    private func setStacked(
        top: String, bottom: String, topColor: NSColor?, bottomColor: NSColor?,
        topGauge: Double? = nil, bottomGauge: Double? = nil,
        topIcon: NSImage? = nil, bottomIcon: NSImage? = nil
    ) {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.image = renderStackedImage(
                top: top, bottom: bottom, topColor: topColor, bottomColor: bottomColor,
                normalColor: .labelColor, topGauge: topGauge, bottomGauge: bottomGauge,
                topIcon: topIcon, bottomIcon: bottomIcon)
        }
    }

    private func renderStackedImage(
        top: String, bottom: String, topColor: NSColor?, bottomColor: NSColor?,
        normalColor: NSColor, topGauge: Double? = nil, bottomGauge: Double? = nil,
        topIcon: NSImage? = nil, bottomIcon: NSImage? = nil
    ) -> NSImage {
        renderStacked(
            top: top, bottom: bottom, topColor: topColor, bottomColor: bottomColor,
            fontSize: fontSize, weight: fontWeight, lineGap: lineGap, yOffset: yOffset,
            height: NSStatusBar.system.thickness, normalColor: normalColor,
            topGauge: topGauge, bottomGauge: bottomGauge, topIcon: topIcon, bottomIcon: bottomIcon)
    }

    /// Provider icon sized for the menu-bar lines (matches renderStacked's icon box).
    private func lineIcon(_ provider: Provider) -> NSImage {
        provider.icon(pointSize: providerIconSize(fontSize: fontSize))
    }

    /// Plain text rows (used by the error / auth / "Loading..." paths). Not column-aligned.
    private func rebuildMenu(detailLines: [String], showLogin: Bool = false, showCodexLogin: Bool = false) {
        let menu = NSMenu()
        menu.autoenablesItems = false  // so the info lines are not shown dimmed (disabled)
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
        appendInteractiveItems(to: menu, showLogin: showLogin, showCodexLogin: showCodexLogin)
        statusItem.menu = menu
    }

    /// Aligned usage table (3 columns) plus a de-emphasized footer (model / updated).
    private func rebuildMenu(
        claudeRows: [UsageRow], codexRows: [UsageRow], footerLines: [String],
        showCodexLogin: Bool = false
    ) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func addUsageTable(_ provider: Provider, _ rows: [UsageRow]) {
            menu.addItem(makeProviderHeaderItem(provider))
            let tableItem = NSMenuItem()
            tableItem.isEnabled = true
            tableItem.view = makeUsageTableView(rows: rows)
            menu.addItem(tableItem)
        }

        addUsageTable(.claude, claudeRows)
        if !codexRows.isEmpty {
            menu.addItem(.separator())
            addUsageTable(.codex, codexRows)
        }

        if !footerLines.isEmpty {
            menu.addItem(.separator())
            for line in footerLines {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = true
                item.attributedTitle = NSAttributedString(
                    string: line,
                    attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                )
                menu.addItem(item)
            }
        }
        appendInteractiveItems(to: menu, showLogin: false, showCodexLogin: showCodexLogin)
        statusItem.menu = menu
    }

    /// Shared tail: separator + (optional Login) + About / Refresh Now / Quit.
    private func appendInteractiveItems(to menu: NSMenu, showLogin: Bool, showCodexLogin: Bool) {
        menu.addItem(.separator())
        if showLogin {
            let loginItem = NSMenuItem(
                title: "Log In via Claude Code", action: #selector(login), keyEquivalent: "l")
            loginItem.target = self
            menu.addItem(loginItem)
        }
        if showCodexLogin {
            let loginItem = NSMenuItem(
                title: "Log In via Codex", action: #selector(loginCodex), keyEquivalent: "l")
            loginItem.target = self
            menu.addItem(loginItem)
        }
        let aboutItem = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}

/// Section header for one provider's usage table: brand icon + name, de-emphasized like the footer.
func makeProviderHeaderItem(_ provider: Provider) -> NSMenuItem {
    let item = NSMenuItem(title: provider.displayName, action: nil, keyEquivalent: "")
    item.isEnabled = true
    item.image = provider.icon(pointSize: 14)
    item.attributedTitle = NSAttributedString(
        string: provider.displayName,
        attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    )
    return item
}

/// Build a non-interactive view hosting an aligned 3-column usage table
/// (label | percent right-aligned | reset). Sized to its intrinsic content so the
/// menu item adopts the table's width. A free function so the offscreen render path
/// can build it without an AppDelegate.
func makeUsageTableView(rows: [UsageRow]) -> NSView {
    // Match the standard menu item insets so the table lines up with the items
    // below the separator. `leading` ~= the menu's text gutter (checkmark + gap).
    let leading: CGFloat = 21
    let trailing: CGFloat = 14
    let vPad: CGFloat = 5

    let menuFont = NSFont.menuFont(ofSize: 0)
    let digitFont = NSFont.monospacedDigitSystemFont(ofSize: menuFont.pointSize, weight: .regular)

    func cell(_ s: String, font: NSFont, color: NSColor, align: NSTextAlignment = .left) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = color
        t.alignment = align
        t.lineBreakMode = .byClipping
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }

    let gridRows: [[NSView]] = rows.map { row in
        [
            cell(row.label, font: menuFont, color: .labelColor),
            cell("\(row.pct)%", font: digitFont, color: .labelColor, align: .right),
            cell("· \(row.reset)", font: menuFont, color: .secondaryLabelColor),
        ]
    }
    let grid = NSGridView(views: gridRows)
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.rowSpacing = 3
    grid.columnSpacing = 8
    grid.column(at: 0).xPlacement = NSGridCell.Placement.leading
    grid.column(at: 1).xPlacement = NSGridCell.Placement.trailing  // line up the % signs
    grid.column(at: 2).xPlacement = NSGridCell.Placement.leading

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(grid)
    NSLayoutConstraint.activate([
        grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
        grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -trailing),
        grid.topAnchor.constraint(equalTo: container.topAnchor, constant: vPad),
        grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vPad),
    ])
    container.frame = NSRect(origin: .zero, size: container.fittingSize)
    return container
}

/// Side of the square provider icon drawn next to a menu-bar line of `fontSize` text.
/// Matches the font size so two stacked icons never touch at the default 10pt line gap.
func providerIconSize(fontSize: CGFloat) -> CGFloat { ceil(fontSize) }

/// Render two stacked lines into an image sized to height (the menu-bar height).
func renderStacked(
    top: String, bottom: String, topColor: NSColor?, bottomColor: NSColor?,
    fontSize: CGFloat, weight: NSFont.Weight, lineGap: CGFloat, yOffset: CGFloat, height: CGFloat,
    normalColor: NSColor = .labelColor, topGauge: Double? = nil, bottomGauge: Double? = nil,
    topIcon: NSImage? = nil, bottomIcon: NSImage? = nil
) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
    // A brand-colored provider icon can never be part of a template (monochrome) image.
    let isTemplate = topColor == nil && bottomColor == nil && topIcon == nil && bottomIcon == nil
    let topAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: topColor ?? (isTemplate ? NSColor.black : normalColor),
    ]
    let bottomAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: bottomColor ?? (isTemplate ? NSColor.black : normalColor),
    ]

    let topSize = (top as NSString).size(withAttributes: topAttrs)
    let botSize = (bottom as NSString).size(withAttributes: bottomAttrs)
    let gaugeSegmentWidth: CGFloat = 1.5
    let gaugeSegmentGap: CGFloat = 0.75
    let gaugeSegments = 5
    let gaugeWidth = CGFloat(gaugeSegments) * gaugeSegmentWidth
        + CGFloat(gaugeSegments - 1) * gaugeSegmentGap
    let gaugeSpacing: CGFloat = 3
    // Provider icon drawn left of the text, sized to the line's cap height.
    let iconSize = providerIconSize(fontSize: fontSize)
    let iconSpacing: CGFloat = 3
    func lineWidth(_ textWidth: CGFloat, _ progress: Double?, _ icon: NSImage?) -> CGFloat {
        textWidth + (progress == nil ? 0 : gaugeSpacing + gaugeWidth)
            + (icon == nil ? 0 : iconSize + iconSpacing)
    }
    let hasIcons = topIcon != nil || bottomIcon != nil
    let topWidth = lineWidth(topSize.width, topGauge, topIcon)
    let botWidth = lineWidth(botSize.width, bottomGauge, bottomIcon)
    let width = ceil(max(topWidth, botWidth)) + 2

    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    let centerY = height / 2 + yOffset
    let topY = centerY + lineGap / 2 - topSize.height / 2
    let botY = centerY - lineGap / 2 - botSize.height / 2
    func drawLine(
        _ text: String, size: NSSize, attrs: [NSAttributedString.Key: Any], y: CGFloat,
        color: NSColor, progress: Double?, icon: NSImage?
    ) {
        let contentWidth = lineWidth(size.width, progress, icon)
        // Icon lines are left-aligned so the two provider marks form a column; text-only
        // lines keep the centered look.
        var x = hasIcons ? 1 : (width - contentWidth) / 2
        if let icon {
            // Center the mark on the digits' cap height rather than the full line box.
            let capCenter = y - font.descender + font.capHeight / 2
            let iconRect = NSRect(x: x, y: capCenter - iconSize / 2, width: iconSize, height: iconSize)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            x += iconSize + iconSpacing
        }
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        guard let progress else { return }

        // Five compact segments make the 5h countdown scannable without adding another number.
        // A partially elapsed hour keeps its segment until that hour is gone (ceil), like a
        // battery indicator; faint empty segments make an imminent reset distinct from unknown.
        let filled = Int(ceil(min(1, max(0, progress)) * Double(gaugeSegments)))
        let gaugeX = x + size.width + gaugeSpacing
        let gaugeHeight: CGFloat = 4
        let gaugeY = y + (size.height - gaugeHeight) / 2
        for index in 0..<gaugeSegments {
            let rect = NSRect(
                x: gaugeX + CGFloat(index) * (gaugeSegmentWidth + gaugeSegmentGap),
                y: gaugeY, width: gaugeSegmentWidth, height: gaugeHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 0.6, yRadius: 0.6)
            (index < filled ? color.withAlphaComponent(0.9) : color.withAlphaComponent(0.22)).setFill()
            path.fill()
        }
    }
    drawLine(
        top, size: topSize, attrs: topAttrs, y: topY,
        color: topColor ?? (isTemplate ? .black : normalColor), progress: topGauge, icon: topIcon)
    drawLine(
        bottom, size: botSize, attrs: bottomAttrs, y: botY,
        color: bottomColor ?? (isTemplate ? .black : normalColor), progress: bottomGauge,
        icon: bottomIcon)
    image.unlockFocus()
    image.isTemplate = isTemplate
    return image
}

// --render: scale up the menu-bar display image and save it as a PNG (for offscreen visual checks)
if let idx = CommandLine.arguments.firstIndex(of: "--render") {
    let outPath = CommandLine.arguments.indices.contains(idx + 1)
        ? CommandLine.arguments[idx + 1] : NSTemporaryDirectory() + "stacked.png"
    let env = ProcessInfo.processInfo.environment
    func num(_ k: String, _ d: Double) -> CGFloat {
        if let r = env[k], let v = Double(r) { return CGFloat(v) }
        return CGFloat(d)
    }
    let height = NSStatusBar.system.thickness
    // Use black text (non-template) to check the layout
    let img = renderStacked(
        top: "5%", bottom: "42%", topColor: .black, bottomColor: .black,
        fontSize: num("CLAUDE_USAGE_FONT_SIZE", 9),
        weight: NSFont.Weight(num("CLAUDE_USAGE_FONT_WEIGHT", Double(NSFont.Weight.bold.rawValue))),
        lineGap: num("CLAUDE_USAGE_LINE_GAP", 10),
        yOffset: num("CLAUDE_USAGE_Y_OFFSET", 0),
        height: height, topGauge: 0.82, bottomGauge: 0.28,
        topIcon: Provider.claude.icon(pointSize: providerIconSize(fontSize: num("CLAUDE_USAGE_FONT_SIZE", 9))),
        bottomIcon: Provider.codex.icon(pointSize: providerIconSize(fontSize: num("CLAUDE_USAGE_FONT_SIZE", 9))))

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
        print("Saved: \(outPath)  (menu-bar height=\(height), item size=\(img.size))")
    }
    exit(0)
}

// --selftest: exercise the pure refresh/merge helpers (no network, no keychain), then exit.
if CommandLine.arguments.contains("--selftest") {
    var failures = 0
    func check(_ cond: Bool, _ label: String) {
        print((cond ? "PASS" : "FAIL") + ": " + label)
        if !cond { failures += 1 }
    }

    // parseRefreshResponse: rotated refresh token + computed expiry.
    let resp = #"{"access_token":"newA","refresh_token":"newR","expires_in":28800}"#.data(using: .utf8)!
    if let t = try? parseRefreshResponse(resp, previousRefreshToken: "oldR", nowMs: 1_000_000) {
        check(t.accessToken == "newA", "parseRefreshResponse access token")
        check(t.refreshToken == "newR", "parseRefreshResponse rotated refresh token")
        check(t.expiresAtMs == 1_000_000 + 28_800 * 1000, "parseRefreshResponse expiry = now + expires_in*1000")
    } else {
        check(false, "parseRefreshResponse parsed")
    }

    // parseRefreshResponse: missing refresh_token carries the previous one forward.
    let respNoRefresh = #"{"access_token":"a2","expires_in":3600}"#.data(using: .utf8)!
    if let t = try? parseRefreshResponse(respNoRefresh, previousRefreshToken: "keepR", nowMs: 0) {
        check(t.refreshToken == "keepR", "parseRefreshResponse falls back to previous refresh token")
    } else {
        check(false, "parseRefreshResponse (no refresh_token) parsed")
    }

    // mergedCredentialsData: preserves unrelated fields + wrapper shape, updates the three token fields.
    let existing = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"oldR","expiresAt":1,"scopes":["x"],"subscriptionType":"pro"}}"#.data(using: .utf8)!
    if let merged = try? mergedCredentialsData(existing: existing, accessToken: "A", refreshToken: "R", expiresAtMs: 1782033795750),
       let obj = (try? JSONSerialization.jsonObject(with: merged)) as? [String: Any],
       let oauth = obj["claudeAiOauth"] as? [String: Any] {
        check(oauth["accessToken"] as? String == "A", "merge updates accessToken")
        check(oauth["refreshToken"] as? String == "R", "merge updates refreshToken")
        check((oauth["expiresAt"] as? NSNumber)?.int64Value == 1782033795750, "merge writes integer expiresAt")
        check(oauth["scopes"] != nil, "merge preserves scopes")
        check(oauth["subscriptionType"] as? String == "pro", "merge preserves subscriptionType")
    } else {
        check(false, "mergedCredentialsData (wrapper) produced valid JSON")
    }

    // mergedCredentialsData: empty input defaults to Claude Code's wrapper shape.
    if let merged = try? mergedCredentialsData(existing: nil, accessToken: "A", refreshToken: "R", expiresAtMs: 2),
       let obj = (try? JSONSerialization.jsonObject(with: merged)) as? [String: Any] {
        check(obj["claudeAiOauth"] is [String: Any], "merge with no existing data uses wrapper shape")
    } else {
        check(false, "mergedCredentialsData (empty) produced valid JSON")
    }

    // pickFreshest: the store holding the newer token wins, whichever store that is.
    func blob(_ token: String, _ expiresAt: Int?) -> Data {
        var oauth: [String: Any] = ["accessToken": token, "refreshToken": "r"]
        if let e = expiresAt { oauth["expiresAt"] = e }
        return (try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])) ?? Data()
    }
    func isKeychain(_ c: Credentials?) -> Bool {
        guard let c = c else { return false }
        if case .keychain = c.source { return true }
        return false
    }
    let fileURL = URL(fileURLWithPath: "/tmp/.credentials.json")

    // The reported bug: a months-old credentials file next to a keychain item refreshed today.
    let staleFile = pickFreshest([(blob("dead", 1_000), .file(fileURL)), (blob("live", 9_000), .keychain)])
    check(staleFile?.accessToken == "live", "pickFreshest: fresh keychain beats stale file")
    check(isKeychain(staleFile), "pickFreshest: source follows the winner (keychain)")

    // The mirror case must not regress: a live file next to a stale keychain item.
    let staleKeychain = pickFreshest([(blob("live", 9_000), .file(fileURL)), (blob("dead", 1_000), .keychain)])
    check(staleKeychain?.accessToken == "live", "pickFreshest: fresh file beats stale keychain")
    check(!isKeychain(staleKeychain), "pickFreshest: source follows the winner (file)")

    check(pickFreshest([(blob("only", 5_000), .file(fileURL))])?.accessToken == "only",
          "pickFreshest: single candidate")
    check(pickFreshest([(blob("good", 5_000), .file(fileURL)), (Data("not json".utf8), .keychain)])?
            .accessToken == "good",
          "pickFreshest: unparseable candidate is skipped")
    check(isKeychain(pickFreshest([(blob("a", 7_000), .file(fileURL)), (blob("b", 7_000), .keychain)])),
          "pickFreshest: equal expiry goes to the keychain (writeback follows Claude Code)")
    check(isKeychain(pickFreshest([(blob("a", nil), .file(fileURL)), (blob("b", nil), .keychain)])),
          "pickFreshest: no expiry anywhere goes to the keychain")
    check(pickFreshest([]) == nil, "pickFreshest: no candidates -> nil")

    // formatRetryIn: the transient-error menu line.
    check(formatRetryIn(0) == "Retrying in 0s", "formatRetryIn 0s")
    check(formatRetryIn(45) == "Retrying in 45s", "formatRetryIn 45s")
    check(formatRetryIn(-5) == "Retrying in 0s", "formatRetryIn clamps negatives")
    check(formatRetryIn(60) == "Retrying in 1m", "formatRetryIn 1m")
    check(formatRetryIn(3599) == "Retrying in 59m", "formatRetryIn 59m (no 60m)")
    check(formatRetryIn(3600) == "Retrying in 1h", "formatRetryIn 1h")
    check(formatRetryIn(3900) == "Retrying in 1h 5m", "formatRetryIn 1h 5m")

    // resetProgress: the 5-segment menu-bar gauge uses a clamped 5h countdown.
    let gaugeNow = Date(timeIntervalSince1970: 1_000_000)
    check(resetProgress(until: gaugeNow.addingTimeInterval(2.5 * 3600), now: gaugeNow) == 0.5,
          "resetProgress half of 5h remaining")
    check(resetProgress(until: gaugeNow.addingTimeInterval(8 * 3600), now: gaugeNow) == 1,
          "resetProgress clamps dates beyond the window")
    check(resetProgress(until: gaugeNow.addingTimeInterval(-1), now: gaugeNow) == 0,
          "resetProgress clamps elapsed resets")
    let noResetDate: Date? = nil
    check(resetProgress(until: noResetDate, now: gaugeNow) == nil,
          "resetProgress preserves an unknown reset")

    // Per-provider menu-bar colors: each displayed percentage crosses thresholds independently.
    check(colorForPercent(79) == nil, "usage color below warning threshold")
    check(colorForPercent(80) == .systemOrange, "usage color at warning threshold")
    check(colorForPercent(95) == .systemRed, "usage color at alert threshold")
    let independentImage = renderStacked(
        top: "Cl 81%", bottom: "Cx 20%", topColor: .systemOrange, bottomColor: nil,
        fontSize: 9, weight: .bold, lineGap: 10, yOffset: 0,
        height: NSStatusBar.system.thickness, topGauge: 0.8, bottomGauge: 0.2)
    check(!independentImage.isTemplate, "stacked display preserves independent line colors")

    // Provider icons: brand-colored marks replace the "Cl"/"Cx" text prefixes.
    let claudeIcon = Provider.claude.icon(pointSize: 10)
    let codexIcon = Provider.codex.icon(pointSize: 10)
    check(claudeIcon.size == NSSize(width: 10, height: 10), "Claude icon is square at the requested size")
    check(!claudeIcon.isTemplate && !codexIcon.isTemplate, "provider icons are colored, not template")
    check(Provider.claude.brandColor != Provider.codex.brandColor, "provider brand colors differ")
    let plainImage = renderStacked(
        top: "5%", bottom: "42%", topColor: nil, bottomColor: nil,
        fontSize: 9, weight: .bold, lineGap: 10, yOffset: 0, height: NSStatusBar.system.thickness)
    let iconImage = renderStacked(
        top: "5%", bottom: "42%", topColor: nil, bottomColor: nil,
        fontSize: 9, weight: .bold, lineGap: 10, yOffset: 0, height: NSStatusBar.system.thickness,
        topIcon: claudeIcon, bottomIcon: codexIcon)
    check(plainImage.isTemplate, "stacked display without colors or icons stays a template image")
    check(!iconImage.isTemplate, "stacked display with provider icons is never a template image")
    check(iconImage.size.width > plainImage.size.width, "provider icons widen the stacked display")

    // hexEncode: the `add-generic-password -X` payload format (lowercase, zero-padded).
    check(hexEncode(Data()) == "", "hexEncode empty")
    check(hexEncode(Data([0x00, 0x7b, 0xff])) == "007bff", "hexEncode pads and lowercases")
    check(hexEncode(Data("{}".utf8)) == "7b7d", "hexEncode JSON braces")

    // securityQuote: `security -i` tokenizer escapes (\" -> literal quote, \\ -> literal backslash).
    check(securityQuote("abc") == "\"abc\"", "securityQuote plain token")
    check(securityQuote("a b") == "\"a b\"", "securityQuote keeps spaces inside one token")
    check(securityQuote("a\"b") == "\"a\\\"b\"", "securityQuote escapes double quote")
    check(securityQuote("a\\b") == "\"a\\\\b\"", "securityQuote escapes backslash")
    check(securityQuote("a\\\"b") == "\"a\\\\\\\"b\"", "securityQuote escapes backslash+quote")

    // addGenericPasswordCommandLine: exact shape Claude Code feeds to `security -i`.
    check(addGenericPasswordCommandLine(
              account: "seolhochoi", service: "Claude Code-credentials", hexPayload: "7b7d")
          == "add-generic-password -U -a \"seolhochoi\" -s \"Claude Code-credentials\" -X \"7b7d\"\n",
          "addGenericPasswordCommandLine -U shape + trailing newline")
    check(addGenericPasswordCommandLine(
              account: "u", service: "s", hexPayload: "00", update: false)
          == "add-generic-password -a \"u\" -s \"s\" -X \"00\"\n",
          "addGenericPasswordCommandLine without -U (self-heal re-add)")

    // stdin-vs-argv selection: exactly securityStdinLimit goes to stdin, one more byte to argv.
    let fixedOverhead = addGenericPasswordCommandLine(
        account: "seolhochoi", service: "Claude Code-credentials", hexPayload: "").utf8.count
    let atLimit = addGenericPasswordCommandLine(
        account: "seolhochoi", service: "Claude Code-credentials",
        hexPayload: String(repeating: "a", count: securityStdinLimit - fixedOverhead))
    check(atLimit.utf8.count == securityStdinLimit, "command line sized exactly at the stdin limit")
    check(atLimit.utf8.count <= securityStdinLimit && atLimit.utf8.count + 1 > securityStdinLimit,
          "one more byte would select the argv fallback")

    // parseKeychainAccount: promptless `find-generic-password` attribute output.
    let findOutput = """
    keychain: "/Users/seolhochoi/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        0x00000007 <blob>="Claude Code-credentials"
        "acct"<blob>="seolhochoi"
        "svce"<blob>="Claude Code-credentials"
    """
    check(parseKeychainAccount(fromFindOutput: findOutput) == "seolhochoi",
          "parseKeychainAccount reads acct")
    check(parseKeychainAccount(fromFindOutput: "    \"acct\"<blob>=<NULL>\n") == nil,
          "parseKeychainAccount NULL acct -> nil")
    check(parseKeychainAccount(fromFindOutput: "") == nil, "parseKeychainAccount empty -> nil")
    check(parseKeychainAccount(fromFindOutput: "    \"svce\"<blob>=\"x\"\n") == nil,
          "parseKeychainAccount ignores non-acct attributes")

    // parseUsage: weekly_scoped entries from the limits array.
    let usageJSON: [String: Any] = [
        "five_hour": ["utilization": 42, "resets_at": "2026-06-04T11:50:00+00:00"],
        "seven_day": ["utilization": 8, "resets_at": "2026-06-10T07:00:00+00:00"],
        "limits": [
            ["kind": "session", "percent": 42, "scope": NSNull()],
            ["kind": "weekly_scoped", "percent": 12, "resets_at": "2026-06-10T07:00:00+00:00",
             "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()]],
        ],
    ]
    if let u = try? parseUsage(usageJSON) {
        check(u.weeklyScoped.count == 1, "parseUsage yields one weekly_scoped entry")
        check(u.weeklyScoped.first?.model == "Fable", "weekly_scoped model is Fable")
        check(u.weeklyScoped.first?.window.utilization == 12, "weekly_scoped percent -> utilization")
    } else {
        check(false, "parseUsage with limits parsed")
    }

    // parseUsage: missing/malformed limits is never fatal.
    let noLimits: [String: Any] = ["five_hour": ["utilization": 1], "seven_day": ["utilization": 2]]
    check((try? parseUsage(noLimits))?.weeklyScoped.isEmpty == true, "absent limits -> empty weeklyScoped")
    var badLimits = noLimits
    badLimits["limits"] = "x"
    check((try? parseUsage(badLimits))?.weeklyScoped.isEmpty == true, "malformed limits -> empty weeklyScoped")

    // parseCodexUsage: primary is the 5-hour window; secondary is the weekly window.
    let codexJSON = #"""
    {
      "rate_limit": {
        "primary_window": {"used_percent": 17.6, "reset_at": 1780000000},
        "secondary_window": {"used_percent": 43.2, "reset_at": 1780500000}
      },
      "plan_type": "plus",
      "credits": {"has_credits": true, "unlimited": false}
    }
    """#.data(using: .utf8)!
    if let codex = try? parseCodexUsage(codexJSON) {
        check(codex.fiveHour.usedPercent == 18, "parseCodexUsage primary -> 5h")
        check(codex.weekly?.usedPercent == 43, "parseCodexUsage secondary -> weekly")
        check(codex.fiveHour.resetsAt == Date(timeIntervalSince1970: 1_780_000_000),
              "parseCodexUsage 5h reset_at")
        check(codex.weekly?.resetsAt == Date(timeIntervalSince1970: 1_780_500_000),
              "parseCodexUsage weekly reset_at")
    } else {
        check(false, "parseCodexUsage with both windows parsed")
    }

    // Older responses without a secondary window remain usable.
    let codexPrimaryOnly = #"{"rate_limit":{"primary_window":{"used_percent":9}}}"#
        .data(using: .utf8)!
    if let codex = try? parseCodexUsage(codexPrimaryOnly) {
        check(codex.fiveHour.usedPercent == 9, "parseCodexUsage keeps primary-only response")
        check(codex.weekly == nil, "parseCodexUsage missing secondary -> no weekly window")
    } else {
        check(false, "parseCodexUsage primary-only response parsed")
    }

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

// --once: print the current values once without the menu bar, then exit (for verification/debugging)
if CommandLine.arguments.contains("--once") {
    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            let usage = try await fetchUsageAutoRefreshing()
            let model = readCurrentModel()
            print("[gauge] " + menuBarText(usage))
            print("  5h:     \(pct(usage.fiveHour.utilization))% · \(formatResetIn(usage.fiveHour.resetsAt))")
            print("  Weekly: \(pct(usage.sevenDay.utilization))% · \(formatResetIn(usage.sevenDay.resetsAt))")
            for scoped in usage.weeklyScoped {
                print("  Weekly \(scoped.model): \(pct(scoped.window.utilization))% · \(formatResetIn(scoped.window.resetsAt))")
            }
            if let model = model { print("  Model:  \(model.name) (\(model.id))") }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

// --codex-once: print Codex usage once without starting the menu bar app.
if CommandLine.arguments.contains("--codex-once") {
    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            let usage = try await fetchCodexUsage()
            print("[codex]")
            print("  5h:     \(usage.fiveHour.usedPercent)% · \(formatResetIn(usage.fiveHour.resetsAt))")
            if let weekly = usage.weekly {
                print("  Weekly: \(weekly.usedPercent)% · \(formatResetIn(weekly.resetsAt))")
            }
            if let plan = usage.planType { print("  Plan: \(plan)") }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

// --about: render the About window content offscreen and save it as a PNG (for layout visual checks)
if let idx = CommandLine.arguments.firstIndex(of: "--about") {
    let outPath = CommandLine.arguments.indices.contains(idx + 1)
        ? CommandLine.arguments[idx + 1] : NSTemporaryDirectory() + "about.png"
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
            print("Saved: \(outPath)")
        }
    }
    exit(0)
}

// --menu: render the aligned usage table offscreen to a PNG (layout/alignment check).
if let idx = CommandLine.arguments.firstIndex(of: "--menu") {
    let outPath = CommandLine.arguments.indices.contains(idx + 1)
        ? CommandLine.arguments[idx + 1] : NSTemporaryDirectory() + "menu.png"
    let rows = [
        UsageRow(label: "5h", pct: 3, reset: "resets in 2h 13m"),
        UsageRow(label: "Weekly", pct: 27, reset: "resets in 4d 6h"),
        UsageRow(label: "Weekly Opus", pct: 100, reset: "resets in 4d 6h"),
        UsageRow(label: "Weekly Sonnet", pct: 8, reset: "resets in 16h 16m"),
        UsageRow(label: "Weekly Fable", pct: 12, reset: "resets in 4d 6h"),
        UsageRow(label: "Codex 5h", pct: 20, reset: "resets in 3h 1m"),
        UsageRow(label: "Codex Weekly", pct: 48, reset: "resets in 5d 2h"),
    ]
    let view = makeUsageTableView(rows: rows)
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: outPath))
            print("Saved: \(outPath)  size=\(view.bounds.size)")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // live only in the menu bar, with no Dock icon
app.run()
