import Darwin
import Foundation

/// Explicitly selected originals, such as files downloaded through Claude's Library UI.
/// Selection preserves bytes and local provenance; it does not establish Library completeness.
public struct WorkspaceSelectedFiles: Sendable {
    public let files: [ContinuityWorkspace.SelectedFile]
    private let captureID: UUID

    public init(urls: [URL]) throws {
        guard !urls.isEmpty, Set(urls.map(\.absoluteString)).count == urls.count else {
            throw ContinuityWorkspace.WorkspaceError.invalid("choose one or more distinct original files")
        }
        let id = UUID()
        var selected: [ContinuityWorkspace.SelectedFile] = []
        var total = 0
        for (index, url) in urls.enumerated() {
            let data = try Self.readOriginal(url)
            guard total <= 1_073_741_824 - data.count else {
                throw ContinuityWorkspace.WorkspaceError.invalid("selected originals exceed the 1 GiB capture limit; no files were added")
            }
            total += data.count
            // Retain the original name in fileURL provenance; only the inert logical label is sanitized.
            let name = String(url.lastPathComponent.unicodeScalars.map { scalar -> Character in
                CharacterSet.controlCharacters.contains(scalar) || scalar == ":" || scalar == "\\" ? "_" : Character(String(scalar))
            })
            guard !name.isEmpty, name != ".", name != ".." else {
                throw ContinuityWorkspace.WorkspaceError.invalid("selected original has no usable filename")
            }
            selected.append(.init(path: "selected-originals/\(id.uuidString)/\(index + 1)/\(name)", fileURL: url,
                                  expectedSHA256: ContinuityWorkspace.sha256(data), expectedSize: data.count))
        }
        files = selected; captureID = id
    }

    /// Uses the workspace's existing source-path, byte-hash and locked revision checks again at commit.
    @discardableResult
    public func publish(to workspace: ContinuityWorkspace, expectedRevision: Int) throws -> ContinuityWorkspace.Snapshot {
        try workspace.publish(texts: [], files: files,
                              coverage: [.init(component: "Selected originals \(captureID.uuidString)", status: .partial,
                                               detail: "\(files.count) explicitly selected local originals retained with their bytes, paths and hashes. User selection does not verify their Claude Library origin, freshness, or full Library completeness.")],
                              limitations: ["Selected downloaded originals preserve only the chosen files. Other Library items, unavailable downloads, updated versions and native file relationships may still be missing. File selection does not prove that the full Library was transferred."],
                              expectedRevision: expectedRevision)
    }

    private static func readOriginal(_ url: URL) throws -> Data {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), !url.pathComponents.contains("."), !url.pathComponents.contains("..") else {
            throw ContinuityWorkspace.WorkspaceError.invalid("choose a local regular file without path traversal")
        }
        var parts = url.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { throw ContinuityWorkspace.WorkspaceError.invalid("choose a file, not a directory") }
        // Match the workspace validator's macOS system aliases; user-created links remain rejected.
        if let first = parts.first, first == "var" || first == "tmp" {
            let path = "/" + first
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                guard target == "private/" + first || target == "/private/" + first else {
                    throw ContinuityWorkspace.WorkspaceError.invalid("unexpected system path alias")
                }
                parts.insert("private", at: 0)
            }
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ContinuityWorkspace.WorkspaceError.invalid("selected file root is unavailable") }
        defer { close(descriptor) }
        for (index, part) in parts.enumerated() {
            let final = index == parts.count - 1
            let next = openat(descriptor, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (final ? 0 : O_DIRECTORY))
            guard next >= 0 else { throw ContinuityWorkspace.WorkspaceError.invalid("selected path contains an inaccessible component or symbolic link: \(url.path)") }
            close(descriptor); descriptor = next
        }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= 1_073_741_824 else {
            throw ContinuityWorkspace.WorkspaceError.invalid("selected original is not a regular file or exceeds 1 GiB: \(url.path)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, data.count == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ContinuityWorkspace.WorkspaceError.sourceChanged(url.path)
        }
        return data
    }
}
