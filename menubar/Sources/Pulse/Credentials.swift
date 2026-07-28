import Foundation
import Security

enum CredentialsError: Error, LocalizedError {
    case notFound(String)
    case denied(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let m): return m
        case .denied(let m): return m
        }
    }
}

private let keychainService = "Claude Code-credentials"

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

private func credentialsFileURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
}

/// Read the credentials string from the macOS keychain. Returns nil if absent or denied.
/// This is the one read that can trigger a keychain ACL prompt.
private func readFromKeychain() -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
        return nil
    }
    return result as? Data
}

/// Extract the accessToken plus its expiry (ms epoch, nil when absent) from credentials JSON.
/// Returns nil instead of throwing so that one unreadable store never masks a good one.
func extractCredentials(_ data: Data) -> (token: String, expiresAt: Double?)? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
    guard let tok = oauth["accessToken"] as? String, !tok.isEmpty else {
        return nil
    }
    return (tok, oauth["expiresAt"] as? Double)
}

/// Pick the live token out of every store that has one ("freshest wins").
///
/// Both stores must be consulted because Claude Code moved to the keychain on macOS and can leave a
/// long-dead ~/.claude/.credentials.json behind: preferring the file unconditionally means every
/// poll presents an expired token, which the API eventually throttles (HTTP 429) instead of
/// rejecting cleanly — and no amount of logging in helps, because Claude Code writes the keychain
/// while we keep reading the file. Candidates are ranked by `expiresAt`; ties go to the LAST
/// candidate, so callers pass the keychain last. Pure (no I/O) so it is testable.
func pickFreshestToken(_ candidates: [Data]) -> String? {
    var best: String?
    var bestRank = -Double.greatestFiniteMagnitude
    for data in candidates {
        guard let c = extractCredentials(data) else { continue }
        let rank = c.expiresAt ?? 0
        if best == nil || rank >= bestRank {
            best = c.token
            bestRank = rank
        }
    }
    return best
}

/// Read Claude Code's OAuth accessToken (the secret read — may prompt on macOS).
/// Reads ~/.claude/.credentials.json and the macOS keychain, then uses whichever token is fresher —
/// see pickFreshestToken for why the file cannot simply win.
/// Strictly read-only: Pulse never refreshes or writes Claude Code's credentials.
func readAccessToken() throws -> String {
    var candidates: [Data] = []
    if let data = try? Data(contentsOf: credentialsFileURL()) {
        candidates.append(data)
    }
    // Keychain last: it wins ties, matching where Claude Code stores credentials on macOS.
    if let data = readFromKeychain() {
        candidates.append(data)
    }
    if let tok = pickFreshestToken(candidates) {
        return tok
    }
    throw CredentialsError.notFound("Could not read credentials. Log in with Claude Code.")
}

// MARK: - Prompt-free change fingerprint

private func fileFingerprint() -> String? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: credentialsFileURL().path),
          let mtime = attrs[.modificationDate] as? Date else {
        return nil
    }
    return "file:\(mtime.timeIntervalSince1970)"
}

private func keychainFingerprint() -> String? {
    // kSecReturnAttributes without kSecReturnData: metadata only, never triggers an ACL prompt.
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnAttributes as String: true,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let attrs = result as? [String: Any],
          let mdat = attrs[kSecAttrModificationDate as String] as? Date else {
        return nil
    }
    return "keychain:\(mdat.timeIntervalSince1970)"
}

/// Join the per-store fingerprints into one. Every present store contributes, so a rotation in
/// EITHER store registers as a change; nil only when no credentials exist anywhere.
///
/// Combining is what makes "freshest wins" hold over time. A file-first fingerprint is stuck on a
/// dead file's mtime: it never changes, so the cache keeps serving the expired token and the
/// keychain rotation is never noticed. Pure (no I/O) so it is testable.
func combineFingerprints(_ parts: [String?]) -> String? {
    let present = parts.compactMap { $0 }
    return present.isEmpty ? nil : present.joined(separator: "|")
}

/// Prompt-free change fingerprint of the credential store: the file's mtime and the keychain item's
/// modification date, combined. nil means no credentials are present anywhere. The source prefixes
/// make a file<->keychain transition register as a change.
func readFingerprint() -> String? {
    combineFingerprints([fileFingerprint(), keychainFingerprint()])
}
