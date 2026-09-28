import Darwin
import Foundation

/// Replaces a closed profile engine without deleting the working app before its replacement is ready.
/// The caller serializes installations and ensures the destination app is not running.
enum EngineInstall {
    typealias Copy = (URL, URL) throws -> Void
    typealias Validate = (URL) throws -> Void
    typealias Exchange = (URL, URL) throws -> Void

    enum InstallError: LocalizedError {
        case invalidBundle(URL, String)
        case overlappingPaths
        case sourceChanged
        case exchangeFailed(String)
        case rollbackFailed(backup: URL, reason: String)

        var errorDescription: String? {
            switch self {
            case let .invalidBundle(url, reason): "Invalid Claude engine at \(url.path): \(reason)"
            case .overlappingPaths: "The source and destination app bundles must be separate."
            case .sourceChanged: "Claude changed while its engine was being copied. Try opening the profile again."
            case let .exchangeFailed(reason): "Could not replace the Claude engine: \(reason)"
            case let .rollbackFailed(backup, reason):
                "Could not restore the previous Claude engine. Its backup is at \(backup.path). \(reason)"
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

    static func validateSignature(at app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.invalidBundle(app, "code signature verification failed")
        }
    }

    static func cloneOrCopy(from source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        // A failed clone may have left a partial item. Only this installation's unique staging path is removed.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    static func exchangeBundles(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw InstallError.exchangeFailed(String(cString: strerror(errno)))
        }
    }
}

/// The Claude Desktop versions this release of Claude Profiles was tested with, and a warning outside them.
public enum ClaudeVersion {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    /// Move the upper end after testing a newer Claude Desktop: card fields, preference keys and links can change.
    public static let tested: ClosedRange<Version> = "2.9939.2"..."2.9939.2"

    /// A dotted version compared part by part as numbers, so 2.10000 is newer than 2.9939.
    public struct Version: Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let text: String
        public init(_ text: String) { self.text = text }
        public init(stringLiteral text: String) { self.text = text }
        public var description: String { text }

        var parts: [Int] { text.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }

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

    static var testedText: String {
        tested.lowerBound == tested.upperBound ? tested.lowerBound.text : "\(tested.lowerBound)–\(tested.upperBound)"
    }

    /// nil inside the tested range; otherwise one sentence for the window list, `doctor` and the start-up check.
    public static func warning(for version: String?) -> String? {
        guard let version, !version.isEmpty else {
            return "Couldn't read which version of Claude Desktop is installed; Claude Profiles was tested with \(testedText)."
        }
        let installed = Version(version)
        if installed < tested.lowerBound {
            return "Claude Desktop \(version) is older than the versions Claude Profiles was tested with (\(testedText)). Update Claude Desktop."
        }
        if installed > tested.upperBound {
            return "Claude Desktop \(version) is newer than the versions Claude Profiles was tested with (\(testedText)). "
                + "Sessions are still shared and Local only checks each setting before writing it; if something looks wrong, send feedback."
        }
        return nil
    }
}
