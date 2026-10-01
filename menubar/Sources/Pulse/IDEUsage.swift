import Foundation

// Which Claude config dirs the Claude Code VS Code extension is using right now (menubar-only).
//
// The extension spawns each session as its bundled `claude` binary with
// CLAUDE_CODE_ENTRYPOINT=claude-vscode in the environment (children such as MCP servers inherit
// it). A session's account is that process's CLAUDE_CONFIG_DIR, or ~/.claude when unset — which
// also covers the extension's `claudeCode.environmentVariables` setting, since the extension
// injects it into the spawned env. `<configDir>/ide/*.lock` is deliberately not used: the
// extension writes it from VS Code's own environment, so it names the wrong dir in that case.

/// A config dir in comparable form: NFC, no trailing slash. Pure.
func normalizedConfigDir(_ dir: String) -> String {
    var d = dir.precomposedStringWithCanonicalMapping
    while d.count > 1 && d.hasSuffix("/") { d.removeLast() }
    return d
}

/// Config dirs of running VS Code Claude sessions, from `ps -E -axww -o command=` output (each line
/// is a command followed by its environment, space-separated). A CLAUDE_CONFIG_DIR value runs up to
/// the next ` NAME=` token. Pure.
func vscodeConfigDirs(psOutput: String, defaultDir: String) -> Set<String> {
    let marker = "CLAUDE_CODE_ENTRYPOINT=claude-vscode"
    let key = " CLAUDE_CONFIG_DIR="
    var dirs = Set<String>()
    for line in psOutput.split(separator: "\n") where line.contains(marker) {
        // The marker must be a whole token (not e.g. "claude-vscode-x").
        guard line.range(of: #"(^| )CLAUDE_CODE_ENTRYPOINT=claude-vscode( |$)"#, options: .regularExpression) != nil
        else { continue }
        var dir = defaultDir
        if let r = line.range(of: key) {
            let rest = line[r.upperBound...]
            let end = rest.range(of: #" [A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression)?.lowerBound
                ?? rest.endIndex
            let value = String(rest[..<end])
            if !value.isEmpty { dir = value }
        }
        dirs.insert(normalizedConfigDir(dir))
    }
    return dirs
}

/// Scan running processes. Nil when `ps` fails (the badge is then just hidden — never an error).
func readVSCodeConfigDirs() -> Set<String>? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-E", "-axww", "-o", "command="]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    proc.standardInput = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    // Read before waiting, or a full pipe would block ps.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
    // A session without CLAUDE_CONFIG_DIR uses ~/.claude — not necessarily Pulse's own env home.
    let defaultDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
    return vscodeConfigDirs(psOutput: text, defaultDir: defaultDir)
}

/// The profile the menu-bar title shows. With `follow` on and a VS Code session using one of the
/// profiles, that profile wins — the manual pick if VS Code uses it too, else the first in display
/// order; otherwise the manual pick (Accounts ▸ Show in Menu Bar). Pure.
func effectivePrimaryID(
    manualID: String, follow: Bool, profiles: [(id: String, configDir: String)], vscodeDirs: Set<String>
) -> String {
    guard follow else { return manualID }
    let inUse = profiles.filter { vscodeDirs.contains(normalizedConfigDir($0.configDir)) }.map(\.id)
    if inUse.contains(manualID) { return manualID }
    return inUse.first ?? manualID
}
