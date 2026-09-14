import Foundation

struct UsageWindow {
    let utilization: Double  // 0-100 (already in percent units)
    let resetsAt: String?
}

/// A per-model weekly window from the `limits` array (kind == "weekly_scoped").
struct ScopedWeeklyWindow {
    let model: String   // scope.model.display_name, e.g. "Fable"
    let window: UsageWindow
}

struct UsageData {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let weeklyScoped: [ScopedWeeklyWindow]
}

/// One aligned row of the menu usage table: label | percent | reset text.
struct UsageRow {
    let label: String   // "5h", "Weekly", "Weekly Opus", "Weekly Fable", ...
    let pct: Int         // 0-100
    let reset: String    // already-formatted, e.g. "resets in 4h 26m"
}

/// One provider's block in the dropdown: the aligned usage table plus de-emphasized
/// note lines rendered directly under it (e.g. "Current model: …", "Updated: …").
struct ProviderSection {
    let rows: [UsageRow]
    let notes: [String]
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

/// Per-model weekly windows from the `limits` array. The value key there is `percent`
/// (integer 0-100, same unit as `utilization`). Lenient: a missing/non-array `limits`
/// or a malformed entry is skipped, never fatal.
private func parseWeeklyScoped(_ any: Any?) -> [ScopedWeeklyWindow] {
    guard let items = any as? [Any] else { return [] }
    var out: [ScopedWeeklyWindow] = []
    for item in items {
        guard let d = item as? [String: Any],
              d["kind"] as? String == "weekly_scoped",
              let percent = d["percent"] as? NSNumber,
              let scope = d["scope"] as? [String: Any],
              let model = (scope["model"] as? [String: Any])?["display_name"] as? String,
              !model.isEmpty else { continue }
        out.append(ScopedWeeklyWindow(
            model: model,
            window: UsageWindow(utilization: percent.doubleValue, resetsAt: d["resets_at"] as? String)))
    }
    return out
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
        sevenDaySonnet: parseWindow(obj["seven_day_sonnet"]),
        weeklyScoped: parseWeeklyScoped(obj["limits"])
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

/// Process-lifetime cache of the most recently refreshed credentials.
///
/// Writeback can fail (e.g. the keychain ACL denies writes to Claude Code's item). Without this
/// cache the freshly minted token would be dropped on the floor and the next poll would re-refresh
/// using an already-rotated — hence revoked — refresh token: a permanent auth failure that also
/// keeps hammering the endpoint. Holding the rotation in memory keeps the process working.
private final class RefreshedCredentialsCache {
    static let shared = RefreshedCredentialsCache()
    private let lock = NSLock()
    private var cached: Credentials?

    func store(_ c: Credentials) {
        lock.lock()
        cached = c
        lock.unlock()
    }

    /// The cached credentials if they are newer than `other`, otherwise nil.
    func fresherThan(_ other: Credentials) -> Credentials? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = cached else { return nil }
        return (cached.expiresAtMs ?? 0) > (other.expiresAtMs ?? 0) ? cached : nil
    }
}

/// Map a token-refresh failure onto the usage error the UI should show. A throttled refresh is
/// transient (back off and retry); anything else means we genuinely cannot authenticate.
private func usageError(forFailedRefresh error: Error) -> UsageError {
    if case RefreshError.http(let code) = error, code == 429 {
        return .rateLimited(retryAfter: nil)
    }
    return .auth
}

/// Fetch usage, transparently refreshing the OAuth token when it is expired or rejected.
/// This is what lets Pulse recover after a boot without a manual `claude` login: the access
/// token (~8h life) is refreshed from the stored refresh token, exactly as Claude Code does.
func fetchUsageAutoRefreshing() async throws -> UsageData {
    var creds = try readCredentials()
    // A refresh whose writeback failed lives only in memory; prefer it over the stores' older copy.
    if let cached = RefreshedCredentialsCache.shared.fresherThan(creds) {
        creds = cached
    }

    // Proactive: if the stored token is at/near expiry, refresh before spending a request on it.
    let nowMs = Date().timeIntervalSince1970 * 1000
    if let exp = creds.expiresAtMs, nowMs >= exp - 300_000 {  // within 5 minutes of expiry
        if let rt = creds.refreshToken {
            do {
                creds = try await performRefresh(rt, source: creds.source)
            } catch {
                // Already past expiry: the token cannot work, and repeated dead-token requests are
                // what make the endpoint answer 429 instead of 401. Report instead of trying.
                if nowMs >= exp { throw usageError(forFailedRefresh: error) }
                // Still inside the pre-expiry window — the current token is valid, carry on.
            }
        } else if nowMs >= exp {
            throw UsageError.auth  // expired with no refresh token: only a login can fix this
        }
    }

    do {
        return try await fetchUsage(token: creds.accessToken)
    } catch UsageError.auth {
        // Reactive: token rejected (e.g. Claude Code rotated it, or clock skew). Refresh once, retry.
        guard let rt = creds.refreshToken else { throw UsageError.auth }
        let refreshed: Credentials
        do {
            refreshed = try await performRefresh(rt, source: creds.source)
        } catch {
            throw usageError(forFailedRefresh: error)
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
    let refreshed = Credentials(
        accessToken: t.accessToken, refreshToken: t.refreshToken,
        expiresAtMs: t.expiresAtMs, source: source)
    // Keep the rotation even if writeback failed, so the next poll does not reuse a revoked token.
    RefreshedCredentialsCache.shared.store(refreshed)
    return refreshed
}
