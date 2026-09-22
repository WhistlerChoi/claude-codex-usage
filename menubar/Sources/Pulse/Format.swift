import Foundation

/// Convert utilization (0-100) to an integer percent.
func pct(_ utilization: Double) -> Int {
    Int(utilization.rounded())
}

/// Compact menu-bar display: "4% · 4%" (5h · weekly). The icon is attached separately.
func menuBarText(_ usage: UsageData) -> String {
    "\(pct(usage.fiveHour.utilization))% · \(pct(usage.sevenDay.utilization))%"
}

func parseISODate(_ s: String) -> Date? {
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFrac.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
}

/// Fraction of a fixed window still remaining until reset, clamped to 0...1.
/// Returns nil when the provider did not supply a usable reset time.
func resetProgress(
    until resetsAt: Date?, window: TimeInterval = 5 * 60 * 60, now: Date = Date()
) -> Double? {
    guard let target = resetsAt, window > 0 else { return nil }
    return min(1, max(0, target.timeIntervalSince(now) / window))
}

/// String-date overload used by the Claude usage response.
func resetProgress(
    until resetsAt: String?, window: TimeInterval = 5 * 60 * 60, now: Date = Date()
) -> Double? {
    guard let resetsAt, let target = parseISODate(resetsAt) else { return nil }
    return resetProgress(until: target, window: window, now: now)
}

/// Compact "5d 4h" / "3h 5m" / "<1m" for a positive time interval.
private func resetDurationText(_ diff: TimeInterval) -> String {
    let totalMin = Int(diff / 60)
    let days = totalMin / (60 * 24)
    let hours = (totalMin % (60 * 24)) / 60
    let mins = totalMin % 60

    var parts: [String] = []
    if days > 0 { parts.append("\(days)d") }
    if hours > 0 { parts.append("\(hours)h") }
    if days == 0 && mins > 0 { parts.append("\(mins)m") }
    if parts.isEmpty { parts.append("<1m") }
    return parts.joined(separator: " ")
}

/// Bare time remaining until a reset ("3h 5m"), for the dropdown table whose column caption
/// already says "resets in". "soon" once the reset time has passed, "—" when unknown.
func formatResetDuration(_ resetsAt: Date?, now: Date = Date()) -> String {
    guard let target = resetsAt else { return "—" }
    let diff = target.timeIntervalSince(now)
    if diff <= 0 { return "soon" }
    return resetDurationText(diff)
}

/// ISO-string overload of `formatResetDuration` (the Claude API's `resets_at`).
func formatResetDuration(_ resetsAt: String?, now: Date = Date()) -> String {
    guard let resetsAt, let target = parseISODate(resetsAt) else { return "—" }
    return formatResetDuration(target, now: now)
}

/// Time remaining until resetsAt, in English ("resets in 4h 26m"). Used wherever the phrase
/// stands alone: tooltip lines, `--once` output, and the other ports' identical strings.
func formatResetIn(_ resetsAt: String?, now: Date = Date()) -> String {
    guard let resetsAt = resetsAt, let target = parseISODate(resetsAt) else {
        return "reset time unknown"
    }
    return formatResetIn(target, now: now)
}

/// Time remaining until a Date-based reset (used by the Codex provider).
func formatResetIn(_ resetsAt: Date?, now: Date = Date()) -> String {
    guard let target = resetsAt else { return "reset time unknown" }
    let diff = target.timeIntervalSince(now)
    if diff <= 0 { return "resets soon" }
    return "resets in " + resetDurationText(diff)
}

/// Peak utilization across the two windows (0-1 fraction).
func peakUtilization(_ usage: UsageData) -> Double {
    max(usage.fiveHour.utilization, usage.sevenDay.utilization) / 100.0
}

func clockString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}

private let maxRetry: TimeInterval = 3600   // upper bound for retry delay (1 hour)
private let retryFloor: TimeInterval = 60   // floor for 429 backoff (60s)

/// Delay (seconds) until the next poll after a transient failure.
/// - If retryAfter is present, honor it (not clamped by interval, only capped by maxRetry).
/// - Otherwise use exponential backoff (×2) starting at 60s, capped by interval (min 60s).
/// Finally add 0-20% jitter of base to spread out concurrent polling collisions.
/// - Parameter rand: 0-1 random source (for test injection, defaults to Double.random).
func nextRetryDelay(
    _ consecutiveFailures: Int, _ interval: TimeInterval, _ retryAfter: TimeInterval?,
    rand: () -> Double = { Double.random(in: 0..<1) }
) -> TimeInterval {
    let base: TimeInterval
    if let ra = retryAfter, ra > 0 {
        base = min(ra, maxRetry)
    } else {
        let ceiling = max(interval, retryFloor)
        let exp = retryFloor * pow(2.0, Double(max(0, consecutiveFailures - 1)))
        base = min(exp, ceiling)
    }
    return base + base * 0.2 * rand()
}

/// Menu line telling the user when the next automatic retry happens, e.g. "Retrying in 45s",
/// "Retrying in 2m", "Retrying in 1h 5m". Shown for transient failures (network, HTTP 429) so a
/// throttle is never mistaken for a login problem.
func formatRetryIn(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "Retrying in \(total)s" }
    if total < 3600 { return "Retrying in \(total / 60)m" }
    let hours = total / 3600
    let mins = (total % 3600) / 60
    return mins > 0 ? "Retrying in \(hours)h \(mins)m" : "Retrying in \(hours)h"
}

/// Stale if age since the last success is at least interval*3.
func shouldShowStale(_ age: TimeInterval, _ interval: TimeInterval) -> Bool {
    return age >= interval * 3
}

/// The later of two optional dates (nil only when both are nil). The dropdown shows one
/// "Updated:" line for both providers, so it takes whichever poll succeeded most recently.
func latestDate(_ a: Date?, _ b: Date?) -> Date? {
    switch (a, b) {
    case let (a?, b?): return max(a, b)
    case let (a?, nil): return a
    case let (nil, b?): return b
    default: return nil
    }
}
