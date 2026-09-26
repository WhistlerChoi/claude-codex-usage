import Foundation

/// Daily token ledger shared by every Pulse front-end (mirrors `src/tokenHistory.ts`), so 7-day /
/// 30-day totals and their trend survive Claude Code's transcript cleanup (`cleanupPeriodDays`,
/// default 30) without any server.
///
/// Files under `$PULSE_HOME` (default `~/.pulse`); all apps read and write the same ones:
///   token-history.json          — the ledger: {version, since: {provider: date}, days: {date: {provider: totals}}}
///   cache/<provider>-files.json — per-transcript parse cache: {version, files: {path: {mtime, size, days}}}
///
/// The one rule that keeps this correct with deletions and several writers: a day's value in the
/// ledger is the per-field MAX of what has ever been observed for it. A day's total only grows
/// while its transcripts are appended to and only shrinks when a transcript is deleted, so max
/// preserves deleted files' contribution, never double counts, and is the merge rule for
/// concurrent apps too (read → max-merge → atomic write).

/// Only transcripts modified within this many days are stat'ed and parsed; older days live in the ledger.
let scanWindowDays = 61
/// Ledger days older than this are pruned.
let ledgerRetentionDays = 400

struct TokenLedger: Codable {
    var version: Int = 1
    var since: [String: String] = [:]
    var days: [String: [String: TokenTotals]] = [:]

    /// Fold one provider's freshly computed per-day totals in with the max rule. `today` marks
    /// when observation started if the provider is new. Returns whether anything changed.
    mutating func merge(provider: String, daily: DailyTotals, today: String) -> Bool {
        var changed = false
        for (date, totals) in daily {
            var day = days[date] ?? [:]
            let merged = TokenTotals.max(day[provider] ?? TokenTotals(), totals)
            if day[provider] != merged {
                day[provider] = merged
                days[date] = day
                changed = true
            }
        }
        if since[provider] == nil || today < since[provider]! {
            since[provider] = today
            changed = true
        }
        return changed
    }

    /// Union of two ledgers: max per field, earliest since.
    static func merged(_ a: TokenLedger, _ b: TokenLedger) -> TokenLedger {
        var out = TokenLedger()
        for src in [a, b] {
            for (date, providers) in src.days {
                var day = out.days[date] ?? [:]
                for (provider, totals) in providers {
                    day[provider] = TokenTotals.max(day[provider] ?? TokenTotals(), totals)
                }
                out.days[date] = day
            }
            for (provider, s) in src.since where out.since[provider] == nil || s < out.since[provider]! {
                out.since[provider] = s
            }
        }
        return out
    }

    /// Inclusive [from, to] sum for one provider; days without an entry count as zero.
    func sum(provider: String, from: String, to: String) -> TokenTotals {
        var total = TokenTotals()
        for (date, providers) in days where date >= from && date <= to {
            if let t = providers[provider] { total = total + t }
        }
        return total
    }

    /// First day the ledger can vouch for: the earliest recorded day or the first observation.
    private func coverageStart(provider: String) -> String? {
        var start = since[provider]
        for (date, providers) in days where providers[provider] != nil {
            if start == nil || date < start! { start = date }
        }
        return start
    }

    func stats(provider: String, today: String) -> TokenStats {
        let start = coverageStart(provider: provider)
        func window(_ length: Int, endOffset: Int) -> TokenTotals {
            sum(provider: provider, from: dateShift(today, endOffset - length + 1), to: dateShift(today, endOffset))
        }
        func prior(_ length: Int) -> TokenTotals? {
            guard let start, start <= dateShift(today, -(2 * length - 1)) else { return nil }
            return window(length, endOffset: -length)
        }
        return TokenStats(today: sum(provider: provider, from: today, to: today),
                          last7: window(7, endOffset: 0), prev7: prior(7),
                          last30: window(30, endOffset: 0), prev30: prior(30))
    }

    mutating func prune(today: String) {
        let cutoff = dateShift(today, -ledgerRetentionDays)
        for date in days.keys where date < cutoff { days.removeValue(forKey: date) }
    }
}

struct TokenStats: Equatable {
    let today: TokenTotals
    let last7: TokenTotals
    let prev7: TokenTotals?   // nil until the ledger covers the prior window
    let last30: TokenTotals
    let prev30: TokenTotals?
}

struct TokenRow: Equatable {
    let label: String
    let value: String
}

func localDateKey(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

func dateShift(_ key: String, _ days: Int) -> String {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
          let base = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
          let shifted = Calendar.current.date(byAdding: .day, value: days, to: base) else {
        return key
    }
    return localDateKey(shifted)
}

/// "▲ 12%" / "▼ 5%" / "± 0%" on total tokens; "—" when there is nothing to compare against.
func trendText(_ cur: TokenTotals, _ prev: TokenTotals?) -> String {
    guard let prev, prev.total > 0 else { return "—" }
    let pct = Int((Double(cur.total - prev.total) / Double(prev.total) * 100).rounded())
    if pct > 0 { return "▲ \(pct)%" }
    if pct < 0 { return "▼ \(-pct)%" }
    return "± 0%"
}

/// The three rows every port renders (label styling / prefixing is per surface).
func tokenRows(_ s: TokenStats) -> [TokenRow] {
    [
        TokenRow(label: "Tokens today", value: tokenTotalsText(s.today)),
        TokenRow(label: "Tokens 7d", value: "\(tokenTotalsText(s.last7)) · \(trendText(s.last7, s.prev7)) vs prior 7d"),
        TokenRow(label: "Tokens 30d", value: "\(tokenTotalsText(s.last30)) · \(trendText(s.last30, s.prev30)) vs prior 30d"),
    ]
}

/// Split the rows into the always-visible "Tokens today" title and the 7d / 30d titles that the
/// dropdown puts in that row's hover submenu.
func tokenMenuTitles(_ s: TokenStats) -> (today: String, history: [String]) {
    let titles = tokenRows(s).map { "\($0.label): \($0.value)" }
    return (titles[0], Array(titles.dropFirst()))
}

func pulseHome() -> URL {
    if let v = ProcessInfo.processInfo.environment["PULSE_HOME"], !v.isEmpty {
        return URL(fileURLWithPath: v)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pulse")
}

// MARK: - Persistence

private struct FileCacheEntry: Codable {
    let mtime: Int64   // unix milliseconds
    let size: Int
    let days: DailyTotals
}

private struct FileCache: Codable {
    var version: Int = 1
    var files: [String: FileCacheEntry] = [:]
}

private func loadJSON<T: Decodable>(_ type: T.Type, at url: URL) -> (value: T?, present: Bool) {
    guard let data = try? Data(contentsOf: url) else { return (nil, false) }
    return (try? JSONDecoder().decode(type, from: data), true)
}

private func writeAtomic<T: Encodable>(_ value: T, to url: URL) {
    if let data = try? JSONEncoder().encode(value) {
        try? data.write(to: url, options: .atomic)
    }
}

/// Absent → fresh; corrupt → moved aside (never overwritten) and fresh.
private func loadLedger(at url: URL) -> TokenLedger {
    let loaded = loadJSON(TokenLedger.self, at: url)
    if let l = loaded.value, l.version == 1 { return l }
    if loaded.present {
        let quarantined = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970 * 1000))")
        try? FileManager.default.moveItem(at: url, to: quarantined)
    }
    return TokenLedger()
}

private let tokenHistoryLock = NSLock()

/// One poll for a provider: parse changed transcripts under `root` (per-file cache), fold the
/// per-day totals into the shared ledger, persist both atomically, and return the stats to
/// display. `nil` when `root` does not exist, so callers omit the rows.
func updateTokenHistory(
    provider: String, root: URL, extract: (String) -> DailyTotals,
    home: URL = pulseHome(), now: Date = Date()
) -> TokenStats? {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }
    tokenHistoryLock.lock()
    defer { tokenHistoryLock.unlock() }

    let today = localDateKey(now)
    let cacheDir = home.appendingPathComponent("cache")
    guard (try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)) != nil else { return nil }
    let cacheURL = cacheDir.appendingPathComponent("\(provider)-files.json")
    var cache = loadJSON(FileCache.self, at: cacheURL).value ?? FileCache()
    if cache.version != 1 { cache = FileCache() }
    let cutoff = now.addingTimeInterval(-Double(scanWindowDays) * 86_400)

    var live = Set<String>()
    var cacheChanged = false
    if let enumerator = fm.enumerator(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]
    ) {
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let modified = values?.contentModificationDate, modified >= cutoff else { continue }
            let key = url.path
            live.insert(key)
            let mtime = Int64((modified.timeIntervalSince1970 * 1000).rounded())
            let size = values?.fileSize ?? -1
            if let hit = cache.files[key], hit.mtime == mtime, hit.size == size { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            cache.files[key] = FileCacheEntry(mtime: mtime, size: size, days: extract(content))
            cacheChanged = true
        }
    }
    for key in cache.files.keys where !live.contains(key) {
        cache.files.removeValue(forKey: key)
        cacheChanged = true
    }
    if cacheChanged { writeAtomic(cache, to: cacheURL) }

    var daily = DailyTotals()
    for entry in cache.files.values {
        for (date, totals) in entry.days { daily[date] = (daily[date] ?? TokenTotals()) + totals }
    }

    let ledgerURL = home.appendingPathComponent("token-history.json")
    var ledger = loadLedger(at: ledgerURL)
    if ledger.merge(provider: provider, daily: daily, today: today) {
        // Another app may have written meanwhile: fold its view in before replacing the file.
        if let onDisk = loadJSON(TokenLedger.self, at: ledgerURL).value, onDisk.version == 1 {
            ledger = TokenLedger.merged(onDisk, ledger)
        }
        ledger.prune(today: today)
        writeAtomic(ledger, to: ledgerURL)
    }
    return ledger.stats(provider: provider, today: today)
}

/// Per-provider entry points used by the poll loop.
func readTokenStats() -> TokenStats? {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    return updateTokenHistory(provider: "claude", root: root, extract: extractDailyTotals)
}

func readCodexTokenStats() -> TokenStats? {
    updateTokenHistory(provider: "codex", root: codexHome().appendingPathComponent("sessions"), extract: extractCodexDailyTotals)
}
