import Foundation

enum RefreshError: Error, LocalizedError {
    case noRefreshToken
    case http(Int)
    case malformed
    var errorDescription: String? {
        switch self {
        case .noRefreshToken: return "No refresh token available."
        case .http(let c): return "Token refresh failed: HTTP \(c)"
        case .malformed: return "Malformed token refresh response."
        }
    }
}

struct RefreshedTokens {
    let accessToken: String
    let refreshToken: String
    let expiresAtMs: Double
}

// Claude Code's public OAuth client (PKCE, no client secret). Same client_id Claude Code uses
// so the shared refresh token is accepted — a token minted for one client_id can't be refreshed by another.
private let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let oauthTokenURL = "https://platform.claude.com/v1/oauth/token"

/// Parse the OAuth token endpoint response into refreshed tokens. Pure (no network) for testability.
/// `nowMs` is the current time in ms epoch; the new expiry is `now + expires_in * 1000`.
/// If the response omits a rotated `refresh_token`, the previous one is carried forward.
func parseRefreshResponse(_ data: Data, previousRefreshToken: String, nowMs: Double) throws -> RefreshedTokens {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let access = obj["access_token"] as? String, !access.isEmpty else {
        throw RefreshError.malformed
    }
    let rotated = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let expiresIn = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 0
    return RefreshedTokens(
        accessToken: access,
        refreshToken: rotated ?? previousRefreshToken,
        expiresAtMs: nowMs + expiresIn * 1000)
}

/// Exchange a refresh token for a fresh access token via the Claude OAuth token endpoint.
func refreshAccessToken(_ refreshToken: String) async throws -> RefreshedTokens {
    guard !refreshToken.isEmpty else { throw RefreshError.noRefreshToken }

    var req = URLRequest(url: URL(string: oauthTokenURL)!)
    req.httpMethod = "POST"
    // The endpoint expects form-encoding; JSON bodies are reported to hang/time out.
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 20

    var comps = URLComponents()
    comps.queryItems = [
        URLQueryItem(name: "grant_type", value: "refresh_token"),
        URLQueryItem(name: "refresh_token", value: refreshToken),
        URLQueryItem(name: "client_id", value: oauthClientID),
    ]
    req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw RefreshError.malformed }
    guard (200..<300).contains(http.statusCode) else { throw RefreshError.http(http.statusCode) }

    let nowMs = Date().timeIntervalSince1970 * 1000
    return try parseRefreshResponse(data, previousRefreshToken: refreshToken, nowMs: nowMs)
}
