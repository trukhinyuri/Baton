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
        /// Whether cloud features are switched off in this window; `nil` when this build can't tell.
        public var localOnly: Bool?

        public init(id: String, label: String, isMain: Bool, isRunning: Bool, isSignedIn: Bool,
                    claudeCodeVersion: String? = nil, localOnly: Bool? = nil) {
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

        /// Reads only what the app already shows: window states, the sessions check and version numbers.
        public static func collect(paths: Paths, user: String = NSUserName(), errors: [String] = [], log: [String] = [],
                                   lastSync: SyncReport? = nil, lastSyncDate: Date? = nil,
                                   localOnly: [String: Bool] = [:]) -> Facts {
            let manager = ProfileManager(paths: paths)
            let profiles = manager.profiles
            var errors = errors
            if let problem = manager.registryError { errors.insert(problem, at: 0) }
            let windows = manager.statuses().map { status in
                Window(id: status.id, label: status.label, isMain: status.isMain, isRunning: status.isRunning,
                       isSignedIn: status.isSignedIn,
                       claudeCodeVersion: FeedbackReport.claudeCodeVersion(in: status.isMain ? paths.mainDataDir : paths.dataDir(for: status.id)),
                       localOnly: localOnly[status.id])
            }
            var diagnostics: [Diagnostics.Entry] = []
            do { diagnostics = try Diagnostics.inspect(paths: paths) } catch {
                errors.append("The sessions check could not run: \(error.localizedDescription)")
            }
            return Facts(build: .current, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                         architecture: FeedbackReport.architecture, claudeVersion: FeedbackReport.shortVersion(of: paths.claudeApp),
                         windows: windows, diagnostics: diagnostics, lastSync: lastSync, lastSyncDate: lastSyncDate,
                         errors: errors, log: log, home: paths.home.path, user: user,
                         profiles: profiles.map { [$0.label, $0.id] })
        }
    }

    /// Redacted Markdown. Its first line is `BuildInfo.description`.
    public let markdown: String
    /// A few lines for the issue URL when the whole report is too long for it.
    public let summary: String

    public init(facts: Facts, salt: [UInt8]? = nil) {
        var redactor = Redactor(home: facts.home, user: facts.user, profiles: facts.profiles, salt: salt)
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
            let local = window.localOnly.map { $0 ? "Local only on" : "Local only off" } ?? "Local only unknown"
            lines.append("- \(names[window.id] ?? "?"): \(window.isRunning ? "open" : "closed"), "
                         + "\(window.isSignedIn ? "signed in" : "not signed in"), "
                         + "Claude Code \(window.claudeCodeVersion ?? "not downloaded"), \(local)")
        }
        lines.append("")
        lines.append("### Sessions check")
        if facts.diagnostics.isEmpty { lines.append("- not run") }
        for entry in facts.diagnostics {
            let name = entry.id == "main" ? "MAIN" : names[entry.id] ?? r(entry.label)
            lines.append("- \(name): \(entry.localCode) local Code, \(entry.localCowork) Cowork, "
                         + "\(entry.unavailableCoworkHistory) without history, \(entry.accountBoundWorkers) account-linked, "
                         + "\(entry.ambiguousWorkers) ambiguous, \(entry.missingFolders.count) missing folders")
            for issue in entry.issues { lines.append("  - \(r(issue))") }
        }
        lines.append("")
        lines.append("### Last sync")
        if let sync = facts.lastSync {
            let when = facts.lastSyncDate.map { " (\(relativeAge(since: $0)))" } ?? ""
            lines.append("- \(sync.sessions.pairs) session folders, \(sync.sessions.cardsWritten) cards copied, "
                         + "\(sync.sessions.cardsRemoved) removed, \(sync.sessions.tombstonesWritten) deletions shared\(when)")
            lines.append("- \(sync.cowork.pairs) Cowork folders checked, "
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
        summary = (head + ["", "### Recent errors"] + (errors.isEmpty ? ["- none"] : errors.suffix(3).map { "- " + $0 }))
            .joined(separator: "\n") + "\n"
    }

    public static let logLimit = 200

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
