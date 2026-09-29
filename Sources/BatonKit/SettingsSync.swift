import CryptoKit
import Darwin
import Foundation

/// Shares an explicit set of portable desktop settings before a profile starts. Account state, Projects,
/// Remote Control, Cowork grants and unknown future preferences stay with the profile. Portable settings
/// use a three-way merge: a change made only in the profile survives the next launch.
/// Sign-in data (tokens in `config.json`, cookies) is never copied.
///
/// Run it only while the profile's window is closed: Claude writes these files back when it quits.
public struct SettingsSync: Sendable {
    /// Local setup assets. Existing profile customizations are preserved at each top-level item.
    static let copied = ["Claude Extensions Settings", "claude-ssh-remote"]
    /// Claude Code builds the main app has downloaded, one folder per version. Cloning them spares a profile the download.
    static let builds = "claude-code"
    /// Scheduled task switches, which Claude turns on in a window that has tasks. Tasks are kept per account in
    /// each window's own data and never copied, so every window keeps its own switches and runs its own tasks.
    static let windowPreferences = ["ccdScheduledTasksEnabled", "coworkScheduledTasksEnabled"]
    /// Waking the Mac for scheduled tasks stays with the main app: each app copy would register its own
    /// wake helper with macOS and ask for its own approval in Login Items.
    static let mainOnlyPreferences = ["wakeSchedulerEnabled"]
    /// The only `config.json` keys copied; the rest of that file is sign-in and per-window state.
    static let appearanceKeys = ["userThemeMode", "windowControlsZoomFactor", "locale"]

    /// Deliberately opt-in: a new Claude preference must be understood before it can cross profiles.
    /// In particular, Remote Control, folder grants, browser pairing and account consent are not appearance.
    static let portablePreferences: Set<String> = [
        "keepAwakeEnabled", "dockBounceEnabled", "sidebarMode", "quickEntryDictationShortcut",
        "coworkPreferredBrowser", "ccAutoArchiveInactiveDays", "ccAutoArchiveOnPrClose",
    ]

    public let paths: Paths
    private var fm: FileManager { .default }
    /// Where builds older than the two newest go; the Trash unless a test substitutes it.
    var discard: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    public init(paths: Paths) { self.paths = paths }

    /// - Returns: how many files or folders changed.
    @discardableResult
    public func run(into dataDir: URL, now: Date = Date()) throws -> Int {
        let source = paths.mainDataDir
        let backup = Backup(paths: paths, now: now)
        guard !LocalStorage(dataDir: dataDir).isInUse else { throw LocalStorageError.databaseInUse }
        let stateURL = paths.stateDir.appending(path: "Settings/\(dataDir.lastPathComponent).json")
        var base = try Self.readBaseline(stateURL)
        var changed = 0

        changed += try mergeExtensions(into: dataDir, base: &base, backup: backup)
        for name in Self.copied {
            changed += try mergeAsset(
                source.appending(path: name), into: dataDir.appending(path: name),
                key: "asset:" + name, base: &base, backup: backup)
        }

        changed += try mergeSSH(into: dataDir, base: &base, backup: backup)

        changed += try copyBuilds(into: dataDir)

        let desktop = dataDir.appending(path: "claude_desktop_config.json")
        if let main = try Self.readExistingJSON(source.appending(path: "claude_desktop_config.json")) {
            let current = try Self.readExistingJSON(desktop) ?? [:]
            var result = current, attempt = base
            if let sourceServers = main["mcpServers"] {
                guard let servers = sourceServers as? [String: Any],
                    current["mcpServers"] == nil || current["mcpServers"] is [String: Any]
                else {
                    throw LocalStorageError.corrupt("mcpServers must contain a JSON object; the existing configuration was kept")
                }
                let ownServers = current["mcpServers"] as? [String: Any] ?? [:]
                var merged = ownServers
                for key in servers.keys.sorted() {
                    Self.sharePreservingChanges(
                        key, main: servers, own: ownServers, into: &merged,
                        base: &attempt, prefix: "mcp:")
                }
                result["mcpServers"] = merged
                // The old whole-dictionary baseline cannot establish ownership of individual servers.
                attempt.removeValue(forKey: "desktop:mcpServers")
            }
            let mainPrefs = main["preferences"] as? [String: Any] ?? [:]
            let ownPrefs = current["preferences"] as? [String: Any] ?? [:]
            var prefs = ownPrefs
            // Local only's switches belong to each window and are never shared.
            for key in Self.portablePreferences.subtracting(LocalOnly.ownedKeys) {
                Self.share(key, main: mainPrefs, own: ownPrefs, into: &prefs, base: &attempt, prefix: "preferences:")
            }
            // Scheduled tasks keep their own switches; only MAIN registers a wake helper.
            for key in Self.mainOnlyPreferences { prefs[key] = false }
            if !prefs.isEmpty || current["preferences"] != nil { result["preferences"] = prefs }
            if !NSDictionary(dictionary: result).isEqual(to: current) {
                // A linked config is written where it leads, so that file's content is what is backed up.
                if fm.fileExists(atPath: desktop.path) { _ = try backup.save(LocalOnly.writeTarget(desktop)) }
                try Self.writeJSON(result, to: desktop)
                changed += 1
            }
            base = attempt
            try InterfaceSync.writeState(base, to: stateURL)
        }
        // Tool toggles are permissions owned by each account. Never copy another account's grants or
        // replace a profile's deliberate denial with MAIN's enabled switch.
        if try copyAppearance(into: dataDir, base: &base) { changed += 1 }
        try InterfaceSync.writeState(base, to: stateURL)
        return changed
    }

    /// The registry and each installed package describe one unit. Update them together, preserving an
    /// independently installed/edited destination package and its record instead of mixing versions.
    private func mergeExtensions(into dataDir: URL, base: inout [String: String], backup: Backup) throws -> Int {
        let sourceIndex = paths.mainDataDir.appending(path: "extensions-installations.json")
        let targetIndex = dataDir.appending(path: "extensions-installations.json")
        let sourceRoot = paths.mainDataDir.appending(path: "Claude Extensions")
        let targetRoot = dataDir.appending(path: "Claude Extensions")
        guard try Self.itemType(sourceIndex) == .typeRegular,
            try Self.itemType(sourceRoot) == .typeDirectory,
            try Self.itemType(targetIndex) == nil || Self.itemType(targetIndex) == .typeRegular,
            try Self.itemType(targetRoot) == nil || Self.itemType(targetRoot) == .typeDirectory,
            let source = try Self.readExistingJSON(sourceIndex), let sourceRecords = Self.extensionRecords(source)
        else { return 0 }
        let own = try Self.readExistingJSON(targetIndex) ?? ["extensions": [:]]
        guard let ownRecords = Self.extensionRecords(own) else { return 0 }
        var merged = ownRecords, attempt = base, packages: [String: String] = [:]
        for id in sourceRecords.keys.sorted() {
            let sourcePackage = sourceRoot.appending(path: id), targetPackage = targetRoot.appending(path: id)
            guard try Self.itemType(sourcePackage) == .typeDirectory else { continue }
            let targetType = try Self.itemType(targetPackage)
            guard targetType == nil || targetType == .typeDirectory else { continue }
            let sourceHash = try Self.assetFingerprint(sourcePackage)
            let ownHash = targetType == nil ? nil : try Self.assetFingerprint(targetPackage)
            let recordHash = Self.fingerprint(sourceRecords[id]!)
            let ownRecordHash = ownRecords[id].map(Self.fingerprint)
            let assetKey = "extension-asset:" + id, recordKey = "extension-record:" + id
            let previousAsset = base[assetKey], previousRecord = base[recordKey]
            let identical = ownHash == sourceHash && ownRecordHash == recordHash
            let new = ownHash == nil && ownRecordHash == nil && previousAsset == nil && previousRecord == nil
            let unchanged = previousAsset != nil && previousRecord != nil && ownHash == previousAsset && ownRecordHash == previousRecord
            if identical || new || unchanged {
                merged[id] = sourceRecords[id]
                if ownHash != sourceHash { packages[id] = sourceHash }
                attempt[assetKey] = sourceHash; attempt[recordKey] = recordHash
            } else if previousAsset == nil && previousRecord == nil {
                // Remember an initial conflict without claiming that the target accepted this source.
                attempt[assetKey] = sourceHash; attempt[recordKey] = recordHash
            }
        }
        let recordChanges = !NSDictionary(dictionary: merged).isEqual(to: ownRecords)
        guard !packages.isEmpty || recordChanges else { base = attempt; return 0 }
        let oldRootHash = try Self.itemType(targetRoot) == nil ? nil : try Self.assetFingerprint(targetRoot)
        let oldIndexHash = try Self.itemType(targetIndex) == nil ? nil : try Self.assetFingerprint(targetIndex)
        let stage = dataDir.appending(path: ".baton-extensions-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stagedRoot = stage.appending(path: "packages"), stagedIndex = stage.appending(path: "index.json")
        var keepRecovery = false
        defer { if !keepRecovery { try? fm.removeItem(at: stage) } }
        if oldRootHash != nil {
            try fm.copyItem(at: targetRoot, to: stagedRoot)
        } else {
            try fm.createDirectory(at: stagedRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        for (id, hash) in packages {
            let stagedPackage = stagedRoot.appending(path: id)
            if try Self.itemType(stagedPackage) != nil { try fm.removeItem(at: stagedPackage) }
            try fm.copyItem(at: sourceRoot.appending(path: id), to: stagedPackage)
            guard try Self.assetFingerprint(stagedPackage) == hash else {
                throw LocalStorageError.corrupt("An extension changed during copying; existing setup was kept")
            }
        }
        try Self.writeJSON(["extensions": merged], to: stagedIndex)
        if let mode = try? fm.attributesOfItem(atPath: targetIndex.path)[.posixPermissions] {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: stagedIndex.path)
        }
        guard (try Self.itemType(targetRoot) == nil ? nil : try Self.assetFingerprint(targetRoot)) == oldRootHash,
            (try Self.itemType(targetIndex) == nil ? nil : try Self.assetFingerprint(targetIndex)) == oldIndexHash
        else {
            throw LocalStorageError.corrupt("Extension setup changed during copying; existing setup was kept")
        }
        if oldRootHash != nil { _ = try backup.save(targetRoot) }
        if oldIndexHash != nil { _ = try backup.save(targetIndex) }
        try Self.installStaged(stagedRoot, into: targetRoot, replacing: oldRootHash != nil)
        do { try Self.installStaged(stagedIndex, into: targetIndex, replacing: oldIndexHash != nil) } catch {
            // If the second rename fails, restore the original packages before reporting the error.
            let restored =
                oldRootHash != nil
                ? renamex_np(stagedRoot.path, targetRoot.path, UInt32(RENAME_SWAP))
                : renamex_np(targetRoot.path, stagedRoot.path, UInt32(RENAME_EXCL))
            if restored != 0 {
                keepRecovery = true
                throw LocalStorageError.corrupt("Extension setup could not be restored; recovery files remain at \(stage.path)")
            }
            throw error
        }
        base = attempt
        return packages.count + (recordChanges ? 1 : 0)
    }

    /// Reject future layouts rather than copying package files without their matching registry data.
    private static func extensionRecords(_ object: [String: Any]) -> [String: Any]? {
        guard Set(object.keys) == ["extensions"], let records = object["extensions"] as? [String: Any] else { return nil }
        for (id, value) in records {
            guard !id.isEmpty, id != ".", id != "..", !id.contains("/"),
                let record = value as? [String: Any],
                Set(record.keys) == ["id", "version", "hash", "installedAt", "manifest", "signatureInfo", "source"],
                record["id"] as? String == id, record["version"] is String, record["hash"] is String,
                record["installedAt"] is String, record["manifest"] is [String: Any],
                record["signatureInfo"] is [String: Any], record["source"] is String
            else { return nil }
        }
        return records
    }

    private static func installStaged(_ stage: URL, into target: URL, replacing: Bool) throws {
        guard renamex_np(stage.path, target.path, replacing ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// This is the observed SSH setup schema, not a generic JSON rewrite. Connection definitions may
    /// follow the user; a host trust decision is a permission and remains with the destination profile.
    private func mergeSSH(into dataDir: URL, base: inout [String: String], backup: Backup) throws -> Int {
        let filename = "ssh_configs.json"
        let source = paths.mainDataDir.appending(path: filename), target = dataDir.appending(path: filename)
        guard try Self.itemType(source) == .typeRegular,
            try Self.itemType(target) == nil || Self.itemType(target) == .typeRegular,
            let main = try Self.readExistingJSON(source), let mainConfigs = Self.sshConfigurations(main)
        else { return 0 }
        let own = try Self.readExistingJSON(target) ?? ["configs": []]
        guard let ownConfigs = Self.sshConfigurations(own) else { return 0 }
        let mainByID = Dictionary(uniqueKeysWithValues: mainConfigs.map { ($0["id"] as! String, $0 as Any) })
        let ownByID = Dictionary(uniqueKeysWithValues: ownConfigs.map { ($0["id"] as! String, $0 as Any) })
        var merged = ownByID, attempt = base
        for key in mainByID.keys.sorted() {
            Self.sharePreservingChanges(key, main: mainByID, own: ownByID, into: &merged, base: &attempt, prefix: "ssh:")
        }
        let ownOrder = ownConfigs.compactMap { $0["id"] as? String }
        let added = mainConfigs.compactMap { $0["id"] as? String }.filter { ownByID[$0] == nil && merged[$0] != nil }
        var result = own
        result["configs"] = (ownOrder + added).compactMap { merged[$0] }
        if NSDictionary(dictionary: result).isEqual(to: own) { base = attempt; return 0 }
        if fm.fileExists(atPath: target.path) { _ = try backup.save(target) }
        try Self.writeJSON(result, to: target)
        base = attempt
        return 1
    }

    private static func sshConfigurations(_ object: [String: Any]) -> [[String: Any]]? {
        guard Set(object.keys).isSubset(of: ["configs", "trustedHosts"]),
            let configs = object["configs"] as? [[String: Any]],
            configs.allSatisfy({
                Set($0.keys) == ["id", "name", "sshHost"]
                    && $0["id"] is String && ($0["id"] as? String)?.isEmpty == false
                    && $0["name"] is String && $0["sshHost"] is String
            }),
            Set(configs.compactMap { $0["id"] as? String }).count == configs.count
        else { return nil }
        return configs
    }

    /// Extension packages are indivisible; the directory containing them is not. Merge its immediate
    /// children so a profile-only extension survives when MAIN installs or updates another one.
    private func mergeAsset(
        _ source: URL, into target: URL, key: String,
        base: inout [String: String], backup: Backup
    ) throws -> Int {
        guard let sourceType = try Self.itemType(source) else { return 0 }
        guard sourceType == .typeRegular || sourceType == .typeDirectory else { return 0 }
        let targetType = try Self.itemType(target)
        if sourceType == .typeDirectory {
            // An occupied path of another kind belongs to this profile; never replace or follow it.
            guard targetType == nil || targetType == .typeDirectory else { return 0 }
            if targetType == nil {
                try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            var changed = 0
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                changed += try mergeAssetItem(
                    child, into: target.appending(path: child.lastPathComponent),
                    key: key + "/" + child.lastPathComponent, base: &base, backup: backup)
            }
            return changed
        }
        return try mergeAssetItem(source, into: target, key: key, base: &base, backup: backup)
    }

    private func mergeAssetItem(
        _ source: URL, into target: URL, key: String,
        base: inout [String: String], backup: Backup
    ) throws -> Int {
        guard let sourceType = try Self.itemType(source), sourceType == .typeRegular || sourceType == .typeDirectory else { return 0 }
        let targetType = try Self.itemType(target)
        guard targetType == nil || targetType == sourceType else { return 0 }
        let sourceHash = try Self.assetFingerprint(source)
        let ownHash = targetType == nil ? nil : try Self.assetFingerprint(target)
        if ownHash == sourceHash { base[key] = sourceHash; return 0 }
        let previous = base[key]
        guard (previous == nil && ownHash == nil) || (previous != nil && ownHash == previous) else {
            if previous == nil { base[key] = sourceHash }
            return 0
        }
        // Stage before backing up or replacing anything. A failed copy leaves the live item intact.
        let stage = target.deletingLastPathComponent().appending(path: ".baton-setup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: source, to: stage)
        guard try Self.assetFingerprint(stage) == sourceHash,
            (try Self.itemType(target) == nil ? nil : try Self.assetFingerprint(target)) == ownHash
        else {
            throw LocalStorageError.corrupt("Shared setup changed during copying; the profile's existing item was kept")
        }
        if ownHash != nil { _ = try backup.save(target) }
        // macOS swaps directories atomically too, including nonempty extension packages. The previous
        // item remains at the staging path until cleanup, and in the normal backup for recovery.
        let flags = ownHash == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
        guard renamex_np(stage.path, target.path, flags) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        base[key] = sourceHash
        return 1
    }

    private static func itemType(_ url: URL) throws -> FileAttributeType? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        { return nil }
    }

    /// Hash content, names, kinds and modes without traversing links inside an extension package.
    private static func assetFingerprint(_ root: URL) throws -> String {
        var hash = SHA256()
        func add(_ value: String) { hash.update(data: Data("\(value.utf8.count):\(value)".utf8)) }
        func visit(_ url: URL, name: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let kind = attributes[.type] as? FileAttributeType
            add(name); add(kind?.rawValue ?? "unknown"); add(String(describing: attributes[.posixPermissions] ?? 0))
            switch kind {
            case .typeDirectory:
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: {
                    $0.lastPathComponent < $1.lastPathComponent
                }) {
                    try visit(child, name: name + "/" + child.lastPathComponent)
                }
            case .typeRegular:
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            case .typeSymbolicLink:
                add(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            default:
                throw LocalStorageError.corrupt("Unsupported item in shared local setup; the profile's copy was kept")
            }
        }
        try visit(root, name: "")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies Claude Code versions the profile doesn't have yet. Only finished downloads (with `.verified`) are
    /// copied, under a temporary name first, so a profile never sees half a build.
    /// Keeps the current Claude Code build and the one before it in the profile: the newest two finished builds
    /// of the main app and the profile together. Older finished builds in the profile go to the Trash; a download
    /// in progress (no `.verified`) is left alone. A partial copy is removed when the copy fails, and one left by a
    /// crash or a force quit is removed at the next run.
    private func copyBuilds(into dataDir: URL) throws -> Int {
        let from = paths.mainDataDir.appending(path: Self.builds, directoryHint: .isDirectory)
        let to = dataDir.appending(path: Self.builds, directoryHint: .isDirectory)
        for name in (try? fm.contentsOfDirectory(atPath: to.path)) ?? [] where Self.isPartialBuild(name) {
            try? fm.removeItem(at: to.appending(path: name, directoryHint: .isDirectory))
        }
        func finished(in folder: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter {
                !$0.hasPrefix(".") && fm.fileExists(atPath: folder.appending(path: "\($0)/.verified").path)
            }
        }
        let main = finished(in: from), own = finished(in: to)
        let keep = Set(Set(main + own).sorted { ClaudeVersion.Version($0) > ClaudeVersion.Version($1) }.prefix(2))
        var copied = 0
        for version in own where !keep.contains(version) {
            try discard(to.appending(path: version, directoryHint: .isDirectory))
            copied += 1
        }
        for version in main where keep.contains(version) {
            let build = from.appending(path: version, directoryHint: .isDirectory)
            guard !fm.fileExists(atPath: to.appending(path: version).path) else { continue }
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            let partial = to.appending(path: ".\(version)-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? fm.removeItem(at: partial) }  // nothing left there after the move
            try fm.copyItem(at: build, to: partial)
            try fm.moveItem(at: partial, to: to.appending(path: version, directoryHint: .isDirectory))
            copied += 1
        }
        return copied
    }

    /// `.<version>-<UUID>`, the temporary name `copyBuilds` copies a build under. `UUID().uuidString` is upper case,
    /// which tells it apart from a name Claude would make.
    static func isPartialBuild(_ name: String) -> Bool {
        guard name.hasPrefix("."), let dash = name.index(name.endIndex, offsetBy: -37, limitedBy: name.startIndex),
            name[dash] == "-", dash > name.index(after: name.startIndex)
        else { return false }
        let id = name[name.index(after: dash)...]
        return UUID(uuidString: String(id)) != nil && id == id.uppercased()
    }

    /// Resolves portable values without retaining their contents (MCP configuration may include secrets).
    /// Missing source settings do not delete profile-only settings.
    private static func share(
        _ key: String, main: [String: Any], own: [String: Any],
        into result: inout [String: Any], base: inout [String: String], prefix: String
    ) {
        guard let value = main[key] else { return }
        let stateKey = prefix + key
        let mainHash = fingerprint(value), ownHash = own[key].map(fingerprint) ?? InterfaceSync.missing
        guard InterfaceSync.resolve(own: ownHash, main: mainHash, base: base[stateKey]) == .main else { return }
        result[key] = value
        base[stateKey] = mainHash
    }

    private static func fingerprint(_ value: Any) -> String {
        SHA256.hash(data: Data(InterfaceSync.canonical(value).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Shares independently named settings without replacing pre-existing profile choices. The first
    /// source fingerprint also remembers an initial conflict so a later profile-side deletion stays local.
    private static func sharePreservingChanges(
        _ key: String, main: [String: Any], own: [String: Any],
        into result: inout [String: Any], base: inout [String: String],
        prefix: String
    ) {
        guard let value = main[key] else { return }
        let stateKey = prefix + key, mainHash = fingerprint(value)
        let ownHash = own[key].map(fingerprint)
        let previous = base[stateKey]
        if ownHash == mainHash || (previous == nil && ownHash == nil) || (previous != nil && ownHash == previous) {
            result[key] = value
            base[stateKey] = mainHash
        } else if previous == nil {
            base[stateKey] = mainHash
        }
    }

    /// Missing state is a first launch; damaged state is not. Resetting it could overwrite a profile's
    /// changes with MAIN's values on the next launch, so reject it before copying any setup files.
    private static func readBaseline(_ url: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: String],
            result.values.allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil })
        else {
            throw LocalStorageError.corrupt("Shared settings history is unreadable; setup files were left unchanged")
        }
        return result
    }

    /// A corrupt existing configuration is not an empty configuration and must never be replaced silently.
    private static func readExistingJSON(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalStorageError.corrupt("\(url.lastPathComponent) must contain a JSON object")
        }
        return object
    }

    /// A link stays a link: the file it leads to is written, with that file's permissions (see `LocalOnly.replace`).
    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try LocalOnly.replace(url, with: JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
    }

    /// Copies theme, zoom and language into the profile's `config.json`, leaving everything else in it untouched.
    /// That file also holds the profile's sign-in, so it is edited in place and never backed up or copied.
    private func copyAppearance(into dataDir: URL, base: inout [String: String]) throws -> Bool {
        let to = dataDir.appending(path: "config.json")
        guard let main = Self.readJSON(paths.mainDataDir.appending(path: "config.json")),
            var config = Self.readJSON(to)
        else { return false }
        let own = config
        var attempt = base
        for key in Self.appearanceKeys {
            Self.share(key, main: main, own: own, into: &config, base: &attempt, prefix: "appearance:")
        }
        guard !NSDictionary(dictionary: own).isEqual(to: config) else { base = attempt; return false }
        try Self.writeJSON(config, to: to)
        base = attempt
        return true
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
