import Foundation

/// Token accounting primitives for Claude Code transcripts (`~/.claude/projects/**/*.jsonl`);
/// mirrors `src/tokens.ts`. The usage API only reports rate-limit percentages, so token counts
/// can only come from these files. Pure parsing lives here; the daily ledger that turns it into
/// today / 7d / 30d figures is in `TokenHistory.swift`. Best-effort throughout: a failure means
/// the token rows are omitted, never an error state.
struct TokenTotals: Equatable, Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheCreate: Int = 0

    var total: Int { input + output + cacheRead + cacheCreate }

    static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(input: a.input + b.input, output: a.output + b.output,
                    cacheRead: a.cacheRead + b.cacheRead, cacheCreate: a.cacheCreate + b.cacheCreate)
    }

    static func max(_ a: TokenTotals, _ b: TokenTotals) -> TokenTotals {
        TokenTotals(input: Swift.max(a.input, b.input), output: Swift.max(a.output, b.output),
                    cacheRead: Swift.max(a.cacheRead, b.cacheRead), cacheCreate: Swift.max(a.cacheCreate, b.cacheCreate))
    }
}

/// Per local calendar day ("YYYY-MM-DD") totals of one transcript.
typealias DailyTotals = [String: TokenTotals]

/// The record's `timestamp` as a Date; missing or unparseable → nil (cannot be attributed to a day).
func tokenRecordDate(_ timestamp: Any?) -> Date? {
    guard let s = timestamp as? String else { return nil }
    return parseISODate(s)
}

func tokenInt(_ v: Any?) -> Int {
    if let n = v as? Int { return n }
    if let d = v as? Double, d.isFinite { return Int(d) }
    return 0
}

/// Bucket `message.usage` of the `assistant` records by the local date of their `timestamp`.
/// Claude Code writes one `assistant` line per content block of a response; those lines share
/// `message.id` with identical usage, so each id counts once. `usage.iterations[]` is ignored.
func extractDailyTotals(_ content: String) -> DailyTotals {
    var days = DailyTotals()
    var seen = Set<String>()
    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "assistant",
              let date = tokenRecordDate(obj["timestamp"]),
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            continue
        }
        if let id = message["id"] as? String, !id.isEmpty {
            if seen.contains(id) { continue }
            seen.insert(id)
        }
        let key = localDateKey(date)
        days[key] = (days[key] ?? TokenTotals()) + TokenTotals(
            input: tokenInt(usage["input_tokens"]),
            output: tokenInt(usage["output_tokens"]),
            cacheRead: tokenInt(usage["cache_read_input_tokens"]),
            cacheCreate: tokenInt(usage["cache_creation_input_tokens"]))
    }
    return days
}

/// 0 → "0", 1234 → "1.2K", 48000 → "48K", 9_800_000 → "9.8M", 13_500_000 → "14M", 2.1e9 → "2.1B".
func formatTokens(_ n: Int) -> String {
    func scaled(_ unit: Double, _ suffix: String) -> String {
        let v = Double(n) / unit
        return (v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)) + suffix
    }
    if n < 1000 { return String(n) }
    if n < 999_500 { return scaled(1_000, "K") }
    if n < 999_500_000 { return scaled(1_000_000, "M") }
    return scaled(1_000_000_000, "B")
}

/// "1.2M in · 48K out · 9.8M cache" — cache is read + creation. Identical in all ports.
func tokenTotalsText(_ t: TokenTotals) -> String {
    "\(formatTokens(t.input)) in · \(formatTokens(t.output)) out · \(formatTokens(t.cacheRead + t.cacheCreate)) cache"
}
