import Foundation

/// Which accounts may continue the work in a folder. Work for an employer, for instance, belongs only in the
/// subscription the employer provides, never in a personal one, so continuing it anywhere else is refused.
public struct FolderRule: Codable, Equatable, Sendable {
    /// An absolute path; the rule covers the folder and everything inside it.
    public var folder: String
    /// Email addresses of the accounts that may continue this work, lowercased.
    public var accounts: [String]

    public init(folder: String, accounts: [String]) {
        self.folder = Self.canonical(folder)
        self.accounts = Array(Set(accounts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })).sorted()
    }

    /// Whether `path` is the rule's folder or inside it. Links and `..` are resolved first, also in a path that no
    /// longer exists, such as a deleted worktree; the path as given counts too, and case is ignored, as the Mac's disks
    /// ignore it. Wherever the two could differ, the rule covers more rather than less.
    public func covers(_ path: String) -> Bool {
        Self.forms(of: path).contains(where: contains)
    }

    /// Whether `form`, a path already resolved or standardized, is the rule's folder or inside it; case is ignored.
    func contains(_ form: String) -> Bool {
        let folder = folder.lowercased(), own = form.lowercased()
        return own == folder || own.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// `path` resolved, then as given: the folder its files are in, then the one it is reached through.
    static func forms(of path: String) -> [String] {
        [canonical(path), URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path]
    }

    /// `ConversationIndex.canonical`, also for a path that no longer exists: its closest existing folder is resolved
    /// and the rest appended. A deleted folder under a linked one is then still under the folder the link leads to,
    /// and a gone `/private/tmp/…` still matches `/tmp/…`.
    static func canonical(_ path: String) -> String {
        var existing = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return rest.reduce(ConversationIndex.canonical(existing.path)) { ($0 as NSString).appendingPathComponent($1) }
    }
}

/// Folder rules, kept in `folder-rules.json` apart from the profiles, so removing a profile and adding it back
/// never drops a rule.
public struct FolderRules: Sendable {
    public let file: URL

    public init(paths: Paths) { file = paths.stateDir.appending(path: "folder-rules.json") }

    private struct Stored: Codable {
        var version: Int
        var rules: [FolderRule]
    }

    /// No file means no rules. A file that can't be read throws, so that nothing continues past a rule by mistake.
    public func load() throws -> [FolderRule] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
        guard stored.version == 1 else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path]) }
        return stored.rules.map { FolderRule(folder: $0.folder, accounts: $0.accounts) }
    }

    /// Sets the rule for exactly `folder`, or removes it when `accounts` is empty.
    /// - Returns: the rule as saved, or `nil` if it was removed.
    @discardableResult
    public func set(_ folder: String, accounts: [String]) throws -> FolderRule? {
        let rule = FolderRule(folder: folder, accounts: accounts)
        var rules = try load().filter { $0.folder != rule.folder }
        if !rule.accounts.isEmpty { rules.append(rule) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Stored(version: 1, rules: rules.sorted { $0.folder < $1.folder })).write(to: file, options: .atomic)
        return rule.accounts.isEmpty ? nil : rule
    }

    /// The rules that apply to `path`: the rule of the closest folder that is `path` or contains it, both for the folder
    /// `path` resolves to and for the path as given. Where a link leads from one ruled folder into another the two
    /// differ, and both apply, so the stricter one wins whichever way the link goes.
    public static func rules(for path: String, in rules: [FolderRule]) -> [FolderRule] {
        var found: [FolderRule] = []
        for form in FolderRule.forms(of: path) {
            if let closest = rules.filter({ $0.contains(form) }).max(by: { $0.folder.count < $1.folder.count }), !found.contains(closest) {
                found.append(closest)
            }
        }
        return found
    }

    /// The accounts that may continue work touching all of `folders`: `nil` when no rule covers any of them, and
    /// empty when their rules have no account in common.
    public static func allowedAccounts(for folders: [String], in rules: [FolderRule]) -> (accounts: Set<String>, rules: [FolderRule])? {
        var applied: [FolderRule] = []
        for folder in folders {
            for rule in Self.rules(for: folder, in: rules) where !applied.contains(rule) { applied.append(rule) }
        }
        guard let first = applied.first else { return nil }
        let accounts = applied.dropFirst().reduce(Set(first.accounts)) { $0.intersection($1.accounts) }
        return (accounts, applied)
    }
}
