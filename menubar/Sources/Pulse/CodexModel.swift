import Foundation

/// Best-effort current Codex model, read from the local Codex session logs. Menubar-only;
/// mirrors `Model.swift` for Claude. Every step is lenient — failure means "no model", never
/// an error, because the model is optional in the UI.

/// Find the model of the *last* `turn_context` record in a Codex rollout log, scanning from
/// the end. `turn_context` carries the model actually used for that turn, so a mid-session
/// model switch is reflected; `session_meta` / `thread_settings_applied` are ignored.
func extractLastCodexModel(_ content: String) -> String? {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines.reversed() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "turn_context",
              let payload = obj["payload"] as? [String: Any],
              let model = payload["model"] as? String, !model.isEmpty else {
            continue
        }
        return model
    }
    return nil
}

/// Map a model slug to its display name via Codex's `models_cache.json`
/// (`models[].{slug, display_name}`). Any decode problem or unknown slug → the slug itself.
func codexModelDisplayName(_ slug: String, cache: Data?) -> String {
    guard let cache,
          let obj = try? JSONSerialization.jsonObject(with: cache) as? [String: Any],
          let models = obj["models"] as? [[String: Any]] else {
        return slug
    }
    for model in models where model["slug"] as? String == slug {
        if let name = model["display_name"] as? String, !name.isEmpty { return name }
    }
    return slug
}

/// Read the model from the most recently modified rollout log under `CODEX_HOME/sessions`.
func readCurrentCodexModel() -> CurrentModel? {
    let fm = FileManager.default
    let home = codexHome()
    let root = home.appendingPathComponent("sessions")
    guard let enumerator = fm.enumerator(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
    ) else {
        return nil
    }

    var best: URL?
    var bestDate = Date.distantPast
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date.distantPast
        if date > bestDate {
            bestDate = date
            best = url
        }
    }

    guard let path = best,
          let content = try? String(contentsOf: path, encoding: .utf8),
          let slug = extractLastCodexModel(content) else {
        return nil
    }
    let cache = try? Data(contentsOf: home.appendingPathComponent("models_cache.json"))
    return CurrentModel(id: slug, name: codexModelDisplayName(slug, cache: cache))
}
