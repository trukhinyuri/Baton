import Foundation

/// The text of a "Report a problem" issue: facts about this Mac and its windows that the app already has, run
/// through `Redactor`. Session titles, transcripts, card contents, emails and folder paths never go in; folders
/// travel only as counts. Nothing is sent: the user copies it, saves it or opens a prefilled GitHub form.
public struct FeedbackReport: Sendable {
    public struct Window: Sendable, Equatable {
        public var id: String
        public var label: String
        public var isMain: Bool
        public var isRunning: Bool
        public var isSignedIn: Bool
        /// Newest Claude Code Claude Desktop downloaded for this window (`<data>/claude-code/<version>`).
        public var claudeCodeVersion: String?
        /// Whether cloud features are switched off in this window, or wait for it to close; `nil` when this build can't tell.
        public var localOnly: LocalOnly.Status?

        public init(
            id: String, label: String, isMain: Bool, isRunning: Bool, isSignedIn: Bool,
            claudeCodeVersion: String? = nil, localOnly: LocalOnly.Status? = nil
        ) {
            self.id = id; self.label = label; self.isMain = isMain; self.isRunning = isRunning
            self.isSignedIn = isSignedIn; self.claudeCodeVersion = claudeCodeVersion; self.localOnly = localOnly
        }
    }

    /// Everything the report is made from, before redaction.
    public struct Facts: Sendable {
        public var build: BuildInfo
        public var macOS: String
        public var architecture: String
        public var claudeVersion: String?
        public var windows: [Window]
        public var diagnostics: [Diagnostics.Entry]
        public var lastSync: SyncReport?
        public var lastSyncDate: Date?
        /// Errors and warnings as the UI or CLI showed them, newest last.
        public var errors: [String]
        /// This app's own log lines, oldest first.
        public var log: [String]
        /// Used only to redact.
        public var home: String
        public var user: String
        public var profiles: [[String]]
        /// Folder rules' folders and the missing working folders, hidden by name (see `Redactor`).
        public var folders: [String]

        public init(
            build: BuildInfo, macOS: String, architecture: String, claudeVersion: String?, windows: [Window],
            diagnostics: [Diagnostics.Entry], lastSync: SyncReport?, lastSyncDate: Date?, errors: [String],
            log: [String], home: String, user: String, profiles: [[String]], folders: [String] = []
        ) {
            self.build = build; self.macOS = macOS; self.architecture = architecture; self.claudeVersion = claudeVersion
            self.windows = windows; self.diagnostics = diagnostics; self.lastSync = lastSync; self.lastSyncDate = lastSyncDate
            self.errors = errors; self.log = log; self.home = home; self.user = user; self.profiles = profiles
            self.folders = folders
        }

        /// Reads only what the app already shows: window states, the sessions check and version numbers.
        public static func collect(
            paths: Paths, user: String = NSUserName(), errors: [String] = [], log: [String] = [],
            lastSync: SyncReport? = nil, lastSyncDate: Date? = nil,
            localOnly: [String: LocalOnly.Status] = [:]
        ) -> Facts {
            let manager = ProfileManager(paths: paths)
            let profiles = manager.profiles
            var errors = errors
            if let problem = manager.registryError { errors.insert(problem, at: 0) }
            let windows = manager.statuses().map { status in
                Window(
                    id: status.id, label: status.label, isMain: status.isMain, isRunning: status.isRunning,
                    isSignedIn: status.isSignedIn,
                    claudeCodeVersion: FeedbackReport.claudeCodeVersion(in: status.isMain ? paths.mainDataDir : paths.dataDir(for: status.id)),
                    localOnly: localOnly[status.id])
            }
            var diagnostics: [Diagnostics.Entry] = []
            do { diagnostics = try Diagnostics.inspect(paths: paths) } catch {
                errors.append("The sessions check could not run: \(error.localizedDescription)")
            }
            return Facts(
                build: .current, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: FeedbackReport.architecture, claudeVersion: FeedbackReport.shortVersion(of: paths.claudeApp),
                windows: windows, diagnostics: diagnostics, lastSync: lastSync, lastSyncDate: lastSyncDate,
                errors: errors, log: log, home: paths.home.path, user: user,
                profiles: profiles.map { [$0.label, $0.id] },
                folders: ((try? FolderRules(paths: paths).load()) ?? []).map(\.folder) + diagnostics.flatMap(\.missingFolders))
        }
    }

    /// Redacted Markdown. Its first line is `BuildInfo.description`.
    public let markdown: String
    /// A few lines for the issue URL when the whole report is too long for it.
    public let summary: String

    public init(facts: Facts, salt: [UInt8]? = nil) {
        var redactor = Redactor(home: facts.home, user: facts.user, profiles: facts.profiles, folders: facts.folders, salt: salt)
        func r(_ text: String) -> String { redactor.redact(text) }
        let names = Dictionary(facts.windows.map { ($0.id, $0.isMain ? "MAIN" : r($0.label)) }, uniquingKeysWith: { a, _ in a })

        var head = [facts.build.description, ""]
        head.append("### Environment")
        head.append("- macOS \(r(facts.macOS)), \(facts.architecture)")
        head.append("- Claude Desktop \(facts.claudeVersion ?? "not found")")
        let running = facts.windows.filter(\.isRunning).count, signedIn = facts.windows.filter(\.isSignedIn).count
        head.append("- \(facts.windows.count) windows: \(running) open, \(signedIn) signed in")
        var lines = head
        lines.append("")
        lines.append("### Windows")
        for window in facts.windows {
            let local = window.localOnly.map(Self.describe) ?? "Local only unknown"
            lines.append(
                "- \(names[window.id] ?? "?"): \(window.isRunning ? "open" : "closed"), "
                    + "\(window.isSignedIn ? "signed in" : "not signed in"), "
                    + "Claude Code \(window.claudeCodeVersion ?? "not downloaded"), \(local)")
        }
        lines.append("")
        lines.append("### Sessions check")
        if facts.diagnostics.isEmpty { lines.append("- not run") }
        for entry in facts.diagnostics {
            let name = entry.id == "main" ? "MAIN" : names[entry.id] ?? r(entry.label)
            lines.append(
                "- \(name): \(entry.localCode) local Code, \(entry.localCowork) Cowork, "
                    + "\(entry.unavailableCoworkHistory) without history, \(entry.accountBoundWorkers) account-linked, "
                    + "\(entry.ambiguousWorkers) ambiguous, \(entry.missingFolders.count) missing folders")
            for issue in entry.issues { lines.append("  - \(r(issue))") }
        }
        lines.append("")
        lines.append("### Last sync")
        if let sync = facts.lastSync {
            let when = facts.lastSyncDate.map { " (\(relativeAge(since: $0)))" } ?? ""
            lines.append(
                "- \(sync.sessions.pairs) session folders, \(sync.sessions.cardsWritten) cards copied, "
                    + "\(sync.sessions.cardsRemoved) removed, \(sync.sessions.tombstonesWritten) deletions shared\(when)")
            lines.append(
                "- \(sync.cowork.pairs) Cowork folders checked, "
                    + "\(sync.sessions.accountBoundCards + sync.cowork.accountBoundCards) account-linked, "
                    + "\(sync.sessions.ambiguousAccountBoundCards + sync.cowork.ambiguousAccountBoundCards) ambiguous")
        } else {
            lines.append("- not recorded in this run")
        }
        lines.append("")
        lines.append("### Recent errors")
        let errors = facts.errors.suffix(20).map(r)
        lines.append(contentsOf: errors.isEmpty ? ["- none"] : errors.map { "- " + $0 })
        lines.append("")
        lines.append("### Log (last \(min(facts.log.count, Self.logLimit)) entries)")
        lines.append("```")
        lines.append(contentsOf: facts.log.suffix(Self.logLimit).map { r($0).replacingOccurrences(of: "```", with: "'''") })
        lines.append("```")
        markdown = lines.joined(separator: "\n") + "\n"
        summary =
            (head + ["", "### Recent errors"] + (errors.isEmpty ? ["- none"] : errors.suffix(3).map { "- " + $0 }))
            .joined(separator: "\n") + "\n"
    }

    public static let logLimit = 200

    // MARK: Sharing

    /// Where issues go. One place, so a renamed project changes only this.
    public static let repository = "trukhinyuri/Baton"
    /// GitHub answers 414 to a long link; about 6,000 URL-encoded characters of body are safe.
    public static let urlBodyLimit = 6_000

    /// The report followed by the user's own words, which are shown and sent exactly as typed.
    public func document(description: String) -> String {
        let words = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return markdown }
        return markdown + "\n### What happened (written by the user, not redacted)\n" + words + "\n"
    }

    public struct IssueLink: Sendable, Equatable {
        public var url: URL
        /// `false` when the link carries only the summary and the full report has to be attached.
        public var isComplete: Bool
    }

    /// A prefilled "new issue" form. GitHub's issue *forms* (this repository's `bug_report.yml`) prefill by field
    /// id, not by a single `body`: each of `diagnostics` and `what-happened` fills its own textarea. Opening the
    /// link sends nothing: the user reviews both fields on GitHub and submits it themselves.
    /// - Parameter attachment: the file name to mention when the report is too long for the link.
    public func issueLink(title: String, description: String, attachment: String? = nil) -> IssueLink {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        func link(diagnostics: String, whatHappened: String) -> URL {
            let query = [
                ("template", "bug_report.yml"), ("title", title.isEmpty ? "Problem report" : title),
                ("diagnostics", diagnostics), ("what-happened", whatHappened),
            ]
            .map { "\($0)=\(Self.encode($1))" }.joined(separator: "&")
            return URL(string: "https://github.com/\(Self.repository)/issues/new?\(query)")!
        }
        func encodedLength(_ diagnostics: String, _ whatHappened: String) -> Int {
            Self.encode(diagnostics).count + Self.encode(whatHappened).count
        }
        let words = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let whatHappened = words.isEmpty ? "(not described; see diagnostics below)" : words
        if encodedLength(markdown, whatHappened) <= Self.urlBodyLimit {
            return IssueLink(url: link(diagnostics: markdown, whatHappened: whatHappened), isComplete: true)
        }
        let note =
            summary + "\n\nThe full report is too long for this form. It is on the clipboard and saved as "
            + "\(attachment.map { "“\($0)”" } ?? "a file"): attach that file here or paste it below.\n"
        var short = whatHappened
        while encodedLength(note, short) > Self.urlBodyLimit && !short.isEmpty {
            short = String(short.prefix(max(0, short.count - max(50, short.count / 4)))) + (short.count > 50 ? "…" : "")
            if short == "…" { short = "" }
        }
        if short.isEmpty { short = "(see diagnostics; full report attached separately)" }
        return IssueLink(url: link(diagnostics: note, whatHappened: short), isComplete: false)
    }

    /// Opens the issue form. A report too long for the link is also copied and saved in `folder`, for the user
    /// to attach. Nothing is uploaded: `open` hands the link to the browser.
    public func share(
        title: String, description: String, saveIn folder: URL, copy: (String) -> Void,
        open: (URL) -> Void
    ) throws -> (link: IssueLink, file: URL?) {
        var link = issueLink(title: title, description: description)
        var file: URL?
        if !link.isComplete {
            let text = document(description: description)
            let saved = try Self.save(text, in: folder)
            copy(text)
            link = issueLink(title: title, description: description, attachment: saved.lastPathComponent)
            file = saved
        }
        open(link.url)
        return (link, file)
    }

    /// Writes `text` as a new dated file in `folder`, never replacing one.
    public static func save(_ text: String, in folder: URL, now: Date = Date()) throws -> URL {
        let stamp = now.formatted(
            Date.VerbatimFormatStyle(
                format:
                    "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appending(path: "Baton report \(stamp).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "Baton report \(stamp) \(n).md"); n += 1
        }
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Percent-encodes everything but unreserved characters, so `+`, `&` and `#` survive in a query value.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))
            ?? ""
    }

    // MARK: CLI

    public enum CommandError: LocalizedError {
        case usage(String)
        public var errorDescription: String? {
            switch self {
            case .usage(let text): text
            }
        }
    }

    /// `baton report [--save PATH] [--open]`: prints the report, saves it with `--save`, and with
    /// `--open` opens the prefilled issue form (a long report is also copied and saved, in `downloads` unless
    /// `--save` says where). Returns what to print.
    public static func command(
        _ arguments: [String], paths: Paths, user: String = NSUserName(), errors: [String] = [],
        log: [String] = [], localOnly: [String: LocalOnly.Status] = [:], downloads: URL,
        copy: (String) -> Void, open: (URL) -> Void
    ) throws -> String {
        var savePath: String?
        var opens = false
        var rest = arguments.dropFirst()
        while let argument = rest.popFirst() {
            switch argument {
            case "--open": opens = true
            case "--save":
                guard let path = rest.popFirst(), !path.hasPrefix("--") else { throw CommandError.usage("--save needs a file path") }
                savePath = path
            default: throw CommandError.usage("report takes only --save PATH and --open, not “\(argument)”")
            }
        }
        let report = FeedbackReport(facts: .collect(paths: paths, user: user, errors: errors, log: log, localOnly: localOnly))
        let text = report.document(description: "")
        var lines = [text]
        var saved: URL?
        if let savePath {
            let url = URL(fileURLWithPath: (savePath as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                saved = try save(text, in: url)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
                saved = url
            }
            lines.append("Saved to \(saved!.path).")
        }
        if opens {
            var link = report.issueLink(title: "", description: "", attachment: saved?.lastPathComponent)
            if !link.isComplete {
                let file = try saved ?? save(text, in: downloads)
                copy(text)
                link = report.issueLink(title: "", description: "", attachment: file.lastPathComponent)
                lines.append("The report is too long for the link: it is on the clipboard and in \(file.path). Attach that file to the issue.")
            }
            open(link.url)
            lines.append("Opened a prefilled GitHub issue in your browser. Review it there and submit it yourself.")
        }
        lines.append("Nothing was sent.")
        return lines.joined(separator: "\n")
    }

    static var architecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }

    static func shortVersion(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// A window's Local only state as the report's window list says it. While it waits for the window to close, the
    /// user's choice is not applied yet, so it is neither on nor off.
    static func describe(_ localOnly: LocalOnly.Status) -> String {
        switch localOnly {
        case .on: "Local only on"
        case .off: "Local only off"
        case .pending: "Local only waiting for the window to close"
        case .notSupported: "Local only not available in this Claude Desktop version"
        }
    }

    /// The highest `major.minor.patch` folder name in `<data>/claude-code`.
    static func claudeCodeVersion(in dataDir: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataDir.appending(path: "claude-code").path)) ?? []
        let versions = names.compactMap { name -> (String, [Int])? in
            let parts = name.split(separator: ".").map { Int($0) }
            guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { return nil }
            return (name, parts.compactMap { $0 })
        }
        return versions.max { $0.1.lexicographicallyPrecedes($1.1) }?.0
    }
}
