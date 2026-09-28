import Foundation
import Testing

@testable import BatonKit

@Suite("Account email")
struct AccountEmailTests {
    static let account = "cccccccc-dddd-4eee-8fff-000000000001"

    /// `Fixtures/IndexedDBEmailFixture` is a LevelDB database built with Homebrew leveldb by `make-fixture.cc`
    /// (dev-time only). Its one table is Snappy-compressed, and the profile record's account id and
    /// `email_address` are stored as back-references, so only a reader that decompresses the table finds them.
    @Test func emailFromSnappyCompressedLdb() throws {
        let fixture = Bundle.module.resourceURL!.appending(path: "Fixtures/IndexedDBEmailFixture", directoryHint: .isDirectory)
        let dataDir = FileManager.default.temporaryDirectory.appending(path: "email-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixture, to: dataDir)
        let table = dataDir.appending(path: "IndexedDB/https_claude.ai_0.indexeddb.leveldb/000005.ldb")
        #expect(
            DesktopData.email(inBlob: try Data(contentsOf: table), accountID: Self.account) == nil,
            "the fixture hides the profile from a byte scan")

        #expect(DesktopData.email(in: dataDir, accountID: Self.account) == "me@snappy.example")
        #expect(DesktopData.email(in: dataDir, accountID: "cccccccc-dddd-4eee-8fff-000000000002") == nil)
    }
}
