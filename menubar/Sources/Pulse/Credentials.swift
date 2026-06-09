import Foundation

enum CredentialsError: Error, LocalizedError {
    case notFound(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let m): return m
        }
    }
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

/// Read the credentials string from the macOS keychain. Returns nil if absent.
private func readFromKeychain() -> Data? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = Pipe()
    do {
        try proc.run()
    } catch {
        return nil
    }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    return outPipe.fileHandleForReading.readDataToEndOfFile()
}

/// Read the Claude Code OAuth accessToken.
/// Prefers ~/.claude/.credentials.json; falls back to the macOS keychain.
func readAccessToken() throws -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let credPath = home.appendingPathComponent(".claude/.credentials.json")
    if let data = try? Data(contentsOf: credPath), let tok = extractAccessToken(data) {
        return tok
    }
    if let data = readFromKeychain(), let tok = extractAccessToken(data) {
        return tok
    }
    throw CredentialsError.notFound("Could not read credentials. Log in with Claude Code.")
}
