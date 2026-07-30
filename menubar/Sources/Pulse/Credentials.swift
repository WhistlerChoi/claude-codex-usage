import Foundation

// NOTE: This file must never import Security. Claude Code manages the keychain item via
// /usr/bin/security, so the item carries the `apple-tool:` partition list. Touching it with
// SecItemAdd/SecItemUpdate re-stamps it with THIS app's partition instead, after which Claude
// Code's own `security find-generic-password` hits a keychain password prompt on every start
// (an endless, un-dismissable popup loop for the user). See CLAUDE.md.

/// The keychain service name Claude Code stores its OAuth credentials under.
let keychainService = "Claude Code-credentials"
/// Absolute path so a PATH-planted binary can never intercept the token.
let securityToolPath = "/usr/bin/security"
/// `security -i` line budget; longer command lines fall back to argv (matches Claude Code).
let securityStdinLimit = 4032

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

// MARK: - security CLI plumbing (pure helpers are selftest-covered in main.swift)

/// Lowercase hex encoding, the payload format for `add-generic-password -X`.
func hexEncode(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// Quote one token for a `security -i` command line: backslash-escape `\` and `"`, wrap in quotes.
func securityQuote(_ token: String) -> String {
    var out = "\""
    for ch in token {
        if ch == "\\" || ch == "\"" { out.append("\\") }
        out.append(ch)
    }
    out.append("\"")
    return out
}

/// The full `security -i` command line (trailing newline included). `-X` takes the secret as hex,
/// so the only token that ever needs quoting is the account/service name.
func addGenericPasswordCommandLine(
    account: String, service: String, hexPayload: String, update: Bool = true
) -> String {
    let flags = update ? "-U " : ""
    return "add-generic-password \(flags)-a \(securityQuote(account)) "
        + "-s \(securityQuote(service)) -X \(securityQuote(hexPayload))\n"
}

/// Extract the `"acct"<blob>="..."` value from promptless `find-generic-password` output.
/// Returns nil when the attribute is `<NULL>` or missing.
func parseKeychainAccount(fromFindOutput output: String) -> String? {
    for rawLine in output.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("\"acct\"<blob>=") else { continue }
        let value = String(line.dropFirst("\"acct\"<blob>=".count))
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return String(value.dropFirst().dropLast())
    }
    return nil
}

private struct SecurityCLIResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// Run /usr/bin/security with a hard timeout, so an invocation wedged on a hidden keychain
/// prompt cannot stall the poll loop forever. `stdinLine` (used with `-i`) is written to stdin
/// and stdin is closed. Returns nil on launch failure or timeout (the process is terminated,
/// then killed).
private func runSecurityCLI(
    _ args: [String], stdinLine: String? = nil, timeout: TimeInterval
) -> SecurityCLIResult? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: securityToolPath)
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    let inPipe: Pipe?
    if stdinLine != nil {
        let p = Pipe()
        proc.standardInput = p
        inPipe = p
    } else {
        proc.standardInput = FileHandle.nullDevice
        inPipe = nil
    }

    let done = DispatchSemaphore(value: 0)
    proc.terminationHandler = { _ in done.signal() }
    do { try proc.run() } catch { return nil }
    if let line = stdinLine, let inPipe = inPipe {
        // The line is bounded by securityStdinLimit, far below the pipe buffer — cannot block.
        inPipe.fileHandleForWriting.write(Data(line.utf8))
        inPipe.fileHandleForWriting.closeFile()
    }

    // Drain both pipes off-thread before waiting, or a full pipe deadlocks the child.
    var outData = Data()
    var errData = Data()
    let drain = DispatchGroup()
    DispatchQueue.global().async(group: drain) {
        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    }
    DispatchQueue.global().async(group: drain) {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    }

    if done.wait(timeout: .now() + timeout) == .timedOut {
        proc.terminate()
        if done.wait(timeout: .now() + 2) == .timedOut {
            kill(proc.processIdentifier, SIGKILL)
        }
        return nil
    }
    drain.wait()
    return SecurityCLIResult(status: proc.terminationStatus, stdout: outData, stderr: errData)
}

/// Read the credentials string from the macOS keychain via the `security` CLI.
/// Returns nil if absent or unreadable. Promptless in the healthy state: the item is created by
/// `security` (Claude Code), so `apple-tool:` partition members read it without authorization.
private func readFromKeychain() -> Data? {
    guard let r = runSecurityCLI(
        ["find-generic-password", "-s", keychainService, "-w"], timeout: 5),
        r.status == 0,
        let s = String(data: r.stdout, encoding: .utf8) else { return nil }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : Data(trimmed.utf8)
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

/// One add-generic-password invocation. The secret travels hex-encoded over `security -i` stdin
/// so it never appears in argv; oversized lines fall back to argv, exactly like Claude Code.
private func runAddGenericPassword(
    account: String, hexPayload: String, update: Bool
) -> SecurityCLIResult? {
    let line = addGenericPasswordCommandLine(
        account: account, service: keychainService, hexPayload: hexPayload, update: update)
    if line.utf8.count <= securityStdinLimit {
        return runSecurityCLI(["-i"], stdinLine: line, timeout: 10)
    }
    FileHandle.standardError.write(
        Data("Pulse: credentials exceed the security -i line budget; falling back to argv\n".utf8))
    var args = ["add-generic-password"]
    if update { args.append("-U") }
    args += ["-a", account, "-s", keychainService, "-X", hexPayload]
    return runSecurityCLI(args, timeout: 10)
}

private func writeCredentialsToKeychain(
    accessToken: String, refreshToken: String, expiresAtMs: Double
) throws {
    // Update-only: an absent item means Claude Code logged out. Recreating it here would
    // resurrect stale credentials mid-login (and stamp the wrong partition list) — the very bug
    // this path exists to avoid. The in-memory RefreshedCredentialsCache keeps us running.
    guard let probe = runSecurityCLI(
        ["find-generic-password", "-s", keychainService], timeout: 5),
        probe.status == 0 else {
        throw CredentialsError.writeFailed(
            "Keychain item not found; skipping writeback — Claude Code owns the item lifecycle.")
    }
    // `-U` matches on account+service; a wrong account would silently create a second item.
    let account = parseKeychainAccount(
        fromFindOutput: String(data: probe.stdout, encoding: .utf8) ?? "") ?? NSUserName()

    let existing = readFromKeychain()
    let data = try mergedCredentialsData(
        existing: existing, accessToken: accessToken, refreshToken: refreshToken, expiresAtMs: expiresAtMs)
    let hex = hexEncode(data)

    let first = runAddGenericPassword(account: account, hexPayload: hex, update: true)
    if let first = first, first.status == 0 { return }

    // Self-heal: `-U` is denied when some app once rewrote the item with a native SecItem* call
    // (wrong partition list). Deleting needs no access to the secret, and the re-add is performed
    // by `security` itself, so the recreated item carries the `apple-tool:` partition Claude Code
    // expects — this repairs the endless-password-prompt state on the next writeback.
    _ = runSecurityCLI(
        ["delete-generic-password", "-a", account, "-s", keychainService], timeout: 10)
    let second = runAddGenericPassword(account: account, hexPayload: hex, update: false)
    if let second = second, second.status == 0 { return }

    let detail: String
    if let r = second ?? first {
        var err = String(data: r.stderr, encoding: .utf8) ?? ""
        if err.contains(hex) { err = "" }  // never leak the payload if security echoed the line
        err = err.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = String(err.prefix(200))
        detail = "exit \(r.status)" + (snippet.isEmpty ? "" : ": \(snippet)")
    } else {
        detail = "security did not complete (timeout or launch failure)"
    }
    throw CredentialsError.writeFailed("Keychain write failed (\(detail)).")
}
