import Foundation

/// Auto Wakeup: keep the 5h row from sitting empty.
///
/// The 5-hour window is clock-aligned — `resets_at` lands on the hour (verified: a window
/// running 04:00→09:00 UTC while the session's own activity began at 01:03). So the window
/// is never "asleep": it rolls over on its own whether or not anything is sent.
///
/// What *does* go missing is `resets_at` itself. When no activity has been recorded in the
/// current window, the API omits it, and the UI falls back to "reset time unknown" / "—"
/// (`formatResetIn` / `formatResetDuration` in Format.swift). Auto Wakeup sends one minimal
/// request in that state so the provider starts reporting a reset time again.
///
/// Because the window is clock-aligned, a successful wakeup keeps the row populated until the
/// next boundary, which bounds sending to at most once per 5 hours in the healthy case.

// MARK: - Pure logic

/// Per-provider bookkeeping, persisted so a restart cannot reset the cooldown.
struct WakeupState: Equatable {
    var lastWakeupAt: Date?        // when a wakeup was last *attempted*
    var lastWindowResetsAt: Date?  // the most recent reset time actually observed
}

/// Minimum spacing between two attempts for one provider. In the healthy case the 5h boundary
/// already limits sending; this only engages when a wakeup fails to make `resets_at` appear.
let wakeupCooldown: TimeInterval = 30 * 60

/// Is the 5h row currently missing its reset time?
///
/// Only absence counts. A reset time that has merely passed is left alone: that is the
/// provider's own settling lag, and the row still has a value to show.
func needsWakeup(resetsAt: Date?, now: Date = Date()) -> Bool {
    resetsAt == nil
}

/// String overload for the Claude API's `resets_at` (matches Format.swift's overload pairs).
/// An unparsable value displays as unknown, so it is treated as absent.
func needsWakeup(resetsAt: String?, now: Date = Date()) -> Bool {
    guard let resetsAt, parseISODate(resetsAt) != nil else { return true }
    return false
}

/// The single decision point. Every guard lives here so the call site cannot bypass one.
func shouldWakeUp(
    enabled: Bool,
    resetsAt: Date?,
    state: WakeupState,
    inFlight: Bool,
    now: Date = Date(),
    cooldown: TimeInterval = wakeupCooldown
) -> Bool {
    guard enabled else { return false }
    guard !inFlight else { return false }
    guard needsWakeup(resetsAt: resetsAt, now: now) else { return false }
    // Backstop: even if the predicate above is wrong, spend stays bounded.
    if let last = state.lastWakeupAt, now < last.addingTimeInterval(cooldown) { return false }
    return true
}

/// Recorded when an attempt *starts*, not when it succeeds: a crash or hang mid-request then
/// still costs the cooldown, instead of being retried on every poll.
func stateAfterWakeup(_ state: WakeupState, resetsAt: Date?, now: Date = Date()) -> WakeupState {
    var next = state
    next.lastWakeupAt = now
    if let resetsAt { next.lastWindowResetsAt = resetsAt }
    return next
}

/// Menu status line for the standalone note form. English only, per CLAUDE.md.
func wakeupStatusLine(enabled: Bool, state: WakeupState, now: Date = Date()) -> String {
    guard enabled else { return "Auto Wakeup: off" }
    guard let last = state.lastWakeupAt else { return "Auto Wakeup: on" }
    return "Auto Wakeup: last " + clockString(last)
}

/// On/Off word shown next to the switch. The switch's accent-blue fill is close in weight to
/// its grey off track inside a menu, so the state is spelled out as well as coloured — that also
/// keeps it readable without relying on colour alone.
func wakeupStateLabel(enabled: Bool) -> String {
    enabled ? "On" : "Off"
}

/// Suffix shown next to the "Auto Wakeup" label on the single-row control. The switch already
/// conveys on/off, so this carries only what the switch cannot: when it last fired. Empty when
/// there is nothing to add, keeping the row to just the label and the switch.
func wakeupRowDetail(enabled: Bool, state: WakeupState, now: Date = Date()) -> String {
    guard enabled, let last = state.lastWakeupAt else { return "" }
    return "last " + clockString(last)
}

// MARK: - Network (impure)

enum WakeupError: Error {
    case failed(Int)
    case notConfigured
}

/// Smallest possible request that makes the provider record activity in the current window.
/// One attempt, no retry. Throws on any failure; the caller swallows it.
func sendClaudeWakeup() async throws {
    let token = try await currentAccessToken()
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 20
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 1,
        "messages": [["role": "user", "content": "."]],
    ])

    let (_, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw WakeupError.failed(0) }
    guard (200..<300).contains(http.statusCode) else { throw WakeupError.failed(http.statusCode) }
}

/// Request body for the Codex wakeup: the Responses wire format Codex itself sends to
/// `backend-api/codex/responses`, reduced to a one-character user turn. Pure, so it is tested.
func codexWakeupRequestBody(model: String) -> [String: Any] {
    [
        "model": model,
        "instructions": "",
        "store": false,
        "stream": true,
        "input": [[
            "type": "message",
            "role": "user",
            "content": [["type": "input_text", "text": "."]],
        ]],
    ]
}

/// Which model the Codex wakeup uses. The current Codex model (from the rollout logs) is known
/// to be accepted for this account; otherwise the first user-visible entry of
/// `models_cache.json`. nil when neither is available.
func codexWakeupModel(current: String?, cache: Data?) -> String? {
    if let current, !current.isEmpty { return current }
    guard let cache,
          let obj = try? JSONSerialization.jsonObject(with: cache) as? [String: Any],
          let models = obj["models"] as? [[String: Any]] else {
        return nil
    }
    for model in models where model["visibility"] as? String == "list" {
        if let slug = model["slug"] as? String, !slug.isEmpty { return slug }
    }
    return nil
}

/// Codex counterpart: one minimal turn on the endpoint Codex itself uses (seen in Codex's
/// logs as `api.path="/responses"`). Codex prefers a websocket; the plain SSE POST is its
/// fallback transport and is what this uses. The stream is read to `response.completed` so
/// the turn actually registers instead of being cancelled mid-flight.
/// One attempt, no retry. Throws on any failure; the caller swallows it.
func sendCodexWakeup() async throws {
    let credentials = try readCodexCredentials()
    let cache = try? Data(contentsOf: codexHome().appendingPathComponent("models_cache.json"))
    guard let model = codexWakeupModel(current: readCurrentCodexModel()?.id, cache: cache) else {
        throw WakeupError.notConfigured
    }

    var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    if let accountId = credentials.accountId, !accountId.isEmpty {
        req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
    }
    req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
    req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 30
    req.httpBody = try JSONSerialization.data(withJSONObject: codexWakeupRequestBody(model: model))

    let (bytes, response) = try await URLSession.shared.bytes(for: req)
    guard let http = response as? HTTPURLResponse else { throw WakeupError.failed(0) }
    guard (200..<300).contains(http.statusCode) else { throw WakeupError.failed(http.statusCode) }

    for try await line in bytes.lines {
        guard line.hasPrefix("event:") || line.hasPrefix("data:") else { continue }
        if line.contains("response.completed") { return }
        if line.contains("response.failed") || line.contains("\"type\":\"error\"") {
            throw WakeupError.failed(http.statusCode)
        }
    }
    throw WakeupError.failed(http.statusCode)  // stream ended without completing
}
