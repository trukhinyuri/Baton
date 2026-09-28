import Foundation
import Testing

@testable import ClaudeProfilesKit

@Suite("Archived sessions in sharing")
struct SessionSyncArchiveTests {
    func archived(_ pair: URL) throws -> [String]? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: pair.appending(path: "archived-sessions.idx"))) as? [String: Any]
        return object?["archived"] as? [String]
    }

    @Test func unarchiveSticks() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"v":1,"archived":["s1","s2"]}"#, to: a.appending(path: "archived-sessions.idx"))
        try box.write(#"{"v":1,"archived":["s1"]}"#, to: b.appending(path: "archived-sessions.idx"))
        _ = try box.sync()

        try box.write(#"{"v":1,"archived":["s2"]}"#, to: a.appending(path: "archived-sessions.idx"))  // unarchived in A
        try box.write(#"{"v":1,"archived":["s1","s2","s3"]}"#, to: b.appending(path: "archived-sessions.idx"))  // archived in B
        _ = try box.sync()

        #expect(try archived(a) == ["s2", "s3"], "an unarchive in one window is not undone by sync")
        #expect(try archived(b) == ["s2", "s3"], "and reaches the other windows, with what they archived")
        #expect(try box.sync().changes == 0)
    }

    @Test func unarchivingTheLastSessionEmptiesEveryIndex() throws {
        let box = try Sandbox()
        let a = try box.pair(box.main, account: Sandbox.accountA)
        let b = try box.pair(box.work, account: Sandbox.accountB)
        try box.write(#"{"v":1,"archived":["s1"]}"#, to: a.appending(path: "archived-sessions.idx"))
        _ = try box.sync()
        #expect(try archived(b) == ["s1"])

        try box.write(#"{"v":1,"archived":[]}"#, to: b.appending(path: "archived-sessions.idx"))
        _ = try box.sync()

        #expect(try archived(a) == [])
        #expect(try archived(b) == [])
    }
}
