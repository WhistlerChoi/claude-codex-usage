import Foundation

/// utilization(0~100)을 정수 퍼센트로.
func pct(_ utilization: Double) -> Int {
    Int(utilization.rounded())
}

/// 메뉴바 압축 표시: "4% · 4%" (5시간 · 주간). 아이콘은 별도로 붙인다.
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

/// resetsAt까지 남은 시간을 한국어로.
func formatResetIn(_ resetsAt: String?, now: Date = Date()) -> String {
    guard let resetsAt = resetsAt, let target = parseISODate(resetsAt) else {
        return "리셋 시각 미정"
    }
    let diff = target.timeIntervalSince(now)
    if diff <= 0 { return "곧 리셋" }

    let totalMin = Int(diff / 60)
    let days = totalMin / (60 * 24)
    let hours = (totalMin % (60 * 24)) / 60
    let mins = totalMin % 60

    var parts: [String] = []
    if days > 0 { parts.append("\(days)일") }
    if hours > 0 { parts.append("\(hours)시간") }
    if days == 0 && mins > 0 { parts.append("\(mins)분") }
    if parts.isEmpty { parts.append("1분 미만") }
    return parts.joined(separator: " ") + " 후 리셋"
}

/// 두 윈도우 중 최고 사용률(0~1 분수).
func peakUtilization(_ usage: UsageData) -> Double {
    max(usage.fiveHour.utilization, usage.sevenDay.utilization) / 100.0
}

func clockString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}

private let maxRetry: TimeInterval = 3600   // 재시도 지연 상한(1시간)
private let retryFloor: TimeInterval = 60   // 429 백오프 바닥(60s)

/// 일시적 실패 후 다음 폴링까지 지연(초).
/// - retryAfter가 있으면 그 값을 "존중"한다(interval로 깎지 않고 maxRetry로만 cap).
/// - 없으면 60s에서 시작하는 지수 백오프(×2)를 interval(최소 60s)로 cap.
/// 마지막에 base의 0~20% 지터를 더해 동시 폴링 충돌을 분산한다.
/// - Parameter rand: 0~1 난수원(테스트 주입용, 기본 Double.random).
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

/// 마지막 성공으로부터 age가 interval*3 이상이면 stale.
func shouldShowStale(_ age: TimeInterval, _ interval: TimeInterval) -> Bool {
    return age >= interval * 3
}
