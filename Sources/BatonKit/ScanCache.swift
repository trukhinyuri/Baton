import Darwin
import Foundation

/// What Baton read from a file, kept while the file stays the same: same path, modification time, size, inode and
/// change time. The change time moves on every write and attribute change and can't be set back, so a card that sync
/// writes with its source's modification date still reads as changed. An idle refresh of the window list, the sync
/// and the Continue list then reads no card or transcript again; it only looks at each file's attributes.
/// In memory only, per process; nothing is written.
///
/// It holds at most `limit` entries and about `budget` bytes. Past either, a new value is returned but not kept, so
/// a set of files larger than the cache still finds most of them kept. An entry nobody asked for in an hour goes: its
/// file was most likely removed or renamed.
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

    private struct Entry {
        var stamp: Stamp
        var value: Any
        var cost: Int
        var used: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var lastSweep: TimeInterval
    /// How many times a file had to be read: a miss, or a file that changed. For tests and measurements.
    public private(set) var reads = 0
    /// What the kept values cost, in bytes, as counted when each was kept. For tests and measurements.
    public private(set) var bytes = 0
    /// At most this many entries.
    let limit: Int
    /// At most about this many bytes of kept values.
    let budget: Int
    /// An entry not asked for in this long goes.
    static let idle: TimeInterval = 3600
    /// Seconds on a clock that only moves forward; a test moves its own by hand.
    let clock: @Sendable () -> TimeInterval

    public convenience init(limit: Int = 100_000, budget: Int = 256 << 20) {
        self.init(limit: limit, budget: budget, clock: { ProcessInfo.processInfo.systemUptime })
    }

    init(limit: Int, budget: Int, clock: @escaping @Sendable () -> TimeInterval) {
        self.limit = limit
        self.budget = budget
        self.clock = clock
        lastSweep = clock()
    }

    private static func stamp(of url: URL) -> Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Stamp(modified: info.st_mtimespec, changed: info.st_ctimespec, size: info.st_size, inode: info.st_ino)
    }

    /// `read(url)` the first time and whenever the file changed; the kept value otherwise. `kind` keeps different
    /// reads of one file apart. A file that can't be stat'ed is read every time and kept for nothing.
    /// - Parameter cost: what keeping a value takes, in bytes. By default the size of a `Data`, and the size of the
    ///   file for anything else.
    public func value<T>(_ kind: String, of url: URL, cost: ((T) -> Int)? = nil, read: (URL) throws -> T) rethrows -> T {
        let key = kind + "\n" + url.path
        guard let before = Self.stamp(of: url) else {
            lock.withLock {
                reads += 1
                forget(key)
            }
            return try read(url)
        }
        let now = clock()
        let hit: T? = lock.withLock {
            sweep(now: now)
            guard let entry = entries[key], entry.stamp == before, let value = entry.value as? T else { return nil }
            entries[key]?.used = now
            return value
        }
        if let hit { return hit }
        let value = try read(url)
        let size = max(cost?(value) ?? (value as? Data)?.count ?? Int(before.size), 0)
        lock.withLock {
            reads += 1
            forget(key)
            // Kept only if the file didn't change while it was read, and only if it fits.
            guard Self.stamp(of: url) == before, entries.count < limit, bytes + size <= budget else { return }
            entries[key] = Entry(stamp: before, value: value, cost: size, used: now)
            bytes += size
        }
        return value
    }

    /// Call with `lock` held.
    private func forget(_ key: String) {
        if let gone = entries.removeValue(forKey: key) { bytes -= gone.cost }
    }

    /// Drops what nobody asked for in `idle`, looking at most four times per `idle`. Call with `lock` held.
    private func sweep(now: TimeInterval) {
        guard now - lastSweep >= Self.idle / 4 else { return }
        lastSweep = now
        for (key, entry) in entries where now - entry.used >= Self.idle { forget(key) }
    }
}
