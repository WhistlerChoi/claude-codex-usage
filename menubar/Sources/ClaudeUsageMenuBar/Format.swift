import Foundation

/// Convert utilization (0-100) to an integer percent.
func pct(_ utilization: Double) -> Int {
    Int(utilization.rounded())
}

/// Compact menu-bar display: "4% · 4%" (5h · weekly). The icon is attached separately.
func menuBarText(_ usage: UsageData) -> String {
    "\(pct(usage.fiveHour.utilization))% · \(pct(usage.sevenDay.utilization))%"
}

private func parseISODate(_ s: String) -> Date? {
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFrac.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
}

/// Time remaining until resetsAt, in English.
func formatResetIn(_ resetsAt: String?, now: Date = Date()) -> String {
    guard let resetsAt = resetsAt, let target = parseISODate(resetsAt) else {
        return "reset time unknown"
    }
    let diff = target.timeIntervalSince(now)
    if diff <= 0 { return "resets soon" }

    let totalMin = Int(diff / 60)
    let days = totalMin / (60 * 24)
    let hours = (totalMin % (60 * 24)) / 60
    let mins = totalMin % 60

    var parts: [String] = []
    if days > 0 { parts.append("\(days)d") }
    if hours > 0 { parts.append("\(hours)h") }
    if days == 0 && mins > 0 { parts.append("\(mins)m") }
    if parts.isEmpty { parts.append("<1m") }
    return "resets in " + parts.joined(separator: " ")
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

/// Stale if age since the last success is at least interval*3.
func shouldShowStale(_ age: TimeInterval, _ interval: TimeInterval) -> Bool {
    return age >= interval * 3
}
