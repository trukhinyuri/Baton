import Foundation

/// Reads only known local card metadata and selected non-secret settings. Never starts or repairs sessions.
public enum Diagnostics {
    public struct Entry: Codable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var localCode = 0
        public var localCowork = 0
        /// Legacy Cowork cards without a real history directory in a known full-ID or compact layout.
        /// A directory's presence alone does not prove that resuming its conversation will succeed.
        public var unavailableCoworkHistory = 0
        public var accountBoundWorkers = 0
        public var ambiguousWorkers = 0
        public var missingFolders: [String] = []
        public var issues: [String] = []
    }

    /// - Parameter cache: what was found in each card, kept while its file stays the same.
    public static func inspect(paths: Paths, cache: ScanCache = .shared) throws -> [Entry] {
        let profiles = try ProfileRegistry(paths: paths).load()
        let entries = [("main", "MAIN", paths.mainDataDir)] + profiles.map { ($0.id, $0.label, paths.dataDir(for: $0.id)) }
        var nativeScopes: [String: Set<String>] = [:]
        var nativeByProfile: [String: Set<String>] = [:]
        var cardScopes: [String: Set<String>] = [:]
        var records: [String: [(key: String, kind: String, hasCoworkHistory: Bool, folderProfile: String?)]] = [:]
        var scopeProblems: [String] = []
        for (kind, filename) in [
            (SessionSync.sessionsFolder, "code-native-session-scopes.json"),
            (CoworkSync.sessionsFolder, "cowork-native-session-scopes.json"),
        ] {
            do {
                let state = try SessionSync.NativeScopeState.load(from: paths.stateDir.appending(path: filename))
                for (name, scopes) in state.scopes { nativeScopes[kind + "/" + name] = Set(scopes) }
            } catch { scopeProblems.append("Saved account ownership could not be read. Synchronization needs review before continuing linked workers.") }
        }
        var reports = entries.map { id, label, directory in
            var entry = Entry(id: id, label: label)
            entry.issues = scopeProblems
            guard let account = DesktopData.accountID(in: directory) else {
                entry.issues.append("Account not available: sign in inside this profile to check its sessions.")
                return entry
            }
            let fm = FileManager.default
            var missing = Set<String>()
            for kind in [SessionSync.sessionsFolder, CoworkSync.sessionsFolder] {
                let root = directory.appending(path: "\(kind)/\(account)")
                guard fm.fileExists(atPath: root.path) else { continue }
                do {
                    for org in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                        guard try org.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                        for file in try fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.isRegularFileKey])
                        where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                            let card = try cache.value(
                                "diagnostics", of: file, cost: { $0?.cost ?? 0 }, read: { url in try autoreleasepool { try Card(Data(contentsOf: url)) } })
                            guard let card else { entry.issues.append("A session card has an unsupported format."); continue }
                            let key = kind + "/" + file.lastPathComponent
                            cardScopes[key, default: []].insert(account + "/" + org.lastPathComponent)
                            var hasCoworkHistory = true
                            var folderProfile: String?
                            if kind == CoworkSync.sessionsFolder {
                                hasCoworkHistory = Self.hasCoworkHistoryFolder(for: file)
                                if let cwd = card.cwd, cwd.hasPrefix("/") {
                                    let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
                                    folderProfile =
                                        entries.first { candidate in
                                            let root = candidate.2.standardizedFileURL.path
                                            return candidate.0 != id && (path == root || path.hasPrefix(root + "/"))
                                        }?.1
                                }
                            }
                            records[id, default: []].append((key, kind, hasCoworkHistory, folderProfile))
                            if card.accountBound || nativeScopes[key] != nil {
                                entry.accountBoundWorkers += 1
                                nativeScopes[key, default: []].insert(account + "/" + org.lastPathComponent)
                                nativeByProfile[id, default: []].insert(key)
                            } else if kind == SessionSync.sessionsFolder {
                                entry.localCode += 1
                            } else {
                                entry.localCowork += 1
                            }
                            if !card.remote, let cwd = card.cwd, cwd.hasPrefix("/"), !fm.fileExists(atPath: cwd) { missing.insert(cwd) }
                        }
                    }
                } catch { entry.issues.append("Could not completely read \(kind): \(error.localizedDescription)") }
            }
            entry.missingFolders = missing.sorted()
            if !missing.isEmpty {
                entry.issues.append("\(missing.count) working folders are missing. Use Choose folder in Claude before continuing those sessions.")
            }
            return entry
        }
        // A native marker in any copy applies to the whole ID, including older copies without that marker.
        for key in Array(nativeScopes.keys) { nativeScopes[key]?.formUnion(cardScopes[key] ?? []) }
        for i in reports.indices {
            reports[i].localCode = 0; reports[i].localCowork = 0; reports[i].accountBoundWorkers = 0
            var coworkFolderProfiles = Set<String>()
            for record in records[reports[i].id] ?? [] {
                if nativeScopes[record.key] != nil {
                    reports[i].accountBoundWorkers += 1
                    nativeByProfile[reports[i].id, default: []].insert(record.key)
                } else if record.kind == SessionSync.sessionsFolder {
                    reports[i].localCode += 1
                } else {
                    reports[i].localCowork += 1
                    if !record.hasCoworkHistory {
                        reports[i].unavailableCoworkHistory += 1
                        if let profile = record.folderProfile { coworkFolderProfiles.insert(profile) }
                    }
                }
            }
            if reports[i].unavailableCoworkHistory > 0 {
                var issue =
                    "\(reports[i].unavailableCoworkHistory) Cowork cards have no local history folder in a known layout. A visible card does not prove the conversation can resume here. Continue in the original profile, or transfer reviewed context to a new conversation."
                if !coworkFolderProfiles.isEmpty {
                    issue += " Working-folder paths refer to profiles: " + coworkFolderProfiles.sorted().joined(separator: ", ") + "."
                }
                reports[i].issues.append(issue)
            }
            reports[i].ambiguousWorkers = (nativeByProfile[reports[i].id] ?? []).filter { (nativeScopes[$0]?.count ?? 0) > 1 }.count
            if reports[i].ambiguousWorkers > 0 {
                reports[i].issues.append(
                    "\(reports[i].ambiguousWorkers) account-linked workers have copies in different accounts. These copies are not synchronized. Continue them from the original Project, or transfer reviewed context to a new conversation."
                )
            }
        }
        return reports
    }

    /// What a report reads from a card, kept instead of its bytes.
    struct Card {
        var accountBound: Bool
        var cwd: String?
        /// Its session runs on another machine over SSH.
        var remote: Bool

        /// `nil` for a card that isn't a JSON object; throws if it isn't JSON at all.
        init?(_ data: Data) throws {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            accountBound = SessionSync.isAccountBoundCard(object)
            cwd = object["cwd"] as? String
            remote = object["sshRemoteProcessId"] != nil || object["sshRemoteTranscriptPath"] != nil
        }

        var cost: Int { 48 + (cwd?.utf8.count ?? 0) }
    }

    /// Claude keeps either the full local_UUID directory or a sibling named with its first eight hex
    /// digits. Only that exact UUID layout is shortened; a link or occupied file is not a local runtime.
    private static func hasCoworkHistoryFolder(for card: URL) -> Bool {
        let full = card.deletingPathExtension()
        var candidates = [full]
        let id = full.lastPathComponent
        if id.range(
            of: #"^local_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression) != nil
        {
            candidates.append(card.deletingLastPathComponent().appending(path: String(id.dropFirst(6).prefix(8))))
        }
        return candidates.contains { directory in
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink == false
        }
    }

}
