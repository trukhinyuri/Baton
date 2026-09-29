import Foundation

/// Claude Desktop sometimes continues a session by starting a new one itself: the new transcript opens with the
/// old conversation (its records keep their ids) and the sidebar card lists the old id in `priorCliSessionIds`.
/// That copy keeps only the conversation. Sub-agent transcripts, Workflow runs, long tool outputs, the scratchpad
/// and background task output stay under the old id, so the new session can't open or resume them.
///
/// This carries them over. It adds only files the new session doesn't have, never overwrites one, and only reads
/// the old session. Files the old session made after the copy are its own and stay there.
///
/// File checkpoints are not carried: the new transcript has no snapshot records that point at them, and Claude
/// Code writes the new session's own checkpoints under the same names. Rewind to a point before the copy works
/// only in the old session, whose checkpoints are left as they are.
public enum NativeForkCarry {
    public struct Lineage: Hashable, Sendable, Codable {
        public var old: String
        public var new: String
        public init(old: String, new: String) { self.old = old; self.new = new }
    }

    public struct Report: Equatable, Sendable {
        public var lineage: Lineage
        /// Files added to the new session, relative to `~/.claude` (`projects/…`) or to Claude Code's temp folder (`tmp/…`).
        public var added: [String] = []
        /// Files the new session already had; left exactly as they were.
        public var kept = 0
        /// Scratchpad and task files not copied: over 1 MB, not text, or past the 20 MB total.
        public var leftBehind: [String] = []
        /// Git worktrees and repositories inside the old scratchpad. They are not copied; `git worktree move` keeps them.
        public var worktrees: [String] = []

        public var changes: Int { added.count }
    }

    static let maxFileSize = 1 << 20
    static let maxScratchTotal = 20 << 20
    /// Build output and repositories: large, regenerable, or owned by git.
    static let skippedFolders: Set<String> = [".build", "build", ".git", "node_modules", "DerivedData", ".swiftpm"]
    /// A scratchpad folder with more files than this is build output, an unpacked app or a copy of a repository.
    static let maxNotesPerFolder = 200
    /// A scratchpad folder with one of these at its top is a copy of a project, not notes.
    static let projectManifests: Set<String> = [
        "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml",
        "pom.xml", "build.gradle", "CMakeLists.txt", "Makefile",
    ]
    /// A file made up to this long after the new transcript still counts as made before the copy.
    static let clockSlack: TimeInterval = 60

    // MARK: Finding copies

    /// Every (old, new) pair that a card in one of `dataDirs` names, with both transcripts on this Mac.
    public static func candidates(dataDirs: [URL], transcripts: [String: URL], cache: ScanCache = .shared) -> [Lineage] {
        var found: Set<Lineage> = []
        for dataDir in dataDirs {
            for card in cards(in: dataDir.appending(path: SessionSync.sessionsFolder, directoryHint: .isDirectory)) {
                // What the sync keeps of each card, read once for both while the file stays the same.
                guard let facts = (try? SessionSync.read(card, cache: cache))?.facts, let new = facts.transcript, transcripts[new] != nil
                else { continue }
                for old in facts.priors where old != new && transcripts[old] != nil {
                    found.insert(Lineage(old: old, new: new))
                }
            }
        }
        return found.sorted { ($0.new, $0.old) < ($1.new, $1.old) }
    }

    /// Whether `new` starts with `old`'s conversation: the first records that carry a message in `new` have ids
    /// that `old` has too. A session started over with `/clear` shares none.
    static func continues(_ new: URL, from old: URL) -> Bool? {
        let head = messageIDs(in: new, limit: 20)
        guard !head.isEmpty, let history = try? Data(contentsOf: old, options: .mappedIfSafe) else { return nil }
        let shared = head.filter { history.range(of: Data(#""uuid":"\#($0)""#.utf8)) != nil }.count
        return shared >= min(3, head.count) && Double(shared) >= 0.9 * Double(head.count)
    }

    /// The `uuid` of the first `limit` user, assistant, system and attachment records.
    static func messageIDs(in transcript: URL, limit: Int) -> [String] {
        guard let data = try? Data(contentsOf: transcript, options: .mappedIfSafe) else { return [] }
        var ids: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where ids.count < limit {
            let uuid = autoreleasepool { () -> String? in
                guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let type = record["type"] as? String, ["user", "assistant", "system", "attachment"].contains(type)
                else { return nil }
                return record["uuid"] as? String
            }
            if let uuid { ids.append(uuid) }
        }
        return ids
    }

    // MARK: Carrying

    /// Carries what the old sessions left behind into every session Claude Desktop copied itself.
    /// Pairs found unrelated, and pairs with nothing left to carry once the copy is older than `clockSlack`, are
    /// remembered and not read again: from then on nothing the old session makes counts, so an idle run walks no
    /// session folder or scratchpad.
    public static func run(paths: Paths, dataDirs: [URL], dryRun: Bool = false, now: Date = Date()) throws -> [Report] {
        let transcripts = ConversationIndex.transcriptFiles(in: paths.claudeProjectsDir)
        var manifest = Manifest.load(paths.carriedFile)
        var changed = false
        var reports: [Report] = []
        func settle(_ lineage: Lineage, _ plan: Plan) {
            guard !dryRun, plan.madeBy < now else { return }
            manifest.settled = (manifest.settled ?? []).union([lineage])
            changed = true
        }
        for lineage in candidates(dataDirs: dataDirs, transcripts: transcripts)
        where !manifest.unrelated.contains(lineage) && manifest.settled?.contains(lineage) != true {
            guard let old = transcripts[lineage.old], let new = transcripts[lineage.new] else { continue }
            let plan = self.plan(lineage, old: old, new: new, paths: paths)
            guard !plan.copies.isEmpty else { settle(lineage, plan); continue }
            switch continues(new, from: old) {
            case true?: break
            case false?:
                if messageIDs(in: new, limit: 5).count == 5 { manifest.unrelated.insert(lineage); changed = true }
                continue
            case nil: continue
            }
            var report = Report(lineage: lineage, kept: plan.kept, leftBehind: plan.leftBehind, worktrees: plan.worktrees)
            if !dryRun {
                for copy in plan.copies {
                    if try place(copy, lineage: lineage) { report.added.append(copy.name) }
                }
                report.kept += plan.copies.count - report.added.count
                if !report.added.isEmpty {
                    manifest.carried.append(.init(lineage: lineage, at: Date(), files: report.added))
                    changed = true
                }
                // Every file planned is in the new session now.
                settle(lineage, plan)
            } else {
                report.added = plan.copies.map { $0.name }
            }
            reports.append(report)
        }
        if changed && !dryRun { try manifest.save(paths.carriedFile) }
        return reports
    }

    struct Copy: Equatable {
        var source: URL
        var target: URL
        /// Shown to the user and kept in the manifest.
        var name: String
        /// A sub-agent transcript: its records get the new session id, the way `TranscriptFork` rewrites one.
        var rewritesIDs: Bool
    }

    struct Plan {
        var copies: [Copy] = []
        var kept = 0
        var leftBehind: [String] = []
        var worktrees: [String] = []
        /// What the old session made up to this time is carried; what it made later stays its own.
        var madeBy: Date = .distantFuture
    }

    static func plan(_ lineage: Lineage, old: URL, new: URL, paths: Paths) -> Plan {
        var plan = Plan()
        let forkedAt = created(new).map { $0.addingTimeInterval(clockSlack) } ?? .distantFuture
        plan.madeBy = forkedAt
        let oldFolder = old.deletingPathExtension(), newFolder = new.deletingPathExtension()
        let project = new.deletingLastPathComponent().lastPathComponent
        for kind in ["subagents", "workflows", "tool-results"] {
            let root = oldFolder.appending(path: kind, directoryHint: .isDirectory)
            for relative in files(under: root) {
                let source = root.appending(path: relative)
                guard (created(source) ?? .distantPast) <= forkedAt else { continue }
                let target = newFolder.appending(path: "\(kind)/\(relative)")
                if FileManager.default.fileExists(atPath: target.path) { plan.kept += 1; continue }
                plan.copies.append(
                    Copy(
                        source: source, target: target, name: "projects/\(project)/\(lineage.new)/\(kind)/\(relative)",
                        rewritesIDs: rewritesIDs("\(kind)/\(relative)")))
            }
        }
        scratchPlan(
            oldProject: old.deletingLastPathComponent().lastPathComponent, project: project, lineage: lineage,
            tempDir: paths.claudeTempDir, madeBy: forkedAt, into: &plan)
        return plan
    }

    /// Whether a file in a session's folder (`subagents/…`, `workflows/…`, `tool-results/…`) gets the new session
    /// id in a copy. Only sub-agent transcripts do, the way the main transcript does. Workflow journals key their
    /// entries by hashes of prompts that name the session's own paths, so Workflow state, journals and scripts
    /// are copied byte for byte: rewriting an id there would make Workflow resume miss its results.
    static func rewritesIDs(_ relative: String) -> Bool {
        let name = (relative as NSString).lastPathComponent
        return relative.hasPrefix("subagents/") && name.hasPrefix("agent-") && name.hasSuffix(".jsonl")
    }

    /// The old session's scratchpad notes and task output, planned into the new session's scratchpad under
    /// `from-<old id>`: text files up to 1 MB each and 20 MB in all, made by `madeBy`. Folders of builds, project
    /// copies and folders of more than 200 files stay behind and are listed; git worktrees are listed, never copied.
    static func scratchPlan(oldProject: String, project: String, lineage: Lineage, tempDir: URL, madeBy: Date, into plan: inout Plan) {
        let oldTemp = tempDir.appending(path: "\(oldProject)/\(lineage.old)", directoryHint: .isDirectory)
        let into = "\(project)/\(lineage.new)/scratchpad/from-\(lineage.old.prefix(8))"
        var total = 0
        for kind in ["scratchpad", "tasks"] {
            let root = oldTemp.appending(path: kind, directoryHint: .isDirectory)
            plan.worktrees += repositories(under: root).map { root.appending(path: $0).path }
            let (notes, bulky) = scratchFiles(under: root)
            plan.leftBehind += bulky.map { "\(kind)/\($0)" }
            for relative in notes {
                let source = root.appending(path: relative)
                let name = "tmp/\(into)/\(kind == "tasks" ? "tasks/" : "")\(relative)"
                let target = tempDir.appending(path: String(name.dropFirst(4)))
                if FileManager.default.fileExists(atPath: target.path) { plan.kept += 1; continue }
                guard (created(source) ?? .distantPast) <= madeBy else { continue }
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                guard size <= maxFileSize, total + size <= maxScratchTotal, isText(source) else {
                    plan.leftBehind.append("\(kind)/\(relative)"); continue
                }
                total += size
                plan.copies.append(Copy(source: source, target: target, name: name, rewritesIDs: false))
            }
        }
    }

    /// Adds one file; `false` if the new session made one with that name first.
    static func place(_ copy: Copy, lineage: Lineage) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: copy.target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard copy.rewritesIDs else {
            do { try fm.copyItem(at: copy.source, to: copy.target); return true } catch  where fm.fileExists(atPath: copy.target.path) { return false }
        }
        let data = TranscriptFork.replacing(
            lineage.old, with: lineage.new,
            in: TranscriptFork.completeRecords(try Data(contentsOf: copy.source)))
        let temporary = copy.target.deletingLastPathComponent().appending(path: ".\(copy.target.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: copy.target.path])
        }
        do { try fm.moveItem(at: temporary, to: copy.target); return true }  // never replaces an existing file
        catch {
            try? fm.removeItem(at: temporary)
            if fm.fileExists(atPath: copy.target.path) { return false }
            throw error
        }
    }

    // MARK: Files

    static func cards(in sessions: URL) -> [URL] {
        let fm = FileManager.default
        var cards: [URL] = []
        for account in (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                cards += ((try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
            }
        }
        return cards
    }

    /// Regular files under `root`, as paths relative to it, sorted; hidden temporaries are skipped.
    static func files(under root: URL, skippingRepositories: Bool = false) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) else { return [] }
        let base = root.standardizedFileURL.path + "/"
        var found: [String] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skippingRepositories && (skippedFolders.contains(url.lastPathComponent) || isRepository(url)) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, !url.lastPathComponent.hasSuffix(".tmp") else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base) { found.append(String(path.dropFirst(base.count))) }
        }
        return found.sorted()
    }

    /// The scratchpad's own notes: its top-level files first, then the files of each folder that holds notes rather
    /// than a project copy or build output. Other folders come back separately, as `name/ (N files)`, so the report
    /// can say what stayed.
    static func scratchFiles(under root: URL) -> (notes: [String], bulky: [String]) {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var top: [String] = [], nested: [String] = [], bulky: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                if (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, !name.hasSuffix(".tmp") { top.append(name) }
                continue
            }
            if skippedFolders.contains(name) || isRepository(entry) { continue }
            let inside = files(under: entry, skippingRepositories: true)
            let isProject = projectManifests.contains { fm.fileExists(atPath: entry.appending(path: $0).path) }
            if isProject || inside.count > maxNotesPerFolder { bulky.append("\(name)/ (\(inside.count) files)"); continue }
            nested += inside.map { "\(name)/\($0)" }
        }
        return (top + nested, bulky)
    }

    /// Folders under `root` that hold a git checkout or worktree (`.git` is a folder or, for a worktree, a file).
    static func repositories(under root: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let base = root.standardizedFileURL.path + "/"
        var found: [String] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if isRepository(url) {
                found.append(String(url.standardizedFileURL.path.dropFirst(base.count)))
                walker.skipDescendants()
            } else if skippedFolders.contains(url.lastPathComponent) {
                walker.skipDescendants()
            }
        }
        return found.sorted()
    }

    static func isRepository(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: ".git").path)
    }

    /// Text if its first 8 KB decode as UTF-8 and hold no NUL byte.
    static func isText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        if head.contains(0) { return false }
        if String(data: head, encoding: .utf8) != nil { return true }
        // A multi-byte character cut at the 8 KB boundary is still text.
        return (1...3).contains { String(data: head.dropLast($0), encoding: .utf8) != nil }
    }

    static func created(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    // MARK: Manifest

    /// `carried.json`: what was added to which session, so each carried file can be found and removed by hand;
    /// and the pairs found unrelated or with nothing left to carry, so they are not read again.
    struct Manifest: Codable {
        struct Entry: Codable, Equatable {
            var lineage: Lineage
            var at: Date
            var files: [String]
        }
        var version = 1
        var carried: [Entry] = []
        var unrelated: Set<Lineage> = []
        /// Missing in files written before it, which read as none.
        var settled: Set<Lineage>?

        static func load(_ url: URL) -> Manifest {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Manifest.self, from: $0) } ?? Manifest()
        }

        func save(_ url: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TranscriptFork.write(try encoder.encode(self), to: url)
        }
    }
}
