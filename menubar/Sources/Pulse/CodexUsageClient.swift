import Foundation

struct CodexUsageWindow {
    let usedPercent: Int
    let resetsAt: Date?
}

struct CodexUsage {
    let fiveHour: CodexUsageWindow
    let weekly: CodexUsageWindow?
    let planType: String?
    let creditsAvailable: Bool
    let creditsUnlimited: Bool
}

enum CodexUsageError: Error, LocalizedError {
    case credentialsNotFound
    case auth
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound: return "Could not read Codex credentials. Log in with Codex."
        case .auth: return "Codex authentication expired. Log in again."
        case .http(let code): return "Codex usage API error: HTTP \(code)"
        case .malformed: return "Malformed Codex usage response."
        }
    }
}

private struct CodexAuth: Decodable {
    struct Tokens: Decodable {
        let accessToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
        }
    }

    let tokens: Tokens?
}

private struct CodexUsageResponse: Decodable {
    struct RateLimit: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let resetAfterSeconds: Double?
            let resetAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAfterSeconds = "reset_after_seconds"
                case resetAt = "reset_at"
            }
        }

        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
        }
    }

    let rateLimit: RateLimit?
    let planType: String?
    let credits: Credits?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case planType = "plan_type"
        case credits
    }
}

private struct CodexCredentials {
    let accessToken: String
    let accountId: String?
}

func codexHome() -> URL {
    let env = ProcessInfo.processInfo.environment
    if let configured = env["CODEX_HOME"], !configured.isEmpty {
        return URL(fileURLWithPath: configured)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
}

private func readCodexCredentials() throws -> CodexCredentials {
    let url = codexHome().appendingPathComponent("auth.json")
    guard let data = try? Data(contentsOf: url) else {
        throw CodexUsageError.credentialsNotFound
    }
    guard let auth = try? JSONDecoder().decode(CodexAuth.self, from: data),
          let token = auth.tokens?.accessToken, !token.isEmpty else {
        throw CodexUsageError.credentialsNotFound
    }
    return CodexCredentials(accessToken: token, accountId: auth.tokens?.accountId)
}

private func parseCodexWindow(_ window: CodexUsageResponse.RateLimit.Window?) -> CodexUsageWindow? {
    guard let window, let rawPercent = window.usedPercent else { return nil }
    let percent = min(100, max(0, Int(rawPercent.rounded())))
    let reset: Date?
    if let epoch = window.resetAt {
        reset = Date(timeIntervalSince1970: epoch)
    } else if let seconds = window.resetAfterSeconds {
        reset = Date().addingTimeInterval(seconds)
    } else {
        reset = nil
    }
    return CodexUsageWindow(usedPercent: percent, resetsAt: reset)
}

func parseCodexUsage(_ data: Data) throws -> CodexUsage {
    guard let response = try? JSONDecoder().decode(CodexUsageResponse.self, from: data),
          let fiveHour = parseCodexWindow(response.rateLimit?.primaryWindow) else {
        throw CodexUsageError.malformed
    }
    return CodexUsage(
        fiveHour: fiveHour,
        weekly: parseCodexWindow(response.rateLimit?.secondaryWindow),
        planType: response.planType,
        creditsAvailable: response.credits?.hasCredits ?? false,
        creditsUnlimited: response.credits?.unlimited ?? false)
}

func fetchCodexUsage() async throws -> CodexUsage {
    let credentials = try readCodexCredentials()
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    if let accountId = credentials.accountId, !accountId.isEmpty {
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
    }
    request.setValue("Pulse/1.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw CodexUsageError.malformed }
    if http.statusCode == 401 || http.statusCode == 403 { throw CodexUsageError.auth }
    guard (200..<300).contains(http.statusCode) else { throw CodexUsageError.http(http.statusCode) }
    return try parseCodexUsage(data)
}
