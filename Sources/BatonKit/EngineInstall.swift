import Darwin
import Foundation
import Security

/// Replaces a closed profile engine without deleting the working app before its replacement is ready.
/// The caller serializes installations and ensures the destination app is not running.
enum EngineInstall {
    typealias Copy = (URL, URL) throws -> Void
    typealias Validate = (URL) throws -> Void
    typealias Exchange = (URL, URL) throws -> Void

    /// Claude Desktop as Anthropic signs it: its bundle id, and a Developer ID certificate Apple issued to Anthropic's
    /// team. Only an app that meets it is copied into a profile or taken for Claude Desktop.
    static let anthropicRequirement =
        #"identifier "\#(ClaudeVersion.bundleIdentifier)" and anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW""#

    enum InstallError: LocalizedError {
        case invalidBundle(URL, String)
        case notFromAnthropic(URL)
        case overlappingPaths
        case sourceChanged
        case exchangeFailed(String)
        case rollbackFailed(backup: URL, reason: String)
        case wouldDowngrade(installed: String, source: String)

        var errorDescription: String? {
            switch self {
            case let .invalidBundle(url, reason): "Invalid Claude engine at \(url.path): \(reason)"
            case let .notFromAnthropic(url):
                "\(url.path) isn't Claude Desktop as Anthropic signs it, so Baton doesn't copy it into a profile. "
                    + "Install Claude Desktop from Anthropic in Applications and try again."
            case .overlappingPaths: "The source and destination app bundles must be separate."
            case .sourceChanged: "Claude changed while its engine was being copied. Try opening the profile again."
            case let .exchangeFailed(reason): "Could not replace the Claude engine: \(reason)"
            case let .rollbackFailed(backup, reason):
                "Could not restore the previous Claude engine. Its backup is at \(backup.path). \(reason)"
            case let .wouldDowngrade(installed, source):
                "The Claude engine is version \(installed), newer than Claude Desktop \(source); it is kept as it is."
            }
        }
    }

    private struct BundleIdentity: Equatable {
        let version: String
        let identifier: String
        let executable: String
    }

    /// The old bundle becomes a temporary backup in the same atomic filesystem exchange that installs
    /// the new one. It remains available for rollback until the installed app has passed validation.
    static func install(
        from source: URL,
        to destination: URL,
        copy: Copy = cloneOrCopy,
        validate: Validate = validateSignature,
        exchange: Exchange = exchangeBundles
    ) throws {
        let fm = FileManager.default
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        let resolvedSource = source.resolvingSymlinksInPath().path
        let resolvedDestination = destination.resolvingSymlinksInPath().path
        guard resolvedSource != resolvedDestination,
            !resolvedSource.hasPrefix(resolvedDestination + "/"),
            !resolvedDestination.hasPrefix(resolvedSource + "/")
        else { throw InstallError.overlappingPaths }

        let identity = try bundleIdentity(at: source)
        // Never replace an engine with an older Claude: versions compared part by part as numbers.
        if let current = try? bundleIdentity(at: destination), isOlder(identity.version, than: current.version) {
            throw InstallError.wouldDowngrade(installed: current.version, source: identity.version)
        }
        try validate(source)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".\(destination.deletingPathExtension().lastPathComponent)-install-\(UUID().uuidString).app")
        var mayRemoveStaging = true
        defer { if mayRemoveStaging { try? fm.removeItem(at: staging) } }

        try copy(source, staging)
        guard try bundleIdentity(at: staging) == identity else { throw InstallError.sourceChanged }
        try validate(staging)

        // Read attributes rather than fileExists: a dangling symlink must not be treated as an absent app.
        let existingType: FileAttributeType?
        do {
            existingType = try fm.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            existingType = nil
        }
        if let existingType {
            guard existingType == .typeDirectory else {
                throw InstallError.invalidBundle(destination, "the destination is not an app directory")
            }
            try exchange(staging, destination)
            do {
                guard try bundleIdentity(at: destination) == identity else { throw InstallError.sourceChanged }
                try validate(destination)
            } catch {
                do { try exchange(staging, destination) } catch let rollbackError {
                    // Staging now contains the previous working engine. Never delete it on rollback failure.
                    mayRemoveStaging = false
                    throw InstallError.rollbackFailed(backup: staging, reason: rollbackError.localizedDescription)
                }
                throw error
            }
        } else {
            // moveItem refuses an existing destination, including one created concurrently.
            try fm.moveItem(at: staging, to: destination)
            do {
                guard try bundleIdentity(at: destination) == identity else { throw InstallError.sourceChanged }
                try validate(destination)
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
        }
    }

    /// Whether version `a` is older than `b`, part by part as numbers: 2.9939.9 is older than 2.9939.10.
    static func isOlder(_ a: String, than b: String) -> Bool { ClaudeVersion.Version(a) < ClaudeVersion.Version(b) }

    private static func bundleIdentity(at app: URL) throws -> BundleIdentity {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw InstallError.invalidBundle(app, "missing app directory")
        }
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let version = info["CFBundleVersion"] as? String, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
            let executable = info["CFBundleExecutable"] as? String,
            !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"),
            fm.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/\(executable)").path)
        else { throw InstallError.invalidBundle(app, "missing version, identifier, or executable") }
        return BundleIdentity(version: version, identifier: identifier, executable: executable)
    }

    /// Every file of `app` as signed, and signed by Anthropic (`anthropicRequirement`); a valid signature from anyone
    /// else, ad hoc included, is refused.
    static func validateSignature(at app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", "-R=" + anthropicRequirement, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // codesign exits with 3 when the signature is valid but the requirement isn't met.
        if process.terminationStatus == 3 { throw InstallError.notFromAnthropic(app) }
        guard process.terminationStatus == 0 else {
            throw InstallError.invalidBundle(app, "code signature verification failed")
        }
    }

    static func cloneOrCopy(from source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        // A failed clone may have left a partial item. Only this installation's unique staging path is removed.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        // Across disks a clone can't be made: the copy takes as much space as Claude itself. `baton doctor` says so.
        Log.notice("engine", "Claude is on another disk than the app copies, so \(destination.lastPathComponent) is a full copy")
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Whether app copies made from `claudeApp` in `enginesDir` are full copies rather than clones: the two are on
    /// different disks. The engines folder may not exist yet; its closest existing folder counts.
    static func copiesAcrossDisks(from claudeApp: URL, to enginesDir: URL) -> Bool {
        var folder = enginesDir.standardizedFileURL
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder = folder.deletingLastPathComponent() }
        func volume(_ url: URL) -> String? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier).map { "\($0)" }
        }
        guard let source = volume(claudeApp), let target = volume(folder) else { return false }
        return source != target
    }

    /// The disk space `app` takes, in bytes.
    static func size(of app: URL) -> Int {
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        }
        return total
    }

    static func exchangeBundles(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw InstallError.exchangeFailed(String(cString: strerror(errno)))
        }
    }
}

/// What `baton doctor` says about the Claude Desktop that profiles are copied from.
public enum ClaudeSource {
    /// Whether `app` is signed by Anthropic as Claude Desktop (`EngineInstall.anthropicRequirement`). It checks who
    /// signed the app and its executable, not every file, so it is quick enough for every start (about 30 ms);
    /// `EngineInstall.validateSignature` checks every file before a copy.
    public static func isSignedByAnthropic(_ app: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(EngineInstall.anthropicRequirement as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) == errSecSuccess
    }

    /// A line when the app isn't signed by Anthropic, so no profile is copied from it, and one when each app copy
    /// is a full copy because Claude is on another disk than the copies. Empty when neither applies.
    public static func notes(paths: Paths) -> [String] {
        guard FileManager.default.fileExists(atPath: paths.claudeApp.path) else { return [] }
        var notes: [String] = []
        if !isSignedByAnthropic(paths.claudeApp) {
            notes.append("Not signed by Anthropic: Baton won't copy this app into a profile. Install Claude Desktop from Anthropic.")
        }
        if EngineInstall.copiesAcrossDisks(from: paths.claudeApp, to: paths.enginesDir) {
            let size = ByteCountFormatter.string(fromByteCount: Int64(EngineInstall.size(of: paths.claudeApp)), countStyle: .file)
            notes.append(
                "On another disk than \(Paths.display(paths.launchersDir, home: paths.home)): each profile's app copy is a full "
                    + "copy of about \(size) instead of a clone, made again after each Claude Desktop update")
        }
        return notes
    }
}

/// The Claude Desktop versions this release of Baton was tested with, and a warning outside them.
public enum ClaudeVersion {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    /// The only list of tested versions, by major.minor: every patch build of a tested minor counts as tested
    /// (2.9939.4 as well as 2.9939.2). Move the upper end after testing a newer Claude Desktop: card fields,
    /// preference keys and links can change.
    public static let tested: ClosedRange<Version> = "2.9939"..."2.9939"
    /// Exact versions known not to work with this release, warned about even inside the tested minors.
    public static let knownIncompatible: Set<String> = []

    /// A dotted version compared part by part as numbers, so 2.10000 is newer than 2.9939.
    public struct Version: Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let text: String
        public init(_ text: String) { self.text = text }
        public init(stringLiteral text: String) { self.text = text }
        public var description: String { text }

        var parts: [Int] { text.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        /// Major and minor only: 2.9939.4 → 2.9939.
        public var minor: Version { Version(parts.prefix(2).map(String.init).joined(separator: ".")) }

        private static func compare(_ a: Version, _ b: Version) -> Int {
            let x = a.parts, y = b.parts
            for i in 0..<max(x.count, y.count) {
                let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
                if l != r { return l < r ? -1 : 1 }
            }
            return 0
        }
        public static func < (a: Version, b: Version) -> Bool { compare(a, b) < 0 }
        public static func == (a: Version, b: Version) -> Bool { compare(a, b) == 0 }
    }

    static func bundleInfo(at app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// The marketing version of the Claude Desktop at `app`, such as `2.9939.2`.
    public static func installed(at app: URL) -> String? {
        bundleInfo(at: app)?["CFBundleShortVersionString"] as? String
    }

    /// Such as `2.9939.x`, or `2.9939.x–2.9940.x`.
    public static var testedText: String {
        tested.lowerBound == tested.upperBound ? "\(tested.lowerBound).x" : "\(tested.lowerBound).x–\(tested.upperBound).x"
    }

    /// nil for any build of a tested major.minor; otherwise one sentence for the window list, `doctor` and the
    /// start-up check.
    public static func warning(for version: String?) -> String? {
        guard let version, !version.isEmpty else {
            return "Couldn't read which version of Claude Desktop is installed; Baton was tested with \(testedText)."
        }
        let installed = Version(version).minor
        if knownIncompatible.contains(version) {
            return "Claude Desktop \(version) is known not to work with this release of Baton. Update Claude Desktop or Baton."
        }
        if installed < tested.lowerBound {
            return "Claude Desktop \(version) is older than the versions Baton was tested with (\(testedText)). Update Claude Desktop."
        }
        if installed > tested.upperBound {
            return "Claude Desktop \(version) is newer than the versions Baton was tested with (\(testedText)). "
                + "Sessions are still shared and Local only checks each setting before writing it; if something looks wrong, send feedback."
        }
        return nil
    }
}
