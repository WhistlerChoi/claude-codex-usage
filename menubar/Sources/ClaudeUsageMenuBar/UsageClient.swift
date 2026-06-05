import Foundation

struct UsageWindow {
    let utilization: Double  // 0~100 (이미 퍼센트 단위)
    let resetsAt: String?
}

struct UsageData {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
}

enum UsageError: Error, LocalizedError {
    case auth
    case http(Int)
    case malformed
    var errorDescription: String? {
        switch self {
        case .auth: return "인증이 만료되었습니다. Claude Code에서 재로그인하세요."
        case .http(let c): return "usage API 오류: HTTP \(c)"
        case .malformed: return "usage 응답 형식 오류."
        }
    }
}

private func parseWindow(_ any: Any?) -> UsageWindow? {
    guard let d = any as? [String: Any],
          let num = d["utilization"] as? NSNumber else {
        return nil
    }
    return UsageWindow(utilization: num.doubleValue, resetsAt: d["resets_at"] as? String)
}

/// 원시 JSON -> UsageData
func parseUsage(_ json: Any) throws -> UsageData {
    guard let obj = json as? [String: Any],
          let five = parseWindow(obj["five_hour"]),
          let week = parseWindow(obj["seven_day"]) else {
        throw UsageError.malformed
    }
    return UsageData(
        fiveHour: five,
        sevenDay: week,
        sevenDayOpus: parseWindow(obj["seven_day_opus"]),
        sevenDaySonnet: parseWindow(obj["seven_day_sonnet"])
    )
}

func fetchUsage() async throws -> UsageData {
    let token = try readAccessToken()
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.timeoutInterval = 20

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
        throw UsageError.malformed
    }
    if http.statusCode == 401 || http.statusCode == 403 {
        throw UsageError.auth
    }
    guard (200..<300).contains(http.statusCode) else {
        throw UsageError.http(http.statusCode)
    }
    let json = try JSONSerialization.jsonObject(with: data)
    return try parseUsage(json)
}
