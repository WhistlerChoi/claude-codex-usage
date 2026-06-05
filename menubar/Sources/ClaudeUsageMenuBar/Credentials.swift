import Foundation

enum CredentialsError: Error, LocalizedError {
    case notFound(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let m): return m
        }
    }
}

/// 자격 증명 JSON Data에서 accessToken 추출. { claudeAiOauth: { accessToken } } 또는 { accessToken }.
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

/// macOS 키체인에서 자격 증명 문자열을 읽는다. 없으면 nil.
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

/// Claude Code OAuth accessToken을 읽는다.
/// 우선 ~/.claude/.credentials.json, 없으면 macOS 키체인.
func readAccessToken() throws -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let credPath = home.appendingPathComponent(".claude/.credentials.json")
    if let data = try? Data(contentsOf: credPath), let tok = extractAccessToken(data) {
        return tok
    }
    if let data = readFromKeychain(), let tok = extractAccessToken(data) {
        return tok
    }
    throw CredentialsError.notFound("Claude Code 자격 증명을 찾지 못했습니다. 로그인 상태를 확인하세요.")
}
