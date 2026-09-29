import Foundation
import Testing

@testable import BatonKit

@Suite("IndexedDB values")
struct IndexedDBTests {
    /// Blink v21 with a zero trailer offset, then V8 v16: the headers measured on Claude's pin record.
    static let headers: [UInt8] = [0xFF, 0x15, 0xFE] + [UInt8](repeating: 0, count: 12) + [0xFF, 0x10]

    static func record(_ text: String) -> [UInt8] {
        var length = ByteWriter()
        length.appendVarint64(UInt64(text.utf8.count))
        return headers + [0x22] + length.bytes + Array(text.utf8)
    }

    @Test func encodeKeepsBlinkAndV8HeadersOfExistingRecord() throws {
        let existing = Self.record(#"{"state":{"starredIds":[]},"version":0}"#)
        let text = #"{"state":{"starredIds":["local_1","local_2"]},"updatedAt":1790000000000,"version":0}"# + String(repeating: "x", count: 200)
        let encoded = try #require(IDBValue.encode(text, like: existing))
        #expect(Array(encoded.prefix(Self.headers.count)) == Self.headers)
        #expect(encoded == Self.record(text), "one-byte string with a two-byte length after the same headers")
        #expect(IDBValue.string(in: encoded) == text)
        // A header without Blink's trailer is kept as it is too.
        let plain: [UInt8] = [0xFF, 0x0F, 0x22, 0x01, 0x61]
        #expect(IDBValue.encode("bc", like: plain) == [0xFF, 0x0F, 0x22, 0x02, 0x62, 0x63])
    }

    @Test func encodeRefusesNonZeroTrailer() {
        var existing = Self.record("[]")
        existing[5] = 0x40  // a trailer offset: something follows the value
        #expect(IDBValue.encode("[1]", like: existing) == nil)
        #expect(IDBValue.encode("[1]", like: [0xFF, 0x0F, 0x6F, 0x7B, 0x00]) == nil, "not one string")
    }

    @Test func encodeUsesTwoByteStringForNonLatin1() throws {
        let existing = Self.record("[]")
        let text = "Я b"
        let encoded = try #require(IDBValue.encode(text, like: existing))
        #expect(IDBValue.string(in: encoded) == text)
        let tag = try #require(encoded.firstIndex(of: 0x63))
        // Headers are 17 bytes; tag + one-byte length would put the characters at an odd offset, so V8 pads first.
        #expect(Array(encoded[Self.headers.count..<tag]) == [0x00])
        #expect((tag + 2) % 2 == 0, "the characters start at an even offset")
        #expect(Array(encoded[(tag + 1)...]) == [0x06, 0x2F, 0x04, 0x20, 0x00, 0x62, 0x00])
        // Without the need to pad, none is written, and an old padding byte is not kept.
        let even: [UInt8] = [0xFF, 0x0F, 0x00, 0x63, 0x02, 0x2F, 0x04]
        #expect(IDBValue.encode("Яb", like: even) == [0xFF, 0x0F, 0x63, 0x04, 0x2F, 0x04, 0x62, 0x00])
    }
}
