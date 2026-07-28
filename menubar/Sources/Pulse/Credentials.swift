import Foundation
import Security

enum CredentialsError: Error, LocalizedError {
    case notFound(String)
    case writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let m): return m
        case .writeFailed(let m): return m
        }
    }
}

/// Where the credentials were read from, so a refreshed token is written back to the same place.
enum CredentialSource {
    case file(URL)
    case keychain
}

/// The OAuth credentials Claude Code stores, plus where they came from.
struct Credentials {
    var accessToken: String
    var refreshToken: String?
    var expiresAtMs: Double?
    let source: CredentialSource
}

/// Extract accessToken from credentials JSON Data. { claudeAiOauth: { accessToken } } or { accessToken }.
func extractAccessToken(_ data: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    if let oauth = obj["claudeAiOauth"] as? [String: Any],
       let tok = oauth["accessToken"] as? String, !tok.isEmpty {
        return tok
    }
    if let tok = obj["accessToken"] as? String, !tok.isEmpty {
        return tok
    }
    return nil
}

/// The dictionary holding the OAuth fields, unwrapping the optional `claudeAiOauth` wrapper.
private func oauthDict(_ obj: [String: Any]) -> [String: Any]? {
    if let oauth = obj["claudeAiOauth"] as? [String: Any] { return oauth }
    if obj["accessToken"] != nil { return obj }
    return nil
}

/// Parse the full credential set (token + refresh token + expiry) from a JSON blob.
func parseCredentials(_ data: Data, source: CredentialSource) -> Credentials? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = oauthDict(obj),
          let tok = oauth["accessToken"] as? String, !tok.isEmpty else {
        return nil
    }
    let refresh = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue
    return Credentials(accessToken: tok, refreshToken: refresh, expiresAtMs: expires, source: source)
}

/// Read the credentials string from the macOS keychain. Returns nil if absent or denied.
private func readFromKeychain() -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
        return nil
    }
    return result as? Data
}

private func credentialsFileURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
}

/// Pick the live credentials out of every store that has some ("freshest wins").
///
/// Both stores are consulted because Claude Code moved to the keychain on macOS and can leave a
/// long-dead ~/.claude/.credentials.json behind: preferring the file unconditionally means every
/// poll presents an expired token, which the API eventually throttles (HTTP 429) instead of
/// rejecting cleanly. Candidates are ranked by `expiresAt`, and ties go to the LAST candidate —
/// callers pass the keychain last, so a refreshed token is written back to where Claude Code
/// reads it. (Writing a rotated refresh token to the file while Claude Code reads the keychain
/// would revoke Claude Code's own credentials.)
/// Pure (no I/O) so it is testable.
func pickFreshest(_ candidates: [(Data, CredentialSource)]) -> Credentials? {
    var best: Credentials?
    var bestRank = -Double.greatestFiniteMagnitude
    for (data, source) in candidates {
        guard let c = parseCredentials(data, source: source) else { continue }
        let rank = c.expiresAtMs ?? 0
        if best == nil || rank >= bestRank {
            best = c
            bestRank = rank
        }
    }
    return best
}

/// Read the Claude Code OAuth credentials (token, refresh token, expiry) and record their source.
/// Reads ~/.claude/.credentials.json and (on macOS) the keychain, then uses whichever is fresher.
func readCredentials() throws -> Credentials {
    let credPath = credentialsFileURL()
    var candidates: [(Data, CredentialSource)] = []
    if let data = try? Data(contentsOf: credPath) {
        candidates.append((data, .file(credPath)))
    }
    // Keychain last: it wins ties, so writeback lands where Claude Code reads.
    if let data = readFromKeychain() {
        candidates.append((data, .keychain))
    }
    if let c = pickFreshest(candidates) {
        return c
    }
    throw CredentialsError.notFound("Could not read credentials. Log in with Claude Code.")
}

/// Read just the OAuth accessToken (back-compat helper).
func readAccessToken() throws -> String {
    try readCredentials().accessToken
}

// MARK: - Writeback (persist a refreshed token to the same store it came from)

/// Merge new token fields into an existing credentials JSON blob, preserving every other field
/// and the `claudeAiOauth` wrapper shape. Pure function (testable without I/O).
func mergedCredentialsData(
    existing: Data?, accessToken: String, refreshToken: String, expiresAtMs: Double
) throws -> Data {
    var root: [String: Any] = [:]
    if let existing = existing,
       let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
        root = obj
    }
    let hasWrapper = root["claudeAiOauth"] is [String: Any]
    let topLevelShape = !hasWrapper && root["accessToken"] != nil
    var oauth: [String: Any] = (root["claudeAiOauth"] as? [String: Any])
        ?? (topLevelShape ? root : [:])

    oauth["accessToken"] = accessToken
    oauth["refreshToken"] = refreshToken
    // Store as an integer (ms epoch) to match Claude Code's on-disk format exactly.
    oauth["expiresAt"] = Int(expiresAtMs.rounded())

    if topLevelShape {
        root = oauth
    } else {
        // Wrapper shape is Claude Code's canonical format; use it for existing-wrapper and empty cases.
        root["claudeAiOauth"] = oauth
    }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

/// Persist refreshed tokens back to wherever they were read from, preserving all other fields.
func writeCredentials(
    accessToken: String, refreshToken: String, expiresAtMs: Double, to source: CredentialSource
) throws {
    switch source {
    case .file(let url):
        try writeCredentialsToFile(
            accessToken: accessToken, refreshToken: refreshToken, expiresAtMs: expiresAtMs, url: url)
    case .keychain:
        try writeCredentialsToKeychain(
            accessToken: accessToken, refreshToken: refreshToken, expiresAtMs: expiresAtMs)
    }
}

private func writeCredentialsToFile(
    accessToken: String, refreshToken: String, expiresAtMs: Double, url: URL
) throws {
    let existing = try? Data(contentsOf: url)
    let data = try mergedCredentialsData(
        existing: existing, accessToken: accessToken, refreshToken: refreshToken, expiresAtMs: expiresAtMs)

    // Atomic replace: write to a sibling temp file, lock it down to 0600, then swap into place.
    let dir = url.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent(".credentials.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
    try data.write(to: tmp)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
    if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    } else {
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}

private func writeCredentialsToKeychain(
    accessToken: String, refreshToken: String, expiresAtMs: Double
) throws {
    let existing = readFromKeychain()
    let data = try mergedCredentialsData(
        existing: existing, accessToken: accessToken, refreshToken: refreshToken, expiresAtMs: expiresAtMs)

    let update: [String: Any] = [kSecValueData as String: data]

    // Prefer the exact item (service + account = current user, the shape Claude Code writes).
    let exactQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecAttrAccount as String: NSUserName(),
    ]
    var status = SecItemUpdate(exactQuery as CFDictionary, update as CFDictionary)
    if status == errSecSuccess { return }

    if status == errSecItemNotFound {
        // Fall back to matching by service only (account may differ from NSUserName()).
        let serviceQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
        ]
        status = SecItemUpdate(serviceQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }

        // Nothing to update — create the item.
        var addQuery = exactQuery
        addQuery[kSecValueData as String] = data
        status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return }
    }
    throw CredentialsError.writeFailed("Keychain write failed (OSStatus \(status)).")
}
