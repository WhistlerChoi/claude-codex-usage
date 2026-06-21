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

/// One aligned row of the menu usage table: label | percent | reset text.
struct UsageRow {
    let label: String   // "5h", "Weekly", "Weekly Opus", "Weekly Sonnet"
    let pct: Int         // 0-100
    let reset: String    // already-formatted, e.g. "resets in 4h 26m"
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

func fetchUsage(token: String) async throws -> UsageData {
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

/// Fetch usage, transparently refreshing the OAuth token when it is expired or rejected.
/// This is what lets Pulse recover after a boot without a manual `claude` login: the access
/// token (~8h life) is refreshed from the stored refresh token, exactly as Claude Code does.
func fetchUsageAutoRefreshing() async throws -> UsageData {
    var creds = try readCredentials()

    // Proactive: if the stored token is at/near expiry and we have a refresh token, refresh first.
    if let exp = creds.expiresAtMs, let rt = creds.refreshToken {
        let nowMs = Date().timeIntervalSince1970 * 1000
        if nowMs >= exp - 300_000 {  // within 5 minutes of expiry
            if let refreshed = try? await performRefresh(rt, source: creds.source) {
                creds = refreshed
            }
        }
    }

    do {
        return try await fetchUsage(token: creds.accessToken)
    } catch UsageError.auth {
        // Reactive: token rejected (e.g. Claude Code rotated it, or clock skew). Refresh once, retry.
        guard let rt = creds.refreshToken,
              let refreshed = try? await performRefresh(rt, source: creds.source) else {
            throw UsageError.auth
        }
        return try await fetchUsage(token: refreshed.accessToken)
    }
}

/// Refresh the access token and persist it back to its source. Writeback failure is logged but
/// non-fatal so the current poll still succeeds with the freshly minted token.
private func performRefresh(_ refreshToken: String, source: CredentialSource) async throws -> Credentials {
    let t = try await refreshAccessToken(refreshToken)
    do {
        try writeCredentials(
            accessToken: t.accessToken, refreshToken: t.refreshToken,
            expiresAtMs: t.expiresAtMs, to: source)
    } catch {
        FileHandle.standardError.write(
            Data("Pulse: token refreshed but writeback failed: \(error.localizedDescription)\n".utf8))
    }
    return Credentials(
        accessToken: t.accessToken, refreshToken: t.refreshToken,
        expiresAtMs: t.expiresAtMs, source: source)
}
