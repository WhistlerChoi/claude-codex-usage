import Foundation

/// Token accounting for Codex, read from the rollout logs under `CODEX_HOME/sessions/**/*.jsonl`.
/// Two record shapes carry per-response usage:
///   - top-level `type == "token_usage_record"` (newer CLIs): `payload.usage`, deduplicated by
///     `payload.response_id`;
///   - `type == "event_msg"` with `payload.type == "token_count"`: `payload.info.last_token_usage`.
///     `payload.info` may be null, and the same usage is sometimes re-emitted on consecutive
///     events, so consecutive repeats are dropped. `payload.info.total_token_usage` is the
///     session's running total and must never be summed.
/// When a file has any `token_usage_record`, only those are used for that file.
///
/// Codex's `input_tokens` already includes `cached_input_tokens`; the shared totals keep them
/// apart (input = uncached input, cacheRead = cached input, cacheCreate = cache_write_input_tokens).
private func codexTotals(_ usage: [String: Any]) -> TokenTotals {
    let cached = tokenInt(usage["cached_input_tokens"])
    return TokenTotals(input: max(0, tokenInt(usage["input_tokens"]) - cached), output: tokenInt(usage["output_tokens"]),
                       cacheRead: cached, cacheCreate: tokenInt(usage["cache_write_input_tokens"]))
}

/// Bucket per-response usage by the local date of the record timestamp.
func extractCodexDailyTotals(_ content: String) -> DailyTotals {
    var fromRecords = DailyTotals()
    var fromEvents = DailyTotals()
    var haveRecords = false
    var seenResponses = Set<String>()
    var prevEvent: NSDictionary?
    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else {
            continue
        }
        let day = tokenRecordDate(obj["timestamp"]).map(localDateKey)
        if obj["type"] as? String == "token_usage_record", let usage = payload["usage"] as? [String: Any] {
            haveRecords = true
            if let id = payload["response_id"] as? String, !id.isEmpty {
                if seenResponses.contains(id) { continue }
                seenResponses.insert(id)
            }
            if let day { fromRecords[day] = (fromRecords[day] ?? TokenTotals()) + codexTotals(usage) }
        } else if obj["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] {
            let key = last as NSDictionary
            if let prev = prevEvent, prev.isEqual(to: last) { continue }
            prevEvent = key
            if let day { fromEvents[day] = (fromEvents[day] ?? TokenTotals()) + codexTotals(last) }
        }
    }
    return haveRecords ? fromRecords : fromEvents
}
