import Darwin
import Foundation

/// What Baton read from a file, kept while the file stays the same: same path, modification time, size, inode and
/// change time. The change time moves on every write and attribute change and can't be set back, so a card that sync
/// writes with its source's modification date still reads as changed. An idle refresh of the window list, the sync
/// and the Continue list then reads no card or transcript again; it only looks at each file's attributes.
/// In memory only, per process; nothing is written.
public final class ScanCache: @unchecked Sendable {
    public static let shared = ScanCache()

    private struct Stamp: Equatable {
        var modified: timespec, changed: timespec, size: off_t, inode: ino_t
        static func == (a: Stamp, b: Stamp) -> Bool {
            a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
                && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
                && a.size == b.size && a.inode == b.inode
        }
    }

    private let lock = NSLock()
    private var entries: [String: (stamp: Stamp, value: Any)] = [:]
    /// How many times a file had to be read: a miss, or a file that changed. For tests and measurements.
    public private(set) var reads = 0
    /// Past this many entries the cache starts over rather than grow without bound.
    let limit: Int

    public init(limit: Int = 100_000) { self.limit = limit }

    private static func stamp(of url: URL) -> Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Stamp(modified: info.st_mtimespec, changed: info.st_ctimespec, size: info.st_size, inode: info.st_ino)
    }

    /// `read(url)` the first time and whenever the file changed; the kept value otherwise. `kind` keeps different
    /// reads of one file apart. A file that can't be stat'ed is read every time and kept for nothing.
    public func value<T>(_ kind: String, of url: URL, read: (URL) throws -> T) rethrows -> T {
        let key = kind + "\n" + url.path
        guard let before = Self.stamp(of: url) else {
            lock.withLock { reads += 1 }
            return try read(url)
        }
        if let hit = lock.withLock({ entries[key] }), hit.stamp == before, let value = hit.value as? T { return value }
        let value = try read(url)
        lock.withLock {
            reads += 1
            // Kept only if the file didn't change while it was read.
            guard Self.stamp(of: url) == before else { return }
            if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
            entries[key] = (before, value)
        }
        return value
    }
}
