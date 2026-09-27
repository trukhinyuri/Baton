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
                do { try exchange(staging, destination) }
                catch let rollbackError {
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
