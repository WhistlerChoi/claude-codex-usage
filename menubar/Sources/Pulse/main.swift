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
                or run "claude" in a terminal yourself.

                (\(detail))
                """
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private static let repoURL = "https://github.com/WhistlerChoi/claude-usage"

    @objc func openGitHub() {
        if let url = URL(string: AppDelegate.repoURL) {
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
            as? String ?? "1.0.0"

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
            "Shows Claude Code's 5-hour and weekly usage\nand the current model in your menu bar.",
            size: 12, color: .labelColor)
        let meta = label(
            "Data: ~/.claude · /usage API   ·   Poll interval: \(Int(interval))s",
            size: 11, color: .secondaryLabelColor)

        // GitHub link button
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

        // Trademark / non-affiliation notice. Pulse is an independent product; it
        // reads Claude Code's local data but is not affiliated with Anthropic.
        let disclaimer = label(
            "Not affiliated with or endorsed by Anthropic.\nClaude is a trademark of Anthropic, PBC.",
            size: 10, color: .tertiaryLabelColor)

        let stack = NSStackView(views: [versionLabel, desc, meta, github, copyright, disclaimer])
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

    /// Return the About header banner image.
    /// Prefers the bundled PNG (generated by the visualize skill),
    /// falling back to a code-drawn gradient if absent.
    private func headerBannerImage(size: NSSize) -> NSImage {
        if let url = Bundle.module.url(forResource: "header", withExtension: "png"),
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

    // MARK: - Rendering

    private func renderUsage(_ usage: UsageData, _ model: CurrentModel?) {
        lastUsage = usage
        lastModel = model
        lastUpdated = Date()

        setStacked(
            top: "\(pct(usage.fiveHour.utilization))%",
            bottom: "\(pct(usage.sevenDay.utilization))%",
            color: colorForPeak(peakUtilization(usage))
        )

        var rows: [UsageRow] = [
            UsageRow(label: "5h", pct: pct(usage.fiveHour.utilization),
                     reset: formatResetIn(usage.fiveHour.resetsAt)),
            UsageRow(label: "Weekly", pct: pct(usage.sevenDay.utilization),
                     reset: formatResetIn(usage.sevenDay.resetsAt)),
        ]
        if let opus = usage.sevenDayOpus {
            rows.append(UsageRow(label: "Opus", pct: pct(opus.utilization),
                                 reset: formatResetIn(opus.resetsAt)))
        }
        if let sonnet = usage.sevenDaySonnet {
            rows.append(UsageRow(label: "Sonnet", pct: pct(sonnet.utilization),
                                 reset: formatResetIn(sonnet.resetsAt)))
        }

        var footer: [String] = []
        if let model = model {
            footer.append("Current model: \(model.name) (\(model.id))")
        }
        footer.append("Updated: \(clockString(lastUpdated!))")

        rebuildMenu(usageRows: rows, footerLines: footer)
    }

    /// Update the error display and return the delay (seconds) until the next poll.
    private func handleError(_ error: Error) -> TimeInterval {
        if error is CredentialsError || isAuthError(error) {
            setStacked(top: "Login", bottom: "needed", color: .systemRed)
            rebuildMenu(detailLines: [error.localizedDescription], showLogin: true)
            consecutiveFailures = 0
            return interval
        }
        // Transient error: retry with backoff
        consecutiveFailures += 1
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
            setStacked(top: "Login", bottom: "needed", color: .systemRed)
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

    /// Display two stacked lines in the menu bar (network-speed-indicator style).
    /// Draw directly into an image sized to the menu-bar height for precise vertical control.
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

    /// Plain text rows (used by the error / auth / "Loading..." paths). Not column-aligned.
    private func rebuildMenu(detailLines: [String], showLogin: Bool = false) {
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
        appendInteractiveItems(to: menu, showLogin: showLogin)
        statusItem.menu = menu
    }

    /// Aligned usage table (3 columns) plus a de-emphasized footer (model / updated).
    private func rebuildMenu(usageRows: [UsageRow], footerLines: [String]) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let tableItem = NSMenuItem()
        tableItem.isEnabled = true
        tableItem.view = makeUsageTableView(rows: usageRows)
        menu.addItem(tableItem)

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
        appendInteractiveItems(to: menu, showLogin: false)
        statusItem.menu = menu
    }

    /// Shared tail: separator + (optional Login) + About / Refresh Now / Quit.
    private func appendInteractiveItems(to menu: NSMenu, showLogin: Bool) {
        menu.addItem(.separator())
        if showLogin {
            let loginItem = NSMenuItem(
                title: "Log In via Claude Code", action: #selector(login), keyEquivalent: "l")
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

/// Render two stacked lines into an image sized to height (the menu-bar height).
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
            if let model = model { print("  Model:  \(model.name) (\(model.id))") }
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
        UsageRow(label: "Opus", pct: 100, reset: "resets in 4d 6h"),
        UsageRow(label: "Sonnet", pct: 8, reset: "resets in 16h 16m"),
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
