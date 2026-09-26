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
    private var lastTokens: TokenStats?
    private var lastClaudeUpdated: Date?
    private var lastSuccessAt: Date?
    private var consecutiveFailures = 0
    private var inFlight = false
    private var aboutWindow: NSWindow?
    private var lastCodexUsage: CodexUsage?
    private var lastCodexModel: CurrentModel?
    private var lastCodexTokens: TokenStats?
    private var lastCodexUpdated: Date?
    private var codexLoginNeeded = false
    private var codexInFlight = false

    // Auto Wakeup: off unless the user turns it on. State is persisted so quitting and
    // relaunching cannot reset the cooldown and re-send.
    private var autoWakeupEnabled: Bool
    private var claudeWakeup = WakeupState()
    private var codexWakeup = WakeupState()
    private var claudeWakeupInFlight = false
    private var codexWakeupInFlight = false

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
        // An absent key reads as false, which is the required default-off.
        autoWakeupEnabled = defaults.bool(forKey: "AutoWakeupEnabled")
        super.init()
        claudeWakeup = Self.loadWakeupState(provider: "claude")
        codexWakeup = Self.loadWakeupState(provider: "codex")
    }

    private static func loadWakeupState(provider: String) -> WakeupState {
        let d = UserDefaults.standard
        func date(_ key: String) -> Date? {
            let v = d.double(forKey: key)
            return v > 0 ? Date(timeIntervalSince1970: v) : nil
        }
        return WakeupState(
            lastWakeupAt: date("AutoWakeupLastAt.\(provider)"),
            lastWindowResetsAt: date("AutoWakeupLastWindow.\(provider)"))
    }

    private func saveWakeupState(_ state: WakeupState, provider: String) {
        let d = UserDefaults.standard
        d.set(state.lastWakeupAt?.timeIntervalSince1970 ?? 0, forKey: "AutoWakeupLastAt.\(provider)")
        d.set(state.lastWindowResetsAt?.timeIntervalSince1970 ?? 0,
              forKey: "AutoWakeupLastWindow.\(provider)")
    }

    /// Evaluate and, if warranted, send one wakeup. Called only from a successful poll, on the
    /// main actor. Every failure path here is silent: a wakeup must never touch the usage
    /// display, and must never be reported as a login problem.
    private func maybeWakeUpClaude(resetsAt: String?) {
        let parsed = resetsAt.flatMap(parseISODate)
        if let parsed { claudeWakeup.lastWindowResetsAt = parsed }
        guard shouldWakeUp(enabled: autoWakeupEnabled, resetsAt: parsed,
                           state: claudeWakeup, inFlight: claudeWakeupInFlight) else {
            saveWakeupState(claudeWakeup, provider: "claude")
            return
        }
        claudeWakeupInFlight = true
        // Recorded before the request goes out, so a crash mid-flight still costs the cooldown.
        claudeWakeup = stateAfterWakeup(claudeWakeup, resetsAt: parsed)
        saveWakeupState(claudeWakeup, provider: "claude")
        Task.detached { [weak self] in
            do {
                try await sendClaudeWakeup()
            } catch {
                FileHandle.standardError.write(
                    "pulse: claude wakeup failed: \(error)\n".data(using: .utf8)!)
            }
            await MainActor.run { self?.claudeWakeupInFlight = false }
        }
    }

    private func maybeWakeUpCodex(resetsAt: Date?) {
        if let resetsAt { codexWakeup.lastWindowResetsAt = resetsAt }
        guard shouldWakeUp(enabled: autoWakeupEnabled, resetsAt: resetsAt,
                           state: codexWakeup, inFlight: codexWakeupInFlight) else {
            saveWakeupState(codexWakeup, provider: "codex")
            return
        }
        codexWakeupInFlight = true
        codexWakeup = stateAfterWakeup(codexWakeup, resetsAt: resetsAt)
        saveWakeupState(codexWakeup, provider: "codex")
        Task.detached { [weak self] in
            do {
                try await sendCodexWakeup()
            } catch {
                FileHandle.standardError.write(
                    "pulse: codex wakeup failed: \(error)\n".data(using: .utf8)!)
            }
            await MainActor.run { self?.codexWakeupInFlight = false }
        }
    }

    /// Sent by the row's NSSwitch, which has *already* flipped its own state. Read that state
    /// rather than toggling again, or the model ends up inverted relative to the control.
    @objc func toggleAutoWakeup(_ sender: Any?) {
        if let sw = sender as? NSSwitch {
            autoWakeupEnabled = (sw.state == .on)
        } else {
            autoWakeupEnabled.toggle()  // keyboard/menu invocation with no control attached
        }
        UserDefaults.standard.set(autoWakeupEnabled, forKey: "AutoWakeupEnabled")
        // The menu is open right now, and rebuilding it does not touch the visible copy, so
        // repaint this row's own view in place.
        refreshAutoWakeupRow()
    }

    /// One row covers both providers, so its "last HH:MM" is the later of the two attempts.
    private var combinedWakeupState: WakeupState {
        WakeupState(lastWakeupAt: latestDate(claudeWakeup.lastWakeupAt, codexWakeup.lastWakeupAt),
                    lastWindowResetsAt: nil)
    }

    /// Update the live Auto Wakeup row (label colour and text) without rebuilding the menu.
    /// Rebuilding would leave the currently-open menu untouched.
    private func refreshAutoWakeupRow() {
        guard let menu = statusItem?.menu else { return }
        for item in menu.items {
            guard let view = item.view, view.identifier == autoWakeupRowIdentifier else { continue }
            updateAutoWakeupView(view, enabled: autoWakeupEnabled, state: combinedWakeupState)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStacked(top: "··", bottom: "··", color: nil)
        rebuildMenu(detailLines: ["Loading..."])

        refreshAll()
    }

    /// "Refresh Now" and launch: poll both providers. Each has its own in-flight guard and timer.
    @objc func refreshAll() {
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
                let tokens = readTokenStats()
                await MainActor.run {
                    self.inFlight = false
                    self.renderUsage(usage, model, tokens)
                    self.maybeWakeUpClaude(resetsAt: usage.fiveHour.resetsAt)
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
                let model = readCurrentCodexModel()
                let tokens = readCodexTokenStats()
                await MainActor.run {
                    self.codexInFlight = false
                    self.renderCodexUsage(usage, model, tokens)
                    // An idle Codex window still reports a (rolling) reset time; treat it as
                    // absent so the wakeup rule matches Claude's.
                    self.maybeWakeUpCodex(
                        resetsAt: usage.fiveHour.idle ? nil : usage.fiveHour.resetsAt)
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

        // Unbundled (e.g. `swift run`) there is no Info.plist; "dev" beats a stale literal that
        // silently drifts behind the real version.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"

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

    private func renderCodexUsage(_ usage: CodexUsage, _ model: CurrentModel?, _ tokens: TokenStats?) {
        lastCodexUsage = usage
        lastCodexModel = model
        lastCodexTokens = tokens
        lastCodexUpdated = Date()
        codexLoginNeeded = false
        if lastUsage != nil {
            renderAll()
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
            if let tokens { lines.append(tokenMenuTitles(tokens).today) }
            if let at = lastCodexUpdated {
                lines.append("Updated: \(clockString(at))")
            }
            rebuildMenu(detailLines: lines)
        }
    }

    private func handleCodexError(_ error: Error) {
        if case CodexUsageError.credentialsNotFound = error {
            codexLoginNeeded = true
            if lastUsage != nil {
                renderAll()
            } else {
                setStacked(
                    top: "Login", bottom: "needed", topColor: .systemRed, bottomColor: .systemRed,
                    topIcon: lineIcon(.codex))
                rebuildMenu(detailLines: [error.localizedDescription], showCodexLogin: true)
            }
        } else if case CodexUsageError.auth = error {
            codexLoginNeeded = true
            if lastUsage != nil {
                renderAll()
            } else {
                setStacked(
                    top: "Login", bottom: "needed", topColor: .systemRed, bottomColor: .systemRed,
                    topIcon: lineIcon(.codex))
                rebuildMenu(detailLines: [error.localizedDescription], showCodexLogin: true)
            }
        } else if lastUsage != nil {
            renderAll()
        } else {
            rebuildMenu(detailLines: [error.localizedDescription])
        }
    }

    // MARK: - Rendering

    /// Store a fresh Claude result and redraw. Only this path moves the Claude timestamp.
    private func renderUsage(_ usage: UsageData, _ model: CurrentModel?, _ tokens: TokenStats?) {
        lastUsage = usage
        lastModel = model
        lastTokens = tokens
        lastClaudeUpdated = Date()
        renderAll()
    }

    /// Redraw the status item and dropdown from cached state (both providers). Used by the
    /// Codex paths too, so a Codex-only poll never touches the Claude "Updated" time.
    private func renderAll() {
        guard let usage = lastUsage else { return }
        let model = lastModel

        renderPrimaryDisplay()

        var claudeRows: [UsageRow] = [
            UsageRow(label: "5h", pct: pct(usage.fiveHour.utilization),
                     reset: formatResetDuration(usage.fiveHour.resetsAt)),
            UsageRow(label: "Weekly", pct: pct(usage.sevenDay.utilization),
                     reset: formatResetDuration(usage.sevenDay.resetsAt)),
        ]
        var legacyModels = Set<String>()
        if let opus = usage.sevenDayOpus {
            claudeRows.append(UsageRow(label: "Weekly Opus", pct: pct(opus.utilization),
                                 reset: formatResetDuration(opus.resetsAt)))
            legacyModels.insert("Opus")
        }
        if let sonnet = usage.sevenDaySonnet {
            claudeRows.append(UsageRow(label: "Weekly Sonnet", pct: pct(sonnet.utilization),
                                 reset: formatResetDuration(sonnet.resetsAt)))
            legacyModels.insert("Sonnet")
        }
        for scoped in usage.weeklyScoped where !legacyModels.contains(scoped.model) {
            claudeRows.append(UsageRow(label: "Weekly \(scoped.model)", pct: pct(scoped.window.utilization),
                                 reset: formatResetDuration(scoped.window.resetsAt)))
        }
        var codexSection: ProviderSection?
        if let codex = lastCodexUsage {
            var codexRows = [
                UsageRow(label: "5h", pct: codex.fiveHour.usedPercent,
                         reset: formatResetDuration(codex.fiveHour.resetsAt))
            ]
            if let weekly = codex.weekly {
                codexRows.append(UsageRow(label: "Weekly", pct: weekly.usedPercent,
                                          reset: formatResetDuration(weekly.resetsAt)))
            }
            codexSection = ProviderSection(rows: codexRows, model: lastCodexModel, tokens: lastCodexTokens)
        }

        rebuildMenu(
            claude: ProviderSection(rows: claudeRows, model: model, tokens: lastTokens),
            codex: codexSection,
            updatedAt: latestDate(lastClaudeUpdated, lastCodexUpdated),
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

    /// One section per provider: header (icon + name, current model at the right edge) and
    /// the aligned usage table (3 columns). The last-updated time is not a section line — it
    /// rides along on "Refresh Now" below, since it belongs to both providers (they poll on the
    /// same timer) and to the action that changes it.
    private func rebuildMenu(
        claude: ProviderSection, codex: ProviderSection?, updatedAt: Date?, showCodexLogin: Bool = false
    ) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // One measurement over every row of both providers: each section's table is its own
        // NSGridView, so without a shared width their columns would be sized independently
        // and the reset column would start at a different x in each section.
        let widths = usageTableColumnWidths(sections: [claude.rows, codex?.rows ?? []])

        // The "resets in" column caption is drawn once, over the first table only.
        func addSection(_ provider: Provider, _ section: ProviderSection, caption: Bool) {
            menu.addItem(makeProviderHeaderItem(provider, model: section.model))
            let tableItem = NSMenuItem()
            tableItem.isEnabled = true
            tableItem.view = makeUsageTableView(
                rows: section.rows, columnWidths: widths, captionResetColumn: caption)
            menu.addItem(tableItem)
            if let tokens = section.tokens {
                menu.addItem(makeTokensItem(tokens))
            }
        }

        addSection(.claude, claude, caption: true)
        if let codex {
            menu.addItem(.separator())
            addSection(.codex, codex, caption: false)
        }
        appendInteractiveItems(
            to: menu, showLogin: false, showCodexLogin: showCodexLogin, updatedAt: updatedAt)
        statusItem.menu = menu
    }

    /// Shared tail: separator + (optional Login) + About / Refresh Now / Quit.
    /// `updatedAt`, when known, is appended to "Refresh Now" in a smaller, de-emphasized font.
    private func appendInteractiveItems(
        to menu: NSMenu, showLogin: Bool, showCodexLogin: Bool, updatedAt: Date? = nil
    ) {
        menu.addItem(.separator())
        menu.addItem(makeAutoWakeupItem(
            enabled: autoWakeupEnabled, state: combinedWakeupState,
            target: self, action: #selector(toggleAutoWakeup(_:))))
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
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshAll), keyEquivalent: "r")
        refreshItem.target = self
        if let updatedAt {
            refreshItem.attributedTitle = refreshTitle(updatedAt: updatedAt)
        }
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}

/// De-emphasized note row under a provider's usage table: "Tokens today: 1.2M in · 48K out ·
/// 9.8M cache". The rolling 7d and 30d rows (with their trend) live in its submenu, so they only
/// appear when the row is hovered. Local ledger figures (`TokenHistory.swift`); same wording as
/// the other ports.
func makeTokensItem(_ tokens: TokenStats) -> NSMenuItem {
    func noteItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }
    let titles = tokenMenuTitles(tokens)
    let item = noteItem(titles.today)
    let submenu = NSMenu()
    submenu.autoenablesItems = false  // keep the info rows readable (not dimmed)
    for line in titles.history { submenu.addItem(noteItem(line)) }
    item.submenu = submenu
    return item
}

/// "Refresh Now" followed by the last-updated clock time in a smaller, de-emphasized font.
/// The time hangs off the action that changes it rather than off either provider's section,
/// where it would read as belonging to that one provider. The ⌘R key equivalent keeps the
/// item's right edge, so the time trails the label instead of being right-aligned.
func refreshTitle(updatedAt: Date) -> NSAttributedString {
    let menuFont = NSFont.menuFont(ofSize: 0)
    let title = NSMutableAttributedString(
        string: "Refresh Now",
        attributes: [.font: menuFont, .foregroundColor: NSColor.labelColor])
    title.append(NSAttributedString(
        string: "   \(clockString(updatedAt))",
        attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: menuFont.pointSize - 2, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
    return title
}

/// De-emphasized, non-interactive info line ("Updated: …", error details).
func makeNoteItem(_ line: String) -> NSMenuItem {
    let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
    item.isEnabled = true
    item.attributedTitle = NSAttributedString(
        string: line,
        attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    )
    return item
}

/// Section header for one provider's usage table, hosted in a custom view so the current
/// model can sit flush at the right edge: `[icon] Claude …………… Opus (claude-opus-5)`.
let autoWakeupRowIdentifier = NSUserInterfaceItemIdentifier("autoWakeupRow")
let autoWakeupStatusIdentifier = NSUserInterfaceItemIdentifier("autoWakeupStatus")
let autoWakeupDetailIdentifier = NSUserInterfaceItemIdentifier("autoWakeupDetail")
let autoWakeupSwitchIdentifier = NSUserInterfaceItemIdentifier("autoWakeupSwitch")

/// Repaint an existing Auto Wakeup row in place. An open NSMenu keeps showing the views it was
/// built with, so flipping the switch has to update those views rather than rebuild the menu.
func updateAutoWakeupView(_ view: NSView, enabled: Bool, state: WakeupState, now: Date = Date()) {
    for sub in view.subviews {
        switch sub.identifier {
        case autoWakeupStatusIdentifier?:
            guard let field = sub as? NSTextField else { continue }
            field.stringValue = wakeupStateLabel(enabled: enabled)
            field.textColor = enabled ? .systemGreen : .tertiaryLabelColor
        case autoWakeupDetailIdentifier?:
            guard let field = sub as? NSTextField else { continue }
            field.stringValue = wakeupRowDetail(enabled: enabled, state: state, now: now)
        case autoWakeupSwitchIdentifier?:
            // Keep the control in sync when the change came from somewhere other than a click.
            (sub as? NSSwitch)?.state = enabled ? .on : .off
        default:
            continue
        }
    }
}

/// Single-row Auto Wakeup control: label on the left, an NSSwitch pinned to the right edge.
/// Replaces the old two-line (checkmark item + note line) form. The status text rides along as a
/// de-emphasised suffix so the row still says when it last fired without costing a second line.
/// A free function, like the other menu-view builders, so `--menu` can render it headlessly.
func makeAutoWakeupView(
    enabled: Bool, state: WakeupState, target: AnyObject?, action: Selector?, now: Date = Date()
) -> NSView {
    let leading: CGFloat = 14   // align with the provider header / table rows
    let trailing: CGFloat = 14
    let vPad: CGFloat = 3
    let font = NSFont.menuFont(ofSize: 0)

    let title = NSTextField(labelWithString: "Auto Wakeup")
    title.font = font
    title.textColor = .labelColor

    // The switch alone reads ambiguously in a menu (its accent-blue "on" fill is close in weight
    // to the grey "off" track), so the state is also stated in words and in colour.
    let status = NSTextField(labelWithString: wakeupStateLabel(enabled: enabled))
    status.font = NSFont.menuFont(ofSize: 0)
    status.textColor = enabled ? .systemGreen : .tertiaryLabelColor

    let detail = NSTextField(labelWithString: wakeupRowDetail(enabled: enabled, state: state, now: now))
    detail.font = font
    detail.textColor = .secondaryLabelColor

    let toggle = NSSwitch()
    toggle.state = enabled ? .on : .off
    toggle.target = target
    toggle.action = action
    // Keep the switch at its natural size; only the gap before it should absorb extra width.
    toggle.setContentHuggingPriority(.required, for: .horizontal)
    toggle.setContentCompressionResistancePriority(.required, for: .horizontal)

    let container = NSView()
    container.identifier = autoWakeupRowIdentifier
    status.identifier = autoWakeupStatusIdentifier
    detail.identifier = autoWakeupDetailIdentifier
    toggle.identifier = autoWakeupSwitchIdentifier
    for v in [title, detail, status, toggle] as [NSView] {
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
    }

    NSLayoutConstraint.activate([
        title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
        title.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
        detail.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        status.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 12),
        status.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -6),
        status.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -trailing),
        toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        container.heightAnchor.constraint(
            greaterThanOrEqualTo: toggle.heightAnchor, constant: 2 * vPad),
    ])

    // Same frame-based handoff as makeProviderHeaderView: NSMenu sets the view's frame directly
    // to widen it, which never reaches the subviews while Auto Layout still owns them.
    let fitting = container.fittingSize
    container.translatesAutoresizingMaskIntoConstraints = true
    container.autoresizingMask = [.width]
    container.frame = NSRect(origin: .zero, size: fitting)
    return container
}

func makeAutoWakeupItem(
    enabled: Bool, state: WakeupState, target: AnyObject?, action: Selector?
) -> NSMenuItem {
    let item = NSMenuItem()
    item.isEnabled = true
    item.view = makeAutoWakeupView(enabled: enabled, state: state, target: target, action: action)
    return item
}

func makeProviderHeaderItem(_ provider: Provider, model: CurrentModel?) -> NSMenuItem {
    let item = NSMenuItem()
    item.isEnabled = true
    item.view = makeProviderHeaderView(provider, model: model)
    return item
}

/// Header row view: brand icon + provider name on the left, `model` (name + id) on the right,
/// both de-emphasized like the note lines. AppKit stretches a menu item's view to the menu's
/// width, so the trailing-pinned model label lands at the right edge whichever item is widest.
/// A free function so the offscreen `--menu` render can build it without an AppDelegate.
func makeProviderHeaderView(_ provider: Provider, model: CurrentModel?) -> NSView {
    let leading: CGFloat = 14   // icon sits in the menu's checkmark gutter, like NSMenuItem.image did
    let trailing: CGFloat = 14  // same right inset as the usage table
    let vPad: CGFloat = 3
    let iconSize: CGFloat = 14
    let font = NSFont.menuFont(ofSize: 0)

    func label(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = .secondaryLabelColor
        t.lineBreakMode = .byClipping  // truncating mode under-reports the intrinsic width by a few points
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }

    let icon = NSImageView(image: provider.icon(pointSize: iconSize))
    icon.translatesAutoresizingMaskIntoConstraints = false
    let name = label(provider.displayName)

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(icon)
    container.addSubview(name)
    var constraints = [
        icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
        icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: iconSize),
        icon.heightAnchor.constraint(equalToConstant: iconSize),
        name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
        name.topAnchor.constraint(equalTo: container.topAnchor, constant: vPad),
        name.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vPad),
    ]
    if let model {
        let modelLabel = label("\(model.name) (\(model.id))")
        container.addSubview(modelLabel)
        constraints += [
            modelLabel.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 16),
            modelLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -trailing),
            modelLabel.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ]
    } else {
        constraints.append(
            container.trailingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: trailing))
    }
    NSLayoutConstraint.activate(constraints)
    // Measure the intrinsic width with Auto Layout, then hand the container over to frame-based
    // sizing: NSMenu (and the --menu render) widen the item view to the menu width by setting
    // its frame, and a constraint-sized root view would snap back to its fitting width on the
    // next layout pass — leaving the model label short of the right edge.
    let fitting = container.fittingSize
    container.translatesAutoresizingMaskIntoConstraints = true
    container.autoresizingMask = [.width]
    container.frame = NSRect(origin: .zero, size: fitting)
    return container
}

/// The two fonts a usage table is drawn with. Built in one place so measuring
/// (`usageTableColumnWidths`) and rendering (`makeUsageTableView`) can never drift apart.
func usageTableFonts() -> (menu: NSFont, digit: NSFont) {
    let menu = NSFont.menuFont(ofSize: 0)
    return (menu, NSFont.monospacedDigitSystemFont(ofSize: menu.pointSize, weight: .regular))
}

/// Width of the widest label, percent and reset cell across *all* rows of *all*
/// provider sections. Both usage tables must be built with these widths or their columns
/// disagree: NSGridView sizes each column to the widest cell in that grid alone, so
/// Claude's ("Weekly Fable", "43%") and Codex's ("Weekly", "0%") end up different widths.
/// The reset column matters just as much as the other two: it is right-aligned at the menu's
/// edge, so a section whose widest reset is narrower ("5d 2h" vs "16h 16m") starts that column
/// further right and leaves its percent cell stranded mid-row instead of tucked against it.
func usageTableColumnWidths(sections: [[UsageRow]]) -> (label: CGFloat, pct: CGFloat, reset: CGFloat) {
    let fonts = usageTableFonts()
    var label: CGFloat = 0
    var pct: CGFloat = 0
    var reset: CGFloat = 0
    for rows in sections {
        for row in rows {
            label = max(label, (row.label as NSString).size(withAttributes: [.font: fonts.menu]).width)
            pct = max(pct, ("\(row.pct)%" as NSString).size(withAttributes: [.font: fonts.digit]).width)
            reset = max(reset, (row.reset as NSString).size(withAttributes: [.font: fonts.menu]).width)
        }
    }
    return (ceil(label), ceil(pct), ceil(reset))
}

/// Build a non-interactive view hosting an aligned 3-column usage table
/// (label | percent right-aligned | remaining time). Sized to its intrinsic content so the
/// menu item adopts the table's width. A free function so the offscreen render path
/// can build it without an AppDelegate.
///
/// Pass `columnWidths` (from `usageTableColumnWidths` over every section's rows) so the
/// label and percent columns match across provider sections; `nil` keeps each table
/// self-sizing. `captionResetColumn` adds a small "resets in" caption row above the
/// table, over the third column — meant for the first section only, so the phrase appears
/// once in the menu instead of on every row.
func makeUsageTableView(
    rows: [UsageRow], columnWidths: (label: CGFloat, pct: CGFloat, reset: CGFloat)? = nil,
    captionResetColumn: Bool = false
) -> NSView {
    // Match the standard menu item insets so the table lines up with the items
    // below the separator. `leading` ~= the menu's text gutter (checkmark + gap).
    let leading: CGFloat = 21
    let trailing: CGFloat = 14
    let vPad: CGFloat = 5

    let (menuFont, digitFont) = usageTableFonts()

    func cell(
        _ s: String, font: NSFont, color: NSColor, align: NSTextAlignment = .left,
        stretches: Bool = false
    ) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = color
        t.alignment = align
        t.lineBreakMode = .byClipping
        t.translatesAutoresizingMaskIntoConstraints = false
        if stretches {
            // Let the label column absorb any extra width the menu is stretched to (a long
            // header line, e.g. "Sonnet (claude-sonnet-5)", widens the whole item view).
            // Otherwise NSGridView hands that slack to the last flexible column instead —
            // pushing the reset column away from percent and leaving percent looking
            // centered instead of tucked against it at the right edge.
            t.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return t
    }

    var gridRows: [[NSView]] = []
    if captionResetColumn {
        let captionFont = NSFont.systemFont(ofSize: menuFont.pointSize - 2)
        gridRows.append([
            NSView(), NSView(),
            cell("resets in", font: captionFont, color: .secondaryLabelColor, align: .right),
        ])
    }
    gridRows += rows.map { row in
        [
            cell(row.label, font: menuFont, color: .labelColor, stretches: true),
            cell("\(row.pct)%", font: digitFont, color: .labelColor, align: .right),
            cell(row.reset, font: menuFont, color: .secondaryLabelColor, align: .right),
        ]
    }
    let grid = NSGridView(views: gridRows)
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.rowSpacing = 4
    grid.columnSpacing = 8
    grid.column(at: 0).xPlacement = NSGridCell.Placement.leading
    grid.column(at: 1).xPlacement = NSGridCell.Placement.trailing  // line up the % signs
    grid.column(at: 2).xPlacement = NSGridCell.Placement.trailing  // right-align remaining time
    // Percent and remaining time sit close together as one right-aligned block; the label
    // column (set to stretch, above) absorbs any extra width instead.
    grid.column(at: 0).trailingPadding = 16
    grid.column(at: 1).trailingPadding = 6
    if let w = columnWidths {
        // Percent stays fixed-width so the "%" signs line up across sections. The label
        // column instead gets a *minimum* width, via constraints on its cells rather than
        // `NSGridColumn.width` (which pins an exact width): that leaves it free to grow when
        // the menu is stretched wider by a long header line, so that slack lands here —
        // between label and percent — instead of prying percent away from reset.
        grid.column(at: 1).width = w.pct
        grid.column(at: 2).width = w.reset
        for i in 0..<gridRows.count {
            let labelCell = gridRows[i][0]
            labelCell.widthAnchor.constraint(greaterThanOrEqualToConstant: w.label).isActive = true
        }
    }

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(grid)
    // Hug the grid's intrinsic width rather than pinning trailing outright: `fittingSize`
    // still resolves to the intrinsic width, but a menu made wider by a longer item below
    // can no longer hand the slack to the last column.
    let trailingHug = container.trailingAnchor.constraint(
        equalTo: grid.trailingAnchor, constant: trailing)
    trailingHug.priority = .defaultLow
    NSLayoutConstraint.activate([
        grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
        container.trailingAnchor.constraint(greaterThanOrEqualTo: grid.trailingAnchor, constant: trailing),
        trailingHug,
        grid.topAnchor.constraint(equalTo: container.topAnchor, constant: vPad),
        grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vPad),
    ])
    // Measure the intrinsic width with Auto Layout, then hand off to frame-based sizing —
    // same reasoning as makeProviderHeaderView: NSMenu widens a menu-item view by setting its
    // frame directly, and without `autoresizingMask` (and constraints switched off) that width
    // change never reaches `grid`, so a narrower table (Codex, with only "5h"/"Weekly" labels)
    // silently keeps its own intrinsic width while a wider one (Claude) gets stretched.
    let fitting = container.fittingSize
    container.translatesAutoresizingMaskIntoConstraints = true
    container.autoresizingMask = [.width]
    container.frame = NSRect(origin: .zero, size: fitting)
    grid.translatesAutoresizingMaskIntoConstraints = true
    grid.autoresizingMask = [.width]
    grid.frame = NSRect(x: leading, y: vPad, width: fitting.width - leading - trailing,
                         height: fitting.height - 2 * vPad)
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

    // formatResetDuration: bare duration for the dropdown table; formatResetIn keeps the phrase.
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    check(formatResetDuration(t0.addingTimeInterval(3 * 3600 + 5 * 60), now: t0) == "3h 5m",
          "formatResetDuration h m")
    check(formatResetDuration(t0.addingTimeInterval(5 * 86400 + 4 * 3600 + 30 * 60), now: t0) == "5d 4h",
          "formatResetDuration d h (minutes dropped)")
    check(formatResetDuration(t0.addingTimeInterval(20), now: t0) == "<1m", "formatResetDuration <1m")
    check(formatResetDuration(t0.addingTimeInterval(-5), now: t0) == "soon", "formatResetDuration past → soon")
    check(formatResetDuration(nil as Date?, now: t0) == "—", "formatResetDuration nil → —")
    check(formatResetDuration("2023-11-14T22:13:20+00:00", now: t0.addingTimeInterval(-90 * 60)) == "1h 30m",
          "formatResetDuration ISO string")
    check(formatResetDuration("garbage", now: t0) == "—", "formatResetDuration unparsable → —")
    check(formatResetIn(t0.addingTimeInterval(3 * 3600 + 5 * 60), now: t0) == "resets in 3h 5m",
          "formatResetIn keeps prefix")
    check(formatResetIn(t0.addingTimeInterval(-5), now: t0) == "resets soon", "formatResetIn past")
    check(formatResetIn(nil as Date?, now: t0) == "reset time unknown", "formatResetIn nil")
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

    // codexWindowIsIdle: an idle window reports reset_after == limit_window (rolling reset).
    check(codexWindowIsIdle(resetAfterSeconds: 18000, limitWindowSeconds: 18000),
          "codexWindowIsIdle: full window remaining -> idle")
    check(codexWindowIsIdle(resetAfterSeconds: 17999.4, limitWindowSeconds: 18000),
          "codexWindowIsIdle: rounding slack -> idle")
    check(!codexWindowIsIdle(resetAfterSeconds: 17000, limitWindowSeconds: 18000),
          "codexWindowIsIdle: countdown running -> not idle")
    check(!codexWindowIsIdle(resetAfterSeconds: 18000, limitWindowSeconds: nil),
          "codexWindowIsIdle: missing limit -> not idle")
    check(!codexWindowIsIdle(resetAfterSeconds: nil, limitWindowSeconds: 18000),
          "codexWindowIsIdle: missing reset_after -> not idle")
    let codexIdle = #"{"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":18000,"reset_at":1790254660}}}"#
        .data(using: .utf8)!
    check((try? parseCodexUsage(codexIdle))?.fiveHour.idle == true,
          "parseCodexUsage: idle window -> idle (rolling reset_at present)")
    check((try? parseCodexUsage(codexJSON))?.fiveHour.idle == false,
          "parseCodexUsage: no window length -> not idle")

    // Token accounting (Tokens.swift): per-local-day buckets, deduplicated by message.id.
    let dayA = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 22))!
    let dayB = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 1))!
    let iso = ISO8601DateFormatter()
    func aLine(_ id: String, _ d: Date, _ usage: String) -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"\(iso.string(from: d))\",\"message\":{\"id\":\"\(id)\",\"usage\":{\(usage)}}}"
    }
    let claudeTok = [
        aLine("a", dayA, "\"input_tokens\":10,\"output_tokens\":20,\"cache_creation_input_tokens\":30,\"cache_read_input_tokens\":40"),
        aLine("a", dayA, "\"input_tokens\":10,\"output_tokens\":20,\"cache_creation_input_tokens\":30,\"cache_read_input_tokens\":40"),
        aLine("b", dayB, "\"input_tokens\":1,\"output_tokens\":2,\"cache_creation_input_tokens\":3,\"cache_read_input_tokens\":4"),
        "{\"type\":\"assistant\",\"message\":{\"id\":\"nots\",\"usage\":{\"input_tokens\":100}}}",
        "{\"type\":\"user\",\"timestamp\":\"\(iso.string(from: dayB))\",\"message\":{\"usage\":{\"input_tokens\":999}}}",
        "junk",
        aLine("c", dayB, "\"output_tokens\":2"),
    ].joined(separator: "\n")
    let ct = extractDailyTotals(claudeTok)
    check(ct == ["2026-09-25": TokenTotals(input: 10, output: 20, cacheRead: 40, cacheCreate: 30),
                 "2026-09-26": TokenTotals(input: 1, output: 4, cacheRead: 4, cacheCreate: 3)],
          "extractDailyTotals: local-day buckets, dedup by message.id, junk skipped (got \(ct))")
    check(extractDailyTotals("").isEmpty, "extractDailyTotals: empty -> no buckets")

    // formatTokens / tokenTotalsText: identical strings to the other ports.
    check(formatTokens(0) == "0" && formatTokens(999) == "999", "formatTokens: plain below 1000")
    check(formatTokens(1234) == "1.2K" && formatTokens(48_000) == "48K" && formatTokens(310_400) == "310K",
          "formatTokens: K scale")
    check(formatTokens(999_999) == "1.0M" && formatTokens(9_800_000) == "9.8M" && formatTokens(13_500_000) == "14M",
          "formatTokens: M scale")
    check(formatTokens(999_999_999) == "1.0B" && formatTokens(2_100_000_000) == "2.1B", "formatTokens: B scale")
    check(tokenTotalsText(TokenTotals(input: 1_200_000, output: 48_000, cacheRead: 9_000_000, cacheCreate: 800_000))
          == "1.2M in · 48K out · 9.8M cache", "tokenTotalsText: in · out · cache")

    // Codex (CodexTokens.swift): token_usage_record preferred and deduplicated by response_id;
    // input_tokens includes cached_input_tokens, which the shared totals keep apart.
    let codexDay = localDateKey(parseISODate("2026-09-26T01:00:00Z")!)
    let codexRecords = """
    {"timestamp":"2026-09-26T01:00:00Z","type":"turn_context","payload":{"model":"gpt-6-astra"}}
    {"timestamp":"2026-09-26T01:00:00Z","type":"token_usage_record","payload":{"response_id":"r1","usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":50}}}
    {"timestamp":"2026-09-26T01:00:00.5Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999999},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":50}}}}
    {"timestamp":"2026-09-26T01:01:00Z","type":"token_usage_record","payload":{"response_id":"r2","usage":{"input_tokens":300,"cached_input_tokens":0,"cache_write_input_tokens":20,"output_tokens":5}}}
    {"timestamp":"2026-09-26T01:01:00Z","type":"token_usage_record","payload":{"response_id":"r2","usage":{"input_tokens":300,"cached_input_tokens":0,"cache_write_input_tokens":20,"output_tokens":5}}}
    {"timestamp":"2026-09-20T01:00:00Z","type":"token_usage_record","payload":{"response_id":"r0","usage":{"input_tokens":5000,"output_tokens":5000}}}
    """
    let cr = extractCodexDailyTotals(codexRecords)
    check(cr[codexDay] == TokenTotals(input: 700, output: 55, cacheRead: 600, cacheCreate: 20) && cr.count == 2,
          "extractCodexDailyTotals: records preferred, response_id dedup, day buckets (got \(cr))")
    let codexEvents = """
    {"timestamp":"2026-09-26T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":50}}}}
    {"timestamp":"2026-09-26T01:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":50}}}}
    {"timestamp":"2026-09-26T01:00:02Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}
    {"timestamp":"2026-09-26T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":0,"cache_write_input_tokens":20,"output_tokens":5}}}}
    """
    let ce = extractCodexDailyTotals(codexEvents)
    check(ce[codexDay] == TokenTotals(input: 700, output: 55, cacheRead: 600, cacheCreate: 20) && ce.count == 1,
          "extractCodexDailyTotals: token_count fallback, consecutive repeats and null info skipped (got \(ce))")
    check(extractCodexDailyTotals("junk\n\n{\"type\":\"session_meta\"}").isEmpty,
          "extractCodexDailyTotals: junk -> no buckets")

    // TokenHistory.swift: ledger max rule, ranges, trend, stats, rows.
    check(localDateKey(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 23, minute: 59))!) == "2026-09-26",
          "localDateKey")
    check(dateShift("2026-09-26", -6) == "2026-09-20" && dateShift("2026-03-01", -1) == "2026-02-28"
          && dateShift("2026-01-01", -1) == "2025-12-31", "dateShift")
    var ledger = TokenLedger()
    check(ledger.merge(provider: "claude", daily: ["2026-09-25": TokenTotals(input: 10, output: 5), "2026-09-26": TokenTotals(input: 1, output: 1)], today: "2026-09-26"),
          "ledger.merge: first merge changes")
    check(ledger.merge(provider: "claude", daily: ["2026-09-25": TokenTotals(input: 4, output: 9), "2026-09-26": TokenTotals(input: 1, output: 1)], today: "2026-09-26"),
          "ledger.merge: growing field changes")
    check(ledger.days["2026-09-25"]?["claude"] == TokenTotals(input: 10, output: 9), "ledger.merge: per-field max, never adds")
    check(!ledger.merge(provider: "claude", daily: ["2026-09-26": TokenTotals(input: 1, output: 1)], today: "2026-09-26"),
          "ledger.merge: no-op reports no change")
    check(ledger.since["claude"] == "2026-09-26", "ledger.merge: since = first observation")
    _ = ledger.merge(provider: "codex", daily: ["2026-09-26": TokenTotals(input: 7)], today: "2026-09-26")
    check(ledger.days["2026-09-26"]?["codex"] == TokenTotals(input: 7) && ledger.days["2026-09-26"]?["claude"] == TokenTotals(input: 1, output: 1),
          "ledger.merge: providers side by side")
    var other = TokenLedger()
    _ = other.merge(provider: "claude", daily: ["2026-09-25": TokenTotals(input: 4, output: 50), "2026-09-20": TokenTotals(input: 2)], today: "2026-09-20")
    let merged = TokenLedger.merged(ledger, other)
    check(merged.days["2026-09-25"]?["claude"] == TokenTotals(input: 10, output: 50) && merged.days["2026-09-20"]?["claude"] == TokenTotals(input: 2)
          && merged.since["claude"] == "2026-09-20", "TokenLedger.merged: max per field, earliest since")
    var l3 = TokenLedger()
    _ = l3.merge(provider: "claude", daily: ["2026-09-20": TokenTotals(input: 1), "2026-09-21": TokenTotals(input: 2), "2026-09-22": TokenTotals(input: 4), "2026-09-23": TokenTotals(input: 8)], today: "2026-09-23")
    check(l3.sum(provider: "claude", from: "2026-09-21", to: "2026-09-22") == TokenTotals(input: 6), "ledger.sum: inclusive range")
    check(trendText(TokenTotals(input: 112), TokenTotals(input: 100)) == "▲ 12%" && trendText(TokenTotals(input: 95), TokenTotals(input: 100)) == "▼ 5%"
          && trendText(TokenTotals(input: 50, output: 50), TokenTotals(input: 60, output: 40)) == "± 0%"
          && trendText(TokenTotals(input: 5), TokenTotals()) == "—" && trendText(TokenTotals(input: 5), nil) == "—", "trendText")
    var l4 = TokenLedger()
    var daily14: [String: TokenTotals] = [:]
    for i in 0..<14 { daily14[dateShift("2026-09-26", -i)] = TokenTotals(input: 1) }
    _ = l4.merge(provider: "claude", daily: daily14, today: "2026-09-26")
    let st = l4.stats(provider: "claude", today: "2026-09-26")
    check(st.today == TokenTotals(input: 1) && st.last7 == TokenTotals(input: 7) && st.prev7 == TokenTotals(input: 7)
          && st.last30 == TokenTotals(input: 14) && st.prev30 == nil, "ledger.stats: rolling windows, prior 30d needs coverage (got \(st))")
    let rows = tokenRows(TokenStats(
        today: TokenTotals(input: 5_900, output: 406_000, cacheRead: 78_000_000, cacheCreate: 2_300_000),
        last7: TokenTotals(input: 41_000_000, output: 2_900_000, cacheRead: 600_000_000, cacheCreate: 20_000_000),
        prev7: TokenTotals(input: 30_000_000, output: 2_000_000, cacheRead: 550_000_000, cacheCreate: 10_000_000),
        last30: TokenTotals(input: 120_000_000, output: 9_100_000, cacheRead: 2_000_000_000, cacheCreate: 100_000_000),
        prev30: nil))
    check(rows.map { $0.label } == ["Tokens today", "Tokens 7d", "Tokens 30d"]
          && rows[0].value == "5.9K in · 406K out · 80M cache"
          && rows[1].value == "41M in · 2.9M out · 620M cache · ▲ 12% vs prior 7d"
          && rows[2].value == "120M in · 9.1M out · 2.1B cache · — vs prior 30d", "tokenRows: shared wording (got \(rows))")

    // tokenMenuTitles: "Tokens today" is the visible row; 7d / 30d go into its hover submenu.
    let menuTitles = tokenMenuTitles(TokenStats(
        today: TokenTotals(input: 1200, output: 48, cacheRead: 100), last7: TokenTotals(input: 7), prev7: nil,
        last30: TokenTotals(input: 30), prev30: nil))
    check(menuTitles.today == "Tokens today: 1.2K in · 48 out · 100 cache"
          && menuTitles.history == ["Tokens 7d: 7 in · 0 out · 0 cache · — vs prior 7d",
                                    "Tokens 30d: 30 in · 0 out · 0 cache · — vs prior 30d"],
          "tokenMenuTitles: today visible, 7d / 30d in submenu (got \(menuTitles))")
    let tokensItem = makeTokensItem(TokenStats(
        today: TokenTotals(input: 1200, output: 48, cacheRead: 100), last7: TokenTotals(input: 7), prev7: nil,
        last30: TokenTotals(input: 30), prev30: nil))
    check(tokensItem.title == menuTitles.today && tokensItem.hasSubmenu
          && tokensItem.submenu?.items.map(\.title) == menuTitles.history
          && tokensItem.submenu?.items.allSatisfy(\.isEnabled) == true,
          "makeTokensItem: dropdown row shows today only; 7d / 30d are its hover submenu")

    // updateTokenHistory: backfill, subagents, deleted-file preservation, cache reuse, corrupt ledger quarantine.
    let histBase = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-hist-\(UUID().uuidString)")
    let histRoot = histBase.appendingPathComponent("projects")
    let histHome = histBase.appendingPathComponent("pulse-home")
    let histProj = histRoot.appendingPathComponent("-Users-me-proj")
    try? FileManager.default.createDirectory(at: histProj.appendingPathComponent("sess1/subagents"), withIntermediateDirectories: true)
    let histNow = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12))!
    let h0 = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 10))!
    let h1 = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 10))!
    try? (aLine("a", h0, "\"input_tokens\":10") + "\n" + aLine("b", h1, "\"input_tokens\":3") + "\n")
        .write(to: histProj.appendingPathComponent("sess1.jsonl"), atomically: true, encoding: .utf8)
    try? (aLine("c", h0, "\"output_tokens\":7") + "\n")
        .write(to: histProj.appendingPathComponent("sess1/subagents/agent-x.jsonl"), atomically: true, encoding: .utf8)
    let oldFile = histProj.appendingPathComponent("old.jsonl")
    try? (aLine("d", h1, "\"input_tokens\":100") + "\n").write(to: oldFile, atomically: true, encoding: .utf8)
    var histReads = 0
    let counting: (String) -> [String: TokenTotals] = { histReads += 1; return extractDailyTotals($0) }
    let s1 = updateTokenHistory(provider: "claude", root: histRoot, extract: counting, home: histHome, now: histNow)
    check(s1?.today == TokenTotals(input: 10, output: 7) && s1?.last7 == TokenTotals(input: 113, output: 7) && histReads == 3,
          "updateTokenHistory: backfill incl. subagents (got \(String(describing: s1)) reads \(histReads))")
    try? FileManager.default.removeItem(at: oldFile)
    let s2 = updateTokenHistory(provider: "claude", root: histRoot, extract: counting, home: histHome, now: histNow)
    check(s2?.last7 == TokenTotals(input: 113, output: 7) && histReads == 3,
          "updateTokenHistory: deleted file keeps its contribution, unchanged files not re-read (reads \(histReads))")
    try? (aLine("a", h0, "\"input_tokens\":10") + "\n" + aLine("b", h1, "\"input_tokens\":3") + "\n" + aLine("e", h0, "\"input_tokens\":5") + "\n")
        .write(to: histProj.appendingPathComponent("sess1.jsonl"), atomically: true, encoding: .utf8)
    let s3 = updateTokenHistory(provider: "claude", root: histRoot, extract: counting, home: histHome, now: histNow)
    check(s3?.today == TokenTotals(input: 15, output: 7) && histReads == 4, "updateTokenHistory: appended file re-read once (reads \(histReads))")
    check(FileManager.default.fileExists(atPath: histHome.appendingPathComponent("cache/claude-files.json").path),
          "updateTokenHistory: file cache persisted")
    try? "{not json".write(to: histHome.appendingPathComponent("token-history.json"), atomically: true, encoding: .utf8)
    let s4 = updateTokenHistory(provider: "claude", root: histRoot, extract: counting, home: histHome, now: histNow)
    let histNames = (try? FileManager.default.contentsOfDirectory(atPath: histHome.path)) ?? []
    check(s4?.today == TokenTotals(input: 15, output: 7) && histNames.contains { $0.hasPrefix("token-history.json.corrupt-") },
          "updateTokenHistory: corrupt ledger quarantined (\(histNames))")
    check(updateTokenHistory(provider: "claude", root: histBase.appendingPathComponent("nope"), extract: counting, home: histHome, now: histNow) == nil,
          "updateTokenHistory: missing root -> nil")
    try? FileManager.default.removeItem(at: histBase)

    // extractLastCodexModel: last turn_context wins; other record types and junk are skipped.
    let codexLog = """
    {"type":"session_meta","payload":{"model_provider":"openai"}}
    {"type":"turn_context","payload":{"turn_id":"t1","model":"gpt-6-astra"}}
    {"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.5"}}}
    {"type":"turn_context","payload":{"turn_id":"t2","model":"gpt-5.6-terra"}}
    not json at all
    {"type":"event_msg","payload":{"type":"task_complete"}}

    """
    check(extractLastCodexModel(codexLog) == "gpt-5.6-terra", "extractLastCodexModel picks last turn_context model")
    check(extractLastCodexModel("") == nil, "extractLastCodexModel empty -> nil")
    check(extractLastCodexModel(#"{"type":"session_meta","payload":{"model":"x"}}"#) == nil,
          "extractLastCodexModel ignores non-turn_context records")

    // codexModelDisplayName: slug -> display_name via models_cache.json, lenient fallback to slug.
    let modelsCache = #"{"models":[{"slug":"gpt-5.6-terra","display_name":"GPT-5.6-Terra"},{"slug":"gpt-6-astra","display_name":"GPT-6-Astra"}]}"#
        .data(using: .utf8)
    check(codexModelDisplayName("gpt-5.6-terra", cache: modelsCache) == "GPT-5.6-Terra", "codexModelDisplayName maps known slug")
    check(codexModelDisplayName("gpt-unknown", cache: modelsCache) == "gpt-unknown", "codexModelDisplayName unknown slug -> slug")
    check(codexModelDisplayName("gpt-6-astra", cache: nil) == "gpt-6-astra", "codexModelDisplayName nil cache -> slug")
    check(codexModelDisplayName("gpt-6-astra", cache: "garbage".data(using: .utf8)) == "gpt-6-astra",
          "codexModelDisplayName garbage cache -> slug")

    // latestDate: single "Updated:" line takes the later provider timestamp.
    let d1 = Date(timeIntervalSince1970: 100), d2 = Date(timeIntervalSince1970: 200)
    check(latestDate(d1, d2) == d2 && latestDate(d2, d1) == d2, "latestDate picks the later date")
    check(latestDate(d1, nil) == d1 && latestDate(nil, d2) == d2, "latestDate passes through a lone date")
    check(latestDate(nil, nil) == nil, "latestDate nil,nil -> nil")

    // --- Auto Wakeup -------------------------------------------------------
    // The 5h window is clock-aligned (verified: resets_at lands on the hour), so a missing
    // resets_at means "no activity recorded in this window yet", not "window expired".
    // That absence is exactly what leaves the 5h row showing "reset time unknown" / "—".

    // needsWakeup: fires only when the reset time is genuinely absent.
    check(needsWakeup(resetsAt: nil as Date?, now: t0), "needsWakeup: nil reset -> true")
    check(!needsWakeup(resetsAt: t0.addingTimeInterval(3600), now: t0),
          "needsWakeup: future reset -> false (row already shows a time)")
    check(!needsWakeup(resetsAt: t0.addingTimeInterval(-3600), now: t0),
          "needsWakeup: past reset -> false (only absence triggers, per design)")
    check(needsWakeup(resetsAt: nil as String?, now: t0), "needsWakeup: nil string -> true")
    check(needsWakeup(resetsAt: "garbage", now: t0),
          "needsWakeup: unparsable reset -> true (displays as unknown, so treat as absent)")
    check(!needsWakeup(resetsAt: "2023-11-14T23:13:20Z", now: t0),
          "needsWakeup: parsable future string -> false")

    // shouldWakeUp: the guard chain. Cooldown is the backstop if the predicate is ever wrong.
    let emptyState = WakeupState()
    check(shouldWakeUp(enabled: true, resetsAt: nil as Date?, state: emptyState,
                       inFlight: false, now: t0),
          "shouldWakeUp: enabled + absent reset -> fires")
    check(!shouldWakeUp(enabled: false, resetsAt: nil as Date?, state: emptyState,
                        inFlight: false, now: t0),
          "shouldWakeUp: disabled never fires")
    check(!shouldWakeUp(enabled: true, resetsAt: nil as Date?, state: emptyState,
                        inFlight: true, now: t0),
          "shouldWakeUp: never fires while a request is in flight")
    check(!shouldWakeUp(enabled: true, resetsAt: t0.addingTimeInterval(3600), state: emptyState,
                        inFlight: false, now: t0),
          "shouldWakeUp: reset time present -> does not fire")

    let justFired = WakeupState(lastWakeupAt: t0.addingTimeInterval(-60), lastWindowResetsAt: nil)
    check(!shouldWakeUp(enabled: true, resetsAt: nil as Date?, state: justFired,
                        inFlight: false, now: t0),
          "shouldWakeUp: cooldown blocks a second attempt")
    let cooledDown = WakeupState(
        lastWakeupAt: t0.addingTimeInterval(-wakeupCooldown - 1), lastWindowResetsAt: nil)
    check(shouldWakeUp(enabled: true, resetsAt: nil as Date?, state: cooledDown,
                       inFlight: false, now: t0),
          "shouldWakeUp: fires again once the cooldown has elapsed")

    // Codex wakeup: request body is a minimal Responses-API user turn.
    let codexBody = codexWakeupRequestBody(model: "gpt-x")
    let codexInput = (codexBody["input"] as? [[String: Any]])?.first
    let codexContent = (codexInput?["content"] as? [[String: Any]])?.first
    check(codexBody["model"] as? String == "gpt-x"
          && codexBody["store"] as? Bool == false && codexBody["stream"] as? Bool == true,
          "codexWakeupRequestBody: model, store=false, stream=true")
    check(codexInput?["role"] as? String == "user"
          && codexContent?["type"] as? String == "input_text" && codexContent?["text"] as? String == ".",
          "codexWakeupRequestBody: single '.' input_text user message")

    // codexWakeupModel: current model wins, else first listed cache model.
    let wakeCache = #"{"models":[{"slug":"hidden-1","visibility":"hide"},{"slug":"gpt-list","visibility":"list"},{"slug":"gpt-list-2","visibility":"list"}]}"#.data(using: .utf8)!
    check(codexWakeupModel(current: "gpt-now", cache: wakeCache) == "gpt-now",
          "codexWakeupModel: current model wins")
    check(codexWakeupModel(current: nil, cache: wakeCache) == "gpt-list",
          "codexWakeupModel: falls back to first listed model, skipping hidden")
    check(codexWakeupModel(current: "", cache: wakeCache) == "gpt-list",
          "codexWakeupModel: empty current treated as absent")
    check(codexWakeupModel(current: nil, cache: nil) == nil,
          "codexWakeupModel: no current, no cache -> nil")
    check(codexWakeupModel(current: nil, cache: "garbage".data(using: .utf8)) == nil,
          "codexWakeupModel: garbage cache -> nil")

    // stateAfterWakeup: recorded at attempt start so a crash mid-request still costs the cooldown.
    check(stateAfterWakeup(emptyState, resetsAt: nil, now: t0).lastWakeupAt == t0,
          "stateAfterWakeup records the attempt time")
    check(stateAfterWakeup(emptyState, resetsAt: t0.addingTimeInterval(5 * 3600), now: t0)
            .lastWindowResetsAt == t0.addingTimeInterval(5 * 3600),
          "stateAfterWakeup records the observed window")

    // wakeupStatusLine: English only, per CLAUDE.md.
    check(wakeupStatusLine(enabled: false, state: emptyState, now: t0) == "Auto Wakeup: off",
          "wakeupStatusLine disabled")
    check(wakeupStatusLine(enabled: true, state: emptyState, now: t0) == "Auto Wakeup: on",
          "wakeupStatusLine enabled, never fired")
    check(wakeupStatusLine(enabled: true, state: WakeupState(lastWakeupAt: t0,
                                                             lastWindowResetsAt: nil), now: t0)
            .hasPrefix("Auto Wakeup: last "),
          "wakeupStatusLine shows the last attempt time")

    // wakeupRowDetail: the single-row control's suffix. The switch shows on/off, so the text
    // must not repeat it — only a fired-at time earns space.
    check(wakeupRowDetail(enabled: false, state: emptyState, now: t0) == "",
          "wakeupRowDetail disabled -> empty (switch already shows off)")
    check(wakeupRowDetail(enabled: true, state: emptyState, now: t0) == "",
          "wakeupRowDetail enabled but never fired -> empty")
    check(wakeupRowDetail(enabled: true,
                          state: WakeupState(lastWakeupAt: t0, lastWindowResetsAt: nil), now: t0)
            == "last " + clockString(t0),
          "wakeupRowDetail shows the last attempt time")
    check(wakeupRowDetail(enabled: false,
                          state: WakeupState(lastWakeupAt: t0, lastWindowResetsAt: nil), now: t0)
            == "",
          "wakeupRowDetail disabled hides a stale time")
    check(wakeupStateLabel(enabled: true) == "On" && wakeupStateLabel(enabled: false) == "Off",
          "wakeupStateLabel spells the state out (colour is not the only cue)")

    // The row's views must actually repaint in place: an open NSMenu keeps the views it was
    // built with, so rebuilding the menu would leave a click looking like it did nothing.
    let liveRow = makeAutoWakeupView(enabled: false, state: WakeupState(), target: nil, action: nil)
    func rowText(_ id: NSUserInterfaceItemIdentifier) -> String {
        for sub in liveRow.subviews where sub.identifier == id {
            if let f = sub as? NSTextField { return f.stringValue }
        }
        return "<missing>"
    }
    func rowSwitchOn() -> Bool {
        for sub in liveRow.subviews where sub.identifier == autoWakeupSwitchIdentifier {
            if let sw = sub as? NSSwitch { return sw.state == .on }
        }
        return false
    }
    check(rowText(autoWakeupStatusIdentifier) == "Off" && !rowSwitchOn(),
          "auto wakeup row starts off")
    updateAutoWakeupView(liveRow, enabled: true,
                         state: WakeupState(lastWakeupAt: t0, lastWindowResetsAt: nil), now: t0)
    check(rowText(autoWakeupStatusIdentifier) == "On" && rowSwitchOn(),
          "updateAutoWakeupView flips the row to on in place")
    check(rowText(autoWakeupDetailIdentifier) == "last " + clockString(t0),
          "updateAutoWakeupView refreshes the last-fired time")
    updateAutoWakeupView(liveRow, enabled: false, state: WakeupState(), now: t0)
    check(rowText(autoWakeupStatusIdentifier) == "Off" && !rowSwitchOn()
            && rowText(autoWakeupDetailIdentifier) == "",
          "updateAutoWakeupView flips the row back to off in place")

    // The bug this guards: NSSwitch flips its own state *before* sending the action, so a
    // handler that also toggles ends up inverted — the model says off while the switch shows on.
    // Replay a real click by setting the control's state first, then dispatching, exactly as
    // AppKit does.
    func modelAfterClick(startingEnabled: Bool) -> Bool {
        let sw = NSSwitch()
        sw.state = startingEnabled ? .on : .off
        sw.performClick(nil)          // AppKit flips the control here
        return sw.state == .on        // ...and this is what the handler must adopt verbatim
    }
    check(modelAfterClick(startingEnabled: false) == true,
          "a click from off leaves the switch on (handler must adopt, not re-toggle)")
    check(modelAfterClick(startingEnabled: true) == false,
          "a click from on leaves the switch off")

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
            let tokens = readTokenStats()
            print("[gauge] " + menuBarText(usage))
            print("  5h:     \(pct(usage.fiveHour.utilization))% · \(formatResetIn(usage.fiveHour.resetsAt))")
            print("  Weekly: \(pct(usage.sevenDay.utilization))% · \(formatResetIn(usage.sevenDay.resetsAt))")
            for scoped in usage.weeklyScoped {
                print("  Weekly \(scoped.model): \(pct(scoped.window.utilization))% · \(formatResetIn(scoped.window.resetsAt))")
            }
            if let model = model { print("  Model:  \(model.name) (\(model.id))") }
            if let tokens { for row in tokenRows(tokens) { print("  \(row.label): \(row.value)") } }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

// --codex-wakeup: send one Codex wakeup request and report the result (end-to-end check).
if CommandLine.arguments.contains("--codex-wakeup") {
    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            try await sendCodexWakeup()
            print("Codex wakeup: ok")
        } catch {
            print("Codex wakeup failed: \(error)")
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
            let model = readCurrentCodexModel()
            let tokens = readCodexTokenStats()
            print("[codex]")
            print("  5h:     \(usage.fiveHour.usedPercent)% · \(formatResetIn(usage.fiveHour.resetsAt))")
            if let weekly = usage.weekly {
                print("  Weekly: \(weekly.usedPercent)% · \(formatResetIn(weekly.resetsAt))")
            }
            if let plan = usage.planType { print("  Plan: \(plan)") }
            if let model = model { print("  Model:  \(model.name) (\(model.id))") }
            if let tokens { for row in tokenRows(tokens) { print("  \(row.label): \(row.value)") } }
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
    // Read the real bundle version, as the About menu item does — a render that shows a made-up
    // version cannot catch a version regression.
    let renderVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "dev"
    let view = AppDelegate().makeAboutContentView(version: renderVersion)
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
    // `--dark` renders the same layout under the dark appearance, so colour choices can be
    // checked in both themes without flipping the whole system.
    if CommandLine.arguments.contains("--dark"), let dark = NSAppearance(named: .darkAqua) {
        NSAppearance.current = dark
    }
    // Two sections, as the real menu builds them — a wide-label/3-digit Claude block over a
    // narrow-label/1-digit Codex block. That is the case that used to misalign, so this render
    // is a genuine regression check: the two blocks' `%` right edge and `· resets in` left edge
    // must land at the same x.
    let claudeRows = [
        UsageRow(label: "5h", pct: 3, reset: "2h 13m"),
        UsageRow(label: "Weekly", pct: 27, reset: "4d 6h"),
        UsageRow(label: "Weekly Opus", pct: 100, reset: "4d 6h"),
        UsageRow(label: "Weekly Sonnet", pct: 8, reset: "16h 16m"),
        UsageRow(label: "Weekly Fable", pct: 12, reset: "4d 6h"),
    ]
    let codexRows = [
        UsageRow(label: "5h", pct: 0, reset: "3h 1m"),
        UsageRow(label: "Weekly", pct: 48, reset: "5d 2h"),
    ]
    let widths = usageTableColumnWidths(sections: [claudeRows, codexRows])
    // Each provider's header carries its current model at the right edge; the model label
    // must end at the same x in both headers once the views are stretched to the menu width.
    // A header longer than the table below it (as reported: "Sonnet (claude-sonnet-5)"
    // stretches the item view wider than the table's own intrinsic width) is the case that
    // used to pull percent away from the reset column — keep exercising it here.
    let items: [NSView] = [
        makeProviderHeaderView(.claude, model: CurrentModel(id: "claude-sonnet-5", name: "Sonnet")),
        makeUsageTableView(rows: claudeRows, columnWidths: widths, captionResetColumn: true),
        makeProviderHeaderView(.codex, model: CurrentModel(id: "gpt-5.6-terra", name: "GPT-5.6-Terra")),
        makeUsageTableView(rows: codexRows, columnWidths: widths),
        // The Auto Wakeup row: its switch must sit at the same right edge as the tables' reset
        // column once every view is stretched to the menu width.
        makeAutoWakeupView(
            enabled: true,
            state: WakeupState(lastWakeupAt: Date(timeIntervalSince1970: 1_700_000_000),
                               lastWindowResetsAt: nil),
            target: nil, action: nil),
        // Both states in one render: the On/Off badge and the switch must stay legible and
        // right-aligned in either, and in both light and dark (`--dark`).
        makeAutoWakeupView(enabled: false, state: WakeupState(), target: nil, action: nil),
    ]

    // Stack top-down at the same origin x and stretch every row to the widest one, as the menu does.
    let width = items.map { $0.frame.width }.max() ?? 0
    let view = NSView(frame: NSRect(
        x: 0, y: 0, width: width, height: items.reduce(0) { $0 + $1.frame.height }))
    var y = view.frame.height
    for item in items {
        y -= item.frame.height
        item.frame = NSRect(x: 0, y: y, width: width, height: item.frame.height)
        view.addSubview(item)
    }
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
