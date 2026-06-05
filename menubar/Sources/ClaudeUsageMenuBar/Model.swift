import Foundation

struct CurrentModel {
    let id: String
    let name: String
}

/// 모델 ID -> 사람이 읽는 이름. "claude-opus-4-8" -> "Opus 4.8"
func friendlyModelName(_ id: String) -> String {
    if id.isEmpty { return "Unknown" }
    let lower = id.lowercased()
    let family = ["opus", "sonnet", "haiku"].first { lower.contains($0) }

    var version = ""
    if let regex = try? NSRegularExpression(pattern: "([0-9]+)[-.]([0-9]+)") {
        let range = NSRange(lower.startIndex..., in: lower)
        if let m = regex.firstMatch(in: lower, options: [], range: range),
           let r1 = Range(m.range(at: 1), in: lower),
           let r2 = Range(m.range(at: 2), in: lower) {
            version = "\(lower[r1]).\(lower[r2])"
        }
    }

    if let family = family {
        let cap = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? cap : "\(cap) \(version)"
    }
    return id
}

/// 트랜스크립트 내용에서 끝에서부터 마지막 message.model을 찾는다.
func extractLastModel(_ content: String) -> String? {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines.reversed() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let model = message["model"] as? String, !model.isEmpty else {
            continue
        }
        return model
    }
    return nil
}

/// ~/.claude/projects 아래에서 가장 최근 트랜스크립트의 모델을 읽는다.
func readCurrentModel() -> CurrentModel? {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard let dirs = try? fm.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []
    ) else {
        return nil
    }

    var best: URL?
    var bestDate = Date.distantPast
    for dir in dirs {
        let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if !isDir { continue }
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { continue }
        for f in files where f.pathExtension == "jsonl" {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            if date > bestDate {
                bestDate = date
                best = f
            }
        }
    }

    guard let path = best,
          let content = try? String(contentsOf: path, encoding: .utf8),
          let id = extractLastModel(content) else {
        return nil
    }
    return CurrentModel(id: id, name: friendlyModelName(id))
}
