import Foundation

struct UsageWindow {
    let utilization: Double  // 0-100 (already in percent units)
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
    case rateLimited(retryAfter: TimeInterval?)
    case malformed
    var errorDescription: String? {
        switch self {
        case .auth: return "Authentication expired. Log in again."
        case .http(let c): return "usage API error: HTTP \(c)"
        case .rateLimited: return "usage API error: HTTP 429"
        case .malformed: return "Malformed usage response."
        }
    }
}

/// Extract Retry-After (seconds) from the error. Returns nil if not rateLimited.
func retryAfter(from error: Error) -> TimeInterval? {
    if case UsageError.rateLimited(let ra) = error { return ra }
    return nil
}

private func parseWindow(_ any: Any?) -> UsageWindow? {
    guard let d = any as? [String: Any],
          let num = d["utilization"] as? NSNumber else {
        return nil
    }
    return UsageWindow(utilization: num.doubleValue, resetsAt: d["resets_at"] as? String)
}

/// Raw JSON -> UsageData
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
    if http.statusCode == 429 {
        let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
        throw UsageError.rateLimited(retryAfter: ra.map { TimeInterval($0) })
    }
    guard (200..<300).contains(http.statusCode) else {
        throw UsageError.http(http.statusCode)
    }
    let json = try JSONSerialization.jsonObject(with: data)
    return try parseUsage(json)
}
