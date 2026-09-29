import CryptoKit
import Foundation

/// Takes out of a problem report whatever identifies the user or their work, before anyone sees it:
/// the home folder becomes `~`, the macOS username `<user>`, emails `<email-1>`, `<email-2>` in first-seen order,
/// UUIDs a short `<id-…>` hash salted per report, profile labels and ids `<profile-1>`, the folders Baton knows (rule
/// and working folders) and any other folder outside well-known system locations `<folder>`, anything shaped like a
/// token or key `<token>`, and whatever the app put in curly quotes (session titles, task and file names) `“<quoted>”`.
/// Works on Unicode text and is idempotent: redacting its own output changes nothing.
public struct Redactor: Sendable {
    private let home: [String]
    private let user: String
    private let profiles: [[String]]
    /// Folders known by name, longest first, each as given and under `~`.
    private let folders: [String]
    /// Random per report and kept only in memory, so the same UUID gets the same tag within one report
    /// and a different one in the next.
    private let salt: [UInt8]
    private var emails: [String: Int] = [:]

    /// - Parameters:
    ///   - profiles: each profile's names (label and id), in the order they are numbered.
    ///   - folders: folders Baton knows by name, such as folder rules' and working folders. They are hidden whole even
    ///     where nothing marks their end, as a last folder name with a space in it that the sentence goes on after.
    public init(home: String, user: String, profiles: [[String]] = [], folders: [String] = [], salt: [UInt8]? = nil) {
        let home = home.precomposedStringWithCanonicalMapping.trimmingSuffix("/")
        // Temporary and some system folders show up both with and without /private.
        var variants = [home]
        if home.hasPrefix("/private/") {
            variants.append(String(home.dropFirst("/private".count)))
        } else if home.hasPrefix("/var/") || home.hasPrefix("/tmp/") {
            variants.append("/private" + home)
        }
        self.home = variants.filter { $0.count > 1 }.sorted { $0.count > $1.count }
        let homes = self.home
        let named = folders.map { $0.precomposedStringWithCanonicalMapping.trimmingSuffix("/") }.flatMap { folder in
            [folder] + homes.filter { folder.hasPrefix($0 + "/") }.map { "~" + folder.dropFirst($0.count) }
        }
        self.folders = Set(named.filter { $0.count > 2 && !homes.contains($0) }).sorted { $0.count > $1.count }
        self.user = user.precomposedStringWithCanonicalMapping
        self.profiles = profiles.map { $0.map(\.precomposedStringWithCanonicalMapping).filter { !$0.isEmpty } }
        self.salt = salt ?? (0..<16).map { _ in UInt8.random(in: .min ... .max) }
    }

    public mutating func redact(_ text: String) -> String {
        var text = text.precomposedStringWithCanonicalMapping
        for folder in folders {
            let end = #"(?=$|/|[^\p{L}\p{N}._-]|\.(?![\p{L}\p{N}_-]))"#
            text = Self.replace(NSRegularExpression.escapedPattern(for: folder) + end + "(?:\(Self.within))?", in: text) { _ in "<folder>" }
        }
        // The app quotes session titles, task names and file names in curly quotes; none of them leave the Mac. A
        // title can hold a closing quote itself, so the quote runs to the last one on its line.
        text = Self.replace(#"“[^\n]*”"#, in: text) { _ in "“<quoted>”" }
        for home in home {
            text = Self.replace(NSRegularExpression.escapedPattern(for: home) + #"(?=/|$|[^\p{L}\p{N}._-])"#, in: text) { _ in "~" }
        }
        text = Self.replace(Self.email, in: text) { match in
            let key = match.precomposedStringWithCompatibilityMapping.lowercased()
            if emails[key] == nil { emails[key] = emails.count + 1 }
            return "<email-\(emails[key]!)>"
        }
        text = Self.replace(Self.uuid, in: text) { match in
            let digest = SHA256.hash(data: salt + Array(match.precomposedStringWithCompatibilityMapping.lowercased().utf8))
            return "<id-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined() + ">"
        }
        for pattern in Self.tokens { text = Self.replace(pattern, in: text) { _ in "<token>" } }
        text = Self.replace(Self.syncedFolder, in: text) { _ in "<folder>" }
        text = Self.replace(Self.path, in: text) { match in
            // A sentence's closing period stays outside the path.
            let path = String(match.reversed().drop { $0 == "." }.reversed()), end = String(match.dropFirst(path.count))
            return (Self.safePaths.contains { path == $0 || path.hasPrefix($0 + "/") } ? path : "<folder>") + end
        }
        for (i, names) in profiles.enumerated() {
            for name in names.sorted(by: { $0.count > $1.count }) {
                text = Self.replace(Self.word(name), in: text) { _ in "<profile-\(i + 1)>" }
            }
        }
        if user.count > 1 { text = Self.replace("(?i)" + Self.word(user), in: text) { _ in "<user>" } }
        return text
    }

    // MARK: Patterns

    /// Letters and digits in any script, and the full-width `＠` and `．` some lookalike addresses use.
    static let email = #"[\p{L}\p{N}._%+-]+[@＠][\p{L}\p{N}-]+(?:[.．][\p{L}\p{N}-]+)+"#
    private static let hex = "[0-9a-fA-F０-９ａ-ｆＡ-Ｆ]"
    static let uuid = "(?<!\(hex))\(hex){8}-\(hex){4}-\(hex){4}-\(hex){4}-\(hex){12}(?!\(hex))"
    /// API keys, access tokens and JWTs, then any long run of letters and digits that isn't a plain word.
    static let tokens = [
        #"sk-[A-Za-z0-9_-]{16,}"#,
        #"(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{20,}"#,
        #"xox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#,
        #"(?<![A-Za-z0-9_-])(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])"#,
        #"(?<![A-Za-z0-9+/])(?=[A-Za-z0-9+/]*[0-9])(?=[A-Za-z0-9+/]*[a-z])(?=[A-Za-z0-9+/]*[A-Z])[A-Za-z0-9+/]{40,}={0,2}"#,
    ]
    /// An absolute or `~` path starting a word; it runs to the next quote or bracket, and past a space while the next
    /// word goes on with a `/`, as in `/Volumes/Backup Disk/Clients`. A last folder name with a space in it can't be
    /// told from the sentence, so `fail` in the CLI puts the paths it was given in curly quotes (`Log.quoting`), and
    /// the folders Baton knows by name are hidden whole before this runs.
    static let path = #"(?<=^|[\s"“”'‘’(\[])~?"# + within
    /// A path from its first `/` on, past a space while the next word goes on with a `/`.
    static let within = #"/[^\s"“”'‘’()\[\],;:]*(?: [^\s"“”'‘’()\[\],;:/~][^\s"“”'‘’()\[\],;:/]*/[^\s"“”'‘’()\[\],;:]*)*"#
    /// Locations that name no one's work. Anything else, such as `~/src/…` or `/Volumes/…`, becomes `<folder>`.
    /// `~/.claude` and temporary folders are not among them: Claude Code names its folders there after the project's path.
    static let safePaths = [
        "~/Library", "~/Applications", "/Applications", "/Library", "/System", "/usr", "/bin", "/sbin",
        "/opt/homebrew", "/dev",
    ]
    /// iCloud Drive and cloud storage folders hold the user's own files even though they live in ~/Library.
    static let syncedFolder =
        #"~/Library/(?:Mobile Documents|CloudStorage)(?:/[^\s"“”'‘’()\[\],;]*(?: [^\s"“”'‘’()\[\],;/~][^\s"“”'‘’()\[\],;/]*/[^\s"“”'‘’()\[\],;]*)*)?"#

    /// `name` as a whole word, never inside a placeholder such as `<profile-1>`.
    private static func word(_ name: String) -> String {
        #"(?<![\p{L}\p{N}_<])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}_>])"#
    }

    private static func replace(_ pattern: String, in text: String, with replacement: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = "", last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound] + replacement(String(text[range]))
            last = range.upperBound
        }
        return result + text[last...]
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        count > suffix.count && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
