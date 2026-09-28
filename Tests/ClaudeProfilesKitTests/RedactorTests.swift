import Foundation
import Testing
@testable import ClaudeProfilesKit

/// Fails a test when anything that identifies the user or their work is left in text meant for a public issue.
enum LeakScanner {
    /// The shapes from the report spec: emails, UUIDs and anything that looks like a token or key.
    static let patterns = [
        #"[\p{L}\p{N}._%+-]+[@＠][\p{L}\p{N}-]+(?:[.．][\p{L}\p{N}-]+)+"#,
        #"[0-9a-fA-F０-９ａ-ｆＡ-Ｆ]{8}-[0-9a-fA-F０-９ａ-ｆＡ-Ｆ]{4}-[0-9a-fA-F０-９ａ-ｆＡ-Ｆ]{4}-[0-9a-fA-F０-９ａ-ｆＡ-Ｆ]{4}-[0-9a-fA-F０-９ａ-ｆＡ-Ｆ]{12}"#,
        #"sk-[A-Za-z0-9_-]{16,}"#,
        #"(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{20,}"#,
        #"(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{32,}"#,
    ]

    /// Every pattern match and every secret found in `text`, compared without case.
    static func leaks(in text: String, secrets: [String]) -> [String] {
        var found = secrets.filter { !$0.isEmpty && text.range(of: $0, options: [.caseInsensitive]) != nil }
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                found.append(String(text[Range(match.range, in: text)!]))
            }
        }
        return found
    }
}

/// A Mac shaped like a real one: a home named after its user, two profiles with emails, account and organization
/// UUIDs, cards whose folders are gone, titled sessions, and errors and log lines that echo all of it back.
struct LeakFixture {
    let root: URL
    let paths: Paths
    let user = "robin.k"
    static let accountMain = "5c1e8a42-9d3b-4f7a-b2c6-0e4d8f1a3b57"
    static let accountWork = "a7f3c2d1-6b8e-4c9a-8d2f-3e1b5a7c9d04"
    static let org = "e2b4d6f8-1a3c-4e5f-9b7d-2c4e6a8b0d13"
    static let emails = ["robin@acme-corp.example", "lab.robin@research.example.org"]
    static let labels = ["ZEPHYR", "ЛАБА"]
    static let ids = ["zephyr", "laba"]
    static let title = "Acquire Initech quietly"
    static let folder = "secret-merger-plans"
    static let token = "sk-ant-api03-Xk29fLq8Zm3Rp7Tn4Vb6Wc1Yd5He0Jg2Kx8Ls4Mq"
    var home: String { paths.home.path }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "leak-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = root.appending(path: "Users/\(user)", directoryHint: .isDirectory)
        paths = Paths(home: home, claudeApp: root.appending(path: "Applications/Claude.app"))
        let fm = FileManager.default
        try ProfileRegistry(paths: paths).save(zip(Self.ids, zip(Self.labels, Self.emails)).map {
            Profile(id: $0.0, label: $0.1.0, email: $0.1.1, color: "#1971C2")
        })
        for (dir, account) in [(paths.mainDataDir, Self.accountMain), (paths.dataDir(for: "zephyr"), Self.accountWork)] {
            let cards = dir.appending(path: "claude-code-sessions/\(account)/\(Self.org)", directoryHint: .isDirectory)
            try fm.createDirectory(at: cards, withIntermediateDirectories: true)
            try Data("{\"lastKnownAccountUuid\":\"\(account)\"}".utf8).write(to: dir.appending(path: "config.json"))
            let card = ["title": Self.title, "cwd": home.appending(path: "src/\(Self.folder)").path, "sessionId": UUID().uuidString.lowercased()]
            try JSONSerialization.data(withJSONObject: card).write(to: cards.appending(path: "local_\(UUID().uuidString.lowercased()).json"))
        }
        try fm.createDirectory(at: paths.dataDir(for: "laba"), withIntermediateDirectories: true)
    }

    /// Errors as the UI showed them, and log lines as the app wrote them.
    var errors: [String] {
        ["Can’t read \(home)/src/\(Self.folder)/.claude: permission denied",
         "Claude ZEPHYR is signed in as \(Self.emails[0]), expected \(Self.emails[1])",
         "Opening /Volumes/Backup/Users/\(user)/\(Self.folder) failed with token \(Self.token)"]
    }
    var log: [String] {
        ["sync: account \(Self.accountWork) org \(Self.org) in \(paths.dataDir(for: "zephyr").path)",
         "continue: “\(Self.title)” to ЛАБА from \(home)/src/\(Self.folder)",
         "open: Claude laba for \(Self.emails[1])"]
    }
    var secrets: [String] {
        Self.emails + [Self.accountMain, Self.accountWork, Self.org, Self.title, Self.folder, Self.token, home, user]
            + Self.labels + Self.ids.map { "Claude \($0)" } + Self.ids.map { "Profiles/\($0)" }
    }
}

@Suite("Redacting a problem report")
struct RedactorTests {
    private func redactor(home: String = "/Users/robin.k", user: String = "robin.k", profiles: [[String]] = []) -> Redactor {
        Redactor(home: home, user: user, profiles: profiles)
    }

    @Test func emailsGetStableOrdinalsInFirstSeenOrder() {
        var r = redactor()
        #expect(r.redact("Signed in as robin@family.example, expected yuri@example.org; again robin@family.example.")
                == "Signed in as <email-1>, expected <email-2>; again <email-1>.")
        #expect(r.redact("ROBIN@FAMILY.EXAMPLE") == "<email-1>")
    }

    @Test func emailInsideAPathIsCaught() {
        var r = redactor()
        let out = r.redact("/Users/robin.k/Library/Mail/robin@family.example/INBOX.mbox")
        #expect(!out.contains("family.example"))
        #expect(out.hasPrefix("~/Library/Mail/<email-1>/"))
    }

    @Test func uuidInsideAFilenameKeepsTheFilenameShape() throws {
        var r = redactor()
        let out = r.redact("local_87e03916-1234-4abc-9def-0123456789ab.json")
        #expect(out.range(of: #"^local_<id-[0-9a-f]{8}>\.json$"#, options: .regularExpression) != nil, "\(out)")
    }

    @Test func uuidHashIsStableWithinAReportAndFreshAcrossReports() {
        let uuid = "87E03916-1234-4ABC-9DEF-0123456789AB"
        var first = redactor(), second = redactor()
        let a = first.redact(uuid), b = first.redact(uuid.lowercased()), c = second.redact(uuid)
        #expect(a == b)
        #expect(a != c)
        #expect(!a.localizedCaseInsensitiveContains("87e03916"))
    }

    @Test func nonASCIIHomeCollapsesToTilde() {
        var cyrillic = redactor(home: "/Users/Юрий", user: "Юрий")
        #expect(cyrillic.redact("Can’t read /Users/Юрий/Library/Application Support/Claude/config.json")
                == "Can’t read ~/Library/Application Support/Claude/config.json")
        // Decomposed input (as some file APIs return it) still matches.
        var cjk = redactor(home: "/Users/名前", user: "名前")
        #expect(cjk.redact("/Users/名前/Library/Logs") == "~/Library/Logs")
        #expect(cyrillic.redact("/Users/Юрий/Library".decomposedStringWithCanonicalMapping) == "~/Library")
        #expect(cyrillic.redact("/Users/Юрийx/Library").contains("<folder>"))
    }

    @Test func unicodeTextThatIsNotATargetPassesUnchanged() {
        var r = redactor(profiles: [["ZEPHYR", "zephyr"]])
        for text in ["Аккаунт 🚀 готов", "名前のフォルダ", "Ünïcödé — «quotes» · ✓", "working folders are missing", "ZEPHYRS and zephyrlike"] {
            #expect(r.redact(text) == text)
        }
    }

    @Test func existingPlaceholdersAreNotProcessedAgain() {
        var r = redactor(home: "/Users/user", user: "user", profiles: [["PROFILE", "profile"], ["EMAIL"]])
        let text = "~ and ~/Library, <email-1>, <profile-2>, <user>, <id-0a1b2c3d>, <token>, <folder>"
        #expect(r.redact(text) == text)
    }

    @Test func missingFolderIssueShipsWithoutItsPaths() throws {
        let box = try LeakFixture()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let facts = FeedbackReport.Facts.collect(paths: box.paths, errors: [], log: [])
        #expect(facts.diagnostics.contains { !$0.missingFolders.isEmpty })
        let report = FeedbackReport(facts: facts)
        #expect(report.markdown.contains("1 working folders are missing"))
        #expect(report.markdown.contains("1 missing folders"))
        #expect(!report.markdown.contains(LeakFixture.folder))
        var r = redactor()
        #expect(r.redact("Missing: /Users/robin.k/src/secret-merger-plans") == "Missing: <folder>")
        #expect(r.redact("Missing: /Volumes/Ext/Users/robin.k/acme") == "Missing: <folder>")
    }

    @Test func tokenShapedStringsAreStripped() {
        var r = redactor()
        let tokens = ["sk-ant-api03-Xk29fLq8Zm3Rp7Tn4Vb6Wc1Yd5He0Jg2Kx8Ls4Mq", "ghp_16C7e42F292c6912E7710c838347Ae178B4a",
                      "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz", "0123456789abcdef0123456789abcdef01234567",
                      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"]
        for token in tokens {
            let out = r.redact("Authorization: Bearer \(token) end")
            #expect(out == "Authorization: Bearer <token> end", "\(token) → \(out)")
        }
        #expect(r.redact("claude-code-sessions local-agent-mode-sessions") == "claude-code-sessions local-agent-mode-sessions")
    }

    @Test func quotedTitlesAreDropped() {
        var r = redactor()
        #expect(r.redact("continue: “Acquire Initech quietly” to WORK") == "continue: “<quoted>” to WORK")
    }

    @Test func profileLabelsAndUsernameAreReplaced() {
        var r = redactor(profiles: [["ZEPHYR", "zephyr"], ["ЛАБА", "laba"]])
        #expect(r.redact("Claude ZEPHYR and Claude ЛАБА; Profiles/laba") == "Claude <profile-1> and Claude <profile-2>; Profiles/<profile-2>")
        #expect(r.redact("owner robin.k, not robin.kx") == "owner <user>, not robin.kx")
    }

    @Test func redactingTwiceChangesNothing() throws {
        let box = try LeakFixture()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let profiles = zip(LeakFixture.labels, LeakFixture.ids).map { [$0.0, $0.1] }
        var once = Redactor(home: box.home, user: box.user, profiles: profiles)
        let text = (box.errors + box.log).joined(separator: "\n")
        let redacted = once.redact(text)
        #expect(once.redact(redacted) == redacted)
        var fresh = Redactor(home: box.home, user: box.user, profiles: profiles)
        #expect(fresh.redact(redacted) == redacted)
    }

    @Test func reportHasNoEmailUuidHomeUserTitlesOrFolderNames() throws {
        let box = try LeakFixture()
        defer { try? FileManager.default.removeItem(at: box.root) }
        let facts = FeedbackReport.Facts.collect(paths: box.paths, user: box.user, errors: box.errors, log: box.log)
        let report = FeedbackReport(facts: facts)
        #expect(report.markdown.hasPrefix(facts.build.description))
        #expect(report.markdown.contains("3 windows"))
        let leaks = LeakScanner.leaks(in: report.markdown, secrets: box.secrets)
        #expect(leaks.isEmpty, "Leaked: \(leaks)\n\n\(report.markdown)")
        // The scanner's own patterns catch the fixture's shapes before redaction, so an empty result means something.
        let shapes = LeakScanner.leaks(in: (box.errors + box.log).joined(separator: "\n"), secrets: [])
        #expect(Set(shapes).isSuperset(of: [LeakFixture.emails[0], LeakFixture.emails[1], LeakFixture.accountWork, LeakFixture.org, LeakFixture.token]))
    }
}
