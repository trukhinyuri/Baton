import Foundation

/// Claude Desktop's cached server flags, `<dataDir>/fcache`: an 8-byte header, then gzip-compressed JSON
/// `{timestamp, mode, orgUuid?, features: {"<number>": {value, on, off, source, …}}}` as `/api/desktop/features`
/// returned it. Claude drops the cache when it is older than a day, and so does this reader. Baton only reads it.
///
/// Flags are kept under numbers, not names, and which number `ccd_auto_resume_rate_limit` has isn't known yet, so
/// `autoResume` answers `nil` ("unknown") until that number is measured and filled in.
public enum ServerFlags {
    static let fileName = "fcache"
    static let header: [UInt8] = [0x43, 0x4C, 0x46, 0x02, 0x00, 0x9A, 0xB7, 0xE2]
    /// Claude ignores a cache older than this.
    static let maxAge: TimeInterval = 86_400
    /// The cache key of `ccd_auto_resume_rate_limit`, the flag Claude checks before it continues a session by itself.
    /// Not identified yet; `nil` makes `autoResume` answer "unknown".
    static let autoResumeKey: String? = nil

    /// Whether the server lets Claude continue sessions by itself after a limit in the window at `dataDir`:
    /// `nil` when that can't be told (no cache, a stale or unreadable one, or the flag's key unknown).
    public static func autoResume(dataDir: URL, now: Date = Date()) -> Bool? {
        flag(autoResumeKey, dataDir: dataDir, now: now)
    }

    /// One flag's `on`, by its cache key.
    static func flag(_ key: String?, dataDir: URL, now: Date) -> Bool? {
        guard let key, let data = try? Data(contentsOf: dataDir.appending(path: fileName)) else { return nil }
        return features(in: data, now: now)?[key]
    }

    /// Every flag's `on`, by cache key, or `nil` for a cache that is stale or not what Claude writes.
    static func features(in data: Data, now: Date) -> [String: Bool]? {
        let bytes = [UInt8](data)
        guard bytes.count > header.count, Array(bytes.prefix(header.count)) == header,
            let json = gunzip(Array(bytes.dropFirst(header.count))),
            let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
            var timestamp = UsageHistory.number(object["timestamp"]),
            let features = object["features"] as? [String: Any]
        else { return nil }
        if timestamp > 100_000_000_000 { timestamp /= 1000 }
        guard now.timeIntervalSince(Date(timeIntervalSince1970: timestamp)) <= maxAge else { return nil }
        return features.compactMapValues { value -> Bool? in
            guard let on = (value as? [String: Any])?["on"] as? NSNumber, CFGetTypeID(on) == CFBooleanGetTypeID() else { return nil }
            return on.boolValue
        }
    }

    // MARK: gzip

    /// The content of one gzip member (RFC 1952), checked against its CRC-32 and length.
    static func gunzip(_ bytes: [UInt8]) -> Data? {
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 {
            guard i + 2 <= bytes.count else { return nil }
            i += 2 + Int(bytes[i]) + Int(bytes[i + 1]) << 8
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }
        guard i <= bytes.count - 8 else { return nil }
        let trailer = Array(bytes.suffix(8))
        let crc = trailer[0..<4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let size = trailer[4..<8].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        // Apple's `.zlib` is raw DEFLATE (RFC 1951), which is what a gzip member holds.
        guard let content = try? (Data(bytes[i..<(bytes.count - 8)]) as NSData).decompressed(using: .zlib) as Data,
            UInt32(truncatingIfNeeded: content.count) == size, crc32([UInt8](content)) == crc
        else { return nil }
        return content
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    /// CRC-32 as gzip uses it.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(~UInt32(0)) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}
