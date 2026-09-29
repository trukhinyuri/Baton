import Foundation

/// Filesystem helpers shared by `SessionSync` and `CoworkSync`, which keep different per-org files
/// consistent inside the same kind of `<account>/<organization>` folders.
enum SyncFolders {
    /// Every `<account>/<organization>` folder named `folder` across all data directories.
    static func pairs(dataDirs: [URL], folder: String) -> [URL] {
        var result: [URL] = []
        for dataDir in dataDirs {
            let root = dataDir.appending(path: folder, directoryHint: .isDirectory)
            for account in contents(of: root) where account.lastPathComponent.count == 36 && isRealDirectory(account) {
                for org in contents(of: account) where !org.lastPathComponent.hasPrefix(".") && isRealDirectory(org) {
                    result.append(org)
                }
            }
        }
        return result
    }

    static func contents(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// Read from the file system each time: `URL` caches resource values, which would hide a write Claude has
    /// just made. Of the link itself for a symbolic link, as `attributesOfItem` gives it, but with one `lstat` and no
    /// extended attributes.
    static func modificationDate(_ url: URL) -> Date? { modificationTime(url).map(date) }

    /// The modification time to the nanosecond, of the link itself for a symbolic link.
    static func modificationTime(_ url: URL) -> timespec? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mtimespec : nil
    }

    /// The same `Date` as `attributesOfItem` gives for this time.
    static func date(_ time: timespec) -> Date {
        Date(timeIntervalSinceReferenceDate: (Double(time.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate) + 1.0e-9 * Double(time.tv_nsec))
    }

    /// Gives `url` the modification time `time` to the nanosecond. `setAttributes` rounds to the microsecond, which
    /// can make a copy look newer than the file it was copied from.
    @discardableResult
    static func setModificationTime(_ url: URL, _ time: timespec) -> Bool {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), time]
        return utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0
    }
}
