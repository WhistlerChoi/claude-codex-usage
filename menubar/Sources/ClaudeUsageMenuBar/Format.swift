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
