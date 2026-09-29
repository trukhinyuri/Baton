import Foundation
import Testing

@testable import BatonKit

@Suite("Server flags")
struct ServerFlagsTests {
    static let now = Date(timeIntervalSince1970: 1_790_700_000)

    /// A cache the way Claude writes it: the measured header, then gzip JSON, compressed by `/usr/bin/gzip`.
    static func fcache(timestamp: Date, features: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: ["timestamp": Int64(timestamp.timeIntervalSince1970 * 1000), "mode": "1p", "features": features])
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-c", "-n"]
        let input = Pipe(), output = Pipe()
        gzip.standardInput = input
        gzip.standardOutput = output
        try gzip.run()
        input.fileHandleForWriting.write(json)
        input.fileHandleForWriting.closeFile()
        let compressed = output.fileHandleForReading.readDataToEndOfFile()
        gzip.waitUntilExit()
        return Data(ServerFlags.header) + compressed
    }

    static var features: [String: Any] {
        [
            "17519066": ["value": true, "on": true, "off": false, "source": "force"],
            "4242": ["value": false, "on": false, "off": true, "source": "defaultValue"],
            "7": ["value": 3, "on": "yes"],
        ]
    }

    @Test func readsFcacheHeaderAndFeatures() throws {
        let data = try Self.fcache(timestamp: Self.now.addingTimeInterval(-3600), features: Self.features)

        #expect(ServerFlags.features(in: data, now: Self.now) == ["17519066": true, "4242": false], "only a real on/off counts")
        var wrongHeader = data
        wrongHeader[3] = 3
        #expect(ServerFlags.features(in: wrongHeader, now: Self.now) == nil)
        var corrupt = data
        corrupt[corrupt.count - 9] ^= 0xFF
        #expect(ServerFlags.features(in: corrupt, now: Self.now) == nil, "a damaged member fails its checksum")

        let box = try Sandbox()
        try data.write(to: box.work.appending(path: "fcache"))
        #expect(ServerFlags.flag("17519066", dataDir: box.work, now: Self.now) == true)
        #expect(ServerFlags.flag("4242", dataDir: box.work, now: Self.now) == false)
        #expect(ServerFlags.flag("17519066", dataDir: box.main, now: Self.now) == nil, "no cache")
    }

    @Test func staleCacheIsUnknown() throws {
        let data = try Self.fcache(timestamp: Self.now.addingTimeInterval(-86_401), features: Self.features)
        #expect(ServerFlags.features(in: data, now: Self.now) == nil, "Claude drops a cache older than a day")
        let fresh = try Self.fcache(timestamp: Self.now.addingTimeInterval(-86_399), features: Self.features)
        #expect(ServerFlags.features(in: fresh, now: Self.now)?.count == 2)
    }

    @Test func unknownKeyIsUnknown() throws {
        let box = try Sandbox()
        try Self.fcache(timestamp: Self.now, features: Self.features).write(to: box.work.appending(path: "fcache"))
        #expect(ServerFlags.flag("99", dataDir: box.work, now: Self.now) == nil)
        #expect(ServerFlags.flag(nil, dataDir: box.work, now: Self.now) == nil)
        #expect(ServerFlags.autoResumeKey == nil && ServerFlags.autoResume(dataDir: box.work, now: Self.now) == nil, "not measured yet")
    }
}
