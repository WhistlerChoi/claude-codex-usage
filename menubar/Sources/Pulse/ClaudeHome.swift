import CryptoKit
import Foundation

/// Where one Claude Code installation keeps its state. `custom` is true when the directory came
/// from CLAUDE_CONFIG_DIR (or a Pulse account profile), which changes the keychain service name
/// and the global config path. Mirrors src/claudeHome.ts.
struct ClaudeHome: Equatable {
    let configDir: String
    let custom: Bool

    var credentialsURL: URL { URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json") }
    var projectsURL: URL { URL(fileURLWithPath: configDir).appendingPathComponent("projects") }

    /// Claude Code's global config (holds `oauthAccount`), in the order Claude Code consults them:
    /// a legacy `<configDir>/.config.json` wins when it exists, else `.claude.json` in the config
    /// dir (custom home) or the user's home directory.
    var globalConfigCandidates: [URL] {
        let base = custom
            ? URL(fileURLWithPath: configDir)
            : FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: configDir).appendingPathComponent(".config.json"),
            base.appendingPathComponent(".claude.json"),
        ]
    }
}

/// CLAUDE_CONFIG_DIR (an empty value counts as unset, as in Claude Code), else ~/.claude.
func claudeHome(env: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeHome {
    if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
        return ClaudeHome(configDir: dir.precomposedStringWithCanonicalMapping, custom: true)
    }
    return ClaudeHome(
        configDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path,
        custom: false)
}

/// The keychain service Claude Code stores this home's OAuth credentials under:
/// "Claude Code-credentials", plus "-<first 8 hex of sha256(configDir)>" for a custom home.
/// Claude Code hashes the raw NFC string — no tilde expansion, no realpath, and a trailing slash
/// changes the hash — so `configDir` must be exactly what was exported. Pure.
func keychainServiceName(_ home: ClaudeHome) -> String {
    guard home.custom else { return keychainService }
    let digest = SHA256.hash(data: Data(home.configDir.precomposedStringWithCanonicalMapping.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "\(keychainService)-\(hex.prefix(8))"
}

/// Services to try, in order. A profile is stored without a trailing slash, but the user may have
/// exported it with one (`CLAUDE_CONFIG_DIR=~/.claude-work/`), which Claude Code hashes differently.
func keychainServiceCandidates(_ home: ClaudeHome) -> [String] {
    guard home.custom else { return [keychainService] }
    var names = [keychainServiceName(home)]
    let dir = home.configDir
    let alternate = dir.hasSuffix("/") ? String(dir.dropLast()) : dir + "/"
    if !alternate.isEmpty {
        names.append(keychainServiceName(ClaudeHome(configDir: alternate, custom: true)))
    }
    return names
}

// MARK: - Account profiles (menubar-only for now)

/// One Claude Code account Pulse monitors. The default profile is whatever Claude Code uses
/// without CLAUDE_CONFIG_DIR (or the env value Pulse was launched with); the others live in
/// `$PULSE_HOME/accounts.json`, each in its own CLAUDE_CONFIG_DIR.
struct ClaudeProfile: Equatable {
    static let defaultID = "default"

    let id: String       // "default", or a slug: [a-z0-9-]
    let label: String
    let home: ClaudeHome

    var isDefault: Bool { id == Self.defaultID }
    /// Token-ledger provider key. The default keeps "claude" so the other ports share its history.
    var ledgerProvider: String { isDefault ? "claude" : "claude-\(id)" }
    /// Suffix of the Auto Wakeup state keys; the default keeps the pre-profile key.
    var wakeupKey: String { isDefault ? "claude" : "claude.\(id)" }

    static func makeDefault(home: ClaudeHome = claudeHome()) -> ClaudeProfile {
        ClaudeProfile(id: defaultID, label: "Default", home: home)
    }
}

/// Most profiles Pulse will monitor at once (each one is a poll per interval and a menu section).
let maxClaudeProfiles = 5

/// On-disk shape of `$PULSE_HOME/accounts.json`.
private struct AccountsFile: Codable {
    struct Entry: Codable {
        let id: String
        let label: String
        let configDir: String
    }
    var version: Int
    var profiles: [Entry]
}

enum ProfileStoreError: Error, LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self {
        case .unreadable(let m): return m
        }
    }
}

func accountsFileURL(home: URL = pulseHome()) -> URL {
    home.appendingPathComponent("accounts.json")
}

/// Parse accounts.json (pure). Throws on a file that exists but cannot be understood, so the
/// caller never overwrites it — it is user data, like the token ledger.
func parseProfiles(_ data: Data) throws -> [ClaudeProfile] {
    guard let file = try? JSONDecoder().decode(AccountsFile.self, from: data), file.version == 1 else {
        throw ProfileStoreError.unreadable("accounts.json is not a version 1 Pulse accounts file.")
    }
    var seen = Set<String>([ClaudeProfile.defaultID])
    var out: [ClaudeProfile] = []
    for e in file.profiles where isValidProfileID(e.id) && !seen.contains(e.id) && !e.configDir.isEmpty {
        seen.insert(e.id)
        out.append(ClaudeProfile(id: e.id, label: e.label, home: ClaudeHome(configDir: e.configDir, custom: true)))
    }
    return out
}

func serializeProfiles(_ profiles: [ClaudeProfile]) throws -> Data {
    let file = AccountsFile(version: 1, profiles: profiles.filter { !$0.isDefault }.map {
        AccountsFile.Entry(id: $0.id, label: $0.label, configDir: $0.home.configDir)
    })
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try enc.encode(file)
}

/// The extra (non-default) profiles. A missing file is an empty list; an unparseable one throws.
func loadExtraProfiles(home: URL = pulseHome()) throws -> [ClaudeProfile] {
    let url = accountsFileURL(home: home)
    guard let data = try? Data(contentsOf: url) else { return [] }
    return try parseProfiles(data)
}

/// Replace accounts.json atomically. Refuses when the current file cannot be parsed.
func saveExtraProfiles(_ profiles: [ClaudeProfile], home: URL = pulseHome()) throws {
    _ = try loadExtraProfiles(home: home)  // never overwrite a file we could not understand
    let fm = FileManager.default
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let url = accountsFileURL(home: home)
    let tmp = home.appendingPathComponent("accounts.json.tmp-\(ProcessInfo.processInfo.processIdentifier)")
    try serializeProfiles(profiles).write(to: tmp)
    if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    } else {
        try fm.moveItem(at: tmp, to: url)
    }
}

func isValidProfileID(_ id: String) -> Bool {
    !id.isEmpty && id != ClaudeProfile.defaultID && id.count <= 32
        && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
}

/// "My Work!" → "my-work". Empty when nothing usable is left. Pure.
func profileSlug(_ name: String) -> String {
    var out = ""
    for ch in name.lowercased() {
        if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
            out.append(ch)
        } else if !out.isEmpty, out.last != "-" {
            out.append("-")
        }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return String(out.prefix(32))
}

/// POSIX single-quote a shell word. Pure.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The shell command that runs Claude Code with this profile (logging in if needed).
func claudeCommand(for profile: ClaudeProfile) -> String {
    profile.home.custom ? "CLAUDE_CONFIG_DIR=\(shellQuote(profile.home.configDir)) claude" : "claude"
}

/// `alias claude-work="CLAUDE_CONFIG_DIR='/Users/me/.claude-work' claude"` for the user's shell rc.
func shellAlias(for profile: ClaudeProfile) -> String {
    "alias claude-\(profile.id)=\"\(claudeCommand(for: profile))\""
}
