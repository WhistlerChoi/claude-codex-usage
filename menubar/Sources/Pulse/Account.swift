import Foundation

/// The logged-in account, from `oauthAccount` in Claude Code's global config. Mirrors src/account.ts.
struct AccountInfo: Equatable {
    let email: String
    var displayName: String? = nil
    var orgName: String? = nil
    var orgType: String? = nil   // e.g. "claude_team", "claude_enterprise", "claude_max"
    var accountUUID: String? = nil
    var orgUUID: String? = nil

    /// Identifies one login (an account inside one organization), for de-duplicating profiles.
    var identity: String? {
        guard let accountUUID, let orgUUID else { return nil }
        return "\(accountUUID)|\(orgUUID)"
    }
}

/// Parse Claude Code's global config JSON. Nil when it holds no logged-in account. Pure.
func parseAccountInfo(_ data: Data) -> AccountInfo? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oa = obj["oauthAccount"] as? [String: Any] else { return nil }
    func str(_ key: String) -> String? {
        (oa[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    guard let email = str("emailAddress") else { return nil }
    return AccountInfo(
        email: email, displayName: str("displayName"), orgName: str("organizationName"),
        orgType: str("organizationType"), accountUUID: str("accountUuid"), orgUUID: str("organizationUuid"))
}

private struct AccountCacheEntry {
    let modified: Date
    let size: Int
    let info: AccountInfo?
}

// The global config is large and rewritten constantly by Claude Code; re-parse only on change.
private let accountCacheLock = NSLock()
private var accountCache: [String: AccountCacheEntry] = [:]

/// Best-effort: any failure (no file, unreadable, logged out) is nil, never an error.
func readAccountInfo(home: ClaudeHome = claudeHome()) -> AccountInfo? {
    let fm = FileManager.default
    for url in home.globalConfigCandidates {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
        let modified = attrs[.modificationDate] as? Date ?? .distantPast
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        accountCacheLock.lock()
        let hit = accountCache[url.path]
        accountCacheLock.unlock()
        if let hit, hit.modified == modified, hit.size == size { return hit.info }
        let info = (try? Data(contentsOf: url)).flatMap(parseAccountInfo)
        accountCacheLock.lock()
        accountCache[url.path] = AccountCacheEntry(modified: modified, size: size, info: info)
        accountCacheLock.unlock()
        return info
    }
    return nil
}

/// Plan name from the credentials' subscriptionType / rateLimitTier. Nil when neither is known.
/// e.g. ("max", "default_claude_max_20x") → "Max 20x", ("team", "default_claude_max_5x") →
/// "Team (Max 5x)". Mirrors src/format.ts. Pure.
func planLabel(subscriptionType: String?, rateLimitTier: String?) -> String? {
    var tier: String?
    if let t = rateLimitTier, let r = t.range(of: #"max_(\d+)x"#, options: .regularExpression) {
        let digits = t[r].dropFirst("max_".count).dropLast()
        tier = "Max \(digits)x"
    }
    guard let sub = subscriptionType, !sub.isEmpty else { return tier }
    if sub == "max" { return tier ?? "Max" }
    let names = ["pro": "Pro", "team": "Team", "enterprise": "Enterprise"]
    let base = names[sub] ?? (sub.prefix(1).uppercased() + sub.dropFirst())
    return tier.map { "\(base) (\($0))" } ?? base
}

/// One-line account summary "email · plan · org". The org name is shown only for team /
/// enterprise orgs — a personal org is just named after the email. Nil when nothing is known.
/// Mirrors src/format.ts. Pure.
func accountLine(_ info: AccountInfo?, plan: String?) -> String? {
    var parts: [String] = []
    if let email = info?.email { parts.append(email) }
    if let plan { parts.append(plan) }
    if let org = info?.orgName, let type = info?.orgType,
       type.contains("team") || type.contains("enterprise") {
        parts.append(org)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}
